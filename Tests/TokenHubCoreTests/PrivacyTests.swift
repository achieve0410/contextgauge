import Foundation
import Testing
@testable import TokenHubCore

@Suite("Privacy boundaries")
struct PrivacyTests {
    @Test("Collector discards conversation bodies and source paths")
    func collectorDiscardsSensitiveSourceFields() throws {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "senpi-normal",
                withExtension: "jsonl",
                subdirectory: "Fixtures"
            )
        )
        let result = SenpiUsageCollector(deviceID: "fixture-mac")
            .parse(try Data(contentsOf: fixture))
        let encoded = String(
            decoding: try JSONEncoder().encode(result.events),
            as: UTF8.self
        )

        #expect(!encoded.contains("/private/project"))
        #expect(!encoded.contains("must not survive parsing"))
        #expect(!encoded.contains("ignored"))
    }

    @Test("Synchronized payload exposes aggregate fields only")
    func synchronizedPayloadHasOnlyAllowedFields() throws {
        let payload = CloudSyncPayload(
            dailyUsage: [
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
                ),
            ],
            quotaSnapshots: []
        )
        let object = try #require(
            JSONSerialization.jsonObject(
                with: JSONEncoder().encode(payload)
            ) as? [String: Any]
        )
        let keys = allKeys(in: object).map { $0.lowercased() }
        let forbiddenFragments = [
            "prompt", "response", "body", "content", "cookie", "auth",
            "cwd", "path", "session", "eventid",
        ]

        #expect(
            keys.allSatisfy { key in
                forbiddenFragments.allSatisfy { !key.contains($0) }
            }
        )
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

    @Test("SQLite persistence excludes source conversation and cwd")
    func databaseExcludesSensitiveSourceFields() throws {
        let fixture = try #require(
            Bundle.module.url(
                forResource: "senpi-normal",
                withExtension: "jsonl",
                subdirectory: "Fixtures"
            )
        )
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appending(path: "session.jsonl")
        let database = directory.appending(path: "usage.sqlite")
        try Data(contentsOf: fixture).write(to: log)
        let store = try SQLiteUsageStore(databaseURL: database)
        _ = try CollectionCoordinator(store: store, parserVersion: 1).scan(
            fileURL: log,
            collector: SenpiUsageCollector(deviceID: "fixture-mac")
        )
        let persisted = String(
            decoding: try Data(contentsOf: database),
            as: UTF8.self
        )

        #expect(!persisted.contains("/private/project"))
        #expect(!persisted.contains("must not survive parsing"))
        #expect(!persisted.contains("ignored"))
        #expect(try store.eventCount() == 1)
    }

    private func allKeys(in value: Any) -> [String] {
        if let dictionary = value as? [String: Any] {
            return dictionary.flatMap { [$0.key] + allKeys(in: $0.value) }
        }
        if let array = value as? [Any] {
            return array.flatMap(allKeys)
        }
        return []
    }
}
