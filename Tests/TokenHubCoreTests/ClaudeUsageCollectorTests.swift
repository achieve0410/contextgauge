import Foundation
import Testing
@testable import TokenHubCore

@Suite("Claude usage collector")
struct ClaudeUsageCollectorTests {
    @Test("Parses main and subagent usage and keeps the final streaming total")
    func subagentSession() throws {
        let result = try parseFixture("claude-subagent")
        #expect(result.events.map(\.sessionID) == ["claude-main", "claude-subagent"])
        #expect(result.events.map(\.eventID) == ["msg-main:req-main", "msg-sub:req-sub"])
        #expect(result.events.map(\.model) == ["claude-opus-4-1", "claude-sonnet-4-5"])
        #expect(result.events.map(\.inputTokens) == [30, 11])
        #expect(result.events.map(\.cacheReadTokens) == [100, 40])
        #expect(result.events.map(\.cacheWriteTokens) == [20, 5])
        #expect(result.events.map(\.outputTokens) == [9, 4])
        #expect(result.events.map(\.totalTokens) == [159, 60])
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
        let malformed = try parseFixture("claude-malformed")
        #expect(malformed.events.map(\.eventID) == ["msg-after:req-after"])
        #expect(malformed.diagnostics.map(\.line) == [2])
        let data = try fixtureData("claude-partial")
        let partial = ClaudeUsageCollector(deviceID: "fixture-mac").parse(data)
        #expect(partial.events.map(\.eventID) == ["msg-complete:req-complete"])
        #expect(partial.diagnostics.isEmpty)
        #expect(partial.consumedByteCount < data.count)
    }

    private func parseFixture(_ name: String) throws -> CollectorParseResult {
        ClaudeUsageCollector(deviceID: "fixture-mac").parse(try fixtureData(name))
    }

    private func fixtureData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "jsonl", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }
}
