import Foundation

public struct LocalUsageConfiguration: Sendable {
    public let databaseURL: URL
    public let deviceID: String
    public let deviceName: String
    public let roots: [UsageSource: URL]
    public let parserVersion: Int
    public let additionalRoots: [UsageSource: [URL]]

    public init(
        databaseURL: URL,
        deviceID: String,
        deviceName: String,
        roots: [UsageSource: URL],
        parserVersion: Int,
        additionalRoots: [UsageSource: [URL]] = [:]
    ) {
        self.databaseURL = databaseURL
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.roots = roots
        self.parserVersion = parserVersion
        self.additionalRoots = additionalRoots
    }

    public static func systemDefault(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LocalUsageConfiguration {
        let home = fileManager.homeDirectoryForCurrentUser
        let codexRoot = environment["CODEX_HOME"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
                .appending(path: "sessions", directoryHint: .isDirectory)
        } ?? home.appending(path: ".codex/sessions")
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appending(path: "TokenHub", directoryHint: .isDirectory)
        try fileManager.createDirectory(at: support, withIntermediateDirectories: true)
        let host = Host.current().localizedName ?? "Mac"
        let deviceID = try loadOrCreateDeviceIdentifier(
            at: support.appending(path: "device-id")
        )
        return LocalUsageConfiguration(
            databaseURL: support.appending(path: "usage.sqlite"),
            deviceID: deviceID,
            deviceName: host,
            roots: [
                .senpi: home.appending(path: ".senpi/agent/sessions"),
                .codex: codexRoot,
                .claude: home.appending(path: ".claude/projects"),
            ],
            parserVersion: 2,
            additionalRoots: [
                .senpi: [home.appending(path: ".omo/sessions")],
            ]
        )
    }

    static func loadOrCreateDeviceIdentifier(at url: URL) throws -> String {
        if let stored = try? String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           let identifier = UUID(uuidString: stored)
        {
            return identifier.uuidString.lowercased()
        }
        let identifier = UUID().uuidString.lowercased()
        try Data("\(identifier)\n".utf8).write(to: url, options: .atomic)
        return identifier
    }
}

public final class LocalUsageService {
    private let configuration: LocalUsageConfiguration
    private let store: SQLiteUsageStore

    public init(configuration: LocalUsageConfiguration) throws {
        self.configuration = configuration
        store = try SQLiteUsageStore(databaseURL: configuration.databaseURL)
    }

    public func collect(now: Date = .now) throws -> DashboardSnapshot {
        var statuses: [CollectorStatus] = []
        for source in UsageSource.allCases {
            guard let root = configuration.roots[source] else { continue }
            var errorCode: String?
            do {
                let files = try jsonlFiles(
                    at: [root]
                        + (configuration.additionalRoots[source] ?? [])
                )
                for file in files {
                    let result = try scan(file, source: source)
                    if !result.diagnostics.isEmpty {
                        errorCode = "malformed-row"
                    }
                }
            } catch RootAvailabilityError.rootMissing {
                errorCode = "root-missing"
            } catch RootAvailabilityError.noJSONLFiles {
                errorCode = "no-jsonl-files"
            } catch {
                errorCode = "collection-failed"
            }
            let wasSuccessful =
                errorCode == nil || errorCode == "malformed-row"
            statuses.append(
                CollectorStatus(
                    source: source,
                    lastSuccessfulCollectionAt: wasSuccessful ? now : nil,
                    errorCode: errorCode
                )
            )
        }
        let events = try store.usageEvents()
        let aggregation = Self.aggregate(events, calendar: .current)
        var locallyRebuiltDeviceIDs = Set(events.map(\.deviceID))
        locallyRebuiltDeviceIDs.insert(configuration.deviceID)
        let aggregateOnlyUsage = try store.dailyUsage().filter {
            !locallyRebuiltDeviceIDs.contains($0.deviceID)
        }
        let allUsage = (aggregation.usage + aggregateOnlyUsage).sorted {
            ($0.day, $0.deviceID, $0.source.rawValue, $0.provider, $0.model)
                < ($1.day, $1.deviceID, $1.source.rawValue, $1.provider, $1.model)
        }
        try store.replaceDailyUsage(allUsage)
        let previousSync = try store.devices()
            .first(where: { $0.id == configuration.deviceID })?
            .lastSyncedAt
        try store.upsertDevices([
            Device(
                id: configuration.deviceID,
                name: configuration.deviceName,
                lastCollectedAt: now,
                lastSyncedAt: previousSync
            ),
        ])
        for source in aggregation.incompleteSources
        where !statuses.contains(where: { $0.source == source && $0.errorCode != nil }) {
            statuses.append(
                CollectorStatus(
                    source: source,
                    lastSuccessfulCollectionAt: now,
                    errorCode: "pricing-incomplete"
                )
            )
        }
        return DashboardSnapshot(
            dailyUsage: allUsage,
            quotaSnapshots: try store.quotaSnapshots(),
            devices: try store.devices(),
            collectorStatuses: statuses
        )
    }

    public func persistSynchronizedSnapshot(
        _ snapshot: DashboardSnapshot
    ) throws {
        try store.replaceDailyUsage(snapshot.dailyUsage)
        try store.replaceQuotaSnapshots(snapshot.quotaSnapshots)
        try store.upsertDevices(snapshot.devices)
    }

    public func persistQuotaSnapshots(
        _ snapshots: [QuotaSnapshot]
    ) throws {
        try store.replaceQuotaSnapshots(snapshots)
    }

    private func scan(
        _ file: URL,
        source: UsageSource
    ) throws -> CollectionScanResult {
        let coordinator = CollectionCoordinator(
            store: store,
            parserVersion: configuration.parserVersion,
            includeAggregateTotal: false
        )
        switch source {
        case .senpi:
            return try coordinator.scan(
                fileURL: file,
                collector: SenpiUsageCollector(deviceID: configuration.deviceID)
            )
        case .codex:
            return try coordinator.scan(
                fileURL: file,
                collector: CodexUsageCollector(deviceID: configuration.deviceID)
            )
        case .claude:
            return try coordinator.scan(
                fileURL: file,
                collector: ClaudeUsageCollector(deviceID: configuration.deviceID)
            )
        }
    }

    private func jsonlFiles(at roots: [URL]) throws -> [URL] {
        var files = Set<URL>()
        var hasAvailableRoot = false
        for root in roots {
            do {
                let rootFiles = try jsonlFiles(at: root)
                hasAvailableRoot = true
                files.formUnion(rootFiles)
            } catch RootAvailabilityError.rootMissing {
                continue
            }
        }
        guard hasAvailableRoot else {
            throw RootAvailabilityError.rootMissing
        }
        guard !files.isEmpty else {
            throw RootAvailabilityError.noJSONLFiles
        }
        return files.sorted { $0.path < $1.path }
    }

    private func jsonlFiles(at root: URL) throws -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: root.path,
            isDirectory: &isDirectory
        ) else {
            throw RootAvailabilityError.rootMissing
        }
        if !isDirectory.boolValue {
            return root.pathExtension == "jsonl" ? [root] : []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }
        return enumerator.compactMap { item -> URL? in
            guard let url = item as? URL, url.pathExtension == "jsonl" else {
                return nil
            }
            return url
        }.sorted { $0.path < $1.path }
    }

    private enum RootAvailabilityError: Error {
        case rootMissing
        case noJSONLFiles
    }

    private static func aggregate(
        _ events: [UsageEvent],
        calendar: Calendar
    ) -> (usage: [DailyUsage], incompleteSources: Set<UsageSource>) {
        struct Key: Hashable {
            let day: Date
            let deviceID: String
            let source: UsageSource
            let provider: String
            let model: String
        }
        struct Totals {
            var input = 0
            var output = 0
            var cacheRead = 0
            var cacheWrite = 0
            var total = 0
            var cost = Decimal.zero
            var count = 0
            var isCostComplete = true
        }
        var grouped: [Key: Totals] = [:]
        var incomplete = Set<UsageSource>()
        for event in events {
            let key = Key(
                day: calendar.startOfDay(for: event.occurredAt),
                deviceID: event.deviceID,
                source: event.source,
                provider: event.provider,
                model: event.model
            )
            var totals = grouped[key, default: Totals()]
            totals.input += event.inputTokens
            totals.output += event.outputTokens
            totals.cacheRead += event.cacheReadTokens
            totals.cacheWrite += event.cacheWriteTokens
            totals.total += event.totalTokens
            totals.count += 1
            if let cost = event.estimatedCostUSD {
                totals.cost += cost
            } else {
                incomplete.insert(event.source)
                totals.isCostComplete = false
            }
            grouped[key] = totals
        }
        let usage = grouped.map { key, totals in
            DailyUsage(
                day: key.day,
                deviceID: key.deviceID,
                source: key.source,
                provider: key.provider,
                model: key.model,
                inputTokens: totals.input,
                outputTokens: totals.output,
                cacheReadTokens: totals.cacheRead,
                cacheWriteTokens: totals.cacheWrite,
                totalTokens: totals.total,
                estimatedCostUSD: totals.cost,
                eventCount: totals.count,
                isCostComplete: totals.isCostComplete
            )
        }
        return (
            usage.sorted {
                ($0.day, $0.deviceID, $0.source.rawValue, $0.provider, $0.model)
                    < ($1.day, $1.deviceID, $1.source.rawValue, $1.provider, $1.model)
            },
            incomplete
        )
    }
}
