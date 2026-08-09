import Foundation
import Testing
@testable import TokenHubCore

@Suite("Local-calendar daily usage") struct DailyUsageTests {
    @Test("Groups by local day and identity") func grouping() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let before = ISO8601DateFormatter().date(from: "2026-08-02T06:59:59Z")!, after = ISO8601DateFormatter().date(from: "2026-08-02T07:00:00Z")!
        let rows = try DailyUsageAggregator(calendar: cal, pricingCatalog: catalog).aggregate([
            event(id: "a", at: before, model: "known", input: 1, version: "v1"),
            event(id: "b", at: before, model: "known", output: 2, version: "v1"),
            event(id: "c", source: .codex, at: before, model: "known", input: 3, version: "v1"),
            event(id: "d", at: after, model: "known", input: 4, version: "v1")])
        #expect(rows.count == 3)
        let expectedDay = cal.startOfDay(for: before)
        let matchingRow = rows.first { $0.source == UsageSource.senpi && $0.day == expectedDay }
        let row = try #require(matchingRow)
        #expect(row.eventCount == 2 && row.inputTokens == 1 && row.outputTokens == 2)
        #expect(row.estimatedCostUSD == Decimal(string: "0.000021"))
    }
    @Test("Uses logged costs and pinned versions") func costs() throws {
        let rows = try DailyUsageAggregator(pricingCatalog: catalog).aggregate([
            event(id: "old", model: "known", input: 1, version: "v1"), event(id: "new", model: "known", input: 1, version: "v2"),
            event(id: "logged", model: "unknown", logged: Decimal(string: "0.5")!, version: nil)])
        #expect(rows.reduce(Decimal.zero) { $0 + $1.estimatedCostUSD } == Decimal(string: "0.500010"))
    }
    @Test("Unresolved costs are explicit") func unresolved() {
        #expect(throws: DailyUsageAggregator.Error.unresolvedPricing(eventID: "x")) {
            try DailyUsageAggregator(pricingCatalog: catalog).aggregate([event(id: "x", model: "unknown", version: "v1")])
        }
    }
}
