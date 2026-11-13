import Foundation
import Observation
import TypingRTCore

@MainActor
protocol TranscriptionWorkerClient: AnyObject {
    var onDisconnection: (() -> Void)? { get set }
    func prepare(_ request: WorkerRequest) async throws -> WorkerReply
    func transcribe(_ request: WorkerRequest) async throws -> WorkerReply
    func cancel(sessionID: UUID?)
}

extension WorkerClient: TranscriptionWorkerClient {}

@MainActor @Observable
final class TranscriptionPipeline {
    private(set) var result: LocalTranscript?
    @ObservationIgnored var onFailure: ((UUID, String) -> Void)?
    @ObservationIgnored var onRecoverableFailure: ((UUID, String) -> Void)?
    @ObservationIgnored var onRecognized: ((UUID, String) -> Void)?
    @ObservationIgnored var onFinished: ((UUID, String?) -> Void)?
    @ObservationIgnored private let worker: any TranscriptionWorkerClient
    @ObservationIgnored private let clean: (@Sendable (String) async throws -> String)?
    @ObservationIgnored private var request: WorkerRequest?
    @ObservationIgnored private var session: DictationSnapshot?
    @ObservationIgnored private var preload: Task<WorkerReply, Error>?
    @ObservationIgnored private var processing: Task<Void, Never>?
    @ObservationIgnored private var acceptedAudioURL: URL?

    init(worker: any TranscriptionWorkerClient = WorkerClient(),
         clean: (@Sendable (String) async throws -> String)? = nil) {
        self.worker = worker
        self.clean = clean
        worker.onDisconnection = { [weak self] in
            guard let self, let id = self.request?.sessionID else { return }
            self.cancel(sessionID: id)
            self.onFailure?(id, "Der lokale Erkennungsdienst wurde unterbrochen. Bitte erneut prüfen und bewusst neu diktieren.")
        }
    }

    func start(session: DictationSnapshot, modelURL: URL, tokenizerURL: URL) {
        let sessionID = session.id
        result = nil
        acceptedAudioURL = nil
        self.session = session
        let request = WorkerRequest(sessionID: sessionID, audioPath: "", modelPath: modelURL.path, tokenizerPath: tokenizerURL.path, canonicalTerms: session.dictionary.entries.map(\.canonical))
        self.request = request
        let worker = worker
        let task = Task { try await worker.prepare(request) }
        preload = task
        Task { [weak self] in
            do { _ = try await task.value }
            catch {
                guard let self, self.request?.sessionID == sessionID, !Task.isCancelled else { return }
                self.onFailure?(sessionID, "Das lokale Modell konnte nicht geladen werden. Bitte Installation und Erkennungsdienst prüfen.")
            }
        }
    }

    func consume(_ audio: CapturedAudio) {
        guard let request, let session, request.sessionID == audio.sessionID, session.id == audio.sessionID else {
            Task { await Self.remove(audio.url) }
            return
        }
        // A repeated capture callback must neither transcribe twice nor delete
        // the file currently owned by the first consumer.
        guard acceptedAudioURL == nil else {
            if acceptedAudioURL != audio.url { Task { await Self.remove(audio.url) } }
            return
        }
        acceptedAudioURL = audio.url
        let preload = preload
        processing = Task { [weak self] in
            guard let self else { await Self.remove(audio.url); return }
            do {
                let loaded = try await preload?.value
                try Task.checkCancellation()
                guard self.request?.sessionID == audio.sessionID else { await Self.remove(audio.url); return }
                let reply = try await self.worker.transcribe(WorkerRequest(
                    sessionID: request.sessionID, audioPath: audio.url.path,
                    modelPath: request.modelPath, tokenizerPath: request.tokenizerPath, canonicalTerms: request.canonicalTerms))
                try Task.checkCancellation()
                guard self.request?.sessionID == audio.sessionID else { await Self.remove(audio.url); return }
                let rawText = reply.text ?? ""
                // Claim the measurement before any suspension after a valid ASR
                // result. Later Esc can discard text, but not accepted word usage.
                self.onRecognized?(audio.sessionID, rawText)
                await Self.remove(audio.url)
                try Task.checkCancellation()
                guard self.request?.sessionID == audio.sessionID else { return }
                let dictionaryTask = Task.detached(priority: .userInitiated) {
                    // Coding never enters snippet recognition or expansion.
                    let protection = session.mode == .standard ? try session.snippets.protectCalls(in: rawText) : nil
                    let applied = session.dictionary.apply(to: protection?.text ?? rawText, protecting: protection?.protectedRanges ?? [])
                    return (applied, protection)
                }
                let (applied, protection) = try await withTaskCancellationHandler { try await dictionaryTask.value } onCancel: { dictionaryTask.cancel() }
                try Task.checkCancellation()
                let intermediate: String
                if let clean = self.clean {
                    intermediate = try await clean(applied.text)
                } else {
                    let cleanTask = Task.detached(priority: .userInitiated) {
                        ConservativeTextCleaner.clean(applied.text, protecting: applied.protectedRanges)
                    }
                    intermediate = await withTaskCancellationHandler { await cleanTask.value } onCancel: { cleanTask.cancel() }
                }
                try Task.checkCancellation()
                guard self.request?.sessionID == audio.sessionID else { return }
                let expansionTask = Task.detached(priority: .userInitiated) {
                    try protection?.expand(in: intermediate) ?? intermediate
                }
                let cleanedText = try await withTaskCancellationHandler { try await expansionTask.value } onCancel: { expansionTask.cancel() }
                try Task.checkCancellation()
                guard self.request?.sessionID == audio.sessionID else { return }
                self.result = LocalTranscript(session: session, rawText: rawText, cleanedText: cleanedText,
                    loadSeconds: loaded?.loadSeconds ?? reply.loadSeconds, inferenceSeconds: reply.inferenceSeconds,
                    relevantCanonicalSpellings: applied.relevantCanonicalSpellings, protectedCanonicalSpellings: applied.protectedCanonicalSpellings)
                self.request = nil
                self.session = nil
                self.preload = nil
                self.processing = nil
                let message = cleanedText.isEmpty ? (rawText.isEmpty ? "Keine Sprache erkannt." : "Nach der Bereinigung bleibt kein Text übrig.") : nil
                self.onFinished?(audio.sessionID, message)
            } catch {
                await Self.remove(audio.url)
                guard self.request?.sessionID == audio.sessionID else { return }
                self.worker.cancel(sessionID: audio.sessionID)
                self.request = nil
                self.session = nil
                self.preload = nil
                self.processing = nil
                if error is SnippetError {
                    self.onRecoverableFailure?(audio.sessionID, "Die Snippet-Verarbeitung konnte nicht sicher abgeschlossen werden. Es wird kein Text eingefügt. Bitte das Diktat erneut versuchen.")
                } else if let error = error as? WorkerClientError, case .incompleteTranscription = error {
                    self.onRecoverableFailure?(audio.sessionID, error.localizedDescription)
                } else {
                    self.onFailure?(audio.sessionID, "Die lokale Erkennung wurde unterbrochen. Bitte den Erkennungsdienst erneut prüfen.")
                }
            }
        }
    }

    func cancel(sessionID: UUID) {
        if result?.sessionID == sessionID { result = nil }
        guard request?.sessionID == sessionID else { return }
        request = nil
        session = nil
        preload?.cancel()
        processing?.cancel()
        worker.cancel(sessionID: sessionID)
        result = nil
    }

    func clearResult() { result = nil }

    func finishShutdown() async {
        if let id = request?.sessionID { cancel(sessionID: id) }
        await processing?.value
        _ = try? await preload?.value
        worker.cancel(sessionID: nil)
        result = nil
    }

    private static func remove(_ url: URL) async {
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }.value
    }
}
