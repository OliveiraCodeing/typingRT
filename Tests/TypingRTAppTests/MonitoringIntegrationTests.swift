import Foundation
import Testing
@testable import TypingRTCore
@testable import TypingRTApp

@Suite(.timeLimit(.minutes(1))) @MainActor
struct MonitoringIntegrationTests {
    @Test func monotonicReferenceUsesDisjointPhasesAndReceiptWPMSnapshotExactlyOnce() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.remove() }
        let monitor = fixture.monitor
        monitor.load()
        await monitor.flush()
        let id = UUID()
        monitor.begin(sessionID: id)
        fixture.clock.advance(.seconds(45))
        monitor.stop(sessionID: id)
        monitor.recognized(sessionID: id, wordCount: 12)
        monitor.recognized(sessionID: id, wordCount: 999)
        fixture.clock.advance(.seconds(3))
        monitor.ready(sessionID: id)
        fixture.clock.advance(.seconds(600)) // Conscious later waiting is not processing/insertion.
        monitor.ready(sessionID: id)
        monitor.confirmed(sessionID: id, outputWords: 120, insertionSeconds: 0.6)
        #expect(fixture.preferences.setTypingWordsPerMinute("120"))
        monitor.confirmed(sessionID: id, outputWords: 999, insertionSeconds: 0)
        monitor.finish(sessionID: id)
        await monitor.flush()
        let summary = try #require(monitor.summary)
        #expect(summary.spokenWords == 12)
        #expect(summary.latencySampleCount == 1)
        #expect(summary.medianLatencySeconds == 3)
        #expect(abs(summary.savedMinutes - 2.19) < 0.000_001)
        #expect(abs(summary.savedHours - 0.0365) < 0.000_001)
        monitor.load()
        await monitor.flush()
        #expect(monitor.summary == summary) // Updated setting does not rewrite stored estimates.
    }

    @Test func resetRejectsDelayedOldEventsAndNewSessionUsesNewPeriod() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.remove() }
        let monitor = fixture.monitor
        monitor.load()
        await monitor.flush()
        let oldPeriod = try #require(monitor.summary?.periodID)
        let old = UUID()
        monitor.begin(sessionID: old)
        fixture.clock.advance(.seconds(5))
        monitor.stop(sessionID: old)
        monitor.recognized(sessionID: old, wordCount: 20)
        monitor.reset()
        fixture.clock.advance(.seconds(2))
        monitor.ready(sessionID: old)
        monitor.confirmed(sessionID: old, outputWords: 120, insertionSeconds: 0.1)
        await monitor.flush()
        #expect(monitor.summary?.periodID != oldPeriod)
        #expect(monitor.summary?.spokenWords == 0)
        #expect(monitor.summary?.medianLatencySeconds == nil)
        #expect(monitor.summary?.savedHours == 0)
        monitor.finish(sessionID: old)
        let next = UUID()
        monitor.begin(sessionID: next)
        fixture.clock.advance(.seconds(1))
        monitor.stop(sessionID: next)
        monitor.recognized(sessionID: next, wordCount: 3)
        fixture.clock.advance(.seconds(0.5))
        monitor.ready(sessionID: next)
        await monitor.flush()
        #expect(monitor.summary?.spokenWords == 3)
        #expect(monitor.summary?.latencySampleCount == 1)
        #expect(monitor.summary?.medianLatencySeconds == 0.5)
    }

    @Test func startDuringResetCannotBorrowRetiredPeriod() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.remove() }
        let monitor = fixture.monitor
        monitor.load()
        await monitor.flush()
        monitor.reset()
        let id = UUID()
        monitor.begin(sessionID: id)
        await monitor.flush()
        monitor.stop(sessionID: id)
        monitor.recognized(sessionID: id, wordCount: 20)
        monitor.ready(sessionID: id)
        monitor.confirmed(sessionID: id, outputWords: 120, insertionSeconds: 0.1)
        await monitor.flush()
        #expect(monitor.summary?.spokenWords == 0)
        #expect(monitor.summary?.latencySampleCount == 0)
        #expect(monitor.summary?.savedMinutes == 0)
    }

    @Test func abortRetainsAlreadyRecognizedWordsButNoLateReadinessOrSavings() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.remove() }
        let monitor = fixture.monitor
        monitor.load()
        await monitor.flush()
        let id = UUID()
        monitor.begin(sessionID: id)
        monitor.stop(sessionID: id)
        monitor.recognized(sessionID: id, wordCount: 7)
        monitor.finish(sessionID: id)
        monitor.recognized(sessionID: id, wordCount: 70)
        monitor.ready(sessionID: id)
        monitor.confirmed(sessionID: id, outputWords: 700, insertionSeconds: 0)
        await monitor.flush()
        #expect(monitor.summary?.spokenWords == 7)
        #expect(monitor.summary?.latencySampleCount == 0)
        #expect(monitor.summary?.savedMinutes == 0)
    }

    @Test func actualDeliveryEmitsSavingsOnlyForConfirmedInsertionNeverCopy() async throws {
        for outcome in [TextDeliveryOutcome.confirmed, .uncertain, .unavailable("Kein Textfeld.")] {
            let fixture = try MonitoringFixture()
            defer { fixture.remove() }
            let monitor = fixture.monitor
            monitor.load()
            await monitor.flush()
            let id = UUID()
            monitor.begin(sessionID: id)
            fixture.clock.advance(.seconds(1))
            monitor.stop(sessionID: id)
            monitor.recognized(sessionID: id, wordCount: 3)
            fixture.clock.advance(.seconds(1))
            monitor.ready(sessionID: id)
            let client = MonitoringInsertion(outcome: outcome)
            let delivery = TextDelivery(client: client)
            let finished = MonitoringSignal(), awaiting = MonitoringSignal()
            var receipts = 0
            delivery.onConfirmedInsertion = { id, words, seconds in
                receipts += 1
                monitor.confirmed(sessionID: id, outputWords: words, insertionSeconds: seconds)
            }
            delivery.onFinished = { id, _ in monitor.finish(sessionID: id); finished.signal() }
            delivery.onStateChanged = { _, phase in if phase == .awaitingResult { awaiting.signal() } }
            delivery.start(sessionID: id)
            let transcript = LocalTranscript(session: DictationSnapshot(id: id, mode: .standard),
                rawText: "Snippet meine Vorlage", cleanedText: Array(repeating: "Vorlagenwort", count: 120).joined(separator: " "),
                loadSeconds: 0, inferenceSeconds: 0)
            delivery.submit(transcript)
            delivery.submit(transcript)
            if outcome != .confirmed {
                await awaiting.wait()
                delivery.copy(sessionID: id)
            }
            await finished.wait()
            await monitor.flush()
            #expect(await client.insertions == 1)
            #expect(receipts == (outcome == .confirmed ? 1 : 0))
            #expect(monitor.summary?.spokenWords == 3)
            if outcome == .confirmed { #expect((monitor.summary?.savedMinutes ?? 0) > 2.9) }
            else { #expect(monitor.summary?.savedMinutes == 0) }
            await delivery.finishShutdown()
        }
    }

    @Test func rootCodingFailureAndExplicitRetryCountASROnceAndReadinessOnlyOnSuccess() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.remove() }
        let monitor = fixture.monitor
        monitor.load()
        await monitor.flush()
        let remote = MonitoringRequesty()
        let coding = CodingPipeline(credentials: MonitoringCredentials(), client: remote)
        let insertion = MonitoringInsertion(outcome: .confirmed)
        let delivery = TextDelivery(client: insertion)
        let model = AppModel(preferences: fixture.preferences, nativeMonitoringEnabled: false,
            dictionaryURL: fixture.root.appendingPathComponent("dictionary.sqlite"),
            snippetsURL: fixture.root.appendingPathComponent("snippets.sqlite"), coding: coding, delivery: delivery, monitoring: monitor)
        let readiness = Readiness(microphoneGranted: true, accessibilityGranted: true, hotkeyAvailable: true, modelInstalled: true)
        let metadata = RequestyModel(id: "fixture/model", contextWindow: 100_000, maxOutputTokens: 16_000)
        model.sessions.seedKeyState(isPressed: false)
        let id = try #require(model.sessions.handleRightOption(isPressed: true, readiness: readiness, selectedMode: .coding,
            requestyModelID: metadata.id, requestyModel: metadata))
        model.dictation.onSessionStarted?(id)
        fixture.clock.advance(.seconds(2))
        _ = model.sessions.handleRightOption(isPressed: false, readiness: readiness, selectedMode: .coding)
        model.dictation.onRecordingStopped?(id)
        model.transcription.onRecognized?(id, "Ähm bitte Login prüfen")
        let snapshot = try #require(model.sessions.activeSession)
        let local = LocalTranscript(session: snapshot, rawText: "Ähm bitte Login prüfen", cleanedText: "Bitte Login prüfen",
            loadSeconds: 0, inferenceSeconds: 0)
        delivery.start(sessionID: id)
        coding.start(local, model: metadata)
        while coding.phase != .awaitingDecision { await Task.yield() }
        await monitor.flush()
        #expect(monitor.summary?.spokenWords == 4)
        #expect(monitor.summary?.latencySampleCount == 0)
        #expect(monitor.summary?.savedMinutes == 0)
        model.transcription.onRecognized?(id, "Ähm bitte Login prüfen")
        fixture.clock.advance(.seconds(3))
        coding.retry(sessionID: id)
        coding.retry(sessionID: id)
        while delivery.outcome != .confirmed { await Task.yield() }
        await monitor.flush()
        #expect(await remote.calls == 2)
        #expect(await insertion.insertions == 1)
        #expect(monitor.summary?.spokenWords == 4)
        #expect(monitor.summary?.latencySampleCount == 1)
        #expect(monitor.summary?.medianLatencySeconds == 3)
        model.shutDown()
        await model.finishShutdown()
    }

    @Test func actualTranscriptionCountsRawBeforeSubsequentCleanupFailure() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.remove() }
        let monitor = fixture.monitor
        monitor.load()
        await monitor.flush()
        let pipeline = TranscriptionPipeline(worker: MonitoringWorker(), clean: { _ in throw MonitoringCleanupError.failed })
        let id = UUID(), failed = MonitoringSignal()
        monitor.begin(sessionID: id)
        monitor.stop(sessionID: id)
        var recognizedCallbacks = 0, finishedCallbacks = 0
        pipeline.onRecognized = { id, rawText in
            recognizedCallbacks += 1
            monitor.recognized(sessionID: id, rawText: rawText)
        }
        pipeline.onFailure = { id, _ in monitor.finish(sessionID: id); failed.signal() }
        pipeline.onFinished = { _, _ in finishedCallbacks += 1 }
        pipeline.start(session: DictationSnapshot(id: id, mode: .standard), modelURL: URL(fileURLWithPath: "/fixture/model"), tokenizerURL: URL(fileURLWithPath: "/fixture/tokenizer"))
        let audio = fixture.root.appendingPathComponent("audio.wav")
        try Data().write(to: audio)
        pipeline.consume(CapturedAudio(sessionID: id, url: audio, duration: 1, frames: 16_000, sampleRate: 16_000))
        await failed.wait()
        await monitor.flush()
        #expect(recognizedCallbacks == 1 && finishedCallbacks == 0)
        #expect(monitor.summary?.spokenWords == WordSegmentation.count("Ähm bitte UserStore prüfen"))
        #expect(monitor.summary?.latencySampleCount == 0)
        #expect(monitor.summary?.savedMinutes == 0)
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        await pipeline.finishShutdown()
    }

    @Test func acceptedRawSurvivesSynchronousCancelBeforeDetachedCountingCompletes() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.remove() }
        let monitor = fixture.monitor
        monitor.load()
        await monitor.flush()
        let pipeline = TranscriptionPipeline(worker: MonitoringWorker())
        let id = UUID(), recognized = MonitoringSignal()
        monitor.begin(sessionID: id)
        monitor.stop(sessionID: id)
        pipeline.onRecognized = { id, rawText in
            monitor.recognized(sessionID: id, rawText: rawText)
            // The validated raw result already exists. Synchronous cancellation
            // must not delete that accepted measurement before detached counting.
            pipeline.cancel(sessionID: id)
            monitor.finish(sessionID: id)
            recognized.signal()
        }
        pipeline.start(session: DictationSnapshot(id: id, mode: .standard), modelURL: URL(fileURLWithPath: "/fixture/model"), tokenizerURL: URL(fileURLWithPath: "/fixture/tokenizer"))
        let audio = fixture.root.appendingPathComponent("cancel-audio.wav")
        try Data().write(to: audio)
        pipeline.consume(CapturedAudio(sessionID: id, url: audio, duration: 1, frames: 16_000, sampleRate: 16_000))
        await recognized.wait()
        await monitor.flush()
        #expect(monitor.summary?.spokenWords == WordSegmentation.count("Ähm bitte UserStore prüfen"))
        #expect(monitor.summary?.latencySampleCount == 0)
        #expect(monitor.summary?.savedMinutes == 0)
        #expect(pipeline.result == nil)
        await pipeline.finishShutdown()
    }

    @Test func storageFailureIsNonblockingAndDoesNotCreateAMeasurementContext() async throws {
        let fixture = try MonitoringFixture()
        defer { fixture.remove() }
        let blocked = fixture.root.appendingPathComponent("blocked")
        try Data().write(to: blocked)
        let monitor = MonitoringController(url: blocked.appendingPathComponent("statistics.sqlite"), preferences: fixture.preferences)
        monitor.load()
        await monitor.flush()
        #expect(monitor.summary == nil && monitor.message != nil && !monitor.isLoading)
        let id = UUID()
        monitor.begin(sessionID: id)
        monitor.stop(sessionID: id)
        monitor.recognized(sessionID: id, wordCount: 100)
        monitor.ready(sessionID: id)
        monitor.confirmed(sessionID: id, outputWords: 100, insertionSeconds: 0)
        await monitor.flush()
        #expect(monitor.summary == nil)
    }
}

@MainActor private final class MonitoringClock {
    var instant = ContinuousClock().now
    func advance(_ duration: Duration) { instant = instant.advanced(by: duration) }
}

@MainActor private final class MonitoringFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let preferences: PreferencesStore
    let clock: MonitoringClock
    let monitor: MonitoringController
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("monitoring-integration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        suite = "monitoring-integration-\(UUID())"
        defaults = try #require(UserDefaults(suiteName: suite))
        preferences = PreferencesStore(defaults: defaults)
        clock = MonitoringClock()
        let clock = clock
        monitor = MonitoringController(url: root.appendingPathComponent("monitoring.sqlite"), preferences: preferences, now: { clock.instant })
    }
    func remove() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
}

private actor MonitoringInsertion: TextInsertionClient {
    private(set) var insertions = 0
    let outcome: TextDeliveryOutcome
    init(outcome: TextDeliveryOutcome) { self.outcome = outcome }
    func insert(_ text: String, cancellation: DeliveryCancellation) async -> TextDeliveryOutcome {
        insertions += 1
        return outcome
    }
    func copy(_ text: String, cancellation: DeliveryCancellation) async -> Bool { true }
}

private actor MonitoringCredentials: RequestyCredentialStoring {
    func read() async throws -> String? { "synthetic-fixture" }
    func save(_ value: String) async throws {}
    func delete() async throws {}
}

private actor MonitoringRequesty: RequestyServing {
    private(set) var calls = 0
    func models(apiKey: String) async throws -> [RequestyModel] { [] }
    func complete(sessionID: UUID, modelID: String, system: String, text: String, maxOutputTokens: Int, apiKey: String) async throws -> RequestyCompletion {
        calls += 1
        if calls == 1 { throw RequestyError.network }
        return RequestyCompletion(sessionID: sessionID, text: "Check the login implementation.")
    }
}

private enum MonitoringCleanupError: Error { case failed }

@MainActor private final class MonitoringWorker: TranscriptionWorkerClient {
    var onDisconnection: (() -> Void)?
    func prepare(_ request: WorkerRequest) async throws -> WorkerReply {
        WorkerReply(sessionID: request.sessionID, text: nil, error: nil, loadSeconds: 0, inferenceSeconds: 0)
    }
    func transcribe(_ request: WorkerRequest) async throws -> WorkerReply {
        WorkerReply(sessionID: request.sessionID, text: "Ähm bitte UserStore prüfen", error: nil, loadSeconds: 0, inferenceSeconds: 0)
    }
    func cancel(sessionID: UUID?) {}
}

@MainActor private final class MonitoringSignal {
    private var signaled = false
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() {
        signaled = true
        waiter?.resume()
        waiter = nil
    }
    func wait() async {
        if signaled { return }
        await withCheckedContinuation { waiter = $0 }
    }
}
