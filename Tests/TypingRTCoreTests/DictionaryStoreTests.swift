import Foundation
import Testing
import CSQLite
@testable import TypingRTCore

@Suite struct DictionaryStoreTests {
    @Test func persistsCRUDAndRestartsWithExactData() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = DictionaryStore(url: location)
        #expect(try await store.load().entries.isEmpty)
        let entry = try DictionaryEntry(canonical: "Next.js", aliases: ["Next JS", "Next Dschei Ess"], isProtected: true)
        let created = try await store.save(entry)
        #expect(created.entries == [entry])
        let restarted = DictionaryStore(url: location)
        #expect(try await restarted.load().entries == [entry])
        let edited = try DictionaryEntry(id: entry.id, canonical: "Next.js", aliases: ["next framework"], isProtected: false)
        #expect(try await restarted.save(edited).entries == [edited])
        #expect(try await store.load().entries == [edited])
        #expect(try await store.delete(id: entry.id).entries.isEmpty)
        #expect(try await DictionaryStore(url: location).load().entries.isEmpty)
    }

    @Test func conflictFailurePreservesOldRevisionAndContents() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = DictionaryStore(url: location)
        let first = try DictionaryEntry(canonical: "Supabase", aliases: ["Supa Base"])
        let before = try await store.save(first)
        do {
            _ = try await store.save(DictionaryEntry(canonical: "Other", aliases: ["SUPA  BASE"]))
            Issue.record("Conflicting variant was saved")
        } catch let error as DictionaryError {
            #expect(error == .conflictingVariant(existingID: first.id))
        }
        #expect(try await store.load() == before)
        #expect(try await DictionaryStore(url: location).load().entries == [first])
    }

    @Test func actualSQLiteFailureRollsBackUpdate() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = DictionaryStore(url: location)
        let first = try DictionaryEntry(canonical: "Supabase", aliases: ["Supa Base"])
        let before = try await store.save(first)
        try execute("CREATE TRIGGER test_failure BEFORE INSERT ON dictionary_entries BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END", at: location)
        do {
            _ = try await store.save(DictionaryEntry(id: first.id, canonical: "Changed", aliases: ["New Variant"]))
            Issue.record("SQLite transaction unexpectedly succeeded")
        } catch let error as DictionaryError { #expect(error == .storageFailure) }
        #expect(try await store.load() == before)
        #expect(try await DictionaryStore(url: location).load().entries == [first])
        try execute("DROP TRIGGER test_failure", at: location)
        #expect(try await store.save(DictionaryEntry(canonical: "Other", aliases: ["New Variant"])).entries.count == 2)
    }

    @Test func newerSchemaAndInvalidLocationFailWithoutOverwriting() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: location.deletingLastPathComponent(), withIntermediateDirectories: true)
        try execute("PRAGMA user_version = 99", at: location)
        let before = try Data(contentsOf: location)
        do {
            _ = try await DictionaryStore(url: location).load()
            Issue.record("Unsupported schema was accepted")
        } catch let error as DictionaryError { #expect(error == .unsupportedSchema) }
        #expect(try Data(contentsOf: location) == before)
        do {
            _ = try await DictionaryStore(url: URL(string: "https://example.invalid/dictionary.sqlite")!).load()
            Issue.record("Remote store was accepted")
        } catch let error as DictionaryError { #expect(error == .storageFailure) }
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-dictionary-tests-\(UUID())", isDirectory: true)
            .appendingPathComponent("dictionary.sqlite")
    }

    private func execute(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        guard sqlite3_open(url.path, &database) == SQLITE_OK else { throw DictionaryError.storageFailure }
        defer { sqlite3_close(database) }
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw DictionaryError.storageFailure }
    }
}
