import CSQLite
import Foundation
import Testing
@testable import TokenHubCore

@Suite("Market value gaps")
struct MarketValueGapTests {
    @Test("Senpi reports usage rows missing event identity")
    func senpiMissingIdentity() throws {
        let result = SenpiUsageCollector(deviceID: "market-qa").parse(
            try fixtureData("senpi-semantic-invalid")
        )

        #expect(result.events.isEmpty)
        #expect(result.diagnostics.map(\.source) == [.senpi])
        #expect(result.diagnostics.map(\.line) == [2])
    }

    @Test("Codex reports usage rows missing required token counts")
    func codexMissingRequiredTokens() throws {
        let result = CodexUsageCollector(deviceID: "market-qa").parse(
            try fixtureData("codex-semantic-invalid")
        )

        #expect(result.events.isEmpty)
        #expect(result.diagnostics.map(\.source) == [.codex])
        #expect(result.diagnostics.map(\.line) == [2])
    }

    @Test("Claude reports usage rows missing required token counts")
    func claudeMissingRequiredTokens() throws {
        let result = ClaudeUsageCollector(deviceID: "market-qa").parse(
            try fixtureData("claude-semantic-invalid")
        )

        #expect(result.events.isEmpty)
        #expect(result.diagnostics.map(\.source) == [.claude])
        #expect(result.diagnostics.map(\.line) == [1])
    }

    @Test("Daily usage reads reject an interrupted SQLite step")
    func interruptedDailyUsageRead() throws {
        #expect(
            try withInterruptedStore { store in
                isStepError {
                    _ = try store.dailyUsage()
                }
            }
        )
    }

    @Test("Device reads reject an interrupted SQLite step")
    func interruptedDeviceRead() throws {
        #expect(
            try withInterruptedStore { store in
                isStepError {
                    _ = try store.devices()
                }
            }
        )
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

    private func withInterruptedStore(
        _ operation: (SQLiteUsageStore) throws -> Bool
    ) throws -> Bool {
        let databaseURL = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
            .appendingPathExtension("sqlite")
        defer { try? FileManager.default.removeItem(at: databaseURL) }

        let store = try SQLiteUsageStore(databaseURL: databaseURL)
        sqlite3_progress_handler(store.database, 1, { _ in 1 }, nil)
        defer {
            sqlite3_progress_handler(store.database, 0, nil, nil)
        }
        return try operation(store)
    }

    private func isStepError(_ operation: () throws -> Void) -> Bool {
        do {
            try operation()
            return false
        } catch let error as SQLiteUsageStoreError {
            if case .step = error {
                return true
            }
            return false
        } catch {
            return false
        }
    }
}
