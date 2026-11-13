import Foundation
import Observation
import TypingRTCore

/// Owns only the remote wording stage. The session coordinator retains the
/// dictation until delivery or explicit discard; no local text is an automatic fallback.
@MainActor @Observable
final class CodingPipeline {
    enum Phase: Equatable { case idle, formatting, awaitingDecision }
    private(set) var phase: Phase = .idle
    private(set) var original: LocalTranscript?
    private(set) var message: String?
    private(set) var rejectedText: String?
    @ObservationIgnored var onStateChanged: ((UUID, Phase) -> Void)?
    // Generated text may be handed off automatically. Explicit local-original
    // takeover is manual so clicking the app never pastes into a stale target.
    @ObservationIgnored var onReady: ((LocalTranscript, Bool) -> Void)?
    @ObservationIgnored private let credentials: any RequestyCredentialStoring
    @ObservationIgnored private let client: any RequestyServing
    @ObservationIgnored private var model: RequestyModel?
    @ObservationIgnored private var lastStartedID: UUID?
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var attemptID: UUID?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var retiringOperation: Task<Void, Never>?
    @ObservationIgnored private var stopped = false

    init(credentials: any RequestyCredentialStoring = RequestyCredentials(service: AppIdentity.current.keychainService),
         client: any RequestyServing = RequestyClient()) {
        self.credentials = credentials
        self.client = client
    }

    func start(_ transcript: LocalTranscript, model: RequestyModel?) {
        guard !stopped, phase == .idle, sessionID == nil, lastStartedID != transcript.sessionID,
              transcript.mode == .coding,
              !transcript.cleanedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        lastStartedID = transcript.sessionID
        sessionID = transcript.sessionID
        original = transcript
        self.model = model
        beginAttempt()
    }

    func retry(sessionID id: UUID) {
        guard !stopped, sessionID == id, phase == .awaitingDecision else { return }
        beginAttempt()
    }

    func takeOriginal(sessionID id: UUID) {
        guard !stopped, sessionID == id, phase == .awaitingDecision, let original else { return }
        clear()
        onReady?(original, false)
    }

    func cancel(sessionID id: UUID) {
        guard sessionID == id else { return }
        retireOperation()
        clear()
    }

    /// System interruption preserves the local result, but never resumes a remote
    /// request or inserts its late answer after waking.
    func interrupt(sessionID id: UUID) {
        guard !stopped, sessionID == id, phase == .formatting, original != nil else { return }
        retireOperation()
        phase = .awaitingDecision
        message = "Die Formulierung wurde unterbrochen. Erneut versuchen oder das lokale Original kopieren."
        onStateChanged?(id, .awaitingDecision)
    }

    private func beginAttempt() {
        guard let original, let id = sessionID, !stopped else { return }
        let attempt = UUID()
        attemptID = attempt
        phase = .formatting
        message = nil
        rejectedText = nil
        onStateChanged?(id, .formatting)
        guard isCurrent(id, attempt) else { return }
        let model = model
        let credentials = credentials
        let client = client
        operation = Task { [weak self] in
            do {
                let preparation = Task.detached(priority: .userInitiated) {
                    try CodingPrompt.prepare(transcript: original, model: model)
                }
                let request = try await withTaskCancellationHandler { try await preparation.value } onCancel: { preparation.cancel() }
                try Task.checkCancellation()
                guard let self, self.isCurrent(id, attempt) else { return }
                guard let key = try await credentials.read() else { throw RequestyError.invalidConfiguration }
                try Task.checkCancellation()
                guard self.isCurrent(id, attempt) else { return }
                let reply = try await client.complete(sessionID: id, modelID: request.modelID,
                    system: request.system, text: request.text, maxOutputTokens: request.maxOutputTokens, apiKey: key)
                try Task.checkCancellation()
                guard self.isCurrent(id, attempt) else { return }
                guard reply.sessionID == id else { throw RequestyError.invalidResponse }
                let validation = Task.detached(priority: .userInitiated) {
                    try CodingPrompt.validate(output: reply.text, request: request)
                }
                let text: String
                do {
                    text = try await withTaskCancellationHandler { try await validation.value } onCancel: { validation.cancel() }
                } catch CodingPromptError.changedProtectedElements {
                    guard self.isCurrent(id, attempt), !Task.isCancelled else { return }
                    // Review only, never an insertion/copy candidate. Kept volatile
                    // and bounded like validation, then cleared on any next action.
                    if reply.text.utf8.count <= 262_144 { self.rejectedText = reply.text }
                    throw CodingPromptError.changedProtectedElements
                }
                try Task.checkCancellation()
                guard self.isCurrent(id, attempt) else { return }
                let ready = original.replacingCleanedText(text)
                self.operation = nil
                self.clear()
                self.onReady?(ready, true)
            } catch {
                guard let self, self.isCurrent(id, attempt) else { return }
                self.operation = nil
                self.attemptID = nil
                self.phase = .awaitingDecision
                if let error = error as? CodingPromptError { self.message = error.localizedDescription }
                else if let error = error as? RequestyError { self.message = error.localizedDescription }
                else if error is CancellationError { self.message = "Die Formulierung wurde abgebrochen. Das lokale Original bleibt verfügbar." }
                else { self.message = "Die englische Formulierung ist fehlgeschlagen. Das lokale Original bleibt verfügbar." }
                self.onStateChanged?(id, .awaitingDecision)
            }
        }
    }

    private func isCurrent(_ id: UUID, _ attempt: UUID) -> Bool {
        !stopped && sessionID == id && attemptID == attempt && phase == .formatting
    }

    private func clear() {
        sessionID = nil
        attemptID = nil
        original = nil
        model = nil
        phase = .idle
        message = nil
        rejectedText = nil
    }

    private func retireOperation() {
        attemptID = nil
        operation?.cancel()
        if let operation {
            let previous = retiringOperation
            retiringOperation = Task { await previous?.value; await operation.value }
        }
        operation = nil
    }

    func finishShutdown() async {
        stopped = true
        retireOperation()
        clear()
        await retiringOperation?.value
        retiringOperation = nil
    }
}
