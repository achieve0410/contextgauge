import CSQLite
import Foundation

extension SQLiteUsageStore {
    public func commit(
        events: [UsageEvent],
        cursor: CollectorCursor
    ) throws -> Int {
        try execute("BEGIN IMMEDIATE")
        do {
            var inserted = 0
            for event in events {
                inserted += try insert(event)
            }
            try upsert(cursor)
            try execute("COMMIT")
            return inserted
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func cursor(for sourcePathHash: String) throws -> CollectorCursor? {
        let sql = """
            SELECT source, file_resource_identifier, file_size, modified_at,
                   last_parsed_byte_offset, parser_version,
                   last_successful_event_id, parser_state_json
            FROM collector_cursors WHERE source_path_hash = ?
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(sourcePathHash, at: 1, to: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        guard let source = UsageSource(rawValue: text(statement, column: 0)) else {
            throw SQLiteUsageStoreError.step("Unknown collector source")
        }
        let state: CollectorResumeState?
        if sqlite3_column_type(statement, 7) == SQLITE_NULL {
            state = nil
        } else {
            state = try JSONDecoder().decode(
                CollectorResumeState.self,
                from: Data(text(statement, column: 7).utf8)
            )
        }
        return CollectorCursor(
            source: source,
            sourcePathHash: sourcePathHash,
            fileResourceIdentifier: text(statement, column: 1),
            fileSize: sqlite3_column_int64(statement, 2),
            modifiedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
            lastParsedByteOffset: sqlite3_column_int64(statement, 4),
            parserVersion: Int(sqlite3_column_int64(statement, 5)),
            lastSuccessfulEventID: optionalText(statement, column: 6),
            resumeState: state
        )
    }

    public func eventCount() throws -> Int {
        try scalarInt("SELECT COUNT(*) FROM usage_events")
    }

    public func totalTokens() throws -> Int {
        try scalarInt("SELECT COALESCE(SUM(total_tokens), 0) FROM usage_events")
    }

    public func reset(
        source: UsageSource,
        deviceID: String
    ) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            let eventStatement = try prepare(
                "DELETE FROM usage_events WHERE source = ? AND device_id = ?"
            )
            defer { sqlite3_finalize(eventStatement) }
            try bind(source.rawValue, at: 1, to: eventStatement)
            try bind(deviceID, at: 2, to: eventStatement)
            guard sqlite3_step(eventStatement) == SQLITE_DONE else {
                throw SQLiteUsageStoreError.step(errorMessage)
            }
            let cursorStatement = try prepare(
                "DELETE FROM collector_cursors WHERE source = ?"
            )
            defer { sqlite3_finalize(cursorStatement) }
            try bind(source.rawValue, at: 1, to: cursorStatement)
            guard sqlite3_step(cursorStatement) == SQLITE_DONE else {
                throw SQLiteUsageStoreError.step(errorMessage)
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func usageEvents() throws -> [UsageEvent] {
        let sql = """
            SELECT id, device_id, source, session_id, event_id, occurred_at,
                   provider, model, input_tokens, output_tokens,
                   cache_read_tokens, cache_write_tokens, total_tokens,
                   estimated_cost_usd, pricing_version
            FROM usage_events ORDER BY occurred_at, id
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        var events: [UsageEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let source = UsageSource(rawValue: text(statement, column: 2))
            else {
                throw SQLiteUsageStoreError.step("Unknown usage source")
            }
            events.append(
                UsageEvent(
                    id: text(statement, column: 0),
                    deviceID: text(statement, column: 1),
                    source: source,
                    sessionID: text(statement, column: 3),
                    eventID: text(statement, column: 4),
                    occurredAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(statement, 5)
                    ),
                    provider: text(statement, column: 6),
                    model: text(statement, column: 7),
                    inputTokens: Int(sqlite3_column_int64(statement, 8)),
                    outputTokens: Int(sqlite3_column_int64(statement, 9)),
                    cacheReadTokens: Int(sqlite3_column_int64(statement, 10)),
                    cacheWriteTokens: Int(sqlite3_column_int64(statement, 11)),
                    totalTokens: Int(sqlite3_column_int64(statement, 12)),
                    estimatedCostUSD: optionalText(statement, column: 13)
                        .flatMap { Decimal(string: $0) },
                    pricingVersion: optionalText(statement, column: 14)
                )
            )
        }
        guard sqlite3_errcode(database) == SQLITE_OK
                || sqlite3_errcode(database) == SQLITE_DONE
        else {
            throw SQLiteUsageStoreError.step(errorMessage)
        }
        return events
    }

    private func insert(_ event: UsageEvent) throws -> Int {
        let sql = """
            INSERT INTO usage_events (
                id, device_id, source, session_id, event_id, occurred_at,
                provider, model, input_tokens, output_tokens, cache_read_tokens,
                cache_write_tokens, total_tokens, estimated_cost_usd,
                pricing_version
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                device_id = excluded.device_id,
                source = excluded.source,
                session_id = excluded.session_id,
                event_id = excluded.event_id,
                occurred_at = excluded.occurred_at,
                provider = excluded.provider,
                model = excluded.model,
                input_tokens = excluded.input_tokens,
                output_tokens = excluded.output_tokens,
                cache_read_tokens = excluded.cache_read_tokens,
                cache_write_tokens = excluded.cache_write_tokens,
                total_tokens = excluded.total_tokens,
                estimated_cost_usd = excluded.estimated_cost_usd,
                pricing_version = excluded.pricing_version
            WHERE usage_events.device_id IS NOT excluded.device_id
                OR usage_events.source IS NOT excluded.source
                OR usage_events.session_id IS NOT excluded.session_id
                OR usage_events.event_id IS NOT excluded.event_id
                OR usage_events.occurred_at IS NOT excluded.occurred_at
                OR usage_events.provider IS NOT excluded.provider
                OR usage_events.model IS NOT excluded.model
                OR usage_events.input_tokens IS NOT excluded.input_tokens
                OR usage_events.output_tokens IS NOT excluded.output_tokens
                OR usage_events.cache_read_tokens
                    IS NOT excluded.cache_read_tokens
                OR usage_events.cache_write_tokens
                    IS NOT excluded.cache_write_tokens
                OR usage_events.total_tokens IS NOT excluded.total_tokens
                OR usage_events.estimated_cost_usd
                    IS NOT excluded.estimated_cost_usd
                OR usage_events.pricing_version IS NOT excluded.pricing_version
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        let values = [
            event.id,
            event.deviceID,
            event.source.rawValue,
            event.sessionID,
            event.eventID,
        ]
        for (offset, value) in values.enumerated() {
            try bind(value, at: Int32(offset + 1), to: statement)
        }
        sqlite3_bind_double(statement, 6, event.occurredAt.timeIntervalSince1970)
        try bind(event.provider, at: 7, to: statement)
        try bind(event.model, at: 8, to: statement)
        sqlite3_bind_int64(statement, 9, Int64(event.inputTokens))
        sqlite3_bind_int64(statement, 10, Int64(event.outputTokens))
        sqlite3_bind_int64(statement, 11, Int64(event.cacheReadTokens))
        sqlite3_bind_int64(statement, 12, Int64(event.cacheWriteTokens))
        sqlite3_bind_int64(statement, 13, Int64(event.totalTokens))
        try bind(event.estimatedCostUSD.map(Self.decimalString), at: 14, to: statement)
        try bind(event.pricingVersion, at: 15, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteUsageStoreError.step(errorMessage)
        }
        return Int(sqlite3_changes(database))
    }

    private func upsert(_ cursor: CollectorCursor) throws {
        let sql = """
            INSERT INTO collector_cursors (
                source_path_hash, source, file_resource_identifier, file_size,
                modified_at, last_parsed_byte_offset, parser_version,
                last_successful_event_id, parser_state_json
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(source_path_hash) DO UPDATE SET
                source = excluded.source,
                file_resource_identifier = excluded.file_resource_identifier,
                file_size = excluded.file_size,
                modified_at = excluded.modified_at,
                last_parsed_byte_offset = excluded.last_parsed_byte_offset,
                parser_version = excluded.parser_version,
                last_successful_event_id = excluded.last_successful_event_id,
                parser_state_json = excluded.parser_state_json
            """
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        try bind(cursor.sourcePathHash, at: 1, to: statement)
        try bind(cursor.source.rawValue, at: 2, to: statement)
        try bind(cursor.fileResourceIdentifier, at: 3, to: statement)
        sqlite3_bind_int64(statement, 4, cursor.fileSize)
        sqlite3_bind_double(statement, 5, cursor.modifiedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 6, cursor.lastParsedByteOffset)
        sqlite3_bind_int64(statement, 7, Int64(cursor.parserVersion))
        try bind(cursor.lastSuccessfulEventID, at: 8, to: statement)
        let state = try cursor.resumeState.map {
            String(decoding: try JSONEncoder().encode($0), as: UTF8.self)
        }
        try bind(state, at: 9, to: statement)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw SQLiteUsageStoreError.step(errorMessage)
        }
    }

    private func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else {
            throw SQLiteUsageStoreError.step(errorMessage)
        }
        return Int(sqlite3_column_int64(statement, 0))
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteUsageStoreError.prepare(errorMessage)
        }
        return statement
    }

    func bind(
        _ value: String?,
        at index: Int32,
        to statement: OpaquePointer
    ) throws {
        let result: Int32
        if let value {
            result = sqlite3_bind_text(statement, index, value, -1, Self.transient)
        } else {
            result = sqlite3_bind_null(statement, index)
        }
        guard result == SQLITE_OK else {
            throw SQLiteUsageStoreError.step(errorMessage)
        }
    }

    func text(_ statement: OpaquePointer, column: Int32) -> String {
        String(cString: sqlite3_column_text(statement, column))
    }

    private func optionalText(
        _ statement: OpaquePointer,
        column: Int32
    ) -> String? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else { return nil }
        return text(statement, column: column)
    }

    static func decimalString(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    static let transient = unsafeBitCast(
        -1,
        to: sqlite3_destructor_type.self
    )
}
