import Foundation
import Observation
import Synchronization
import TypingRTCore

enum TextDeliveryOutcome: Equatable, Sendable {
    case confirmed
    /// Pasted once into a target that cannot be read back (terminal).
    case handedOff
    case uncertain
    case unavailable(String)
    case cancelled
}

/// Can be invalidated synchronously by Esc while the system adapter is doing IPC.
final class DeliveryCancellation: Sendable {
    private let cancelled = Mutex(false)
    var isCancelled: Bool { cancelled.withLock { $0 } }
    func cancel() { cancelled.withLock { $0 = true } }
}

protocol TextInsertionClient: Sendable {
    func insert(_ text: String, cancellation: DeliveryCancellation) async -> TextDeliveryOutcome
    func copy(_ text: String, cancellation: DeliveryCancellation) async -> Bool
}

/// Owns exactly one automatic handoff. Focus changes never call submit again.
@MainActor @Observable
final class TextDelivery {
    enum Phase: Equatable { case idle, inserting, awaitingResult, copying }
    private(set) var phase: Phase = .idle
    private(set) var result: LocalTranscript?
    private(set) var outcome: TextDeliveryOutcome?
    private(set) var message: String?
    @ObservationIgnored var onStateChanged: ((UUID, Phase) -> Void)?
    @ObservationIgnored var onConfirmedInsertion: ((UUID, Int, Double) -> Void)?
    @ObservationIgnored var onFinished: ((UUID, String) -> Void)?
    @ObservationIgnored private let client: any TextInsertionClient
    @ObservationIgnored private var sessionID: UUID?
    @ObservationIgnored private var attempted = false
    @ObservationIgnored private var cancellation: DeliveryCancellation?
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var retiringOperation: Task<Void, Never>?

    init(client: any TextInsertionClient = NativeTextInsertion()) { self.client = client }

    func start(sessionID: UUID) {
        if let current = self.sessionID { cancel(sessionID: current) }
        self.sessionID = sessionID
        attempted = false
        result = nil
        outcome = nil
        message = nil
        phase = .idle
    }

    func submit(_ transcript: LocalTranscript, automatic: Bool = true) {
        guard sessionID == transcript.sessionID, !attempted, !transcript.cleanedText.isEmpty else { return }
        // Claim before any suspension, including unavailable targets and Coding previews.
        attempted = true
        result = transcript
        let id = transcript.sessionID
        guard automatic else {
            outcome = .unavailable("Das lokale Original wurde bewusst ausgewählt. Du kannst es kopieren.")
            showPending(id: id)
            return
        }
        let token = DeliveryCancellation()
        cancellation = token
        phase = .inserting
        onStateChanged?(id, phase)
        let insertionStarted = ContinuousClock().now
        operation = Task { [weak self, client] in
            let words = await Task.detached(priority: .utility) { WordSegmentation.count(transcript.cleanedText) }.value
            guard !token.isCancelled else { return }
            let outcome = await client.insert(transcript.cleanedText, cancellation: token)
            guard let self, self.sessionID == id, !token.isCancelled else { return }
            self.outcome = outcome
            self.operation = nil
            self.cancellation = nil
            if outcome == .confirmed {
                let duration = insertionStarted.duration(to: ContinuousClock().now).components
                let seconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                self.onConfirmedInsertion?(id, words, seconds)
                self.finish(id: id, message: "Text eingefügt.")
            } else if outcome == .handedOff {
                // Not verifiable, so it never counts as a confirmed time saving.
                self.finish(id: id, message: "An das Terminal übergeben, ohne Enter. Der Text liegt auch in der Zwischenablage.")
            } else {
                self.showPending(id: id)
            }
        }
    }

    func copy(sessionID id: UUID) {
        guard sessionID == id, phase == .awaitingResult, let result else { return }
        let token = DeliveryCancellation()
        cancellation = token
        phase = .copying
        onStateChanged?(id, phase)
        operation = Task { [weak self, client] in
            let copied = await client.copy(result.cleanedText, cancellation: token)
            guard let self, self.sessionID == id, !token.isCancelled else { return }
            self.operation = nil
            self.cancellation = nil
            if copied { self.finish(id: id, message: "Text kopiert. Du kannst ihn selbst einfügen.") }
            else {
                self.message = "Kopieren ist fehlgeschlagen. Das Ergebnis bleibt bereit."
                self.phase = .awaitingResult
                self.onStateChanged?(id, self.phase)
            }
        }
    }

    func discard(sessionID id: UUID) {
        guard sessionID == id, phase == .awaitingResult else { return }
        finish(id: id, message: "Diktat verworfen.")
    }

    func cancel(sessionID id: UUID) {
        guard sessionID == id else { return }
        sessionID = nil
        retireCurrentOperation()
        result = nil
        outcome = nil
        message = nil
        phase = .idle
    }

    /// Sleep/locking is not an explicit discard of an already finished text.
    func interrupt(sessionID id: UUID) {
        guard sessionID == id, result != nil else { return }
        guard phase == .inserting || phase == .copying else { return }
        retireCurrentOperation()
        outcome = .uncertain
        showPending(id: id)
    }

    private func retireCurrentOperation() {
        cancellation?.cancel()
        cancellation = nil
        operation?.cancel()
        if let operation {
            let previous = retiringOperation
            // The adapter must finish its clipboard cleanup even after Esc.
            // Preserve the handle so termination can wait for that cleanup.
            retiringOperation = Task {
                await previous?.value
                await operation.value
            }
        }
        operation = nil
    }

    func finishShutdown() async {
        if let sessionID { cancel(sessionID: sessionID) }
        await retiringOperation?.value
        retiringOperation = nil
    }

    private func showPending(id: UUID) {
        phase = .awaitingResult
        switch outcome {
        case .uncertain:
            message = "Übergabe versucht. Prüfe dein Textfeld, bevor du erneut einfügst."
        case .unavailable(let reason): message = reason
        default: message = "Nicht eingefügt. Du kannst das Ergebnis kopieren oder verwerfen."
        }
        onStateChanged?(id, phase)
    }

    private func finish(id: UUID, message: String) {
        guard sessionID == id else { return }
        sessionID = nil
        result = nil
        phase = .idle
        self.message = message
        onFinished?(id, message)
    }
}
