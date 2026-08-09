import Foundation

public struct AggregateSyncUploader: Sendable {
    private let sync: any CloudSync

    public init(sync: any CloudSync) {
        self.sync = sync
    }

    public func upload(
        _ snapshot: DashboardSnapshot,
        currentDeviceID: String,
        historySince: Date,
        providerStatuses: [LiveQuotaProviderStatus],
        syncedAt: Date = .now
    ) async throws -> DashboardSnapshot {
        guard
            let currentDevice = snapshot.devices.first(where: {
                $0.id == currentDeviceID
            })
        else {
            throw DeviceSyncEnvelopeError.mismatchedDeviceID
        }
        let synchronizedDevice = Device(
            id: currentDevice.id,
            name: currentDevice.name,
            lastCollectedAt: currentDevice.lastCollectedAt,
            lastSyncedAt: syncedAt
        )
        try await sync.reconcileDevice(
            DeviceSyncEnvelope(
                device: synchronizedDevice,
                dailyUsage: snapshot.dailyUsage.filter {
                    $0.deviceID == currentDeviceID
                },
                quotaSnapshots: snapshot.quotaSnapshots,
                providerStatuses: providerStatuses.filter {
                    $0.deviceID == currentDeviceID
                }
            )
        )
        let payload = try await sync.dashboardPayload(since: historySince)
        return DashboardSnapshot(
            dailyUsage: payload.dailyUsage,
            quotaSnapshots: payload.quotaSnapshots,
            devices: payload.devices,
            collectorStatuses: snapshot.collectorStatuses
        )
    }
}
