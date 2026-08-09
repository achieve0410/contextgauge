import Foundation
import Testing
@testable import TokenHubCore

@Suite("Local usage service")
struct LocalUsageServiceTests {
    @Test("Rebuilds event-backed historical device aggregates once")
    func historicalEventBackedDeviceAggregationIsIdempotent() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "usage.sqlite")
        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        let event = UsageEvent(
            id: "legacy-event",
            deviceID: "legacy-device",
            source: .senpi,
            sessionID: "legacy-session",
            eventID: "legacy-message",
            occurredAt: occurredAt,
            provider: "openai",
            model: "gpt-5.6-sol",
            inputTokens: 8,
            outputTokens: 2,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: 10,
            estimatedCostUSD: Decimal(string: "0.01"),
            pricingVersion: "2026-08-08"
        )
        _ = try store.commit(
            events: [event],
            cursor: CollectorCursor(
                source: .senpi,
                sourcePathHash: "legacy-source",
                fileResourceIdentifier: "legacy-resource",
                fileSize: 1,
                modifiedAt: occurredAt,
                lastParsedByteOffset: 1,
                parserVersion: 1,
                lastSuccessfulEventID: event.eventID,
                resumeState: nil
            )
        )
        try store.replaceDailyUsage([
            DailyUsage(
                day: Calendar.current.startOfDay(for: occurredAt),
                deviceID: event.deviceID,
                source: event.source,
                provider: event.provider,
                model: event.model,
                inputTokens: event.inputTokens,
                outputTokens: event.outputTokens,
                cacheReadTokens: event.cacheReadTokens,
                cacheWriteTokens: event.cacheWriteTokens,
                totalTokens: event.totalTokens,
                estimatedCostUSD: event.estimatedCostUSD ?? 0,
                eventCount: 1
            ),
        ])
        let service = try LocalUsageService(
            configuration: LocalUsageConfiguration(
                databaseURL: databaseURL,
                deviceID: "current-device",
                deviceName: "Current Device",
                roots: [:],
                parserVersion: 1
            )
        )

        let first = try service.collect(now: occurredAt)
        let second = try service.collect(now: occurredAt)

        #expect(first.dailyUsage == second.dailyUsage)
        #expect(second.dailyUsage.count == 1)
        #expect(second.dailyUsage.first?.deviceID == event.deviceID)
        #expect(second.dailyUsage.first?.eventCount == 1)
    }

    @Test("Collects a real JSONL file twice without mutation or duplication")
    func idempotentCollection() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let root = directory.appending(path: "senpi", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let logURL = root.appending(path: "session.jsonl")
        let fixtureURL = try #require(
            Bundle.module.url(
                forResource: "senpi-normal",
                withExtension: "jsonl",
                subdirectory: "Fixtures"
            )
        )
        try Data(contentsOf: fixtureURL).write(to: logURL)
        let sourceBefore = try Data(contentsOf: logURL)
        let service = try LocalUsageService(
            configuration: LocalUsageConfiguration(
                databaseURL: directory.appending(path: "usage.sqlite"),
                deviceID: "macbook",
                deviceName: "MacBook",
                roots: [.senpi: root],
                parserVersion: 1
            )
        )

        let first = try service.collect()
        let second = try service.collect()

        #expect(first.dailyUsage.reduce(0) { $0 + $1.totalTokens } == 125)
        #expect(second.dailyUsage.reduce(0) { $0 + $1.totalTokens } == 125)
        #expect(first.dailyUsage.reduce(0) { $0 + $1.eventCount } == 1)
        #expect(second.dailyUsage.reduce(0) { $0 + $1.eventCount } == 1)
        #expect(first.devices.map(\.id) == ["macbook"])
        #expect(second.collectorStatuses.first?.errorCode == nil)
        #expect(try Data(contentsOf: logURL) == sourceBefore)
        let persisted = try SQLiteUsageStore(
            databaseURL: directory.appending(path: "usage.sqlite")
        )
        #expect(try persisted.dailyUsage() == second.dailyUsage)
        #expect(try persisted.devices() == second.devices)
    }

    @Test("Persists a stable UUID independent of the device name")
    func stableDeviceIdentifier() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let identifierURL = directory.appending(path: "device-id")

        let first = try LocalUsageConfiguration.loadOrCreateDeviceIdentifier(
            at: identifierURL
        )
        let second = try LocalUsageConfiguration.loadOrCreateDeviceIdentifier(
            at: identifierURL
        )

        #expect(UUID(uuidString: first) != nil)
        #expect(second == first)
        #expect(
            try String(contentsOf: identifierURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines) == first
        )
    }

    @Test("Missing and empty configured roots report distinct statuses")
    func rootAvailabilityStatuses() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let emptyRoot = temporary.appending(
            path: "empty",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: emptyRoot,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: temporary)
        }
        let service = try LocalUsageService(
            configuration: LocalUsageConfiguration(
                databaseURL: temporary.appending(path: "usage.sqlite"),
                deviceID: "root-status",
                deviceName: "Root Status",
                roots: [
                    .codex: temporary.appending(path: "missing"),
                    .claude: emptyRoot,
                ],
                parserVersion: 1
            )
        )

        let snapshot = try service.collect()
        let statusBySource = Dictionary(
            uniqueKeysWithValues: snapshot.collectorStatuses.map {
                ($0.source, $0)
            }
        )

        #expect(statusBySource[.codex]?.errorCode == "root-missing")
        #expect(statusBySource[.claude]?.errorCode == "no-jsonl-files")
        #expect(
            statusBySource.values.allSatisfy {
                $0.lastSuccessfulCollectionAt == nil
            }
        )
    }
}
