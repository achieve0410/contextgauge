import Foundation
import Testing
@testable import TokenHubCore

@Suite("Aggregate-only CloudSync")
struct CloudSyncTests {
    @Test("Daily usage upserts are stable and remain separated by device")
    func stableDeviceSeparatedDailyUsage() async throws {
        let sync: any CloudSync = InMemoryCloudSync()
        let macbook = dailyUsage(deviceID: "macbook", totalTokens: 10)
        let macMini = dailyUsage(deviceID: "mac-mini", totalTokens: 20)

        try await sync.upsertDailyUsage([macbook, macMini])
        try await sync.upsertDailyUsage([dailyUsage(deviceID: "macbook", totalTokens: 30)])

        let records = try await sync.dailyUsage()
        #expect(records.count == 2)
        #expect(records.map(\.deviceID) == ["mac-mini", "macbook"])
        #expect(records.first(where: { $0.deviceID == "macbook" })?.totalTokens == 30)
    }

    @Test("Repeated uploads from different Macs suppress duplicates without merging devices")
    func duplicateSuppressionAcrossMacs() async throws {
        let sync: any CloudSync = InMemoryCloudSync()
        let laptop = dailyUsage(deviceID: "laptop", totalTokens: 42)
        let desktop = dailyUsage(deviceID: "desktop", totalTokens: 42)

        try await sync.upsertDailyUsage([laptop, laptop, desktop])
        try await sync.upsertDailyUsage([desktop, laptop])

        #expect(try await sync.dailyUsage() == [desktop, laptop])
    }

    @Test("Quota keeps the latest capture for provider account and window")
    func latestQuotaByIdentity() async throws {
        let sync: any CloudSync = InMemoryCloudSync()
        let old = quota(capturedAt: Date(timeIntervalSince1970: 100), usedPercent: 10)
        let latest = quota(capturedAt: Date(timeIntervalSince1970: 300), usedPercent: 30)
        let stale = quota(capturedAt: Date(timeIntervalSince1970: 200), usedPercent: 20)
        let otherWindow = quota(capturedAt: Date(timeIntervalSince1970: 150), usedPercent: 15, windowKind: "weekly")

        try await sync.upsertQuotaSnapshots([latest, old, otherWindow, stale])

        #expect(try await sync.quotaSnapshots() == [latest, otherWindow])
    }

    @Test("Device metadata upserts by stable device identifier")
    func deviceMetadata() async throws {
        let sync: any CloudSync = InMemoryCloudSync()
        let old = Device(
            id: "macbook",
            name: "Old name",
            lastCollectedAt: Date(timeIntervalSince1970: 100),
            lastSyncedAt: Date(timeIntervalSince1970: 100)
        )
        let latest = Device(
            id: "macbook",
            name: "MacBook",
            lastCollectedAt: Date(timeIntervalSince1970: 200),
            lastSyncedAt: Date(timeIntervalSince1970: 200)
        )

        try await sync.upsertDevices([old, latest])

        #expect(try await sync.devices() == [latest])
    }

    @Test("Cloud payload is aggregate-only and excludes sensitive detail fields")
    func privacySafePayload() throws {
        let payload = CloudSyncPayload(
            dailyUsage: [dailyUsage(deviceID: "macbook", totalTokens: 10)],
            quotaSnapshots: [quota(capturedAt: Date(timeIntervalSince1970: 100), usedPercent: 10)],
            devices: []
        )
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(payload)) as? [String: Any])
        let encodedKeys = Set(allKeys(in: object).map { $0.lowercased() })

        #expect(encodedKeys.isDisjoint(with: [
            "path", "sourcepath", "cwd", "prompt", "response", "token", "tokens",
            "cookie", "cookies", "auth", "authorization", "sessionid", "eventid",
        ]))
        #expect(
            Set(object.keys)
                == [
                    "dailyUsage",
                    "quotaSnapshots",
                    "devices",
                    "providerStatuses",
                ]
        )
    }

    @Test("CloudKit adapter configuration is injected and private")
    func privateCloudKitBoundary() {
        let configuration = CloudKitSync.Configuration(
            containerIdentifier: "iCloud.com.example.ContextGaugeTests"
        )
        let sync = CloudKitSync(configuration: configuration)

        #expect(sync.configuration == configuration)
        #expect(sync.databaseScope == .private)
        #expect(
            CloudKitSync.Configuration.placeholder.containerIdentifier
                == "iCloud.com.example.ContextGauge"
        )
        #expect(
            CloudKitSync.shouldReplaceQuota(
                existingCapturedAt: Date(timeIntervalSince1970: 100),
                incomingCapturedAt: Date(timeIntervalSince1970: 200)
            )
        )
        #expect(
            !CloudKitSync.shouldReplaceQuota(
                existingCapturedAt: Date(timeIntervalSince1970: 300),
                incomingCapturedAt: Date(timeIntervalSince1970: 200)
            )
        )
    }

    @Test("Provider status keeps the latest check per device and provider")
    func providerStatusLatestWins() async throws {
        let sync: any CloudSync = InMemoryCloudSync()
        let older = LiveQuotaProviderStatus(
            deviceID: "macbook",
            provider: .claude,
            accountPseudonym: "profile",
            freshness: .stale,
            checkedAt: Date(timeIntervalSince1970: 100),
            capturedAt: Date(timeIntervalSince1970: 90),
            errorCode: "network-failure"
        )
        let newer = LiveQuotaProviderStatus(
            deviceID: "macbook",
            provider: .claude,
            accountPseudonym: "profile",
            freshness: .error,
            checkedAt: Date(timeIntervalSince1970: 200),
            capturedAt: Date(timeIntervalSince1970: 90),
            errorCode: "credentials-unavailable"
        )

        try await sync.upsertProviderStatuses([newer, older])
        let statuses = try await sync.providerStatuses()
        let payload = CloudSyncPayload(
            dailyUsage: [],
            quotaSnapshots: [],
            devices: [],
            providerStatuses: statuses
        )

        #expect(statuses == [newer])
        let json = String(
            decoding: try JSONEncoder().encode(payload),
            as: UTF8.self
        )
        #expect(json.contains("credentials-unavailable"))
        #expect(!json.contains("network-failure"))
    }

    @Test("Device reconciliation removes only current-device stale keys")
    func deviceScopedReconciliation() async throws {
        let sync: any CloudSync = InMemoryCloudSync()
        let currentStale = dailyUsage(
            deviceID: "macbook",
            totalTokens: 10
        )
        let otherDevice = dailyUsage(
            deviceID: "mac-mini",
            totalTokens: 20
        )
        try await sync.upsertDailyUsage([currentStale, otherDevice])
        let replacement = DailyUsage(
            day: currentStale.day.addingTimeInterval(86_400),
            deviceID: "macbook",
            source: .senpi,
            provider: "openai",
            model: "gpt",
            inputTokens: 30,
            outputTokens: 0,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: 30,
            estimatedCostUSD: 1,
            eventCount: 1
        )

        try await sync.reconcileDevice(
            DeviceSyncEnvelope(
                device: Device(
                    id: "macbook",
                    name: "MacBook",
                    lastCollectedAt: replacement.day,
                    lastSyncedAt: replacement.day
                ),
                dailyUsage: [replacement],
                quotaSnapshots: [],
                providerStatuses: []
            )
        )

        let records = try await sync.dailyUsage()
        #expect(records.contains(replacement))
        #expect(records.contains(otherDevice))
        #expect(!records.contains(currentStale))
    }

    @Test("CloudKit modifications are partitioned into bounded batches")
    func boundedCloudKitBatches() {
        #expect(
            CloudKitSync.batchSizes(itemCount: 451)
                == [200, 200, 51]
        )
        #expect(CloudKitSync.batchSizes(itemCount: 0).isEmpty)
    }

    private func dailyUsage(deviceID: String, totalTokens: Int) -> DailyUsage {
        DailyUsage(
            day: Date(timeIntervalSince1970: 1_800_000_000), deviceID: deviceID, source: .senpi,
            provider: "openai", model: "gpt", inputTokens: totalTokens, outputTokens: 0,
            cacheReadTokens: 0, cacheWriteTokens: 0, totalTokens: totalTokens,
            estimatedCostUSD: 0, eventCount: 1
        )
    }

    private func quota(capturedAt: Date, usedPercent: Decimal, windowKind: String = "daily") -> QuotaSnapshot {
        QuotaSnapshot(
            provider: "openai",
            accountPseudonym: "account-pseudonym",
            capturedAt: capturedAt,
            windowKind: windowKind, usedPercent: usedPercent, resetsAt: nil, source: "api"
        )
    }

    private func allKeys(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { [$0.key] + allKeys(in: $0.value) }
        }
        if let array = value as? [Any] { return array.flatMap(allKeys) }
        return []
    }
}
