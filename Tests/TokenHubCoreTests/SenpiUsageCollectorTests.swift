import Foundation
import Testing
@testable import TokenHubCore

@Suite("Senpi usage collector")
struct SenpiUsageCollectorTests {
    @Test("Parses usage and ignores messages without usage")
    func normalSession() throws {
        let result = try parseFixture("senpi-normal")

        let event = try #require(result.events.first)
        #expect(result.events.count == 1)
        #expect(event.sessionID == "session-normal")
        #expect(event.eventID == "message-1")
        #expect(event.deviceID == "fixture-mac")
        #expect(event.source == .senpi)
        #expect(event.provider == "openai-codex")
        #expect(event.model == "gpt-5.3-codex-spark")
        #expect(event.inputTokens == 100)
        #expect(event.outputTokens == 25)
        #expect(event.totalTokens == 125)
        #expect(event.estimatedCostUSD == Decimal(string: "0.0125"))
        #expect(result.diagnostics.isEmpty)
    }

    @Test("Tracks provider and model changes")
    func modelChanges() throws {
        let result = try parseFixture("senpi-model-change")

        #expect(result.events.map(\.provider) == ["anthropic", "openai"])
        #expect(result.events.map(\.model) == ["claude-opus-4-1", "gpt-5"])
        #expect(result.events.map(\.totalTokens) == [12, 23])
    }

    @Test("Preserves cache categories and Senpi cost precision")
    func cacheTokens() throws {
        let result = try parseFixture("senpi-cache")
        let event = try #require(result.events.first)

        #expect(event.cacheReadTokens == 200)
        #expect(event.cacheWriteTokens == 40)
        #expect(event.totalTokens == 275)
        #expect(event.estimatedCostUSD == Decimal(string: "0.000123456789"))
        #expect(event.pricingVersion == nil)
    }

    @Test("Reports a malformed row and continues parsing")
    func malformedRow() throws {
        let result = try parseFixture("senpi-malformed")

        #expect(result.events.map(\.eventID) == ["message-after-error"])
        #expect(result.diagnostics.count == 1)
        #expect(result.diagnostics.first?.line == 3)
    }

    @Test("Defers a partial final row without a diagnostic")
    func partialFinalRow() throws {
        let data = try fixtureData("senpi-partial")
        let result = SenpiUsageCollector(deviceID: "fixture-mac").parse(data)

        #expect(result.events.map(\.eventID) == ["message-complete"])
        #expect(result.diagnostics.isEmpty)
        #expect(result.consumedByteCount < data.count)
    }

    private func parseFixture(_ name: String) throws -> CollectorParseResult {
        SenpiUsageCollector(deviceID: "fixture-mac").parse(try fixtureData(name))
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
}
