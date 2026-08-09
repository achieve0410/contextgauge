import Foundation

public struct DailyUsageAggregator: Sendable {
    public enum Error: Swift.Error, Equatable {
        case unresolvedPricing(eventID: String)
    }

    private struct Key: Hashable {
        let day: Date
        let deviceID: String
        let source: UsageSource
        let provider: String
        let model: String
    }

    private struct Totals {
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
        var total = 0
        var cost = Decimal.zero
        var count = 0
    }

    private let calendar: Calendar
    private let pricingCatalog: PricingCatalog

    public init(calendar: Calendar = .current, pricingCatalog: PricingCatalog) {
        self.calendar = calendar
        self.pricingCatalog = pricingCatalog
    }

    public func aggregate(_ events: [UsageEvent]) throws -> [DailyUsage] {
        var grouped: [Key: Totals] = [:]
        for event in events {
            guard let cost = pricingCatalog.estimatedCostUSD(for: event) else {
                throw Error.unresolvedPricing(eventID: event.id)
            }
            let key = Key(day: calendar.startOfDay(for: event.occurredAt), deviceID: event.deviceID,
                          source: event.source, provider: event.provider, model: event.model)
            var totals = grouped[key, default: Totals()]
            totals.input += event.inputTokens
            totals.output += event.outputTokens
            totals.cacheRead += event.cacheReadTokens
            totals.cacheWrite += event.cacheWriteTokens
            totals.total += event.totalTokens
            totals.cost += cost
            totals.count += 1
            grouped[key] = totals
        }

        return grouped.map { key, totals in
            DailyUsage(day: key.day, deviceID: key.deviceID, source: key.source, provider: key.provider,
                       model: key.model, inputTokens: totals.input, outputTokens: totals.output,
                       cacheReadTokens: totals.cacheRead, cacheWriteTokens: totals.cacheWrite,
                       totalTokens: totals.total, estimatedCostUSD: totals.cost, eventCount: totals.count)
        }.sorted {
            ($0.day, $0.deviceID, $0.source.rawValue, $0.provider, $0.model)
                < ($1.day, $1.deviceID, $1.source.rawValue, $1.provider, $1.model)
        }
    }
}
