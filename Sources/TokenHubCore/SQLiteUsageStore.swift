import CSQLite
import Foundation

public enum SQLiteUsageStoreError: Error, Equatable {
    case openDatabase(String)
    case execute(String)
    case prepare(String)
    case step(String)
}

public final class SQLiteUsageStore {
    let database: OpaquePointer

    public init(databaseURL: URL) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        let result = sqlite3_open_v2(databaseURL.path, &connection, flags, nil)
        guard result == SQLITE_OK, let connection else {
            let message = connection.map { String(cString: sqlite3_errmsg($0)) }
                ?? "SQLite returned \(result)"
            if let connection {
                sqlite3_close_v2(connection)
            }
            throw SQLiteUsageStoreError.openDatabase(message)
        }
        database = connection
        sqlite3_busy_timeout(database, 5_000)
        do {
            try migrate()
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
    }

    deinit {
        sqlite3_close_v2(database)
    }

    public func tableNames() throws -> Set<String> {
        let sql = """
            SELECT name
            FROM sqlite_master
            WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement
        else {
            throw SQLiteUsageStoreError.prepare(errorMessage)
        }
        defer { sqlite3_finalize(statement) }

        var names = Set<String>()
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW:
                if let text = sqlite3_column_text(statement, 0) {
                    names.insert(String(cString: text))
                }
            case SQLITE_DONE:
                return names
            default:
                throw SQLiteUsageStoreError.step(errorMessage)
            }
        }
    }

    var errorMessage: String {
        String(cString: sqlite3_errmsg(database))
    }

    private func migrate() throws {
        try execute("BEGIN IMMEDIATE")
        do {
            for statement in Self.schemaStatements {
                try execute(statement)
            }
            if try !hasColumn("is_cost_complete", in: "daily_usage") {
                try execute(
                    """
                    ALTER TABLE daily_usage
                    ADD COLUMN is_cost_complete INTEGER NOT NULL DEFAULT 1
                    """
                )
            }
            try execute(
                "INSERT OR IGNORE INTO schema_migrations(version) VALUES (1)"
            )
            try execute(
                "INSERT OR IGNORE INTO schema_migrations(version) VALUES (2)"
            )
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &message)
        guard result == SQLITE_OK else {
            let detail = message.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(message)
            throw SQLiteUsageStoreError.execute(detail)
        }
    }

    private func hasColumn(
        _ column: String,
        in table: String
    ) throws -> Bool {
        var statement: OpaquePointer?
        let sql = "PRAGMA table_info(\(table))"
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil)
                == SQLITE_OK,
              let statement
        else {
            throw SQLiteUsageStoreError.prepare(errorMessage)
        }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let name = sqlite3_column_text(statement, 1) else {
                continue
            }
            if String(cString: name) == column {
                return true
            }
        }
        return false
    }

    private static let schemaStatements = [
        """
        CREATE TABLE IF NOT EXISTS usage_events (
            id TEXT PRIMARY KEY,
            device_id TEXT NOT NULL,
            source TEXT NOT NULL,
            session_id TEXT NOT NULL,
            event_id TEXT NOT NULL,
            occurred_at REAL NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_write_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            estimated_cost_usd TEXT,
            pricing_version TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS daily_usage (
            day REAL NOT NULL,
            device_id TEXT NOT NULL,
            source TEXT NOT NULL,
            provider TEXT NOT NULL,
            model TEXT NOT NULL,
            input_tokens INTEGER NOT NULL,
            output_tokens INTEGER NOT NULL,
            cache_read_tokens INTEGER NOT NULL,
            cache_write_tokens INTEGER NOT NULL,
            total_tokens INTEGER NOT NULL,
            estimated_cost_usd TEXT NOT NULL,
            event_count INTEGER NOT NULL,
            is_cost_complete INTEGER NOT NULL DEFAULT 1,
            PRIMARY KEY (day, device_id, source, provider, model)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS collector_cursors (
            source_path_hash TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            file_resource_identifier TEXT NOT NULL,
            file_size INTEGER NOT NULL,
            modified_at REAL NOT NULL,
            last_parsed_byte_offset INTEGER NOT NULL,
            parser_version INTEGER NOT NULL,
            last_successful_event_id TEXT,
            parser_state_json TEXT
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS quota_snapshots (
            provider TEXT NOT NULL,
            account_hash TEXT NOT NULL,
            captured_at REAL NOT NULL,
            window_kind TEXT NOT NULL,
            used_percent TEXT NOT NULL,
            resets_at REAL,
            source TEXT NOT NULL,
            PRIMARY KEY (provider, account_hash, window_kind, captured_at)
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS devices (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            last_collected_at REAL,
            last_synced_at REAL
        )
        """,
        """
        CREATE TABLE IF NOT EXISTS schema_migrations (
            version INTEGER PRIMARY KEY,
            applied_at REAL NOT NULL DEFAULT (unixepoch())
        )
        """,
    ]
}
