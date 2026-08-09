import Foundation
import Testing
@testable import TokenHubCore

@Suite("Aggregate sync uploader")
struct AggregateSyncUploaderTests {
    @Test("Uploads aggregates and stamps the synchronized device")
    func uploadsAggregateSnapshot() async throws {
        let sync = SyncSpy()
        let uploader = AggregateSyncUploader(sync: sync)
        let syncedAt = Date(timeIntervalSince1970: 1_800_000_100)
        let snapshot = DashboardSnapshot(
            dailyUsage: [dailyUsage()],
            quotaSnapshots: [quota()],
            devices: [
                Device(
                    id: "macbook",
                    name: "MacBook",
                    lastCollectedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    lastSyncedAt: nil
                ),
            ],
            collectorStatuses: []
        )

        let updated = try await uploader.upload(
            snapshot,
            currentDeviceID: "macbook",
            historySince: .distantPast,
            providerStatuses: [],
            syncedAt: syncedAt
        )

        #expect(await sync.uploadedUsage == snapshot.dailyUsage)
        #expect(await sync.uploadedQuotas == snapshot.quotaSnapshots)
        #expect(await sync.uploadedDevices == updated.devices)
        #expect(updated.devices.first?.lastSyncedAt == syncedAt)
        #expect(updated.dailyUsage == snapshot.dailyUsage)
    }

    @Test("Returns merged remote aggregates and device metadata")
    func mergesRemoteSnapshot() async throws {
        let sync = InMemoryCloudSync()
        let remote = DailyUsage(
            day: Date(timeIntervalSince1970: 1_800_000_000),
            deviceID: "desktop",
            source: .claude,
            provider: "anthropic",
            model: "claude",
            inputTokens: 20,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: 20,
            estimatedCostUSD: 2,
            eventCount: 1
        )
        try await sync.upsertDailyUsage([remote])
        try await sync.upsertDevices([
            Device(
                id: "desktop",
                name: "Mac mini",
                lastCollectedAt: Date(timeIntervalSince1970: 1_799_999_900),
                lastSyncedAt: Date(timeIntervalSince1970: 1_799_999_950)
            ),
        ])
        let snapshot = DashboardSnapshot(
            dailyUsage: [dailyUsage()],
            quotaSnapshots: [],
            devices: [
                Device(
                    id: "macbook",
                    name: "MacBook",
                    lastCollectedAt: Date(timeIntervalSince1970: 1_800_000_000),
                    lastSyncedAt: nil
                ),
            ],
            collectorStatuses: []
        )

        let merged = try await AggregateSyncUploader(sync: sync).upload(
            snapshot,
            currentDeviceID: "macbook",
            historySince: .distantPast,
            providerStatuses: [],
            syncedAt: Date(timeIntervalSince1970: 1_800_000_100)
        )

        #expect(Set(merged.dailyUsage.map(\.deviceID)) == ["desktop", "macbook"])
        #expect(merged.devices.map(\.name) == ["Mac mini", "MacBook"])
    }

    @Test("Uploads only the current device and requests bounded history")
    func uploadsCurrentDeviceEnvelope() async throws {
        let sync = SyncSpy()
        let uploader = AggregateSyncUploader(sync: sync)
        let current = usage(deviceID: "macbook", totalTokens: 10)
        let remote = usage(deviceID: "mac-mini", totalTokens: 20)
        let historySince = Date(timeIntervalSince1970: 1_780_000_000)
        let snapshot = DashboardSnapshot(
            dailyUsage: [current, remote],
            quotaSnapshots: [],
            devices: [
                Device(
                    id: "macbook",
                    name: "MacBook",
                    lastCollectedAt: current.day,
                    lastSyncedAt: nil
                ),
                Device(
                    id: "mac-mini",
                    name: "Mac mini",
                    lastCollectedAt: remote.day,
                    lastSyncedAt: remote.day
                ),
            ],
            collectorStatuses: []
        )

        _ = try await uploader.upload(
            snapshot,
            currentDeviceID: "macbook",
            historySince: historySince,
            providerStatuses: [],
            syncedAt: historySince
        )

        let envelope = try #require(await sync.lastEnvelope())
        #expect(envelope.device.id == "macbook")
        #expect(envelope.dailyUsage == [current])
        #expect(await sync.requestedHistorySince() == historySince)
    }

    private func dailyUsage() -> DailyUsage {
        DailyUsage(
            day: Date(timeIntervalSince1970: 1_800_000_000),
            deviceID: "macbook",
            source: .senpi,
            provider: "openai",
            model: "gpt",
            inputTokens: 8,
            outputTokens: 2,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: 10,
            estimatedCostUSD: 1,
            eventCount: 1
        )
    }

    private func quota() -> QuotaSnapshot {
        QuotaSnapshot(
            provider: "openai",
            accountPseudonym: "account-hash",
            capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
            windowKind: "weekly",
            usedPercent: 40,
            resetsAt: nil,
            source: "api"
        )
    }

    private func usage(
        deviceID: String,
        totalTokens: Int
    ) -> DailyUsage {
        DailyUsage(
            day: Date(timeIntervalSince1970: 1_800_000_000),
            deviceID: deviceID,
            source: .senpi,
            provider: "openai",
            model: "gpt",
            inputTokens: totalTokens,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: totalTokens,
            estimatedCostUSD: 1,
            eventCount: 1
        )
    }
}

private actor SyncSpy: CloudSync {
    private(set) var uploadedUsage: [DailyUsage] = []
    private(set) var uploadedQuotas: [QuotaSnapshot] = []
    private(set) var uploadedDevices: [Device] = []
    private(set) var uploadedStatuses: [LiveQuotaProviderStatus] = []
    private var profiles: [QuotaAccountProfile] = []
    private var envelope: DeviceSyncEnvelope?
    private var historySince: Date?

    func reconcileDevice(_ envelope: DeviceSyncEnvelope) async throws {
        self.envelope = envelope
        uploadedUsage = envelope.dailyUsage
        uploadedQuotas = envelope.quotaSnapshots
        uploadedDevices = [envelope.device]
        uploadedStatuses = envelope.providerStatuses
    }

    func dashboardPayload(
        since day: Date
    ) async throws -> CloudSyncPayload {
        historySince = day
        return CloudSyncPayload(
            dailyUsage: uploadedUsage,
            quotaSnapshots: uploadedQuotas,
            devices: uploadedDevices,
            providerStatuses: uploadedStatuses
        )
    }

    func lastEnvelope() -> DeviceSyncEnvelope? {
        envelope
    }

    func requestedHistorySince() -> Date? {
        historySince
    }

    func accounts(
        for provider: LiveQuotaProvider
    ) async throws -> [QuotaAccountProfile] {
        profiles.filter { $0.provider == provider }
    }

    func createAccount(
        provider: LiveQuotaProvider,
        displayName: String
    ) async throws -> QuotaAccountProfile {
        let profile = QuotaAccountProfile.make(
            provider: provider,
            displayName: displayName
        )
        profiles.append(profile)
        return profile
    }

    func upsertDailyUsage(_ usage: [DailyUsage]) async throws {
        uploadedUsage = usage
    }

    func upsertQuotaSnapshots(_ snapshots: [QuotaSnapshot]) async throws {
        uploadedQuotas = snapshots
    }

    func upsertDevices(_ devices: [Device]) async throws {
        uploadedDevices = devices
    }

    func upsertProviderStatuses(
        _ statuses: [LiveQuotaProviderStatus]
    ) async throws {
        uploadedStatuses = statuses
    }

    func dailyUsage() async throws -> [DailyUsage] {
        uploadedUsage
    }

    func quotaSnapshots() async throws -> [QuotaSnapshot] {
        uploadedQuotas
    }

    func devices() async throws -> [Device] {
        uploadedDevices
    }

    func providerStatuses() async throws -> [LiveQuotaProviderStatus] {
        uploadedStatuses
    }
}
