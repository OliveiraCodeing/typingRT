import Foundation
import Testing
import CSQLite
@testable import TypingRTCore

@Suite struct SnippetStoreTests {
    @Test func persistsCRUDAndRestartWithExactMultilineTemplate() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = SnippetStore(url: location)
        #expect(try await store.load().entries.isEmpty)
        let first = try SnippetEntry(name: "Name", trigger: "Signatur", aliases: ["Unterschrift"], template: "  Ähm,\r\nSnippet Signatur\t🙂  ")
        #expect(try await store.save(first).entries == [first])
        let restart = SnippetStore(url: location)
        #expect(try await restart.load().entries == [first])
        let edited = try SnippetEntry(id: first.id, name: "Neu", trigger: "Abschluss", template: "New\nText")
        #expect(try await restart.save(edited).entries == [edited])
        #expect(try await store.load().entries == [edited])
        #expect(try await store.delete(id: first.id).entries.isEmpty)
        #expect(try await SnippetStore(url: location).load().entries.isEmpty)
    }
    @Test func jsonRoundTripIsOnlyVersionedSnippetData() async throws {
        let sourceURL = temporaryDatabase(), targetURL = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: sourceURL.deletingLastPathComponent()); try? FileManager.default.removeItem(at: targetURL.deletingLastPathComponent()) }
        let source = SnippetStore(url: sourceURL)
        let first = try SnippetEntry(name: "Gruß", trigger: "Gruß", aliases: ["Gruss"], template: "Case\r\nÄhm\t\"Quote\"/\\🙂")
        _ = try await source.save(first)
        let data = try await source.exportJSON()
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["version", "snippets"])
        let rows = try #require(object["snippets"] as? [[String: Any]])
        #expect(Set(rows[0].keys) == ["id", "name", "trigger", "aliases", "template"])
        let target = SnippetStore(url: targetURL)
        #expect(try await target.importJSON(data).entries == [first])
        #expect(try await SnippetStore(url: targetURL).load().entries == [first])
    }
    @Test func importValidatesWholeFileAndExistingConflictsWithoutMutation() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = SnippetStore(url: location)
        let first = try SnippetEntry(name: "First", trigger: "Signatur", template: "Original")
        let before = try await store.save(first)
        let valid = try SnippetEntry(name: "Valid", trigger: "Greeting", template: "New")
        let collision = try SnippetEntry(name: "Conflict", trigger: "SIGNATUR", template: "No")
        for bad in [Data("{".utf8), try payload([valid, collision]), try payload([valid, valid]), try payload([valid], version: 99), Data(#"{"version":1,"snippets":[{"id":"invalid"}]}"#.utf8)] {
            do { _ = try await store.importJSON(bad); Issue.record("Bad import accepted") } catch { }
            #expect(try await store.load() == before)
            #expect(try await SnippetStore(url: location).load().entries == [first])
        }
        #expect(try await store.importJSON(payload([valid])).entries.count == 2)
    }
    @Test func actualSQLiteImportFailureRollsBackEveryRowAndRevision() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = SnippetStore(url: location)
        let first = try SnippetEntry(name: "First", trigger: "Original", template: "Original")
        let before = try await store.save(first)
        try execute("CREATE TRIGGER test_failure BEFORE INSERT ON snippet_entries WHEN NEW.name = 'Fail' BEGIN SELECT RAISE(ABORT, 'synthetic'); END", at: location)
        let one = try SnippetEntry(name: "New", trigger: "New", template: "New")
        let two = try SnippetEntry(name: "Fail", trigger: "Fail", template: "Fail")
        do { _ = try await store.importJSON(payload([one, two])); Issue.record("Import should rollback") }
        catch let error as SnippetError { #expect(error == .storageFailure) }
        #expect(try await store.load() == before)
        #expect(try await SnippetStore(url: location).load().entries == [first])
        try execute("DROP TRIGGER test_failure", at: location)
        #expect(try await store.importJSON(payload([one, two])).entries.count == 3)
    }
    @Test func acceptedLongGraphemesAndEscapedAliasesReload() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = SnippetStore(url: location)
        let largeName = String(repeating: "a" + String(repeating: "\u{0301}", count: 1_024), count: 128)
        #expect(largeName.utf8.count > 262_144)
        let large = try SnippetEntry(name: largeName, trigger: "Large", template: "Exact")
        _ = try await store.save(large)
        #expect(try await SnippetStore(url: location).load().entries == [large])
        _ = try await store.delete(id: large.id)
        let entries = try (0..<250).map { index in
            try SnippetEntry(name: "N\(index)", trigger: "T\(index)", aliases: (0..<64).map {
                String(repeating: "\\", count: 240) + "i\(index)x\($0)"
            }, template: "X")
        }
        _ = try await store.importJSON(payload(entries))
        #expect(try await SnippetStore(url: location).load().entries.count == 250)
        #expect(try await store.exportJSON().count <= 16_777_216)
    }
    @Test func maximumAcceptedPayloadStillExportsEscapedJSON() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let metadata = (0..<64).reduce(0) { $0 + "N\($1)".utf8.count + "T\($1)".utf8.count }
        let entries = try (0..<64).map { index in
            try SnippetEntry(name: "N\(index)", trigger: "T\(index)", template: String(repeating: "\\", count: 65_536 - (index == 63 ? metadata : 0)))
        }
        _ = try SnippetSnapshot(entries: entries)
        let store = SnippetStore(url: location)
        #expect(try await store.importJSON(payload(entries)).entries.count == 64)
        let exported = try await store.exportJSON()
        #expect(exported.count <= 16_777_216)
        struct File: Decodable { let version: Int; let snippets: [SnippetEntry] }
        #expect(try JSONDecoder().decode(File.self, from: exported).snippets.count == 64)
    }
    @Test func failedSavePreservesSnapshotAndUnknownSchemaDoesNotOverwrite() async throws {
        let location = temporaryDatabase()
        defer { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
        let store = SnippetStore(url: location)
        let first = try SnippetEntry(name: "First", trigger: "Signatur", template: "Original")
        let before = try await store.save(first)
        do { _ = try await store.save(SnippetEntry(name: "Other", trigger: "Signatur erweitert", template: "No")); Issue.record("Ambiguous save accepted") } catch { }
        #expect(try await store.load() == before)
        try execute("PRAGMA user_version = 99", at: location)
        let bytes = try Data(contentsOf: location)
        do { _ = try await SnippetStore(url: location).load(); Issue.record("Unsupported DB opened") }
        catch let error as SnippetError { #expect(error == .unsupportedSchema) }
        #expect(try Data(contentsOf: location) == bytes)
    }
    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-snippet-tests-\(UUID())", isDirectory: true).appendingPathComponent("snippets.sqlite")
    }
    private func payload(_ entries: [SnippetEntry], version: Int = 1) throws -> Data {
        struct File: Encodable { let version: Int; let snippets: [SnippetEntry] }
        return try JSONEncoder().encode(File(version: version, snippets: entries))
    }
    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw SnippetError.storageFailure }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw SnippetError.storageFailure }
    }
}
