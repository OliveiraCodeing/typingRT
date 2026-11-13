import Foundation
import CSQLite

/// All disk/SQLite/JSON work is confined to this actor, never the UI/audio executor.
public actor SnippetStore {
    private let url: URL
    private var connection: SnippetConnection?
    private var revision = UUID()
    public init(url: URL) { self.url = url }

    public func load() throws -> SnippetSnapshot {
        try SnippetSnapshot(entries: database().entries(), revision: revision)
    }
    @discardableResult public func save(_ entry: SnippetEntry) throws -> SnippetSnapshot {
        let db = try database(), next = UUID()
        let result = try db.transaction {
            var entries = try db.entries()
            if let index = entries.firstIndex(where: { $0.id == entry.id }) { entries[index] = entry } else { entries.append(entry) }
            let result = try SnippetSnapshot(entries: entries, revision: next)
            try db.execute("DELETE FROM snippet_entries WHERE id = ?", strings: [entry.id.uuidString])
            try db.insert(entry)
            return result
        }
        revision = next
        return result
    }
    @discardableResult public func delete(id: UUID) throws -> SnippetSnapshot {
        let db = try database(), next = UUID()
        let result = try db.transaction {
            var entries = try db.entries()
            guard entries.contains(where: { $0.id == id }) else { throw SnippetError.missingEntry }
            entries.removeAll { $0.id == id }
            let result = try SnippetSnapshot(entries: entries, revision: next)
            try db.execute("DELETE FROM snippet_entries WHERE id = ?", strings: [id.uuidString])
            return result
        }
        revision = next
        return result
    }
    /// Additive restore: existing IDs and trigger conflicts are never silently overwritten.
    @discardableResult public func importJSON(_ data: Data) throws -> SnippetSnapshot {
        guard data.count <= 16_777_216 else { throw SnippetError.tooLarge }
        let file: SnippetFile
        do { file = try JSONDecoder().decode(SnippetFile.self, from: data) }
        catch let error as SnippetError { throw error }
        catch { throw SnippetError.invalidFile }
        guard file.version == 1 else { throw SnippetError.unsupportedSchema }
        _ = try SnippetSnapshot(entries: file.snippets)
        let db = try database(), next = UUID()
        let result = try db.transaction {
            let result = try SnippetSnapshot(entries: db.entries() + file.snippets, revision: next)
            for entry in file.snippets { try db.insert(entry) }
            return result
        }
        revision = next
        return result
    }
    public func exportJSON() throws -> Data {
        let snapshot = try load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(SnippetFile(version: 1, snippets: snapshot.entries))
        guard data.count <= 16_777_216 else { throw SnippetError.tooLarge }
        return data
    }
    private func database() throws -> SnippetConnection {
        if let connection { return connection }
        let opened = try SnippetConnection(url: url)
        connection = opened
        return opened
    }
}

private struct SnippetFile: Codable { let version: Int; let snippets: [SnippetEntry] }

private final class SnippetConnection: @unchecked Sendable {
    private var handle: OpaquePointer?
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    init(url: URL) throws {
        guard url.isFileURL else { throw SnippetError.storageFailure }
        do { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw SnippetError.storageFailure }
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }; handle = nil
            throw SnippetError.storageFailure
        }
        do {
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            sqlite3_busy_timeout(handle, 1_000)
            let statement = try prepare("PRAGMA user_version")
            let version: Int32
            if sqlite3_step(statement) == SQLITE_ROW { version = sqlite3_column_int(statement, 0) }
            else { sqlite3_finalize(statement); throw SnippetError.storageFailure }
            sqlite3_finalize(statement)
            guard version == 0 || version == 1 else { throw SnippetError.unsupportedSchema }
            if version == 0 {
                try transaction {
                    try execute("CREATE TABLE snippet_entries(id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, trigger TEXT NOT NULL, aliases_json TEXT NOT NULL, template TEXT NOT NULL)")
                    try execute("PRAGMA user_version = 1")
                }
            }
        } catch {
            sqlite3_close(handle); handle = nil
            throw (error as? SnippetError) ?? SnippetError.storageFailure
        }
    }
    deinit { if let handle { sqlite3_close(handle) } }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do { let result = try body(); try execute("COMMIT"); return result }
        catch { try? execute("ROLLBACK"); throw error }
    }
    func execute(_ sql: String, strings: [String] = []) throws {
        let statement = try prepare(sql, strings: strings)
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SnippetError.storageFailure }
    }
    func insert(_ entry: SnippetEntry) throws {
        let aliases = try JSONEncoder().encode(entry.aliases)
        guard let encoded = String(data: aliases, encoding: .utf8) else { throw SnippetError.invalidStoredData }
        try execute("INSERT INTO snippet_entries(id,name,trigger,aliases_json,template) VALUES(?,?,?,?,?)", strings: [entry.id.uuidString, entry.name, entry.trigger, encoded, entry.template])
    }
    func entries() throws -> [SnippetEntry] {
        let statement = try prepare("SELECT id,name,trigger,aliases_json,template FROM snippet_entries ORDER BY id")
        defer { sqlite3_finalize(statement) }
        var entries: [SnippetEntry] = [], bytesRead = 0
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return entries }
            guard status == SQLITE_ROW, entries.count < 1_000 else { throw SnippetError.invalidStoredData }
            var fields: [String] = []
            for column in 0..<5 {
                guard let value = sqlite3_column_text(statement, Int32(column)), sqlite3_column_bytes(statement, Int32(column)) <= 16_777_216 else { throw SnippetError.invalidStoredData }
                bytesRead += Int(sqlite3_column_bytes(statement, Int32(column)))
                guard bytesRead <= 16_777_216 else { throw SnippetError.invalidStoredData }
                let bytes = UnsafeBufferPointer(start: value, count: Int(sqlite3_column_bytes(statement, Int32(column))))
                guard let text = String(bytes: bytes, encoding: .utf8) else { throw SnippetError.invalidStoredData }
                fields.append(text)
            }
            guard let id = UUID(uuidString: fields[0]) else { throw SnippetError.invalidStoredData }
            do {
                let aliases = try JSONDecoder().decode([String].self, from: Data(fields[3].utf8))
                entries.append(try SnippetEntry(id: id, name: fields[1], trigger: fields[2], aliases: aliases, template: fields[4]))
            } catch { throw SnippetError.invalidStoredData }
        }
    }
    private func prepare(_ sql: String, strings: [String] = []) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SnippetError.storageFailure }
        for (index, value) in strings.enumerated() {
            let status = value.withCString { sqlite3_bind_text(statement, Int32(index + 1), $0, Int32(value.utf8.count), transient) }
            guard status == SQLITE_OK else { sqlite3_finalize(statement); throw SnippetError.storageFailure }
        }
        return statement
    }
}
