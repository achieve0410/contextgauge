import CryptoKit
import Foundation

public struct CollectionScanResult: Sendable {
    public let insertedEventCount: Int
    public let totalTokens: Int
    public let startingByteOffset: Int64
    public let bytesRead: Int
    public let cursor: CollectorCursor
    public let diagnostics: [CollectorDiagnostic]
}

public struct CollectionCoordinator {
    private let store: SQLiteUsageStore
    private let parserVersion: Int
    private let includeAggregateTotal: Bool

    public init(
        store: SQLiteUsageStore,
        parserVersion: Int,
        includeAggregateTotal: Bool = true
    ) {
        self.store = store
        self.parserVersion = parserVersion
        self.includeAggregateTotal = includeAggregateTotal
    }

    public func scan(
        fileURL: URL,
        collector: some UsageCollector
    ) throws -> CollectionScanResult {
        let metadata = try FileMetadata(url: fileURL)
        let pathHash = Self.pathHash(fileURL)
        var previous = try store.cursor(for: pathHash)
        if let cursor = previous, cursor.parserVersion != parserVersion {
            try store.reset(
                source: collector.source,
                deviceID: collector.deviceID
            )
            previous = nil
        }
        let canResume = previous.map {
            $0.parserVersion == parserVersion
                && $0.fileResourceIdentifier == metadata.resourceIdentifier
                && metadata.size >= $0.lastParsedByteOffset
        } ?? false
        let startingOffset = canResume ? previous?.lastParsedByteOffset ?? 0 : 0
        let resumeState = canResume ? previous?.resumeState : nil

        if let previous,
           canResume,
           previous.fileSize == metadata.size,
           previous.modifiedAt == metadata.modifiedAt,
           previous.lastParsedByteOffset == metadata.size
        {
            return CollectionScanResult(
                insertedEventCount: 0,
                totalTokens: includeAggregateTotal ? try store.totalTokens() : 0,
                startingByteOffset: metadata.size,
                bytesRead: 0,
                cursor: previous,
                diagnostics: []
            )
        }

        let data: Data
        if startingOffset == metadata.size {
            data = Data()
        } else {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }
            try handle.seek(toOffset: UInt64(startingOffset))
            data = try handle.readToEnd() ?? Data()
        }

        let parsed: CollectorParseResult
        if let incremental = collector as? any IncrementalUsageCollector {
            parsed = incremental.parse(data, resumingFrom: resumeState)
        } else {
            parsed = collector.parse(data)
        }
        let cursor = CollectorCursor(
            source: collector.source,
            sourcePathHash: pathHash,
            fileResourceIdentifier: metadata.resourceIdentifier,
            fileSize: metadata.size,
            modifiedAt: metadata.modifiedAt,
            lastParsedByteOffset: startingOffset + Int64(parsed.consumedByteCount),
            parserVersion: parserVersion,
            lastSuccessfulEventID: parsed.events.last?.id
                ?? previous?.lastSuccessfulEventID,
            resumeState: parsed.resumeState ?? resumeState
        )
        let inserted = try store.commit(events: parsed.events, cursor: cursor)
        return CollectionScanResult(
            insertedEventCount: inserted,
            totalTokens: includeAggregateTotal ? try store.totalTokens() : 0,
            startingByteOffset: startingOffset,
            bytesRead: data.count,
            cursor: cursor,
            diagnostics: parsed.diagnostics
        )
    }

    private static func pathHash(_ url: URL) -> String {
        let path = url.standardizedFileURL.path
        return SHA256.hash(data: Data(path.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

}

private struct FileMetadata {
    let resourceIdentifier: String
    let size: Int64
    let modifiedAt: Date

    init(url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let fileSize = (attributes[.size] as? NSNumber)?.int64Value
        guard let fileNumber, let fileSize else {
            throw CocoaError(.fileReadUnknown)
        }
        resourceIdentifier = String(fileNumber)
        size = fileSize
        modifiedAt = attributes[.modificationDate] as? Date ?? .distantPast
    }
}
