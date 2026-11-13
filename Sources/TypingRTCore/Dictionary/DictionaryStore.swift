import Foundation
import CSQLite

/// Lazy connection creation keeps SQLite and file work on this actor's executor.
public actor DictionaryStore {
    private let url: URL
    private var connection: DictionaryConnection?
    private var revision = UUID()

    public init(url: URL) { self.url = url }

    public func load() throws -> DictionarySnapshot {
        let database = try database()
        return try DictionarySnapshot(entries: database.entries(), revision: revision)
    }

    @discardableResult public func save(_ entry: DictionaryEntry) throws -> DictionarySnapshot {
        let database = try database()
        let next = UUID()
        let snapshot: DictionarySnapshot = try database.transaction {
            var entries = try database.entries()
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry }
            else { entries.append(entry) }
            let snapshot = try DictionarySnapshot(entries: entries, revision: next)
            try database.execute("DELETE FROM dictionary_entries WHERE id = ?", strings: [entry.id.uuidString])
            let aliases = try JSONEncoder().encode(entry.aliases)
            guard let encoded = String(data: aliases, encoding: .utf8) else { throw DictionaryError.invalidStoredData }
            try database.execute("INSERT INTO dictionary_entries(id, canonical, aliases_json, protected) VALUES(?, ?, ?, ?)",
                strings: [entry.id.uuidString, entry.canonical, encoded, entry.isProtected ? "1" : "0"])
            for variant in [entry.canonical] + entry.aliases {
                try database.execute("INSERT INTO dictionary_variants(normalized, entry_id) VALUES(?, ?)",
                    strings: [DictionaryNormalization.key(variant), entry.id.uuidString])
            }
            return snapshot
        }
        revision = next
        return snapshot
    }

    @discardableResult public func delete(id: UUID) throws -> DictionarySnapshot {
        let database = try database()
        let next = UUID()
        let snapshot: DictionarySnapshot = try database.transaction {
            var entries = try database.entries()
            guard entries.contains(where: { $0.id == id }) else { throw DictionaryError.missingEntry }
            entries.removeAll { $0.id == id }
            try database.execute("DELETE FROM dictionary_entries WHERE id = ?", strings: [id.uuidString])
            return try DictionarySnapshot(entries: entries, revision: next)
        }
        revision = next
        return snapshot
    }

    private func database() throws -> DictionaryConnection {
        if let connection { return connection }
        let opened = try DictionaryConnection(url: url)
        connection = opened
        return opened
    }
}

/// Access is confined to DictionaryStore. The wrapper owns cleanup outside actor deinit.
private final class DictionaryConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        guard url.isFileURL else { throw DictionaryError.storageFailure }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
        } catch { throw DictionaryError.storageFailure }
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            handle = nil
            throw DictionaryError.storageFailure
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(handle, 1_000)
            try execute("PRAGMA foreign_keys = ON")
            let version = try schemaVersion()
            guard version == 0 || version == 1 else { throw DictionaryError.unsupportedSchema }
            if version == 0 {
                try transaction {
                    try execute("CREATE TABLE dictionary_entries(id TEXT PRIMARY KEY NOT NULL, canonical TEXT NOT NULL, aliases_json TEXT NOT NULL, protected INTEGER NOT NULL CHECK(protected IN (0,1)))")
                    try execute("CREATE TABLE dictionary_variants(normalized TEXT PRIMARY KEY NOT NULL, entry_id TEXT NOT NULL REFERENCES dictionary_entries(id) ON DELETE CASCADE)")
                    try execute("PRAGMA user_version = 1")
                }
            }
        } catch {
            sqlite3_close(handle)
            handle = nil
            throw (error as? DictionaryError) ?? DictionaryError.storageFailure
        }
    }

    deinit { if let handle { sqlite3_close(handle) } }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func execute(_ sql: String, strings: [String] = []) throws {
        let statement = try prepare(sql, strings: strings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw DictionaryError.storageFailure }
    }

    func entries() throws -> [DictionaryEntry] {
        let statement = try prepare("SELECT id, canonical, aliases_json, protected FROM dictionary_entries ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var entries: [DictionaryEntry] = []
        while true {
            let code = sqlite3_step(statement)
            if code == SQLITE_DONE { return entries }
            guard code == SQLITE_ROW,
                  let idText = sqlite3_column_text(statement, 0),
                  let canonicalText = sqlite3_column_text(statement, 1),
                  let aliasesText = sqlite3_column_text(statement, 2),
                  let id = UUID(uuidString: String(cString: idText)) else { throw DictionaryError.invalidStoredData }
            let canonical = String(cString: canonicalText)
            let encoded = Data(String(cString: aliasesText).utf8)
            let protected = sqlite3_column_int(statement, 3)
            guard protected == 0 || protected == 1 else { throw DictionaryError.invalidStoredData }
            do {
                let aliases = try JSONDecoder().decode([String].self, from: encoded)
                entries.append(try DictionaryEntry(id: id, canonical: canonical, aliases: aliases, isProtected: protected == 1))
            } catch { throw DictionaryError.invalidStoredData }
        }
    }

    private func schemaVersion() throws -> Int32 {
        let statement = try prepare("PRAGMA user_version")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw DictionaryError.storageFailure }
        return sqlite3_column_int(statement, 0)
    }

    private func prepare(_ sql: String, strings: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw DictionaryError.storageFailure
        }
        for (index, value) in strings.enumerated() {
            let result = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, -1, transient) }
            guard result == SQLITE_OK else { sqlite3_finalize(statement); throw DictionaryError.storageFailure }
        }
        return statement
    }
}
