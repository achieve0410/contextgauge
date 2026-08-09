import Foundation

public struct PricingCatalog: Sendable {
    public static let productionVersion = "2026-08-08"

    public static let production = PricingCatalog(
        versions: [
            productionVersion: [
                Model(provider: "openai", model: "gpt-5.4"): Price(
                    inputPerMillionTokens: Decimal(25) / 10,
                    outputPerMillionTokens: 15,
                    cacheReadPerMillionTokens: Decimal(25) / 100,
                    cacheWritePerMillionTokens: 0
                ),
                Model(provider: "openai", model: "gpt-5.4-mini"): Price(
                    inputPerMillionTokens: Decimal(75) / 100,
                    outputPerMillionTokens: Decimal(45) / 10,
                    cacheReadPerMillionTokens: Decimal(75) / 1_000,
                    cacheWritePerMillionTokens: 0
                ),
                Model(
                    provider: "openai",
                    model: "gpt-5.3-codex-spark"
                ): Price(
                    inputPerMillionTokens: Decimal(175) / 100,
                    outputPerMillionTokens: 14,
                    cacheReadPerMillionTokens: Decimal(175) / 1_000,
                    cacheWritePerMillionTokens: 0
                ),
                Model(provider: "openai", model: "gpt-5.6-sol"): Price(
                    inputPerMillionTokens: 5,
                    outputPerMillionTokens: 30,
                    cacheReadPerMillionTokens: Decimal(5) / 10,
                    cacheWritePerMillionTokens: 0
                ),
                Model(provider: "anthropic", model: "claude-opus-4-1"):
                    Price(
                        inputPerMillionTokens: 15,
                        outputPerMillionTokens: 75,
                        cacheReadPerMillionTokens: Decimal(15) / 10,
                        cacheWritePerMillionTokens: Decimal(75) / 4
                    ),
                Model(provider: "anthropic", model: "claude-sonnet-4-5"):
                    Price(
                        inputPerMillionTokens: 3,
                        outputPerMillionTokens: 15,
                        cacheReadPerMillionTokens: Decimal(3) / 10,
                        cacheWritePerMillionTokens: Decimal(15) / 4
                    ),
            ],
        ]
    )

    public struct Model: Hashable, Sendable {
        public let provider: String
        public let model: String

        public init(provider: String, model: String) {
            self.provider = provider
            self.model = model
        }
    }

    public struct Price: Hashable, Sendable {
        public let inputPerMillionTokens: Decimal
        public let outputPerMillionTokens: Decimal
        public let cacheReadPerMillionTokens: Decimal
        public let cacheWritePerMillionTokens: Decimal

        public init(
            inputPerMillionTokens: Decimal,
            outputPerMillionTokens: Decimal,
            cacheReadPerMillionTokens: Decimal,
            cacheWritePerMillionTokens: Decimal
        ) {
            self.inputPerMillionTokens = inputPerMillionTokens
            self.outputPerMillionTokens = outputPerMillionTokens
            self.cacheReadPerMillionTokens = cacheReadPerMillionTokens
            self.cacheWritePerMillionTokens = cacheWritePerMillionTokens
        }
    }

    private let versions: [String: [Model: Price]]

    public init(versions: [String: [Model: Price]]) {
        self.versions = versions
    }

    public func price(provider: String, model: String, version: String) -> Price? {
        let prices = versions[version]
        return prices?[Model(provider: provider, model: model)]
            ?? (
                provider == "openai-codex"
                    ? prices?[Model(provider: "openai", model: model)]
                    : nil
            )
    }

    public func estimatedCostUSD(for event: UsageEvent) -> Decimal? {
        if let loggedCost = event.estimatedCostUSD { return loggedCost }
        guard
            let version = event.pricingVersion,
            let price = price(provider: event.provider, model: event.model, version: version)
        else { return nil }

        let million = Decimal(1_000_000)
        return (
            Decimal(event.inputTokens) * price.inputPerMillionTokens
                + Decimal(event.outputTokens) * price.outputPerMillionTokens
                + Decimal(event.cacheReadTokens) * price.cacheReadPerMillionTokens
                + Decimal(event.cacheWriteTokens) * price.cacheWritePerMillionTokens
        ) / million
    }

    public func applying(
        to event: UsageEvent,
        version: String
    ) -> UsageEvent {
        guard event.estimatedCostUSD == nil,
              price(
                provider: event.provider,
                model: event.model,
                version: version
              ) != nil
        else {
            return event
        }
        let pinned = UsageEvent(
            id: event.id,
            deviceID: event.deviceID,
            source: event.source,
            sessionID: event.sessionID,
            eventID: event.eventID,
            occurredAt: event.occurredAt,
            provider: event.provider,
            model: event.model,
            inputTokens: event.inputTokens,
            outputTokens: event.outputTokens,
            cacheReadTokens: event.cacheReadTokens,
            cacheWriteTokens: event.cacheWriteTokens,
            totalTokens: event.totalTokens,
            estimatedCostUSD: nil,
            pricingVersion: version
        )
        return UsageEvent(
            id: pinned.id,
            deviceID: pinned.deviceID,
            source: pinned.source,
            sessionID: pinned.sessionID,
            eventID: pinned.eventID,
            occurredAt: pinned.occurredAt,
            provider: pinned.provider,
            model: pinned.model,
            inputTokens: pinned.inputTokens,
            outputTokens: pinned.outputTokens,
            cacheReadTokens: pinned.cacheReadTokens,
            cacheWriteTokens: pinned.cacheWriteTokens,
            totalTokens: pinned.totalTokens,
            estimatedCostUSD: estimatedCostUSD(for: pinned),
            pricingVersion: version
        )
    }
}
