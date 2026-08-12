import Foundation

public struct ClaudeUsageCollector: UsageCollector {
    public let source = UsageSource.claude
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
            if line.isEmpty { consumed = data.distance(from: data.startIndex, to: next); cursor = next; continue }
            do {
                guard let row = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw ParseError.invalidRow }
                if row["type"] as? String == "assistant",
                   let message = row["message"] as? [String: Any],
                   let usage = message["usage"] as? [String: Any]
                {
                    guard let sessionID = Self.sessionID(
                        row: row,
                        message: message
                    ),
                    let messageID = message["id"] as? String,
                    let requestID =
                        row["requestId"] as? String
                            ?? row["request_id"] as? String,
                    let timestamp = row["timestamp"] as? String,
                    let occurredAt = Self.parseDate(timestamp),
                    let input = Self.integer(
                        usage["input_tokens"],
                        required: true
                    ),
                    let output = Self.integer(
                        usage["output_tokens"],
                        required: true
                    ),
                    let cacheRead = Self.integer(
                        usage["cache_read_input_tokens"]
                    ),
                    let cacheWrite = Self.integer(
                        usage["cache_creation_input_tokens"]
                    )
                    else {
                        throw ParseError.invalidRow
                    }
                    let eventID = "\(messageID):\(requestID)"
                    let event = pricingCatalog.applying(to: UsageEvent(
                        id: UsageEvent.stableID(source: .claude, sessionID: sessionID, eventID: eventID, usageSequence: 0),
                        deviceID: deviceID, source: .claude, sessionID: sessionID, eventID: eventID,
                        occurredAt: occurredAt, provider: "anthropic", model: message["model"] as? String ?? "unknown",
                        inputTokens: input, outputTokens: output, cacheReadTokens: cacheRead, cacheWriteTokens: cacheWrite,
                        totalTokens: input + output + cacheRead + cacheWrite, estimatedCostUSD: nil, pricingVersion: nil
                    ), version: pricingVersion)
                    if keyedEvents[eventID] == nil { eventOrder.append(eventID) }
                    keyedEvents[eventID] = event
                }
            } catch {
                if next == data.endIndex, Self.looksIncomplete(line) { break }
                diagnostics.append(.init(source: .claude, line: lineNumber, message: "Malformed JSONL row"))
            }
            consumed = data.distance(from: data.startIndex, to: next)
            cursor = next
        }
        return .init(events: eventOrder.compactMap { keyedEvents[$0] }, diagnostics: diagnostics, consumedByteCount: consumed)
    }

    private static func sessionID(row: [String: Any], message: [String: Any]) -> String? {
        if let value = row["sessionId"] as? String ?? row["session_id"] as? String { return value }
        if let metadata = row["metadata"] as? [String: Any], let value = metadata["sessionId"] as? String { return value }
        if let metadata = message["metadata"] as? [String: Any] { return metadata["sessionId"] as? String }
        return nil
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
