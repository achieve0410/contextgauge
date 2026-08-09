import Foundation

public protocol UsageCollector: Sendable {
    var source: UsageSource { get }
    var deviceID: String { get }
    func parse(_ data: Data) -> CollectorParseResult
}

public protocol IncrementalUsageCollector: UsageCollector {
    func parse(
        _ data: Data,
        resumingFrom state: CollectorResumeState?
    ) -> CollectorParseResult
}

public struct CollectorResumeState: Codable, Hashable, Sendable {
    public let sessionID: String?
    public let provider: String?
    public let model: String?
    public let eventID: String?
    public let usageSequence: Int?

    public init(
        sessionID: String?,
        provider: String?,
        model: String?,
        eventID: String? = nil,
        usageSequence: Int? = nil
    ) {
        self.sessionID = sessionID
        self.provider = provider
        self.model = model
        self.eventID = eventID
        self.usageSequence = usageSequence
    }
}

public struct CollectorDiagnostic: Codable, Hashable, Sendable {
    public let source: UsageSource
    public let line: Int
    public let message: String

    public init(source: UsageSource, line: Int, message: String) {
        self.source = source
        self.line = line
        self.message = message
    }
}

public struct CollectorParseResult: Hashable, Sendable {
    public let events: [UsageEvent]
    public let diagnostics: [CollectorDiagnostic]
    public let consumedByteCount: Int
    public let resumeState: CollectorResumeState?

    public init(
        events: [UsageEvent],
        diagnostics: [CollectorDiagnostic],
        consumedByteCount: Int,
        resumeState: CollectorResumeState? = nil
    ) {
        self.events = events
        self.diagnostics = diagnostics
        self.consumedByteCount = consumedByteCount
        self.resumeState = resumeState
    }
}
