import Foundation
import Testing
@testable import TokenHubCore

@Suite("Codex usage collector")
struct CodexUsageCollectorTests {
    @Test("Parses main and fork usage without replaying cumulative parent usage")
    func forkSession() throws {
        let result = try parseFixture("codex-fork")
        #expect(result.events.map(\.sessionID) == ["codex-parent", "codex-child"])
        #expect(result.events.map(\.eventID) == ["turn-parent-1", "turn-child-1"])
        #expect(result.events.map(\.model) == ["gpt-5.4", "gpt-5.4-mini"])
        #expect(result.events.map(\.inputTokens) == [80, 40])
        #expect(result.events.map(\.cacheReadTokens) == [20, 10])
        #expect(result.events.map(\.outputTokens) == [12, 7])
        #expect(result.events.map(\.totalTokens) == [112, 57])
        #expect(result.events.allSatisfy { $0.estimatedCostUSD != nil })
        #expect(
            Set(result.events.compactMap(\.pricingVersion))
                == [PricingCatalog.productionVersion]
        )
        #expect(Set(result.events.map(\.id)).count == 2)
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Diagnoses malformed complete rows and defers a partial final row")
    func malformedAndPartial() throws {
        let malformed = try parseFixture("codex-malformed")
        #expect(malformed.events.map(\.eventID) == ["turn-after-error"])
        #expect(malformed.diagnostics.map(\.line) == [2])
        let data = try fixtureData("codex-partial")
        let partial = CodexUsageCollector(deviceID: "fixture-mac").parse(data)
        #expect(partial.events.map(\.eventID) == ["turn-complete"])
        #expect(partial.diagnostics.isEmpty)
        #expect(partial.consumedByteCount < data.count)
    }

    @Test("Keeps multiple token events within one turn")
    func multipleUsageEventsPerTurn() {
        let data = Data(
            """
            {"type":"session_meta","timestamp":"2026-08-08T10:00:00Z","payload":{"id":"session"}}
            {"type":"turn_context","timestamp":"2026-08-08T10:00:00Z","payload":{"model":"gpt-5.4","turn_id":"turn"}}
            {"type":"event_msg","timestamp":"2026-08-08T10:00:01Z","payload":{"type":"token_count","info":{"turn_id":"turn","last_token_usage":{"input_tokens":10,"cached_input_tokens":0,"output_tokens":1}}}}
            {"type":"event_msg","timestamp":"2026-08-08T10:00:02Z","payload":{"type":"token_count","info":{"turn_id":"turn","last_token_usage":{"input_tokens":20,"cached_input_tokens":0,"output_tokens":2}}}}

            """.utf8
        )

        let result = CodexUsageCollector(deviceID: "mac").parse(data)

        #expect(result.events.map(\.totalTokens) == [11, 22])
        #expect(Set(result.events.map(\.id)).count == 2)
    }

    private func parseFixture(_ name: String) throws -> CollectorParseResult {
        CodexUsageCollector(deviceID: "fixture-mac").parse(try fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
