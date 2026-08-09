import CSQLite
import Foundation

extension SQLiteUsageStore {
    public func replaceQuotaSnapshots(
        _ snapshots: [QuotaSnapshot]
    ) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM quota_snapshots")
            for snapshot in snapshots {
                let statement = try prepare(
                    """
                    INSERT INTO quota_snapshots (
                        provider, account_hash, captured_at, window_kind,
                        used_percent, resets_at, source
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """
                )
                defer { sqlite3_finalize(statement) }
                try bind(snapshot.provider, at: 1, to: statement)
                try bind(snapshot.accountPseudonym, at: 2, to: statement)
                sqlite3_bind_double(
                    statement,
                    3,
                    snapshot.capturedAt.timeIntervalSince1970
                )
                try bind(snapshot.windowKind, at: 4, to: statement)
                try bind(
                    Self.decimalString(snapshot.usedPercent),
                    at: 5,
                    to: statement
                )
                if let resetsAt = snapshot.resetsAt {
                    sqlite3_bind_double(
                        statement,
                        6,
                        resetsAt.timeIntervalSince1970
                    )
                } else {
                    sqlite3_bind_null(statement, 6)
                }
                try bind(snapshot.source, at: 7, to: statement)
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

    public func quotaSnapshots() throws -> [QuotaSnapshot] {
        let statement = try prepare(
            """
            SELECT provider, account_hash, captured_at, window_kind,
                   used_percent, resets_at, source
            FROM quota_snapshots
            ORDER BY provider, account_hash, window_kind, captured_at
            """
        )
        defer { sqlite3_finalize(statement) }
        var result: [QuotaSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let resetsAt: Date?
            if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                resetsAt = nil
            } else {
                resetsAt = Date(
                    timeIntervalSince1970: sqlite3_column_double(statement, 5)
                )
            }
            result.append(
                QuotaSnapshot(
                    provider: text(statement, column: 0),
                    accountPseudonym: text(statement, column: 1),
                    capturedAt: Date(
                        timeIntervalSince1970: sqlite3_column_double(
                            statement,
                            2
                        )
                    ),
                    windowKind: text(statement, column: 3),
                    usedPercent: Decimal(
                        string: text(statement, column: 4)
                    ) ?? .zero,
                    resetsAt: resetsAt,
                    source: text(statement, column: 6)
                )
            )
        }
        return result
    }
}
