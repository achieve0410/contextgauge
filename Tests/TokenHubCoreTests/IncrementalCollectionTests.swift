import Foundation
import Testing
@testable import TokenHubCore

@Suite("Incremental collection")
struct IncrementalCollectionTests {
    @Test("An unchanged file is not read or counted twice")
    func unchangedRescan() throws {
        try withStoreAndLog(fixture: "senpi-normal") { store, logURL in
            let coordinator = CollectionCoordinator(store: store, parserVersion: 1)
            let collector = SenpiUsageCollector(deviceID: "macbook")

            let first = try coordinator.scan(fileURL: logURL, collector: collector)
            let second = try coordinator.scan(fileURL: logURL, collector: collector)

            #expect(first.insertedEventCount == 1)
            #expect(first.totalTokens == 125)
            #expect(second.insertedEventCount == 0)
            #expect(second.bytesRead == 0)
            #expect(second.totalTokens == 125)
            #expect(try store.eventCount() == 1)
        }
    }

    @Test("Only appended bytes are parsed with prior session state")
    func appendOnly() throws {
        try withStoreAndLog(fixture: "senpi-normal") { store, logURL in
            let coordinator = CollectionCoordinator(store: store, parserVersion: 1)
            let collector = SenpiUsageCollector(deviceID: "macbook")
            _ = try coordinator.scan(fileURL: logURL, collector: collector)
            let append = Data(
                """
                {"type":"message","id":"message-appended","timestamp":"2026-08-01T10:01:00.000Z","message":{"role":"assistant","usage":{"input":20,"output":3,"cacheRead":0,"cacheWrite":0,"totalTokens":23,"cost":{"total":0.023}}}}

                """.utf8
            )
            try appendToFile(append, at: logURL)

            let result = try coordinator.scan(fileURL: logURL, collector: collector)

            #expect(result.startingByteOffset > 0)
            #expect(result.bytesRead == append.count)
            #expect(result.insertedEventCount == 1)
            #expect(result.totalTokens == 148)
            #expect(try store.eventCount() == 2)
        }
    }

    @Test("A completed partial tail is consumed on the next scan")
    func partialTail() throws {
        try withStoreAndLog(fixture: "senpi-partial") { store, logURL in
            let coordinator = CollectionCoordinator(store: store, parserVersion: 1)
            let collector = SenpiUsageCollector(deviceID: "macbook")
            let first = try coordinator.scan(fileURL: logURL, collector: collector)
            let originalSize = try fileSize(logURL)

            #expect(first.insertedEventCount == 1)
            #expect(first.cursor.lastParsedByteOffset < originalSize)
            try appendToFile(
                Data(
                    (
                        ",\"output\":1,\"cacheRead\":0,\"cacheWrite\":0,"
                            + "\"totalTokens\":100,\"cost\":{\"total\":1.00}}}}\n"
                    ).utf8
                ),
                at: logURL
            )

            let second = try coordinator.scan(fileURL: logURL, collector: collector)
            let completedSize = try fileSize(logURL)

            #expect(second.insertedEventCount == 1)
            #expect(second.totalTokens == 110)
            #expect(second.cursor.lastParsedByteOffset == completedSize)
        }
    }

    @Test("Rotation and parser changes restart at byte zero without duplicates")
    func rotationAndParserVersion() throws {
        try withStoreAndLog(fixture: "senpi-normal") { store, logURL in
            let collector = SenpiUsageCollector(deviceID: "macbook")
            let versionOne = CollectionCoordinator(store: store, parserVersion: 1)
            _ = try versionOne.scan(fileURL: logURL, collector: collector)

            let versionTwo = CollectionCoordinator(store: store, parserVersion: 2)
            let reparsed = try versionTwo.scan(fileURL: logURL, collector: collector)
            #expect(reparsed.startingByteOffset == 0)
            #expect(reparsed.insertedEventCount == 1)
            #expect(reparsed.cursor.parserVersion == 2)
            #expect(try store.eventCount() == 1)

            let rotated = """
                {"type":"session","id":"rotated-session","timestamp":"2026-08-02T00:00:00.000Z","cwd":"/private/rotated","version":3}
                {"type":"model_change","id":"rotated-model","timestamp":"2026-08-02T00:00:01.000Z","provider":"anthropic","modelId":"claude-sonnet-4"}
                {"type":"message","id":"rotated-message","timestamp":"2026-08-02T00:00:02.000Z","message":{"usage":{"input":1,"output":2,"cacheRead":3,"cacheWrite":4,"totalTokens":10,"cost":{"total":0.10}}}}

                """
            try Data(rotated.utf8).write(to: logURL, options: .atomic)
            let afterRotation = try versionTwo.scan(fileURL: logURL, collector: collector)

            #expect(afterRotation.startingByteOffset == 0)
            #expect(afterRotation.insertedEventCount == 1)
            #expect(afterRotation.totalTokens == 135)
        }
    }

    @Test("Codex append restores session model and turn context")
    func codexAppendState() throws {
        try withStoreAndLog(fixture: "codex-fork") { store, logURL in
            let allRows = try Data(contentsOf: logURL)
                .split(separator: 0x0A, omittingEmptySubsequences: true)
            let initial = Data(allRows.prefix(2).joined(separator: Data([0x0A])))
                + Data([0x0A])
            try initial.write(to: logURL, options: .atomic)
            let coordinator = CollectionCoordinator(store: store, parserVersion: 1)
            let collector = CodexUsageCollector(deviceID: "macbook")
            _ = try coordinator.scan(fileURL: logURL, collector: collector)
            let appended = Data(allRows[2]) + Data([0x0A])
            try appendToFile(appended, at: logURL)

            let result = try coordinator.scan(
                fileURL: logURL,
                collector: collector
            )

            #expect(result.insertedEventCount == 1)
            #expect(result.totalTokens == 112)
            #expect(try store.eventCount() == 1)
        }
    }

    @Test("Claude final streaming row replaces partial persisted totals")
    func claudeStreamingUpdate() throws {
        try withStoreAndLog(fixture: "claude-subagent") { store, logURL in
            let rows = try Data(contentsOf: logURL)
                .split(separator: 0x0A, omittingEmptySubsequences: true)
            try (Data(rows[0]) + Data([0x0A]))
                .write(to: logURL, options: .atomic)
            let coordinator = CollectionCoordinator(store: store, parserVersion: 1)
            let collector = ClaudeUsageCollector(deviceID: "macbook")
            _ = try coordinator.scan(fileURL: logURL, collector: collector)
            try appendToFile(Data(rows[1]) + Data([0x0A]), at: logURL)

            let result = try coordinator.scan(
                fileURL: logURL,
                collector: collector
            )

            #expect(result.totalTokens == 159)
            #expect(try store.eventCount() == 1)
        }
    }

    @Test("Codex replay is deduplicated across separate rollout files")
    func codexCrossFileReplay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let rows = try fixtureData("codex-fork")
            .split(separator: 0x0A, omittingEmptySubsequences: true)
        let parent = directory.appending(path: "parent.jsonl")
        let child = directory.appending(path: "child.jsonl")
        try (Data(rows[0...2].joined(separator: Data([0x0A])))
             + Data([0x0A])).write(to: parent)
        try (Data(rows[3...5].joined(separator: Data([0x0A])))
             + Data([0x0A])).write(to: child)
        let store = try SQLiteUsageStore(
            databaseURL: directory.appending(path: "usage.sqlite")
        )
        let coordinator = CollectionCoordinator(store: store, parserVersion: 1)
        let collector = CodexUsageCollector(deviceID: "macbook")

        _ = try coordinator.scan(fileURL: parent, collector: collector)
        let result = try coordinator.scan(fileURL: child, collector: collector)

        #expect(result.totalTokens == 112)
        #expect(try store.eventCount() == 1)
    }

    @Test("Codex parser upgrade rebuilds old source events")
    func codexParserUpgrade() throws {
        try withStoreAndLog(fixture: "codex-fork") { store, logURL in
            let collector = CodexUsageCollector(deviceID: "macbook")
            _ = try CollectionCoordinator(
                store: store,
                parserVersion: 1
            ).scan(fileURL: logURL, collector: collector)

            let upgraded = try CollectionCoordinator(
                store: store,
                parserVersion: 2
            ).scan(fileURL: logURL, collector: collector)

            #expect(upgraded.startingByteOffset == 0)
            #expect(upgraded.insertedEventCount == 2)
            #expect(upgraded.totalTokens == 169)
            #expect(try store.eventCount() == 2)
        }
    }

    private func withStoreAndLog(
        fixture: String,
        body: (SQLiteUsageStore, URL) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appending(path: "usage.sqlite")
        let logURL = directory.appending(path: "session.jsonl")
        var data = try fixtureData(fixture)
        if fixture == "senpi-partial", data.last == 0x0A {
            data.removeLast()
        }
        try data.write(to: logURL)
        try body(SQLiteUsageStore(databaseURL: databaseURL), logURL)
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(
                forResource: name,
                withExtension: "jsonl",
                subdirectory: "Fixtures"
            )
        )
        return try Data(contentsOf: url)
    }

    private func appendToFile(_ data: Data, at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func fileSize(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (try #require(attributes[.size] as? NSNumber)).int64Value
    }
}
