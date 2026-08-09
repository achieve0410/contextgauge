import Foundation
import OSLog
import ServiceManagement
import TokenHubMacCore

#if DEBUG
private let qaHighQuotaArgument = "--qa-high-quota"
private let qaDatabaseArgument = "--qa-database"
#endif

private func defaultMacConfiguration() throws -> LocalUsageConfiguration {
    #if DEBUG
    let arguments = ProcessInfo.processInfo.arguments
    if arguments.contains(qaHighQuotaArgument),
       let index = arguments.firstIndex(of: qaDatabaseArgument),
       arguments.indices.contains(index + 1)
    {
        return LocalUsageConfiguration(
            databaseURL: URL(fileURLWithPath: arguments[index + 1]),
            deviceID: "native-qa-mac",
            deviceName: "Native QA Mac",
            roots: [:],
            parserVersion: 2
        )
    }
    #endif
    return try LocalUsageConfiguration.systemDefault()
}

private func defaultMacLiveQuotaRefresh(
    providers: [LiveQuotaProvider: String],
    deviceID: String,
    previousSnapshots: [QuotaSnapshot]
) async -> LiveQuotaRefreshReport {
    #if DEBUG
    if ProcessInfo.processInfo.arguments.contains(qaHighQuotaArgument),
       providers[.codex] != nil
    {
        let capturedAt = Date.now
        return LiveQuotaRefreshReport(
            snapshots: [
                QuotaSnapshot(
                    provider: "codex",
                    accountPseudonym: providers[.codex]
                        ?? "native-qa-account",
                    capturedAt: capturedAt,
                    windowKind: "5-hour",
                    usedPercent: 85,
                    resetsAt: capturedAt.addingTimeInterval(3_600),
                    source: "qa-fixture"
                ),
            ],
            statuses: [
                LiveQuotaProviderStatus(
                    deviceID: deviceID,
                    provider: .codex,
                    accountPseudonym: providers[.codex],
                    freshness: .fresh,
                    checkedAt: capturedAt,
                    capturedAt: capturedAt,
                    errorCode: nil
                ),
                LiveQuotaProviderStatus(
                    deviceID: deviceID,
                    provider: .claude,
                    accountPseudonym: providers[.claude],
                    freshness: .error,
                    checkedAt: capturedAt,
                    capturedAt: nil,
                    errorCode: "credentials-unavailable"
                ),
            ]
        )
    }
    #endif
    return await LiveQuotaRefreshCoordinator().refresh(
        providers: providers,
        deviceID: deviceID,
        previousSnapshots: previousSnapshots
    )
}

struct ProviderQuotaSelection: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var accountPseudonym: String?

    static let disabled = Self(
        isEnabled: false,
        accountPseudonym: nil
    )
}

@MainActor
protocol ProviderQuotaPreferences: AnyObject {
    func selection(
        for provider: LiveQuotaProvider
    ) -> ProviderQuotaSelection
    func setSelection(
        _ selection: ProviderQuotaSelection,
        for provider: LiveQuotaProvider
    )
}

@MainActor
final class UserDefaultsProviderQuotaPreferences:
    ProviderQuotaPreferences
{
    private let defaults: UserDefaults
    private let keyPrefix = "TokenHub.providerQuota."

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func selection(
        for provider: LiveQuotaProvider
    ) -> ProviderQuotaSelection {
        let key = keyPrefix + provider.rawValue
        guard
            let data = defaults.data(forKey: key),
            let selection = try? JSONDecoder().decode(
                ProviderQuotaSelection.self,
                from: data
            )
        else {
            return .disabled
        }
        return selection
    }

    func setSelection(
        _ selection: ProviderQuotaSelection,
        for provider: LiveQuotaProvider
    ) {
        let key = keyPrefix + provider.rawValue
        if let data = try? JSONEncoder().encode(selection) {
            defaults.set(data, forKey: key)
        }
    }
}

@MainActor
final class MacDashboardController: ObservableObject {
    @Published var period = DashboardPeriod.today
    @Published var selectedDeviceID: String?
    @Published private(set) var snapshot: DashboardSnapshot?
    @Published private(set) var liveQuotaStatuses: [LiveQuotaProviderStatus] = []
    @Published private(set) var quotaWarnings: [QuotaThresholdWarning] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var refreshError: String?
    @Published private(set) var quotaSelections:
        [LiveQuotaProvider: ProviderQuotaSelection]
    @Published private(set) var quotaAccounts:
        [LiveQuotaProvider: [QuotaAccountProfile]] = [:]
    @Published private(set) var quotaSetupErrors:
        [LiveQuotaProvider: String] = [:]
    @Published private(set) var launchAtLogin =
        SMAppService.mainApp.status == .enabled
    private let configurationProvider: () throws -> LocalUsageConfiguration
    private let cloudSyncProvider: () -> (any CloudSync)?
    private let quotaPreferences: any ProviderQuotaPreferences
    private let liveQuotaRefreshProvider:
        @Sendable (
            [LiveQuotaProvider: String],
            String,
            [QuotaSnapshot]
        ) async -> LiveQuotaRefreshReport
    private let quotaWarningSink:
        @Sendable (QuotaThresholdWarning) async -> Void
    private var deliveredQuotaWarningIDs: Set<String> = []
    private var hasStarted = false
    private let logger = Logger(
        subsystem: "com.example.contextgauge.mac",
        category: "startup"
    )

    init(
        configurationProvider: @escaping () throws -> LocalUsageConfiguration = {
            try defaultMacConfiguration()
        },
        cloudSyncProvider: @escaping () -> (any CloudSync)? = {
            guard
                let identifier = Bundle.main.object(
                    forInfoDictionaryKey: "TokenHubCloudContainerIdentifier"
                ) as? String
            else {
                return nil
            }
            let configuration = CloudKitSync.Configuration(
                containerIdentifier: identifier
            )
            guard !configuration.isPlaceholder else { return nil }
            return CloudKitSync(configuration: configuration)
        },
        quotaPreferences: any ProviderQuotaPreferences =
            UserDefaultsProviderQuotaPreferences(),
        liveQuotaRefreshProvider: @escaping @Sendable (
            [LiveQuotaProvider: String],
            String,
            [QuotaSnapshot]
        ) async -> LiveQuotaRefreshReport = {
            await defaultMacLiveQuotaRefresh(
                providers: $0,
                deviceID: $1,
                previousSnapshots: $2
            )
        },
        quotaWarningSink: @escaping @Sendable (
            QuotaThresholdWarning
        ) async -> Void = { _ in
        }
    ) {
        self.configurationProvider = configurationProvider
        self.cloudSyncProvider = cloudSyncProvider
        self.quotaPreferences = quotaPreferences
        var restoredSelections = Dictionary(
            uniqueKeysWithValues: LiveQuotaProvider.allCases.map {
                ($0, quotaPreferences.selection(for: $0))
            }
        )
        self.liveQuotaRefreshProvider = liveQuotaRefreshProvider
        self.quotaWarningSink = quotaWarningSink

        let usesLocalProfiles = cloudSyncProvider() == nil
        var restoredAccounts:
            [LiveQuotaProvider: [QuotaAccountProfile]] = [:]
        for provider in LiveQuotaProvider.allCases {
            var selection = restoredSelections[provider] ?? .disabled
            if usesLocalProfiles,
               selection.isEnabled,
               selection.accountPseudonym == nil
            {
                let profile = Self.localQuotaProfile(
                    id: nil,
                    provider: provider
                )
                selection.accountPseudonym = profile.id
                restoredSelections[provider] = selection
                restoredAccounts[provider] = [profile]
                quotaPreferences.setSelection(
                    selection,
                    for: provider
                )
            } else if let id = selection.accountPseudonym {
                restoredAccounts[provider] = [
                    Self.localQuotaProfile(
                        id: id,
                        provider: provider
                    ),
                ]
            }
        }
        quotaSelections = restoredSelections
        quotaAccounts = restoredAccounts
    }

    var viewModel: DashboardViewModel {
        DashboardViewModel(
            snapshot: snapshot ?? Self.emptySnapshot,
            period: period,
            deviceID: selectedDeviceID
        )
    }

    var menuBarTokenLabel: String {
        viewModel.totalTokens.formatted(.number.notation(.compactName))
    }

    func quotaSelection(
        for provider: LiveQuotaProvider
    ) -> ProviderQuotaSelection {
        quotaSelections[provider] ?? .disabled
    }

    func setQuotaEnabled(
        _ isEnabled: Bool,
        for provider: LiveQuotaProvider
    ) {
        var selection = quotaSelection(for: provider)
        selection.isEnabled = isEnabled
        quotaSelections[provider] = selection
        quotaPreferences.setSelection(selection, for: provider)
    }

    func updateQuotaEnabled(
        _ isEnabled: Bool,
        for provider: LiveQuotaProvider
    ) async {
        guard isEnabled else {
            setQuotaEnabled(false, for: provider)
            quotaSetupErrors[provider] = nil
            return
        }
        guard let cloudSync = cloudSyncProvider() else {
            selectLocalQuotaAccount(for: provider)
            return
        }
        do {
            var profiles = try await cloudSync.accounts(for: provider)
            let profile: QuotaAccountProfile
            if let selected = quotaSelection(for: provider).accountPseudonym,
               let existing = profiles.first(where: { $0.id == selected })
            {
                profile = existing
            } else if let existing = profiles.first {
                profile = existing
            } else {
                profile = try await cloudSync.createAccount(
                    provider: provider,
                    displayName: "Personal"
                )
                profiles.append(profile)
            }
            quotaAccounts[provider] = profiles
            setQuotaAccount(profile.id, for: provider)
            setQuotaEnabled(true, for: provider)
            quotaSetupErrors[provider] = nil
        } catch {
            selectLocalQuotaAccount(for: provider)
        }
    }

    func createAndSelectQuotaAccount(
        for provider: LiveQuotaProvider
    ) async {
        guard let cloudSync = cloudSyncProvider() else {
            selectLocalQuotaAccount(for: provider)
            return
        }
        do {
            let profile = try await cloudSync.createAccount(
                provider: provider,
                displayName: "Account "
                    + String((quotaAccounts[provider]?.count ?? 0) + 1)
            )
            quotaAccounts[provider, default: []].append(profile)
            setQuotaAccount(profile.id, for: provider)
            setQuotaEnabled(true, for: provider)
            quotaSetupErrors[provider] = nil
        } catch {
            selectLocalQuotaAccount(for: provider)
        }
    }

    private func selectLocalQuotaAccount(
        for provider: LiveQuotaProvider
    ) {
        let existingID = quotaSelection(for: provider).accountPseudonym
        let profile = Self.localQuotaProfile(
            id: existingID,
            provider: provider
        )
        quotaAccounts[provider] = [profile]
        setQuotaAccount(profile.id, for: provider)
        setQuotaEnabled(true, for: provider)
        quotaSetupErrors[provider] = nil
    }

    private static func localQuotaProfile(
        id: String?,
        provider: LiveQuotaProvider
    ) -> QuotaAccountProfile {
        guard let id else {
            return QuotaAccountProfile.make(
                provider: provider,
                displayName: "Local"
            )
        }
        return QuotaAccountProfile(
            id: id,
            provider: provider,
            displayName: "Local",
            createdAt: .distantPast
        )
    }

    func setQuotaAccount(
        _ accountPseudonym: String?,
        for provider: LiveQuotaProvider
    ) {
        var selection = quotaSelection(for: provider)
        selection.accountPseudonym = accountPseudonym
        quotaSelections[provider] = selection
        quotaPreferences.setSelection(selection, for: provider)
    }

    func setPeriodFromView(_ period: DashboardPeriod) {
        DispatchQueue.main.async {
            self.period = period
        }
    }

    func setSelectedDeviceFromView(_ deviceID: String?) {
        DispatchQueue.main.async {
            self.selectedDeviceID = deviceID
        }
    }

    func refreshAfterViewUpdate() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
        await refresh()
    }

    func startIfNeeded() async {
        guard !hasStarted else { return }
        hasStarted = true
        logger.notice("TOKENHUB_MAC_STARTUP_REFRESH_STARTED")
        await refresh()
        if refreshError == nil {
            logger.notice("TOKENHUB_MAC_STARTUP_REFRESH_READY")
        } else {
            logger.error("TOKENHUB_MAC_STARTUP_REFRESH_FAILED")
        }
    }

    func refresh() async {
        isRefreshing = true
        refreshError = nil
        defer { isRefreshing = false }
        do {
            let configuration = try configurationProvider()
            let collected = try await Task.detached(priority: .userInitiated) {
                try LocalUsageService(configuration: configuration).collect()
            }.value
            let enabledProviders = quotaSelections.reduce(
                into: [LiveQuotaProvider: String]()
            ) { result, pair in
                let (provider, selection) = pair
                guard
                    selection.isEnabled,
                    let accountPseudonym = selection.accountPseudonym
                else {
                    return
                }
                result[provider] = accountPseudonym
            }
            let quotaReport = await liveQuotaRefreshProvider(
                enabledProviders,
                configuration.deviceID,
                collected.quotaSnapshots
            )
            liveQuotaStatuses = quotaReport.statuses
            let withLiveQuota = Self.mergingQuota(
                quotaReport.snapshots,
                into: collected
            )
            try await Task.detached(priority: .utility) {
                let service = try LocalUsageService(
                    configuration: configuration
                )
                try service.persistQuotaSnapshots(
                    withLiveQuota.quotaSnapshots
                )
            }.value
            snapshot = withLiveQuota
            let warnings = QuotaThresholdEvaluator.warnings(
                snapshots: quotaReport.snapshots
            )
            quotaWarnings = warnings
            for warning in warnings
            where deliveredQuotaWarningIDs.insert(warning.id).inserted {
                await quotaWarningSink(warning)
            }
            guard let sync = cloudSyncProvider() else { return }
            do {
                let synchronized = try await AggregateSyncUploader(sync: sync)
                    .upload(
                        withLiveQuota,
                        currentDeviceID: configuration.deviceID,
                        historySince:
                            DashboardHistoryWindow.earliestRequiredDay(),
                        providerStatuses: liveQuotaStatuses
                    )
                try await Task.detached(priority: .utility) {
                    let service = try LocalUsageService(
                        configuration: configuration
                    )
                    try service.persistSynchronizedSnapshot(synchronized)
                }.value
                snapshot = synchronized
            } catch {
                refreshError = "cloud-sync-failed"
            }
        } catch {
            refreshError = String(describing: error)
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
        } catch {
            refreshError = "login-item: \(error)"
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    private static let emptySnapshot = DashboardSnapshot(
        dailyUsage: [],
        quotaSnapshots: [],
        devices: [],
        collectorStatuses: []
    )

    private static func mergingQuota(
        _ liveSnapshots: [QuotaSnapshot],
        into snapshot: DashboardSnapshot
    ) -> DashboardSnapshot {
        struct Key: Hashable {
            let provider: String
        let accountPseudonym: String
            let windowKind: String
        }
        var latest = Dictionary(
            uniqueKeysWithValues: snapshot.quotaSnapshots.map {
                (
                    Key(
                        provider: $0.provider,
                accountPseudonym: $0.accountPseudonym,
                        windowKind: $0.windowKind
                    ),
                    $0
                )
            }
        )
        for quota in liveSnapshots {
            latest[
                Key(
                    provider: quota.provider,
                accountPseudonym: quota.accountPseudonym,
                    windowKind: quota.windowKind
                )
            ] = quota
        }
        let quotas = latest.values.sorted {
            ($0.provider, $0.windowKind, $0.capturedAt)
                < ($1.provider, $1.windowKind, $1.capturedAt)
        }
        return DashboardSnapshot(
            dailyUsage: snapshot.dailyUsage,
            quotaSnapshots: quotas,
            devices: snapshot.devices,
            collectorStatuses: snapshot.collectorStatuses
        )
    }
}
