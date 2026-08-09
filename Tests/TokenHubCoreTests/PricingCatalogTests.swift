import Foundation
import Testing
@testable import TokenHubCore

@Suite("Versioned pricing catalog") struct PricingCatalogTests {
    @Test("Known model costs are exact Decimals") func exactCost() {
        let e = event(model: "known", input: 3, output: 2, read: 1, write: 4, version: "v1")
        #expect(catalog.estimatedCostUSD(for: e) == Decimal(string: "0.000059"))
    }
    @Test("Unknown models have no cost") func unknown() {
        #expect(catalog.estimatedCostUSD(for: event(model: "unknown", version: "v1")) == nil)
    }
    @Test("Events pin their pricing version") func pinned() {
        #expect(catalog.estimatedCostUSD(for: event(model: "known", input: 1, version: "v1")) == Decimal(string: "0.000001"))
        #expect(catalog.estimatedCostUSD(for: event(model: "known", input: 1, version: "v2")) == Decimal(string: "0.000009"))
        #expect(catalog.estimatedCostUSD(for: event(model: "known", input: 1, version: nil)) == nil)
    }
    @Test("Logged cost wins") func loggedWins() {
        let cost = Decimal(string: "0.123456789012345678")!
        #expect(catalog.estimatedCostUSD(for: event(model: "unknown", logged: cost, version: nil)) == cost)
    }
}

let catalog = PricingCatalog(versions: [
    "v1": [.init(provider: "provider", model: "known"): .init(inputPerMillionTokens: Decimal(string: "1")!, outputPerMillionTokens: Decimal(string: "10")!, cacheReadPerMillionTokens: Decimal(string: "4")!, cacheWritePerMillionTokens: Decimal(string: "8")!)],
    "v2": [.init(provider: "provider", model: "known"): .init(inputPerMillionTokens: Decimal(string: "9")!, outputPerMillionTokens: Decimal(string: "10")!, cacheReadPerMillionTokens: Decimal(string: "4")!, cacheWritePerMillionTokens: Decimal(string: "8")!)]
])

func event(id: String = UUID().uuidString, device: String = "device", source: UsageSource = .senpi, at: Date = .init(timeIntervalSince1970: 0), provider: String = "provider", model: String, input: Int = 0, output: Int = 0, read: Int = 0, write: Int = 0, logged: Decimal? = nil, version: String?) -> UsageEvent {
    UsageEvent(id: id, deviceID: device, source: source, sessionID: "s", eventID: id, occurredAt: at, provider: provider, model: model, inputTokens: input, outputTokens: output, cacheReadTokens: read, cacheWriteTokens: write, totalTokens: input + output + read + write, estimatedCostUSD: logged, pricingVersion: version)
}
