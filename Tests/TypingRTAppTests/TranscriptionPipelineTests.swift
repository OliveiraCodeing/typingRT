import Foundation
import Testing
@testable import TypingRTCore
@testable import TypingRTApp

@Suite(.timeLimit(.minutes(1))) @MainActor
struct TranscriptionPipelineTests {
    @Test func retainsRawTextAndStartModeThroughAsynchronousCleanup() async throws {
        let worker = TestWorker(text: "Ähm, bitte prüfe den Login.")
        let cleaner = HeldCleanup()
        let pipeline = TranscriptionPipeline(worker: worker, clean: { try await cleaner.clean($0) })
        let completed = CompletionProbe()
        pipeline.onFinished = { completed.append($0, $1) }
        let suite = "typingRT.pipeline-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        let sessions = SessionCoordinator()
        sessions.seedKeyState(isPressed: false)
        let ready = Readiness(microphoneGranted: true, accessibilityGranted: true, hotkeyAvailable: true, modelInstalled: true)
        _ = sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: preferences.selectedMode)
        let session = try #require(sessions.activeSession)
        pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        _ = sessions.handleRightOption(isPressed: false, readiness: ready, selectedMode: preferences.selectedMode)
        let audio = try makeAudio(session.id)
        pipeline.consume(audio)
        await cleaner.waitForCalls(1)
        // The live UI preference can change independently; the start snapshot owns output.
        preferences.selectedMode = .coding
        #expect(!FileManager.default.fileExists(atPath: audio.url.path))
        #expect(pipeline.result == nil)
        await cleaner.releaseAll()
        await completed.wait()
        let result = try #require(pipeline.result)
        #expect(result.mode == .standard)
        #expect(result.rawText == "Ähm, bitte prüfe den Login.")
        #expect(result.cleanedText == "Bitte prüfe den Login.")
        #expect(result.loadSeconds == 0.5 && result.inferenceSeconds == 0.25)
        #expect(completed.ids == [session.id])
        pipeline.cancel(sessionID: session.id)
        #expect(pipeline.result == nil)
        await pipeline.finishShutdown()
    }

    @Test func fillerOnlyEndsNormallyWithoutDeliverableText() async throws {
        let pipeline = TranscriptionPipeline(worker: TestWorker(text: "Äh, ähm …"))
        let completed = CompletionProbe()
        pipeline.onFinished = { completed.append($0, $1) }
        var failed = false
        pipeline.onFailure = { _, _ in failed = true }
        let session = DictationSnapshot(id: UUID(), mode: .standard)
        pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        pipeline.consume(try makeAudio(session.id))
        await completed.wait()
        #expect(pipeline.result?.cleanedText == "")
        #expect(pipeline.result?.rawText == "Äh, ähm …")
        #expect(completed.messages.first! != nil)
        #expect(!failed)
        await pipeline.finishShutdown()
    }

    @Test func cancellationDiscardsLateCleanupBeforeNextSession() async throws {
        let worker = TestWorker(text: "Ähm, bitte zuerst.")
        let cleaner = HeldCleanup()
        let pipeline = TranscriptionPipeline(worker: worker, clean: { try await cleaner.clean($0) })
        let completed = CompletionProbe()
        pipeline.onFinished = { completed.append($0, $1) }
        let old = DictationSnapshot(id: UUID(), mode: .standard)
        pipeline.start(session: old, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        pipeline.consume(try makeAudio(old.id))
        await cleaner.waitForCalls(1)
        pipeline.cancel(sessionID: old.id)
        worker.text = "Snippet deploy ähm"
        let next = DictationSnapshot(id: UUID(), mode: .coding)
        pipeline.start(session: next, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        pipeline.consume(try makeAudio(next.id))
        await cleaner.waitForCalls(2)
        await cleaner.releaseAll()
        await completed.wait()
        #expect(completed.ids == [next.id])
        #expect(pipeline.result?.sessionID == next.id)
        #expect(pipeline.result?.mode == .coding)
        #expect(pipeline.result?.cleanedText == "Snippet deploy")
        await pipeline.finishShutdown()
    }

    @Test func cancellationDuringCleanupHasNoResultOrCompletion() async throws {
        let cleaner = HeldCleanup()
        let pipeline = TranscriptionPipeline(worker: TestWorker(text: "Ähm, bitte verwerfen."), clean: { try await cleaner.clean($0) })
        var callbacks = 0
        pipeline.onFinished = { _, _ in callbacks += 1 }
        pipeline.onFailure = { _, _ in callbacks += 1 }
        let session = DictationSnapshot(id: UUID(), mode: .standard)
        pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        pipeline.consume(try makeAudio(session.id))
        await cleaner.waitForCalls(1)
        pipeline.cancel(sessionID: session.id)
        await cleaner.releaseAll()
        await pipeline.finishShutdown()
        #expect(pipeline.result == nil)
        #expect(callbacks == 0)
    }

    @Test func repeatedCaptureCallbackCannotProcessOrDeleteTheSameAudioTwice() async throws {
        let worker = TestWorker(text: "Ähm, bitte einmal.")
        let cleaner = HeldCleanup()
        let pipeline = TranscriptionPipeline(worker: worker, clean: { try await cleaner.clean($0) })
        let completed = CompletionProbe()
        pipeline.onFinished = { completed.append($0, $1) }
        let session = DictationSnapshot(id: UUID(), mode: .standard)
        pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        let audio = try makeAudio(session.id)
        pipeline.consume(audio)
        pipeline.consume(audio)
        await cleaner.waitForCalls(1)
        #expect(worker.transcriptionCalls == 1)
        await cleaner.releaseAll()
        await completed.wait()
        pipeline.consume(audio)
        #expect(completed.ids == [session.id])
        #expect(worker.transcriptionCalls == 1)
        await pipeline.finishShutdown()
    }

    @Test func dictionarySnapshotIsSharedByPrepareRecognitionAndBothModeResults() async throws {
        for mode in DictationMode.allCases {
            let entry = try DictionaryEntry(canonical: "Next.js", aliases: ["Next JS"], isProtected: true)
            let dictionary = try DictionarySnapshot(entries: [entry])
            let worker = TestWorker(text: "Ähm, bitte Next JS verwenden.")
            let pipeline = TranscriptionPipeline(worker: worker)
            let completed = CompletionProbe()
            pipeline.onFinished = { completed.append($0, $1) }
            let session = DictationSnapshot(id: UUID(), mode: mode, dictionary: dictionary)
            pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
            pipeline.consume(try makeAudio(session.id))
            await completed.wait()
            let result = try #require(pipeline.result)
            #expect(result.rawText == "Ähm, bitte Next JS verwenden.")
            #expect(result.cleanedText == "Bitte Next.js verwenden.")
            #expect(result.mode == mode)
            #expect(result.dictionaryRevision == dictionary.revision)
            #expect(result.relevantCanonicalSpellings == ["Next.js"])
            #expect(result.protectedCanonicalSpellings == ["Next.js"])
            #expect(worker.preparedTerms == ["Next.js"])
            #expect(worker.transcribedTerms == worker.preparedTerms)
            await pipeline.finishShutdown()
        }
    }

    @Test func protectedDictionarySpellingSurvivesFillerCleanup() async throws {
        let dictionary = try DictionarySnapshot(entries: [DictionaryEntry(canonical: "Ähm", aliases: ["meine Marke"], isProtected: true)])
        let pipeline = TranscriptionPipeline(worker: TestWorker(text: "meine Marke ähm bleibt"))
        let completed = CompletionProbe()
        pipeline.onFinished = { completed.append($0, $1) }
        let session = DictationSnapshot(id: UUID(), mode: .standard, dictionary: dictionary)
        pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        pipeline.consume(try makeAudio(session.id))
        await completed.wait()
        #expect(pipeline.result?.cleanedText == "Ähm Ähm bleibt")
        await pipeline.finishShutdown()
    }

    @Test func decoderLimitKeepsServiceAvailableAndNeverOffersPartialText() async throws {
        let worker = TestWorker(text: "partial")
        worker.failure = .incompleteTranscription
        let pipeline = TranscriptionPipeline(worker: worker)
        let completed = CompletionProbe()
        var fatalFailures = 0
        pipeline.onFailure = { _, _ in fatalFailures += 1 }
        pipeline.onRecoverableFailure = { completed.append($0, $1) }
        let session = DictationSnapshot(id: UUID(), mode: .standard)
        pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        let audio = try makeAudio(session.id)
        pipeline.consume(audio)
        await completed.wait()
        #expect(fatalFailures == 0)
        #expect(pipeline.result == nil)
        #expect(completed.messages.first!?.contains("unvollständiger Text") == true)
        #expect(!FileManager.default.fileExists(atPath: audio.url.path))
        let reply = WorkerReply(sessionID: session.id, text: nil, error: "untrusted remote message", loadSeconds: 0, inferenceSeconds: 0, errorCode: .incompleteTranscription)
        do {
            _ = try WorkerClient().decode(JSONEncoder().encode(reply), for: session.id)
            Issue.record("Incomplete result was accepted")
        } catch let error as WorkerClientError {
            #expect(error.localizedDescription.contains("unvollständiger Text"))
            #expect(!error.localizedDescription.contains("untrusted"))
        }
        await pipeline.finishShutdown()
    }

    @Test func idleWorkerCrashAfterPrepareInvalidatesAndRequiresExplicitRestart() async throws {
        let worker = CrashWorker()
        let pipeline = TranscriptionPipeline(worker: worker)
        var failures: [UUID] = [], completions = 0
        pipeline.onFailure = { id, _ in failures.append(id) }
        pipeline.onFinished = { _, _ in completions += 1 }
        let old = DictationSnapshot(id: UUID(), mode: .standard)
        pipeline.start(session: old, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        while worker.preparedIDs.isEmpty { await Task.yield() }
        worker.onDisconnection?()
        worker.onDisconnection?() // Repeated invalidation is idempotent.
        #expect(failures == [old.id])
        let discarded = try makeAudio(old.id)
        pipeline.consume(discarded)
        await pipeline.finishShutdown()
        while FileManager.default.fileExists(atPath: discarded.url.path) { await Task.yield() }
        #expect(worker.transcriptionCalls == 0 && completions == 0 && pipeline.result == nil)
        let next = DictationSnapshot(id: UUID(), mode: .standard)
        pipeline.start(session: next, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        let audio = try makeAudio(next.id)
        pipeline.consume(audio)
        while worker.pending == nil { await Task.yield() }
        worker.release()
        while completions == 0 { await Task.yield() }
        #expect(pipeline.result?.sessionID == next.id)
        #expect(failures == [old.id] && completions == 1)
        #expect(!FileManager.default.fileExists(atPath: audio.url.path))
        await pipeline.finishShutdown()
    }

    @Test func workerCrashDuringRecognitionRejectsLateReplyAndRemovesAudio() async throws {
        let worker = CrashWorker()
        let pipeline = TranscriptionPipeline(worker: worker)
        var failures = 0, completions = 0, recognized = 0
        pipeline.onFailure = { _, _ in failures += 1 }
        pipeline.onFinished = { _, _ in completions += 1 }
        pipeline.onRecognized = { _, _ in recognized += 1 }
        let session = DictationSnapshot(id: UUID(), mode: .coding)
        pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        let audio = try makeAudio(session.id)
        pipeline.consume(audio)
        while worker.pending == nil { await Task.yield() }
        worker.onDisconnection?()
        worker.release() // Deliberately ignores cancellation, like a stale XPC callback.
        await pipeline.finishShutdown()
        #expect(failures == 1 && completions == 0 && recognized == 0)
        #expect(pipeline.result == nil)
        #expect(!FileManager.default.fileExists(atPath: audio.url.path))
    }

    private func makeAudio(_ id: UUID) throws -> CapturedAudio {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-s04-test-\(UUID()).wav")
        try Data().write(to: url)
        return CapturedAudio(sessionID: id, url: url, duration: 1, frames: 16000, sampleRate: 16000)
    }
}

@MainActor private final class TestWorker: TranscriptionWorkerClient {
    var onDisconnection: (() -> Void)?
    var text: String
    var failure: WorkerClientError?
    private(set) var transcriptionCalls = 0
    private(set) var preparedTerms: [String] = []
    private(set) var transcribedTerms: [String] = []
    init(text: String) { self.text = text }
    func prepare(_ request: WorkerRequest) async throws -> WorkerReply {
        preparedTerms = request.canonicalTerms
        return WorkerReply(sessionID: request.sessionID, text: nil, error: nil, loadSeconds: 0.5, inferenceSeconds: 0)
    }
    func transcribe(_ request: WorkerRequest) async throws -> WorkerReply {
        transcriptionCalls += 1
        transcribedTerms = request.canonicalTerms
        if let failure { throw failure }
        return WorkerReply(sessionID: request.sessionID, text: text, error: nil, loadSeconds: 0, inferenceSeconds: 0.25)
    }
    func cancel(sessionID: UUID?) {}
}

/// Deliberately returns even after cancellation, exercising the pipeline's final gate.
private actor HeldCleanup {
    private var calls = 0
    private var held: [(String, CheckedContinuation<String, Error>)] = []
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func clean(_ text: String) async throws -> String {
        calls += 1
        return try await withCheckedThrowingContinuation { continuation in
            held.append((text, continuation))
            for (count, waiter) in waiters where count <= calls { waiter.resume() }
            waiters.removeAll { $0.0 <= calls }
        }
    }
    func waitForCalls(_ count: Int) async {
        if calls >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func releaseAll() {
        let pending = held
        held.removeAll()
        for (text, continuation) in pending { continuation.resume(returning: ConservativeTextCleaner.clean(text)) }
    }
}

@MainActor private final class CompletionProbe {
    var ids: [UUID] = []
    var messages: [String?] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func append(_ id: UUID, _ message: String?) {
        ids.append(id); messages.append(message)
        waiter?.resume(); waiter = nil
    }
    func wait() async {
        if !ids.isEmpty { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

@MainActor private final class CrashWorker: TranscriptionWorkerClient {
    var onDisconnection: (() -> Void)?
    var preparedIDs: [UUID] = []
    var transcriptionCalls = 0
    var pending: (UUID, CheckedContinuation<WorkerReply, Error>)?
    func prepare(_ request: WorkerRequest) async throws -> WorkerReply {
        preparedIDs.append(request.sessionID)
        return WorkerReply(sessionID: request.sessionID, text: nil, error: nil, loadSeconds: 0, inferenceSeconds: 0)
    }
    func transcribe(_ request: WorkerRequest) async throws -> WorkerReply {
        transcriptionCalls += 1
        return try await withCheckedThrowingContinuation { pending = (request.sessionID, $0) }
    }
    func release() {
        guard let (id, continuation) = pending else { return }
        pending = nil
        continuation.resume(returning: WorkerReply(sessionID: id, text: "Bitte prüfen.", error: nil, loadSeconds: 0, inferenceSeconds: 0))
    }
    func cancel(sessionID: UUID?) {}
}
