import Foundation
import SQLite3
import SwiftGraphQLCache
import SwiftGraphQLClient

public struct SQLiteNormalizedStoreConfiguration: Sendable, Equatable {
    public var fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }
}

public enum SQLiteNormalizedStoreError: LocalizedError, Sendable, Equatable {
    case openFailed(String)
    case sqlite(String)
    case invalidRow

    public var errorDescription: String? {
        switch self {
        case .openFailed(let message):
            return "Could not open SQLite normalized store: \(message)"
        case .sqlite(let message):
            return "SQLite normalized store error: \(message)"
        case .invalidRow:
            return "SQLite normalized store returned an invalid row."
        }
    }
}

public actor SQLiteNormalizedStore {
    public let configuration: SQLiteNormalizedStoreConfiguration

    private var db: OpaquePointer?
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(configuration: SQLiteNormalizedStoreConfiguration) throws {
        self.configuration = configuration
        try FileManager.default.createDirectory(
            at: configuration.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var openedDB: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(configuration.fileURL.path, &openedDB, flags, nil) == SQLITE_OK else {
            let message = openedDB.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let openedDB {
                sqlite3_close(openedDB)
            }
            throw SQLiteNormalizedStoreError.openFailed(message)
        }
        db = openedDB
        _ = try Self.execute(on: openedDB, sql: "PRAGMA journal_mode = WAL")
        _ = try Self.execute(on: openedDB, sql: "PRAGMA busy_timeout = 5000")
        _ = try Self.execute(on: openedDB, sql: """
        CREATE TABLE IF NOT EXISTS records (
          id TEXT PRIMARY KEY NOT NULL,
          fields BLOB NOT NULL,
          updated_at REAL NOT NULL
        )
        """)
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    public func read(_ id: GraphQLRecordID) throws -> GraphQLRecord? {
        try readRecord(id)
    }

    public func read(_ id: GraphQLRecordID, requiredFields: Set<String>) throws -> GraphQLCacheReadResult {
        let record = try readRecord(id)
        let fields = Set(record.map { Array($0.fields.keys) } ?? [])
        return GraphQLCacheReadResult(record: record, missingFields: requiredFields.subtracting(fields))
    }

    public func write(_ record: GraphQLRecord, merge: Bool = true) throws {
        let finalRecord: GraphQLRecord
        if merge, let existing = try readRecord(record.id) {
            finalRecord = existing.merging(record)
        } else {
            finalRecord = record
        }
        try saveRecord(finalRecord)
    }

    public func write(_ records: [GraphQLRecord], merge: Bool = true) throws {
        try transaction {
            for record in records {
                try write(record, merge: merge)
            }
        }
    }

    public func evict(_ id: GraphQLRecordID) throws {
        let statement = try prepare("DELETE FROM records WHERE id = ?")
        defer { sqlite3_finalize(statement) }
        bind(id.rawValue, to: statement, index: 1)
        try stepDone(statement)
    }

    public func clear() throws {
        try execute("DELETE FROM records")
    }

    private func saveRecord(_ record: GraphQLRecord) throws {
        let fieldsData = try encoder.encode(record.fields)
        let statement = try prepare("""
        INSERT OR REPLACE INTO records (id, fields, updated_at)
        VALUES (?, ?, ?)
        """)
        defer { sqlite3_finalize(statement) }
        bind(record.id.rawValue, to: statement, index: 1)
        try fieldsData.withUnsafeBytes { bytes in
            let pointer = bytes.baseAddress
            guard sqlite3_bind_blob(statement, 2, pointer, Int32(fieldsData.count), sqliteTransient) == SQLITE_OK else {
                throw sqliteError()
            }
        }
        sqlite3_bind_double(statement, 3, Date().timeIntervalSince1970)
        try stepDone(statement)
    }

    private func readRecord(_ id: GraphQLRecordID) throws -> GraphQLRecord? {
        let statement = try prepare("SELECT fields FROM records WHERE id = ? LIMIT 1")
        defer { sqlite3_finalize(statement) }
        bind(id.rawValue, to: statement, index: 1)

        let status = sqlite3_step(statement)
        if status == SQLITE_DONE {
            return nil
        }
        guard status == SQLITE_ROW else {
            throw sqliteError()
        }
        guard let blob = sqlite3_column_blob(statement, 0) else {
            throw SQLiteNormalizedStoreError.invalidRow
        }
        let byteCount = Int(sqlite3_column_bytes(statement, 0))
        let data = Data(bytes: blob, count: byteCount)
        let fields = try decoder.decode([String: GraphQLJSONValue].self, from: data)
        return GraphQLRecord(id: id, fields: fields)
    }

    private func transaction(_ work: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            try work()
            try execute("COMMIT")
        } catch {
            _ = try? execute("ROLLBACK")
            throw error
        }
    }

    @discardableResult
    private func execute(_ sql: String) throws -> Int32 {
        try Self.execute(on: db, sql: sql)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer? {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw sqliteError()
        }
        return statement
    }

    private func bind(_ value: String, to statement: OpaquePointer?, index: Int32) {
        sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
    }

    private func stepDone(_ statement: OpaquePointer?) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw sqliteError()
        }
    }

    private func sqliteError() -> SQLiteNormalizedStoreError {
        if let db {
            return .sqlite(String(cString: sqlite3_errmsg(db)))
        }
        return .sqlite("database is closed")
    }

    private static func execute(on db: OpaquePointer?, sql: String) throws -> Int32 {
        let status = sqlite3_exec(db, sql, nil, nil, nil)
        guard status == SQLITE_OK else {
            if let db {
                throw SQLiteNormalizedStoreError.sqlite(String(cString: sqlite3_errmsg(db)))
            }
            throw SQLiteNormalizedStoreError.sqlite("database is closed")
        }
        return status
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
