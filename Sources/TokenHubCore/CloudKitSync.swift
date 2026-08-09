import Foundation

#if canImport(CloudKit)
import CloudKit

/// Private CloudKit adapter. The container identifier is supplied by the app;
/// the placeholder is documentation-safe and is not a deployable credential.
public final class CloudKitSync: CloudSync, @unchecked Sendable {
    public struct Configuration: Hashable, Sendable {
        public let containerIdentifier: String

        public init(containerIdentifier: String) {
            self.containerIdentifier = containerIdentifier
        }

        public static let placeholder = Configuration(
            containerIdentifier: "iCloud.com.example.ContextGauge"
        )

        public var isPlaceholder: Bool {
            self == Self.placeholder
        }
    }

    public enum DatabaseScope: String, Sendable {
        case `private`
    }

    public let configuration: Configuration
    public let databaseScope: DatabaseScope = .private

    public init(configuration: Configuration) {
        self.configuration = configuration
    }

    private var database: CKDatabase {
        CKContainer(identifier: configuration.containerIdentifier).privateCloudDatabase
    }

    public func accounts(
        for provider: LiveQuotaProvider
    ) async throws -> [QuotaAccountProfile] {
        try await records(recordType: "QuotaAccount")
            .map(Self.account(from:))
            .filter { $0.provider == provider }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func createAccount(
        provider: LiveQuotaProvider,
        displayName: String
    ) async throws -> QuotaAccountProfile {
        let profile = QuotaAccountProfile.make(
            provider: provider,
            displayName: displayName
        )
        try await save([Self.record(for: profile)])
        return profile
    }

    public func reconcileDevice(
        _ envelope: DeviceSyncEnvelope
    ) async throws {
        guard
            envelope.dailyUsage.allSatisfy({
                $0.deviceID == envelope.device.id
            }),
            envelope.providerStatuses.allSatisfy({
                $0.deviceID == envelope.device.id
            })
        else {
            throw DeviceSyncEnvelopeError.mismatchedDeviceID
        }
        let existingDaily = try await records(
            recordType: "DailyUsage",
            predicate: NSPredicate(
                format: "deviceID == %@",
                envelope.device.id
            )
        )
        let existingStatuses = try await records(
            recordType: "ProviderStatus",
            predicate: NSPredicate(
                format: "deviceID == %@",
                envelope.device.id
            )
        )
        let dailyRecords = envelope.dailyUsage.map(Self.record(for:))
        let statusRecords = envelope.providerStatuses.map(Self.record(for:))
        let incomingIDs = Set(
            (dailyRecords + statusRecords).map(\.recordID)
        )
        let staleIDs = (existingDaily + existingStatuses)
            .map(\.recordID)
            .filter { !incomingIDs.contains($0) }
        try await delete(staleIDs)
        try await save(
            dailyRecords
                + statusRecords
                + [Self.record(for: envelope.device)]
        )
        try await upsertQuotaSnapshots(envelope.quotaSnapshots)
    }

    public func dashboardPayload(
        since day: Date
    ) async throws -> CloudSyncPayload {
        async let usage = records(
            recordType: "DailyUsage",
            predicate: NSPredicate(format: "day >= %@", day as NSDate)
        ).map(Self.dailyUsage(from:)).sorted(by: cloudDailyUsageOrder)
        async let quotas = quotaSnapshots()
        async let deviceRecords = devices()
        async let statuses = providerStatuses()
        return try await CloudSyncPayload(
            dailyUsage: usage,
            quotaSnapshots: quotas,
            devices: deviceRecords,
            providerStatuses: statuses
        )
    }

    public func upsertDailyUsage(_ usage: [DailyUsage]) async throws {
        try await save(usage.map(Self.record(for:)))
    }

    public func upsertQuotaSnapshots(_ snapshots: [QuotaSnapshot]) async throws {
        for snapshot in snapshots {
            try await upsert(snapshot, remainingAttempts: 3)
        }
    }

    public func upsertDevices(_ devices: [Device]) async throws {
        try await save(devices.map(Self.record(for:)))
    }

    public func upsertProviderStatuses(
        _ statuses: [LiveQuotaProviderStatus]
    ) async throws {
        try await save(statuses.map(Self.record(for:)))
    }

    public func dailyUsage() async throws -> [DailyUsage] {
        try await records(recordType: "DailyUsage")
            .map(Self.dailyUsage(from:))
            .sorted(by: cloudDailyUsageOrder)
    }

    public func quotaSnapshots() async throws -> [QuotaSnapshot] {
        let all = try await records(recordType: "QuotaSnapshot").map(Self.quota(from:))
        var latest: [QuotaSnapshotCloudKey: QuotaSnapshot] = [:]
        for snapshot in all {
            let key = QuotaSnapshotCloudKey(snapshot)
            if latest[key]?.capturedAt ?? .distantPast <= snapshot.capturedAt {
                latest[key] = snapshot
            }
        }
        return latest.values.sorted(by: cloudQuotaOrder)
    }

    public func devices() async throws -> [Device] {
        try await records(recordType: "Device")
            .map(Self.device(from:))
            .sorted(by: cloudDeviceOrder)
    }

    public func providerStatuses() async throws
        -> [LiveQuotaProviderStatus]
    {
        let all = try await records(recordType: "ProviderStatus")
            .map(Self.providerStatus(from:))
        var latest:
            [ProviderStatusCloudKey: LiveQuotaProviderStatus] = [:]
        for status in all {
            let key = ProviderStatusCloudKey(status)
            if latest[key]?.checkedAt ?? .distantPast <= status.checkedAt {
                latest[key] = status
            }
        }
        return latest.values.sorted(by: cloudProviderStatusOrder)
    }

    static func shouldReplaceQuota(
        existingCapturedAt: Date,
        incomingCapturedAt: Date
    ) -> Bool {
        incomingCapturedAt >= existingCapturedAt
    }

    static func batchSizes(
        itemCount: Int,
        limit: Int = 200
    ) -> [Int] {
        guard itemCount > 0, limit > 0 else { return [] }
        return stride(from: 0, to: itemCount, by: limit).map {
            min(limit, itemCount - $0)
        }
    }

    private func records(
        recordType: String,
        predicate: NSPredicate = NSPredicate(value: true)
    ) async throws -> [CKRecord] {
        var result: [CKRecord] = []
        let query = CKQuery(
            recordType: recordType,
            predicate: predicate
        )
        var page = try await database.records(matching: query)
        result.append(contentsOf: try page.matchResults.map { try $0.1.get() })
        while let cursor = page.queryCursor {
            page = try await database.records(continuingMatchFrom: cursor)
            result.append(contentsOf: try page.matchResults.map { try $0.1.get() })
        }
        return result
    }

    private func save(
        _ records: [CKRecord],
        policy: CKModifyRecordsOperation.RecordSavePolicy = .allKeys
    ) async throws {
        for start in stride(
            from: 0,
            to: records.count,
            by: Self.modifyBatchLimit
        ) {
            let end = min(start + Self.modifyBatchLimit, records.count)
            try await modify(
                saving: Array(records[start..<end]),
                deleting: [],
                policy: policy
            )
        }
    }

    private func delete(
        _ recordIDs: [CKRecord.ID]
    ) async throws {
        for start in stride(
            from: 0,
            to: recordIDs.count,
            by: Self.modifyBatchLimit
        ) {
            let end = min(
                start + Self.modifyBatchLimit,
                recordIDs.count
            )
            try await modify(
                saving: [],
                deleting: Array(recordIDs[start..<end]),
                policy: .allKeys
            )
        }
    }

    private func modify(
        saving records: [CKRecord],
        deleting recordIDs: [CKRecord.ID],
        policy: CKModifyRecordsOperation.RecordSavePolicy
    ) async throws {
        guard !records.isEmpty || !recordIDs.isEmpty else { return }
        try await withCheckedThrowingContinuation { continuation in
            let operation = CKModifyRecordsOperation(
                recordsToSave: records,
                recordIDsToDelete: recordIDs
            )
            operation.savePolicy = policy
            operation.isAtomic = false
            operation.modifyRecordsResultBlock = {
                continuation.resume(with: $0)
            }
            database.add(operation)
        }
    }

    private static let modifyBatchLimit = 200

    private func upsert(
        _ snapshot: QuotaSnapshot,
        remainingAttempts: Int
    ) async throws {
        let candidate = Self.record(for: snapshot)
        let record: CKRecord
        do {
            let existing = try await database.record(
                for: candidate.recordID
            )
            let capturedAt: Date = try Self.field(
                "capturedAt",
                in: existing
            )
            guard Self.shouldReplaceQuota(
                existingCapturedAt: capturedAt,
                incomingCapturedAt: snapshot.capturedAt
            ) else {
                return
            }
            Self.apply(snapshot, to: existing)
            record = existing
        } catch let error as CKError where error.code == .unknownItem {
            record = candidate
        }
        do {
            try await save([record], policy: .ifServerRecordUnchanged)
        } catch let error as CKError
            where error.code == .serverRecordChanged
                && remainingAttempts > 0
        {
            try await upsert(
                snapshot,
                remainingAttempts: remainingAttempts - 1
            )
        }
    }

    private static func record(for usage: DailyUsage) -> CKRecord {
        let name = stableName([usage.day.timeIntervalSince1970.description, usage.deviceID,
                               usage.source.rawValue, usage.provider, usage.model])
        let record = CKRecord(recordType: "DailyUsage", recordID: CKRecord.ID(recordName: name))
        record["day"] = usage.day
        record["deviceID"] = usage.deviceID
        record["source"] = usage.source.rawValue
        record["provider"] = usage.provider
        record["model"] = usage.model
        record["inputTokens"] = usage.inputTokens
        record["outputTokens"] = usage.outputTokens
        record["cacheReadTokens"] = usage.cacheReadTokens
        record["cacheWriteTokens"] = usage.cacheWriteTokens
        record["totalTokens"] = usage.totalTokens
        record["estimatedCostUSD"] = NSDecimalNumber(decimal: usage.estimatedCostUSD)
        record["eventCount"] = usage.eventCount
        record["isCostComplete"] = usage.isCostComplete
        return record
    }

    private static func record(for profile: QuotaAccountProfile) -> CKRecord {
        let record = CKRecord(
            recordType: "QuotaAccount",
            recordID: CKRecord.ID(recordName: "QuotaAccount-\(profile.id)")
        )
        record["pseudonym"] = profile.id
        record["provider"] = profile.provider.rawValue
        record["displayName"] = profile.displayName
        record["createdAt"] = profile.createdAt
        return record
    }

    private static func record(for quota: QuotaSnapshot) -> CKRecord {
        let name = stableName([quota.provider, quota.accountPseudonym, quota.windowKind])
        let record = CKRecord(recordType: "QuotaSnapshot", recordID: CKRecord.ID(recordName: name))
        apply(quota, to: record)
        return record
    }

    private static func apply(
        _ quota: QuotaSnapshot,
        to record: CKRecord
    ) {
        record["provider"] = quota.provider
        record["accountHash"] = quota.accountPseudonym
        record["capturedAt"] = quota.capturedAt
        record["windowKind"] = quota.windowKind
        record["usedPercent"] = NSDecimalNumber(decimal: quota.usedPercent)
        record["resetsAt"] = quota.resetsAt
        record["source"] = quota.source
    }

    private static func record(for device: Device) -> CKRecord {
        let record = CKRecord(
            recordType: "Device",
            recordID: CKRecord.ID(recordName: stableName([device.id]))
        )
        record["deviceID"] = device.id
        record["name"] = device.name
        record["lastCollectedAt"] = device.lastCollectedAt
        record["lastSyncedAt"] = device.lastSyncedAt
        return record
    }

    private static func record(
        for status: LiveQuotaProviderStatus
    ) -> CKRecord {
        let name = stableName([
            status.deviceID,
            status.provider.rawValue,
        ])
        let record = CKRecord(
            recordType: "ProviderStatus",
            recordID: CKRecord.ID(recordName: name)
        )
        record["deviceID"] = status.deviceID
        record["provider"] = status.provider.rawValue
        record["accountPseudonym"] = status.accountPseudonym
        record["freshness"] = status.freshness.rawValue
        record["checkedAt"] = status.checkedAt
        record["capturedAt"] = status.capturedAt
        record["errorCode"] = status.errorCode
        return record
    }

    private static func dailyUsage(from record: CKRecord) throws -> DailyUsage {
        DailyUsage(
            day: try field("day", in: record), deviceID: try field("deviceID", in: record),
            source: try UsageSource(rawValue: field("source", in: record)).required("source"),
            provider: try field("provider", in: record), model: try field("model", in: record),
            inputTokens: try field("inputTokens", in: record), outputTokens: try field("outputTokens", in: record),
            cacheReadTokens: try field("cacheReadTokens", in: record), cacheWriteTokens: try field("cacheWriteTokens", in: record),
            totalTokens: try field("totalTokens", in: record),
            estimatedCostUSD: try decimalField("estimatedCostUSD", in: record),
            eventCount: try field("eventCount", in: record),
            isCostComplete: (record["isCostComplete"] as? NSNumber)?.boolValue
                ?? true
        )
    }

    private static func account(
        from record: CKRecord
    ) throws -> QuotaAccountProfile {
        guard
            let provider = LiveQuotaProvider(
                rawValue: try field("provider", in: record)
            )
        else {
            throw MissingField(name: "provider")
        }
        return QuotaAccountProfile(
            id: try field("pseudonym", in: record),
            provider: provider,
            displayName: try field("displayName", in: record),
            createdAt: try field("createdAt", in: record)
        )
    }

    private static func quota(from record: CKRecord) throws -> QuotaSnapshot {
        QuotaSnapshot(
            provider: try field("provider", in: record),
            accountPseudonym: try field("accountHash", in: record),
            capturedAt: try field("capturedAt", in: record), windowKind: try field("windowKind", in: record),
            usedPercent: try decimalField("usedPercent", in: record), resetsAt: record["resetsAt"] as? Date,
            source: try field("source", in: record)
        )
    }

    private static func device(from record: CKRecord) throws -> Device {
        Device(
            id: try field("deviceID", in: record),
            name: try field("name", in: record),
            lastCollectedAt: record["lastCollectedAt"] as? Date,
            lastSyncedAt: record["lastSyncedAt"] as? Date
        )
    }

    private static func providerStatus(
        from record: CKRecord
    ) throws -> LiveQuotaProviderStatus {
        guard
            let provider = LiveQuotaProvider(
                rawValue: try field("provider", in: record)
            ),
            let freshness = LiveQuotaFreshness(
                rawValue: try field("freshness", in: record)
            )
        else {
            throw MissingField(name: "providerStatus")
        }
        return LiveQuotaProviderStatus(
            deviceID: try field("deviceID", in: record),
            provider: provider,
            accountPseudonym: record["accountPseudonym"] as? String,
            freshness: freshness,
            checkedAt: try field("checkedAt", in: record),
            capturedAt: record["capturedAt"] as? Date,
            errorCode: record["errorCode"] as? String
        )
    }

    private static func field<T>(_ name: String, in record: CKRecord) throws -> T {
        try (record[name] as? T).required(name)
    }

    private static func decimalField(_ name: String, in record: CKRecord) throws -> Decimal {
        try (record[name] as? NSNumber).required(name).decimalValue
    }

    private static func stableName(_ components: [String]) -> String {
        Data(components.joined(separator: "\u{1F}").utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
    }

    fileprivate struct MissingField: Error { let name: String }
}

private extension Optional {
    func required(_ name: String) throws -> Wrapped {
        guard let self else { throw CloudKitSync.MissingField(name: name) }
        return self
    }
}
#endif
