import Foundation

public struct SenpiUsageCollector: IncrementalUsageCollector {
    public let source = UsageSource.senpi
    public let deviceID: String
    private let pricingCatalog: PricingCatalog
    private let pricingVersion: String

    public init(
        deviceID: String,
        pricingCatalog: PricingCatalog = .production,
        pricingVersion: String = PricingCatalog.productionVersion
    ) {
        self.deviceID = deviceID
        self.pricingCatalog = pricingCatalog
        self.pricingVersion = pricingVersion
    }

    public func parse(_ data: Data) -> CollectorParseResult {
        parse(data, resumingFrom: nil)
    }

    public func parse(
        _ data: Data,
        resumingFrom resumeState: CollectorResumeState?
    ) -> CollectorParseResult {
        var state = ParseState(
            sessionID: resumeState?.sessionID,
            provider: resumeState?.provider,
            model: resumeState?.model
        )
        var events: [UsageEvent] = []
        var diagnostics: [CollectorDiagnostic] = []
        var cursor = data.startIndex
        var consumedByteCount = 0
        var lineNumber = 0
        let decoder = JSONDecoder()

        while cursor < data.endIndex {
            lineNumber += 1
            let newline = data[cursor...].firstIndex(of: 0x0A)
            let lineEnd = newline ?? data.endIndex
            let next = newline.map { data.index(after: $0) } ?? data.endIndex
            let line = Data(data[cursor..<lineEnd])

            if line.isEmpty {
                consumedByteCount = data.distance(from: data.startIndex, to: next)
                cursor = next
                continue
            }

            do {
                let envelope = try decoder.decode(SenpiEnvelope.self, from: line)
                process(
                    envelope,
                    lineNumber: lineNumber,
                    state: &state,
                    events: &events,
                    diagnostics: &diagnostics
                )
            } catch {
                let isLastLine = next == data.endIndex
                if isLastLine, Self.looksIncomplete(line) {
                    break
                }
                diagnostics.append(
                    CollectorDiagnostic(
                        source: .senpi,
                        line: lineNumber,
                        message: "Malformed JSONL row"
                    )
                )
            }

            consumedByteCount = data.distance(from: data.startIndex, to: next)
            cursor = next
        }

        return CollectorParseResult(
            events: events,
            diagnostics: diagnostics,
            consumedByteCount: consumedByteCount,
            resumeState: CollectorResumeState(
                sessionID: state.sessionID,
                provider: state.provider,
                model: state.model
            )
        )
    }

    private func process(
        _ envelope: SenpiEnvelope,
        lineNumber: Int,
        state: inout ParseState,
        events: inout [UsageEvent],
        diagnostics: inout [CollectorDiagnostic]
    ) {
        switch envelope.type {
        case "session":
            state.sessionID = envelope.id
        case "model_change":
            state.provider = envelope.provider
            state.model = envelope.modelID
        case "message":
            guard let usage = envelope.message?.usage else {
                return
            }
            guard let sessionID = state.sessionID,
                  let eventID = envelope.id,
                  let occurredAt = Self.parseDate(envelope.timestamp)
            else {
                diagnostics.append(
                    CollectorDiagnostic(
                        source: .senpi,
                        line: lineNumber,
                        message: "Malformed usage row"
                    )
                )
                return
            }
            let provider = envelope.message?.provider ?? state.provider ?? "unknown"
            let model = envelope.message?.model ?? state.model ?? "unknown"
            events.append(
                pricingCatalog.applying(to: UsageEvent(
                    id: UsageEvent.stableID(
                        source: .senpi,
                        sessionID: sessionID,
                        eventID: eventID,
                        usageSequence: 0
                    ),
                    deviceID: deviceID,
                    source: .senpi,
                    sessionID: sessionID,
                    eventID: eventID,
                    occurredAt: occurredAt,
                    provider: provider,
                    model: model,
                    inputTokens: usage.input,
                    outputTokens: usage.output,
                    cacheReadTokens: usage.cacheRead,
                    cacheWriteTokens: usage.cacheWrite,
                    totalTokens: usage.totalTokens,
                    estimatedCostUSD: usage.cost?.total,
                    pricingVersion: nil
                ), version: pricingVersion)
            )
        default:
            return
        }
    }

    private static func parseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    private static func looksIncomplete(_ data: Data) -> Bool {
        var braces = 0
        var brackets = 0
        var inString = false
        var escaped = false

        for byte in data {
            if escaped {
                escaped = false
                continue
            }
            if byte == 0x5C, inString {
                escaped = true
            } else if byte == 0x22 {
                inString.toggle()
            } else if !inString {
                if byte == 0x7B { braces += 1 }
                if byte == 0x7D { braces -= 1 }
                if byte == 0x5B { brackets += 1 }
                if byte == 0x5D { brackets -= 1 }
            }
        }
        return inString || braces > 0 || brackets > 0
    }
}

private struct ParseState {
    var sessionID: String?
    var provider: String?
    var model: String?
}

private struct SenpiEnvelope: Decodable {
    let type: String
    let id: String?
    let timestamp: String?
    let provider: String?
    let modelID: String?
    let message: SenpiMessage?

    private enum CodingKeys: String, CodingKey {
        case type
        case id
        case timestamp
        case provider
        case modelID = "modelId"
        case message
    }
}

private struct SenpiMessage: Decodable {
    let provider: String?
    let model: String?
    let usage: SenpiUsage?
}

private struct SenpiUsage: Decodable {
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite: Int
    let totalTokens: Int
    let cost: SenpiCost?
}

private struct SenpiCost: Decodable {
    let total: Decimal?
}
