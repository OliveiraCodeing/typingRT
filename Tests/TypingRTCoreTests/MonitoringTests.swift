import Foundation
import Testing
import CSQLite
@testable import TypingRTCore

@Suite struct MonitoringTests {
    @Test func segmentationUsesOneDeterministicUnicodeRule() {
        let fixtures: [(String, Int)] = [
            ("", 0), (" \n\t… — 🙂", 0), ("Ähm, prüfe UserStore.", 3),
            ("don't don’t state-of-the-art", 3), ("one--two three- -four", 4),
            ("UserStore user_store foo.bar 1.2.3", 8),
            ("é e\u{301} \u{301} \u{200D} १२ Ⅻ ²", 5),
            ("中文测试 日本語", 2), ("hello\nworld\t42", 3),
            ("'quote' - dash-", 2), ("foo-\u{301}bar", 2)
        ]
        for (text, count) in fixtures { #expect(WordSegmentation.count(text) == count) }
    }

    @Test func freshDatabaseAndReopenPreserveRealZeroStateAndPeriod() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        let first = try await MonitoringStore(url: location).load()
        #expect(first.spokenWords == 0)
        #expect(first.latencySampleCount == 0 && first.medianLatencySeconds == nil)
        #expect(first.savedMinutes == 0 && first.savedHours == 0)
        #expect(try await MonitoringStore(url: location).load() == first)
    }

    @Test func rawWordsPersistIndependentlyOfCodingSuccessAndOnlyOncePerSession() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        let store = MonitoringStore(url: location)
        let period = try await store.load().periodID
        let id = UUID()
        let first = try await store.recordASR(periodID: period, sessionID: id,
                                              wordCount: WordSegmentation.count("Ähm, bitte den UserStore prüfen."))
        #expect(first.spokenWords == 5)
        #expect(first.latencySampleCount == 0 && first.savedMinutes == 0)
        #expect(try await store.recordASR(periodID: period, sessionID: id, wordCount: 999) == first)
        #expect(try await MonitoringStore(url: location).load() == first)
        let second = try await store.recordASR(periodID: period, sessionID: UUID(), wordCount: 2)
        #expect(second.spokenWords == 7)
    }

    @Test func medianIsReproducibleForSingleEvenAndOddCountsAndIgnoresDuplicates() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        let store = MonitoringStore(url: location)
        let period = try await store.load().periodID
        let id = UUID()
        let one = try await store.recordReady(periodID: period, sessionID: id, processingSeconds: 8)
        #expect(one.latencySampleCount == 1 && one.medianLatencySeconds == 8)
        let two = try await store.recordReady(periodID: period, sessionID: UUID(), processingSeconds: 2)
        #expect(two.latencySampleCount == 2 && two.medianLatencySeconds == 5)
        #expect(try await store.recordReady(periodID: period, sessionID: id, processingSeconds: 500) == two)
        let three = try await store.recordReady(periodID: period, sessionID: UUID(), processingSeconds: 3)
        #expect(three.latencySampleCount == 3 && three.medianLatencySeconds == 3)
        let four = try await store.recordReady(periodID: period, sessionID: UUID(), processingSeconds: 10)
        #expect(four.latencySampleCount == 4 && four.medianLatencySeconds == 5.5)
        #expect(try await MonitoringStore(url: location).load() == four)
    }

    @Test func referenceSavingsUseOutputWordsAndRetainPerInsertionWPM() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        let store = MonitoringStore(url: location)
        let period = try await store.load().periodID
        let id = UUID()
        _ = try await store.recordASR(periodID: period, sessionID: id, wordCount: 3)
        let first = try await store.recordConfirmedInsertion(periodID: period, sessionID: id,
            outputWords: 120, wpm: 40, recordingSeconds: 45, processingSeconds: 3, insertionSeconds: 0.6)
        #expect(abs(first.savedMinutes - 2.19) < 0.000_001)
        #expect(abs(first.savedHours - 0.0365) < 0.000_001)
        #expect(first.spokenWords == 3) // Expanded snippet/translated output never becomes spoken input.
        let duplicate = try await store.recordConfirmedInsertion(periodID: period, sessionID: id,
            outputWords: 900, wpm: 80, recordingSeconds: 1, processingSeconds: 0, insertionSeconds: 0)
        #expect(duplicate == first)
        let second = try await store.recordConfirmedInsertion(periodID: period, sessionID: UUID(),
            outputWords: 120, wpm: 80, recordingSeconds: 45, processingSeconds: 3, insertionSeconds: 0.6)
        #expect(abs(second.savedMinutes - (2.19 + 0.69)) < 0.000_001)
        #expect(try await MonitoringStore(url: location).load() == second)
        let rows = try query("SELECT wpm FROM monitoring_insertions ORDER BY wpm", at: location)
        #expect(rows == [["40.0"], ["80.0"]])
    }

    @Test func negativeIndividualSavingsReduceTotalBeforeDisplayClamp() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        let store = MonitoringStore(url: location)
        let period = try await store.load().periodID
        let positive = try await store.recordConfirmedInsertion(periodID: period, sessionID: UUID(),
            outputWords: 40, wpm: 40, recordingSeconds: 0, processingSeconds: 0, insertionSeconds: 0)
        #expect(positive.savedMinutes == 1)
        let negative = try await store.recordConfirmedInsertion(periodID: period, sessionID: UUID(),
            outputWords: 40, wpm: 40, recordingSeconds: 180, processingSeconds: 0, insertionSeconds: 0)
        #expect(negative.savedMinutes == -1 && negative.savedHours == 0)
        let next = try await store.recordConfirmedInsertion(periodID: period, sessionID: UUID(),
            outputWords: 40, wpm: 40, recordingSeconds: 0, processingSeconds: 0, insertionSeconds: 0)
        #expect(next.savedMinutes == 0 && next.savedHours == 0)
    }

    @Test func resetIsAtomicAndOldSessionsCannotRepopulateEvenAfterRestart() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        let store = MonitoringStore(url: location)
        let old = try await store.load().periodID
        let id = UUID()
        _ = try await store.recordASR(periodID: old, sessionID: id, wordCount: 5)
        _ = try await store.recordReady(periodID: old, sessionID: id, processingSeconds: 3)
        _ = try await store.recordConfirmedInsertion(periodID: old, sessionID: id,
            outputWords: 40, wpm: 40, recordingSeconds: 1, processingSeconds: 3, insertionSeconds: 0.1)
        let reset = try await store.reset()
        #expect(reset.periodID != old)
        #expect(reset.spokenWords == 0 && reset.latencySampleCount == 0 && reset.medianLatencySeconds == nil)
        #expect(reset.savedMinutes == 0 && reset.savedHours == 0)
        #expect(try await store.recordASR(periodID: old, sessionID: UUID(), wordCount: 100) == reset)
        #expect(try await store.recordReady(periodID: old, sessionID: id, processingSeconds: 5) == reset)
        let restart = MonitoringStore(url: location)
        #expect(try await restart.recordConfirmedInsertion(periodID: old, sessionID: id,
            outputWords: 100, wpm: 40, recordingSeconds: 0, processingSeconds: 0, insertionSeconds: 0) == reset)
        let current = try await restart.recordASR(periodID: reset.periodID, sessionID: UUID(), wordCount: 2)
        #expect(current.spokenWords == 2)
        #expect(try await store.load() == current)
    }

    @Test func resetFailureRollsBackDeletionAndPeriodChange() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        let store = MonitoringStore(url: location)
        let period = try await store.load().periodID
        let before = try await store.recordASR(periodID: period, sessionID: UUID(), wordCount: 7)
        try execute("CREATE TRIGGER fail_reset BEFORE UPDATE ON monitoring_period BEGIN SELECT RAISE(ABORT, 'synthetic'); END", at: location)
        do { _ = try await store.reset(); Issue.record("Reset should fail") }
        catch let error as MonitoringError { #expect(error == .storageFailure) }
        #expect(try await store.load() == before)
        #expect(try await MonitoringStore(url: location).load() == before)
    }

    @Test func writeFailureDoesNotCreateOrChangeMeasurementsAndCanRecover() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        let store = MonitoringStore(url: location)
        let before = try await store.load()
        try execute("CREATE TRIGGER fail_write BEFORE INSERT ON monitoring_words BEGIN SELECT RAISE(ABORT, 'synthetic'); END", at: location)
        let id = UUID()
        do { _ = try await store.recordASR(periodID: before.periodID, sessionID: id, wordCount: 9); Issue.record("Write should fail") }
        catch let error as MonitoringError { #expect(error == .storageFailure) }
        #expect(try await store.load() == before)
        try execute("DROP TRIGGER fail_write", at: location)
        #expect(try await store.recordASR(periodID: before.periodID, sessionID: id, wordCount: 9).spokenWords == 9)
    }

    @Test func invalidMeasurementsNeverModifyStatistics() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        let store = MonitoringStore(url: location)
        let before = try await store.load()
        do { _ = try await store.recordASR(periodID: before.periodID, sessionID: UUID(), wordCount: -1); Issue.record("Negative words accepted") }
        catch let error as MonitoringError { #expect(error == .invalidMeasurement) }
        for invalid in [-1, Double.infinity, -Double.infinity, Double.nan] {
            do { _ = try await store.recordReady(periodID: before.periodID, sessionID: UUID(), processingSeconds: invalid); Issue.record("Invalid duration accepted") }
            catch let error as MonitoringError { #expect(error == .invalidMeasurement) }
        }
        for invalid in [0, -1, Double.infinity, Double.nan] {
            do { _ = try await store.recordConfirmedInsertion(periodID: before.periodID, sessionID: UUID(),
                outputWords: 1, wpm: invalid, recordingSeconds: 1, processingSeconds: 1, insertionSeconds: 1); Issue.record("Invalid WPM accepted") }
            catch let error as MonitoringError { #expect(error == .invalidMeasurement) }
        }
        do { _ = try await store.recordConfirmedInsertion(periodID: before.periodID, sessionID: UUID(),
            outputWords: 1, wpm: 40, recordingSeconds: 1, processingSeconds: -1, insertionSeconds: 1); Issue.record("Invalid phase duration accepted") }
        catch let error as MonitoringError { #expect(error == .invalidMeasurement) }
        #expect(try await store.load() == before)
    }

    @Test func schemaContainsOnlyContentFreeColumnsAndUnsupportedVersionIsPreserved() async throws {
        let location = temporaryDatabase()
        defer { cleanup(location) }
        _ = try await MonitoringStore(url: location).load()
        let tables = try query("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name", at: location).compactMap(\.first)
        #expect(tables == ["monitoring_insertions", "monitoring_latency", "monitoring_period", "monitoring_words"])
        let expected: [String: Set<String>] = [
            "monitoring_period": ["singleton", "period_id"],
            "monitoring_words": ["session_id", "word_count"],
            "monitoring_latency": ["session_id", "processing_seconds"],
            "monitoring_insertions": ["session_id", "output_words", "wpm", "recording_seconds", "processing_seconds", "insertion_seconds", "saved_minutes"]
        ]
        for table in tables {
            #expect(Set(try query("PRAGMA table_info(\(table))", at: location).map { $0[1] }) == expected[table])
        }
        try execute("PRAGMA user_version = 99", at: location)
        let bytes = try Data(contentsOf: location)
        do { _ = try await MonitoringStore(url: location).load(); Issue.record("Unknown schema accepted") }
        catch let error as MonitoringError { #expect(error == .unsupportedSchema) }
        #expect(try Data(contentsOf: location) == bytes)
    }

    @Test func inaccessibleLocationAndCorruptPeriodFailWithoutReplacingData() async throws {
        do { _ = try await MonitoringStore(url: URL(string: "https://example.invalid/monitoring.sqlite")!).load(); Issue.record("Remote database accepted") }
        catch let error as MonitoringError { #expect(error == .storageFailure) }
        let location = temporaryDatabase()
        defer { cleanup(location) }
        _ = try await MonitoringStore(url: location).load()
        try execute("UPDATE monitoring_period SET period_id = 'invalid'", at: location)
        let bytes = try Data(contentsOf: location)
        do { _ = try await MonitoringStore(url: location).load(); Issue.record("Corrupt period accepted") }
        catch let error as MonitoringError { #expect(error == .invalidStoredData) }
        #expect(try Data(contentsOf: location) == bytes)
    }

    private func temporaryDatabase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-monitoring-tests-\(UUID())", isDirectory: true).appendingPathComponent("monitoring.sqlite")
    }
    private func cleanup(_ location: URL) { try? FileManager.default.removeItem(at: location.deletingLastPathComponent()) }
    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw MonitoringError.storageFailure }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw MonitoringError.storageFailure }
    }
    private func query(_ sql: String, at url: URL) throws -> [[String]] {
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK else { throw MonitoringError.storageFailure }
        defer { sqlite3_close(db) }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else { throw MonitoringError.storageFailure }
        defer { sqlite3_finalize(prepared) }
        var rows: [[String]] = []
        var step = sqlite3_step(prepared)
        while step == SQLITE_ROW {
            rows.append((0..<sqlite3_column_count(prepared)).map { index in
                sqlite3_column_text(prepared, index).map { String(cString: $0) } ?? "NULL"
            })
            step = sqlite3_step(prepared)
        }
        guard step == SQLITE_DONE else { throw MonitoringError.storageFailure }
        return rows
    }
}
