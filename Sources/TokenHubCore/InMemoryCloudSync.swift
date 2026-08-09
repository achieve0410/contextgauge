import Foundation

/// A deterministic CloudSync implementation for tests and local composition.
public actor InMemoryCloudSync: CloudSync {
    private var usageByKey: [DailyUsageCloudKey: DailyUsage] = [:]
    private var quotaByKey: [QuotaSnapshotCloudKey: QuotaSnapshot] = [:]
    private var deviceByID: [String: Device] = [:]
    private var accountByID: [String: QuotaAccountProfile] = [:]
    private var statusByKey:
        [ProviderStatusCloudKey: LiveQuotaProviderStatus] = [:]

    public init() {}

    public func accounts(
        for provider: LiveQuotaProvider
    ) -> [QuotaAccountProfile] {
        accountByID.values
            .filter { $0.provider == provider }
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    public func createAccount(
        provider: LiveQuotaProvider,
        displayName: String
    ) -> QuotaAccountProfile {
        let profile = QuotaAccountProfile.make(
            provider: provider,
            displayName: displayName
        )
        accountByID[profile.id] = profile
        return profile
    }

    public func reconcileDevice(
        _ envelope: DeviceSyncEnvelope
    ) throws {
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
        usageByKey = usageByKey.filter {
            $0.key.deviceID != envelope.device.id
        }
        statusByKey = statusByKey.filter {
            $0.key.deviceID != envelope.device.id
        }
        upsertDailyUsage(envelope.dailyUsage)
        upsertQuotaSnapshots(envelope.quotaSnapshots)
        upsertDevices([envelope.device])
        upsertProviderStatuses(envelope.providerStatuses)
    }

    public func dashboardPayload(
        since day: Date
    ) -> CloudSyncPayload {
        CloudSyncPayload(
            dailyUsage: usageByKey.values
                .filter { $0.day >= day }
                .sorted(by: cloudDailyUsageOrder),
            quotaSnapshots: quotaByKey.values.sorted(by: cloudQuotaOrder),
            devices: deviceByID.values.sorted(by: cloudDeviceOrder),
            providerStatuses: statusByKey.values.sorted(
                by: cloudProviderStatusOrder
            )
        )
    }

    public func upsertDailyUsage(_ usage: [DailyUsage]) {
        for aggregate in usage {
            usageByKey[DailyUsageCloudKey(aggregate)] = aggregate
        }
    }

    public func upsertQuotaSnapshots(_ snapshots: [QuotaSnapshot]) {
        for snapshot in snapshots {
            let key = QuotaSnapshotCloudKey(snapshot)
            if let current = quotaByKey[key], current.capturedAt > snapshot.capturedAt {
                continue
            }
            quotaByKey[key] = snapshot
        }
    }

    public func upsertDevices(_ devices: [Device]) {
        for device in devices {
            let current = deviceByID[device.id]
            let currentDate = current?.lastSyncedAt
                ?? current?.lastCollectedAt
                ?? .distantPast
            let incomingDate = device.lastSyncedAt
                ?? device.lastCollectedAt
                ?? .distantPast
            guard incomingDate >= currentDate else { continue }
            deviceByID[device.id] = device
        }
    }

    public func upsertProviderStatuses(
        _ statuses: [LiveQuotaProviderStatus]
    ) {
        for status in statuses {
            let key = ProviderStatusCloudKey(status)
            if let current = statusByKey[key],
               current.checkedAt > status.checkedAt
            {
                continue
            }
            statusByKey[key] = status
        }
    }

    public func dailyUsage() -> [DailyUsage] {
        usageByKey.values.sorted(by: cloudDailyUsageOrder)
    }

    public func quotaSnapshots() -> [QuotaSnapshot] {
        quotaByKey.values.sorted(by: cloudQuotaOrder)
    }

    public func devices() -> [Device] {
        deviceByID.values.sorted(by: cloudDeviceOrder)
    }

    public func providerStatuses() -> [LiveQuotaProviderStatus] {
        statusByKey.values.sorted(by: cloudProviderStatusOrder)
    }
}
