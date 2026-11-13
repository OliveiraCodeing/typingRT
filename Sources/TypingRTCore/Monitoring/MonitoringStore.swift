import Foundation
import CSQLite

/// Connection creation, migrations, queries and writes run on this actor, never
/// the audio callback or UI executor. Each event kind is idempotent by session ID.
public actor MonitoringStore {
    private let url: URL
    private var connection: MonitoringConnection?

    public init(url: URL) { self.url = url }

    public func load() throws -> MonitoringSummary {
        let db = try database()
        return try db.transaction { try db.summary() }
    }

    @discardableResult public func recordASR(periodID: UUID, sessionID: UUID,
                                            wordCount: Int) throws -> MonitoringSummary {
        guard wordCount >= 0 else { throw MonitoringError.invalidMeasurement }
        return try record(periodID: periodID) { db in
            try db.execute("INSERT OR IGNORE INTO monitoring_words(session_id, word_count) VALUES(?, ?)",
                           [.text(sessionID.uuidString), .integer(wordCount)])
        }
    }

    @discardableResult public func recordReady(periodID: UUID, sessionID: UUID,
                                              processingSeconds: Double) throws -> MonitoringSummary {
        guard Self.validDuration(processingSeconds) else { throw MonitoringError.invalidMeasurement }
        return try record(periodID: periodID) { db in
            try db.execute("INSERT OR IGNORE INTO monitoring_latency(session_id, processing_seconds) VALUES(?, ?)",
                           [.text(sessionID.uuidString), .real(processingSeconds)])
        }
    }

    /// Call only for an actual confirmed insertion receipt; clipboard copy and an
    /// uncertain handoff are not confirmed insertions. Deliberate waiting is not
    /// included in the supplied non-overlapping phase durations.
    @discardableResult public func recordConfirmedInsertion(
        periodID: UUID, sessionID: UUID, outputWords: Int, wpm: Double,
        recordingSeconds: Double, processingSeconds: Double, insertionSeconds: Double
    ) throws -> MonitoringSummary {
        guard outputWords >= 0, wpm.isFinite, wpm > 0,
              Self.validDuration(recordingSeconds), Self.validDuration(processingSeconds),
              Self.validDuration(insertionSeconds) else { throw MonitoringError.invalidMeasurement }
        let savedMinutes = Double(outputWords) / wpm
            - (recordingSeconds + processingSeconds + insertionSeconds) / 60
        guard savedMinutes.isFinite else { throw MonitoringError.invalidMeasurement }
        return try record(periodID: periodID) { db in
            try db.execute("""
                INSERT OR IGNORE INTO monitoring_insertions
                (session_id, output_words, wpm, recording_seconds, processing_seconds, insertion_seconds, saved_minutes)
                VALUES(?, ?, ?, ?, ?, ?, ?)
                """, [.text(sessionID.uuidString), .integer(outputWords), .real(wpm),
                       .real(recordingSeconds), .real(processingSeconds), .real(insertionSeconds), .real(savedMinutes)])
        }
    }

    /// The new period and deletion commit atomically. Previously started sessions
    /// retain their old ID and can never refill the new period.
    public func reset() throws -> MonitoringSummary {
        let db = try database()
        return try db.transaction {
            try db.execute("DELETE FROM monitoring_words")
            try db.execute("DELETE FROM monitoring_latency")
            try db.execute("DELETE FROM monitoring_insertions")
            try db.execute("UPDATE monitoring_period SET period_id = ? WHERE singleton = 1", [.text(UUID().uuidString)])
            return try db.summary()
        }
    }

    private func record(periodID: UUID, body: (MonitoringConnection) throws -> Void) throws -> MonitoringSummary {
        let db = try database()
        return try db.transaction {
            if try db.periodID() == periodID { try body(db) }
            return try db.summary()
        }
    }

    private static func validDuration(_ value: Double) -> Bool { value.isFinite && value >= 0 }

    private func database() throws -> MonitoringConnection {
        if let connection { return connection }
        let opened = try MonitoringConnection(url: url)
        connection = opened
        return opened
    }
}

private enum MonitoringBinding {
    case text(String), integer(Int), real(Double)
}

/// Exclusively used by MonitoringStore's executor, including final connection cleanup.
private final class MonitoringConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard url.isFileURL else { throw MonitoringError.storageFailure }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw MonitoringError.storageFailure }
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw MonitoringError.storageFailure
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(handle, 1_000)
            try transaction {
                let version = try integer("PRAGMA user_version")
                guard version == 0 || version == 1 else { throw MonitoringError.unsupportedSchema }
                if version == 0 {
                    try execute("CREATE TABLE monitoring_period(singleton INTEGER PRIMARY KEY CHECK(singleton = 1), period_id TEXT NOT NULL)")
                    try execute("INSERT INTO monitoring_period(singleton, period_id) VALUES(1, ?)", [.text(UUID().uuidString)])
                    try execute("CREATE TABLE monitoring_words(session_id TEXT PRIMARY KEY NOT NULL, word_count INTEGER NOT NULL CHECK(word_count >= 0))")
                    try execute("CREATE TABLE monitoring_latency(session_id TEXT PRIMARY KEY NOT NULL, processing_seconds REAL NOT NULL CHECK(processing_seconds >= 0))")
                    try execute("""
                        CREATE TABLE monitoring_insertions(session_id TEXT PRIMARY KEY NOT NULL,
                        output_words INTEGER NOT NULL CHECK(output_words >= 0), wpm REAL NOT NULL CHECK(wpm > 0),
                        recording_seconds REAL NOT NULL CHECK(recording_seconds >= 0),
                        processing_seconds REAL NOT NULL CHECK(processing_seconds >= 0),
                        insertion_seconds REAL NOT NULL CHECK(insertion_seconds >= 0), saved_minutes REAL NOT NULL)
                        """)
                    try execute("PRAGMA user_version = 1")
                }
            }
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw (error as? MonitoringError) ?? MonitoringError.storageFailure
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, _ bindings: [MonitoringBinding] = []) throws {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw MonitoringError.storageFailure }
    }

    func periodID() throws -> UUID {
        let statement = try prepare("SELECT period_id FROM monitoring_period WHERE singleton = 1")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0),
              let value = UUID(uuidString: String(cString: text)) else { throw MonitoringError.invalidStoredData }
        return value
    }

    func summary() throws -> MonitoringSummary {
        let period = try periodID()
        let words = try integer("SELECT COALESCE(SUM(word_count), 0) FROM monitoring_words")
        let count = try integer("SELECT COUNT(*) FROM monitoring_latency")
        var median: Double?
        if count > 0 {
            median = try real("""
                SELECT AVG(processing_seconds) FROM (
                    SELECT processing_seconds FROM monitoring_latency ORDER BY processing_seconds
                    LIMIT ? OFFSET ?)
                """, [.integer(2 - count % 2), .integer((count - 1) / 2)])
        }
        let saved = try real("SELECT COALESCE(SUM(saved_minutes), 0) FROM monitoring_insertions")
        guard words >= 0, count >= 0, median.map({ $0 >= 0 }) ?? true else { throw MonitoringError.invalidStoredData }
        return MonitoringSummary(periodID: period, spokenWords: words, latencySampleCount: count,
                                 medianLatencySeconds: median, savedMinutes: saved)
    }

    private func integer(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW, sqlite3_column_type(statement, 0) == SQLITE_INTEGER,
              let value = Int(exactly: sqlite3_column_int64(statement, 0)) else { throw MonitoringError.invalidStoredData }
        return value
    }

    private func real(_ sql: String, _ bindings: [MonitoringBinding] = []) throws -> Double {
        let statement = try prepare(sql, bindings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              sqlite3_column_type(statement, 0) != SQLITE_NULL else { throw MonitoringError.invalidStoredData }
        let value = sqlite3_column_double(statement, 0)
        guard value.isFinite else { throw MonitoringError.invalidStoredData }
        return value
    }

    private func prepare(_ sql: String, _ bindings: [MonitoringBinding] = []) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw MonitoringError.storageFailure
        }
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .text(let value): code = value.withCString { sqlite3_bind_text(prepared, index, $0, -1, transient) }
            case .integer(let value): code = sqlite3_bind_int64(prepared, index, Int64(value))
            case .real(let value): code = sqlite3_bind_double(prepared, index, value)
            }
            guard code == SQLITE_OK else { sqlite3_finalize(prepared); throw MonitoringError.storageFailure }
        }
        return prepared
    }
}
