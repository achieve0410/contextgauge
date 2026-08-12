import Foundation

public struct CodexUsageCollector: IncrementalUsageCollector {
    public let source = UsageSource.codex
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
        resumingFrom state: CollectorResumeState?
    ) -> CollectorParseResult {
        var sessionID = state?.sessionID
        var model = state?.model
        var turnID = state?.eventID
        var usageSequence = state?.usageSequence ?? 0
        var keyedEvents: [String: UsageEvent] = [:]
        var eventOrder: [String] = []
        var diagnostics: [CollectorDiagnostic] = []
        var consumed = 0
        var cursor = data.startIndex
        var lineNumber = 0

        while cursor < data.endIndex {
            lineNumber += 1
            let newline = data[cursor...].firstIndex(of: 0x0A)
            let end = newline ?? data.endIndex
            let next = newline.map { data.index(after: $0) } ?? data.endIndex
            let line = Data(data[cursor..<end])
            if line.isEmpty {
                consumed = data.distance(from: data.startIndex, to: next)
                cursor = next
                continue
            }
            do {
                guard let row = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw ParseError.invalidRow
                }
                let type = row["type"] as? String
                let payload = row["payload"] as? [String: Any]
                if type == "session_meta" {
                    sessionID = payload?["id"] as? String
                    model = nil
                    turnID = nil
                    usageSequence = 0
                } else if type == "turn_context" {
                    model = payload?["model"] as? String
                    let nextTurnID = Self.identity(in: payload)
                    if nextTurnID != turnID {
                        usageSequence = 0
                    }
                    turnID = nextTurnID
                } else if type == "event_msg",
                          payload?["type"] as? String == "token_count"
                {
                    guard let info = payload?["info"] as? [String: Any],
                          let sessionID,
                          let usage = (
                              info["last_token_usage"]
                                  ?? info["total_token_usage"]
                          ) as? [String: Any],
                          let timestamp = row["timestamp"] as? String,
                          let occurredAt = Self.parseDate(timestamp),
                          let rawInput = Self.integer(
                              usage["input_tokens"],
                              required: true
                          ),
                          let cache = Self.integer(
                              usage["cached_input_tokens"]
                          ),
                          let output = Self.integer(
                              usage["output_tokens"],
                              required: true
                          )
                    else {
                        throw ParseError.invalidRow
                    }
                    let eventID = Self.identity(in: info) ?? turnID ?? timestamp
                    let input = max(0, rawInput - cache)
                    let event = pricingCatalog.applying(to: UsageEvent(
                        id: UsageEvent.stableID(source: .codex, sessionID: "turn", eventID: eventID, usageSequence: usageSequence),
                        deviceID: deviceID, source: .codex, sessionID: sessionID, eventID: eventID,
                        occurredAt: occurredAt, provider: "openai", model: (info["model"] as? String) ?? model ?? "unknown",
                        inputTokens: input, outputTokens: output, cacheReadTokens: cache, cacheWriteTokens: 0,
                        totalTokens: input + cache + output, estimatedCostUSD: nil, pricingVersion: nil
                    ), version: pricingVersion)
                    if keyedEvents[event.id] == nil {
                        eventOrder.append(event.id)
                        keyedEvents[event.id] = event
                    }
                    usageSequence += 1
                }
            } catch {
                if next == data.endIndex, Self.looksIncomplete(line) { break }
                diagnostics.append(.init(source: .codex, line: lineNumber, message: "Malformed JSONL row"))
            }
            consumed = data.distance(from: data.startIndex, to: next)
            cursor = next
        }
        return .init(
            events: eventOrder.compactMap { keyedEvents[$0] },
            diagnostics: diagnostics,
            consumedByteCount: consumed,
            resumeState: CollectorResumeState(
                sessionID: sessionID,
                provider: "openai",
                model: model,
                eventID: turnID,
                usageSequence: usageSequence
            )
        )
    }

    private static func identity(in object: [String: Any]?) -> String? {
        ["turn_id", "turnId", "request_id", "requestId", "message_id", "messageId"].lazy.compactMap { object?[$0] as? String }.first
    }
    private static func integer(
        _ value: Any?,
        required: Bool = false
    ) -> Int? {
        guard let value else {
            return required ? nil : 0
        }
        guard let number = value as? NSNumber, number.intValue >= 0 else {
            return nil
        }
        return number.intValue
    }
    private static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    private static func looksIncomplete(_ data: Data) -> Bool {
        var braces = 0, brackets = 0; var inString = false, escaped = false
        for byte in data {
            if escaped { escaped = false; continue }
            if byte == 0x5C, inString { escaped = true }
            else if byte == 0x22 { inString.toggle() }
            else if !inString { if byte == 0x7B { braces += 1 }; if byte == 0x7D { braces -= 1 }; if byte == 0x5B { brackets += 1 }; if byte == 0x5D { brackets -= 1 } }
        }
        return inString || braces > 0 || brackets > 0
    }
    private enum ParseError: Error { case invalidRow }
}
