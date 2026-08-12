import CSQLite
import Foundation

extension SQLiteUsageStore {
    public func replaceDailyUsage(_ usage: [DailyUsage]) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM daily_usage")
            for aggregate in usage {
                let statement = try prepare(
                    """
                    INSERT INTO daily_usage (
                        day, device_id, source, provider, model, input_tokens,
                        output_tokens, cache_read_tokens, cache_write_tokens,
                        total_tokens, estimated_cost_usd, event_count,
                        is_cost_complete
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(statement) }
                sqlite3_bind_double(
                    statement,
                    1,
                    aggregate.day.timeIntervalSince1970
                )
                try bind(aggregate.deviceID, at: 2, to: statement)
                try bind(aggregate.source.rawValue, at: 3, to: statement)
                try bind(aggregate.provider, at: 4, to: statement)
                try bind(aggregate.model, at: 5, to: statement)
                sqlite3_bind_int64(
                    statement,
                    6,
                    Int64(aggregate.inputTokens)
                )
                sqlite3_bind_int64(
                    statement,
                    7,
                    Int64(aggregate.outputTokens)
                )
                sqlite3_bind_int64(
                    statement,
                    8,
                    Int64(aggregate.cacheReadTokens)
                )
                sqlite3_bind_int64(
                    statement,
                    9,
                    Int64(aggregate.cacheWriteTokens)
                )
                sqlite3_bind_int64(
                    statement,
                    10,
                    Int64(aggregate.totalTokens)
                )
                try bind(
                    Self.decimalString(aggregate.estimatedCostUSD),
                    at: 11,
                    to: statement
                )
                sqlite3_bind_int64(
                    statement,
                    12,
                    Int64(aggregate.eventCount)
                )
                sqlite3_bind_int64(
                    statement,
                    13,
                    aggregate.isCostComplete ? 1 : 0
                )
                guard sqlite3_step(statement) == SQLITE_DONE else {
                    throw SQLiteUsageStoreError.step(errorMessage)
                }
            }
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func dailyUsage() throws -> [DailyUsage] {
        let statement = try prepare(
            """
            SELECT day, device_id, source, provider, model, input_tokens,
                   output_tokens, cache_read_tokens, cache_write_tokens,
                   total_tokens, estimated_cost_usd, event_count,
                   is_cost_complete
            FROM daily_usage
            ORDER BY day, device_id, source, provider, model
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [DailyUsage] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            guard let source = UsageSource(rawValue: text(statement, column: 2))
            else {
                throw SQLiteUsageStoreError.step("Unknown usage source")
            }
            result.append(
                DailyUsage(
                    day: Date(
                        timeIntervalSince1970: sqlite3_column_double(
                            statement,
                            0
                        )
                    ),
                    deviceID: text(statement, column: 1),
                    source: source,
                    provider: text(statement, column: 3),
                    model: text(statement, column: 4),
                    inputTokens: Int(sqlite3_column_int64(statement, 5)),
                    outputTokens: Int(sqlite3_column_int64(statement, 6)),
                    cacheReadTokens: Int(sqlite3_column_int64(statement, 7)),
                    cacheWriteTokens: Int(sqlite3_column_int64(statement, 8)),
                    totalTokens: Int(sqlite3_column_int64(statement, 9)),
                    estimatedCostUSD: Decimal(
                        string: text(statement, column: 10)
                    ) ?? .zero,
                    eventCount: Int(sqlite3_column_int64(statement, 11)),
                    isCostComplete: sqlite3_column_int64(statement, 12) != 0
                )
            )
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw SQLiteUsageStoreError.step(errorMessage)
        }
        return result
    }

    public func upsertDevices(_ devices: [Device]) throws {
        for device in devices {
            let statement = try prepare(
                """
                INSERT INTO devices (
                    id, name, last_collected_at, last_synced_at
                ) VALUES (?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    name = excluded.name,
                    last_collected_at = COALESCE(
                        excluded.last_collected_at,
                        devices.last_collected_at
                    ),
                    last_synced_at = COALESCE(
                        excluded.last_synced_at,
                        devices.last_synced_at
                    )
                """
            )
            defer { sqlite3_finalize(statement) }
            try bind(device.id, at: 1, to: statement)
            try bind(device.name, at: 2, to: statement)
            bind(device.lastCollectedAt, at: 3, to: statement)
            bind(device.lastSyncedAt, at: 4, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw SQLiteUsageStoreError.step(errorMessage)
            }
        }
    }

    public func devices() throws -> [Device] {
        let statement = try prepare(
            """
            SELECT id, name, last_collected_at, last_synced_at
            FROM devices ORDER BY id
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [Device] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            result.append(
                Device(
                    id: text(statement, column: 0),
                    name: text(statement, column: 1),
                    lastCollectedAt: date(statement, column: 2),
                    lastSyncedAt: date(statement, column: 3)
                )
            )
            stepResult = sqlite3_step(statement)
        }
        guard stepResult == SQLITE_DONE else {
            throw SQLiteUsageStoreError.step(errorMessage)
        }
        return result
    }

    private func bind(
        _ value: Date?,
        at index: Int32,
        to statement: OpaquePointer
    ) {
        if let value {
            sqlite3_bind_double(statement, index, value.timeIntervalSince1970)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }

    private func date(
        _ statement: OpaquePointer,
        column: Int32
    ) -> Date? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL else {
            return nil
        }
        return Date(
            timeIntervalSince1970: sqlite3_column_double(statement, column)
        )
    }
}
