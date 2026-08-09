import CryptoKit
import Foundation

public enum UsageSource: String, Codable, CaseIterable, Hashable, Sendable {
    case senpi
    case codex
    case claude
}

public struct UsageEvent: Codable, Hashable, Sendable {
    public let id: String
    public let deviceID: String
    public let source: UsageSource
    public let sessionID: String
    public let eventID: String
    public let occurredAt: Date
    public let provider: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let totalTokens: Int
    public let estimatedCostUSD: Decimal?
    public let pricingVersion: String?

    public init(
        id: String,
        deviceID: String,
        source: UsageSource,
        sessionID: String,
        eventID: String,
        occurredAt: Date,
        provider: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalTokens: Int,
        estimatedCostUSD: Decimal?,
        pricingVersion: String?
    ) {
        self.id = id
        self.deviceID = deviceID
        self.source = source
        self.sessionID = sessionID
        self.eventID = eventID
        self.occurredAt = occurredAt
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.pricingVersion = pricingVersion
    }

    public static func stableID(
        source: UsageSource,
        sessionID: String,
        eventID: String,
        usageSequence: Int
    ) -> String {
        let identity = [
            source.rawValue,
            sessionID,
            eventID,
            String(usageSequence),
        ].joined(separator: "\u{1F}")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

public struct DailyUsage: Codable, Hashable, Sendable {
    public let day: Date
    public let deviceID: String
    public let source: UsageSource
    public let provider: String
    public let model: String
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheReadTokens: Int
    public let cacheWriteTokens: Int
    public let totalTokens: Int
    public let estimatedCostUSD: Decimal
    public let eventCount: Int
    public let isCostComplete: Bool

    public init(
        day: Date,
        deviceID: String,
        source: UsageSource,
        provider: String,
        model: String,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheWriteTokens: Int,
        totalTokens: Int,
        estimatedCostUSD: Decimal,
        eventCount: Int,
        isCostComplete: Bool = true
    ) {
        self.day = day
        self.deviceID = deviceID
        self.source = source
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
        self.estimatedCostUSD = estimatedCostUSD
        self.eventCount = eventCount
        self.isCostComplete = isCostComplete
    }
}

public struct QuotaAccountProfile: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let provider: LiveQuotaProvider
    public let displayName: String
    public let createdAt: Date

    public init(
        id: String,
        provider: LiveQuotaProvider,
        displayName: String,
        createdAt: Date
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.createdAt = createdAt
    }

    public static func make(
        provider: LiveQuotaProvider,
        displayName: String,
        createdAt: Date = .now
    ) -> Self {
        var generator = SystemRandomNumberGenerator()
        let bytes = Data(
            (0..<32).map { _ in
                UInt8.random(in: .min ... .max, using: &generator)
            }
        )
        let identifier = bytes.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return Self(
            id: identifier,
            provider: provider,
            displayName: displayName,
            createdAt: createdAt
        )
    }
}

public struct QuotaSnapshot: Codable, Hashable, Sendable {
    public let provider: String
    public let accountPseudonym: String
    public let capturedAt: Date
    public let windowKind: String
    public let usedPercent: Decimal
    public let resetsAt: Date?
    public let source: String

    public init(
        provider: String,
        accountPseudonym: String,
        capturedAt: Date,
        windowKind: String,
        usedPercent: Decimal,
        resetsAt: Date?,
        source: String
    ) {
        self.provider = provider
        self.accountPseudonym = accountPseudonym
        self.capturedAt = capturedAt
        self.windowKind = windowKind
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.source = source
    }
}

public struct CollectorCursor: Codable, Hashable, Sendable {
    public let source: UsageSource
    public let sourcePathHash: String
    public let fileResourceIdentifier: String
    public let fileSize: Int64
    public let modifiedAt: Date
    public let lastParsedByteOffset: Int64
    public let parserVersion: Int
    public let lastSuccessfulEventID: String?
    public let resumeState: CollectorResumeState?

    public init(
        source: UsageSource,
        sourcePathHash: String,
        fileResourceIdentifier: String,
        fileSize: Int64,
        modifiedAt: Date,
        lastParsedByteOffset: Int64,
        parserVersion: Int,
        lastSuccessfulEventID: String?,
        resumeState: CollectorResumeState?
    ) {
        self.source = source
        self.sourcePathHash = sourcePathHash
        self.fileResourceIdentifier = fileResourceIdentifier
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
        self.lastParsedByteOffset = lastParsedByteOffset
        self.parserVersion = parserVersion
        self.lastSuccessfulEventID = lastSuccessfulEventID
        self.resumeState = resumeState
    }
}

public struct Device: Codable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let lastCollectedAt: Date?
    public let lastSyncedAt: Date?

    public init(
        id: String,
        name: String,
        lastCollectedAt: Date?,
        lastSyncedAt: Date?
    ) {
        self.id = id
        self.name = name
        self.lastCollectedAt = lastCollectedAt
        self.lastSyncedAt = lastSyncedAt
    }
}
