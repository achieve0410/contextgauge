import Foundation

public enum ReadOnlyDashboardEmptyState: Hashable, Sendable {
    case cloudUnavailable
    case providerFailure
    case noCloudUsage
    case noUsageForSelection
}

public struct ReadOnlyDashboardViewModel: Sendable {
    public let dashboard: DashboardViewModel
    public let availableDeviceIDs: [String]
    public let availableProviders: [String]
    public let availableModels: [String]
    public let providerStatuses: [LiveQuotaProviderStatus]
    public let emptyState: ReadOnlyDashboardEmptyState?
    public let isReadOnly = true
    public let canCollectLocalLogs = false
    public let canAuthenticateProviders = false
    public let canWriteCloudAggregates = false

    public init(
        payload: CloudSyncPayload?,
        fetchedAt: Date?,
        period: DashboardPeriod,
        deviceID: String?,
        provider: String? = nil,
        model: String? = nil,
        now: Date = .now,
        calendar: Calendar = .current
    ) {
        let usage = payload?.dailyUsage ?? []
        availableDeviceIDs = Set(usage.map(\.deviceID)).sorted()
        availableProviders = Set(usage.map(\.provider)).sorted()
        availableModels = Set(
            usage
                .filter { provider == nil || $0.provider == provider }
                .map(\.model)
        ).sorted()
        let filteredUsage = usage.filter {
            (provider == nil || $0.provider == provider)
                && (model == nil || $0.model == model)
        }
        providerStatuses = payload?.providerStatuses ?? []
        let activePseudonyms = Set(
            providerStatuses.compactMap(\.accountPseudonym)
        )
        let filteredQuotas = (payload?.quotaSnapshots ?? []).filter {
            (provider == nil || $0.provider == provider)
                && (
                    activePseudonyms.isEmpty
                        || activePseudonyms.contains($0.accountPseudonym)
                )
        }
        let cloudDevices = payload?.devices ?? []
        let devices = availableDeviceIDs.map { id in
            cloudDevices.first(where: { $0.id == id })
                ?? Device(
                    id: id,
                    name: id,
                    lastCollectedAt: nil,
                    lastSyncedAt: fetchedAt
                )
        }
        dashboard = DashboardViewModel(
            snapshot: DashboardSnapshot(
                dailyUsage: filteredUsage,
                quotaSnapshots: filteredQuotas,
                devices: devices,
                collectorStatuses: []
            ),
            period: period,
            deviceID: deviceID,
            now: now,
            calendar: calendar
        )
        if payload == nil {
            emptyState = .cloudUnavailable
        } else if usage.isEmpty,
                  providerStatuses.contains(where: {
                      $0.freshness == .error
                          || $0.freshness == .unavailable
                  })
        {
            emptyState = .providerFailure
        } else if usage.isEmpty {
            emptyState = .noCloudUsage
        } else if dashboard.rows.isEmpty {
            emptyState = .noUsageForSelection
        } else {
            emptyState = nil
        }
    }
}
