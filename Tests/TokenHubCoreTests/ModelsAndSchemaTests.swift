import Foundation
import Testing
@testable import TokenHubCore

@Suite("Normalized models and schema")
struct ModelsAndSchemaTests {
    @Test("Usage events round-trip all normalized usage fields")
    func usageEventRoundTrip() throws {
        let occurredAt = Date(timeIntervalSince1970: 1_800_000_000)
        let event = UsageEvent(
            id: "stable-event",
            deviceID: "macbook",
            source: .senpi,
            sessionID: "session-1",
            eventID: "message-2",
            occurredAt: occurredAt,
            provider: "openai",
            model: "gpt-5.6",
            inputTokens: 100,
            outputTokens: 20,
            cacheReadTokens: 30,
            cacheWriteTokens: 4,
            totalTokens: 154,
            estimatedCostUSD: Decimal(string: "0.0123"),
            pricingVersion: "2026-08-01"
        )

        let encoded = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(UsageEvent.self, from: encoded)

        #expect(decoded == event)
        #expect(decoded.totalTokens == 154)
        #expect(decoded.estimatedCostUSD == Decimal(string: "0.0123"))
    }

    @Test("Stable IDs depend on source session event and sequence")
    func stableIdentifiers() {
        let first = UsageEvent.stableID(
            source: .senpi,
            sessionID: "session",
            eventID: "message",
            usageSequence: 0
        )
        let repeated = UsageEvent.stableID(
            source: .senpi,
            sessionID: "session",
            eventID: "message",
            usageSequence: 0
        )
        let next = UsageEvent.stableID(
            source: .senpi,
            sessionID: "session",
            eventID: "message",
            usageSequence: 1
        )

        #expect(first == repeated)
        #expect(first != next)
        #expect(first.count == 64)
    }

    @Test("SQLite creates every required v1 table")
    func requiredSchema() throws {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteUsageStore(databaseURL: databaseURL)

        #expect(
            try store.tableNames() == Set([
                "usage_events",
                "daily_usage",
                "collector_cursors",
                "quota_snapshots",
                "devices",
                "schema_migrations",
            ])
        )
    }
}
