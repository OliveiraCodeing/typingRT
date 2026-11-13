import AppKit
import Observation
import TypingRTCore

@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable { case idle, preparing, recording, finishing, transcribing, formatting, inserting, awaitingResult, cancelling }

    private(set) var phase: Phase = .idle
    private(set) var hotkeyAvailable = false
    private(set) var elapsedSeconds: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var message: String?
    private(set) var activeMode: DictationMode = .standard
    /// A routine confirmation the overlay does not announce. Compared by value,
    /// so any later, different message is shown again.
    @ObservationIgnored private(set) var quietMessage: String?

    @ObservationIgnored var readinessProvider: () -> Readiness = {
        Readiness(microphoneGranted: false, accessibilityGranted: false, hotkeyAvailable: false, modelInstalled: false)
    }
    @ObservationIgnored var snippetsProvider: () -> SnippetSnapshot = { .empty }
    @ObservationIgnored var dictionaryProvider: () -> DictionarySnapshot = { .empty }
    @ObservationIgnored var modeProvider: () -> DictationMode = { .standard }
    @ObservationIgnored var requestyMetadataProvider: () -> RequestyModel? = { nil }
    @ObservationIgnored var requestyModelProvider: () -> String? = { nil }
    @ObservationIgnored var modelReadinessTitleProvider: () -> String = { "Lokales Modell fehlt" }
    @ObservationIgnored var captureHealthCheck: (() -> Void)?
    @ObservationIgnored var onStateChanged: (() -> Void)?
    @ObservationIgnored var onCapturedAudio: ((CapturedAudio) -> Void)?
    @ObservationIgnored var onSessionStarted: ((UUID) -> Void)?
    @ObservationIgnored var onRecordingStopped: ((UUID) -> Void)?
    @ObservationIgnored var onSessionCancelled: ((UUID) -> Void)?
    @ObservationIgnored private let sessions: SessionCoordinator
    @ObservationIgnored private let hotkeys = GlobalHotkeyMonitor()
    @ObservationIgnored private let audio = AudioCaptureService()
    @ObservationIgnored private var isHeld = false
    @ObservationIgnored private var ignoreUntilRelease = true
    @ObservationIgnored private var terminated = false
    @ObservationIgnored private var startTask: Task<Void, Error>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?
    @ObservationIgnored private var meterTask: Task<Void, Never>?
    @ObservationIgnored private var cancellationTask: Task<Void, Never>?
    @ObservationIgnored private var startedAt: ContinuousClock.Instant?

    init(sessions: SessionCoordinator) {
        self.sessions = sessions
        hotkeys.onRightOptionChanged = { [weak self] in self?.receiveOption(isPressed: $0) }
        hotkeys.onEscape = { [weak self] in
            guard let self, self.isBusy else { return }
            self.abort(message: "Diktat verworfen")
        }
        hotkeys.onFailure = { [weak self] message in
            guard let self else { return }
            self.hotkeyAvailable = false
            self.ignoreUntilRelease = true
            if self.hasFinishedRecording {
                self.message = message + " Das Ergebnis bleibt verfügbar."
                self.notifyPresentation()
                return
            }
            self.abort(message: message)
        }
        hotkeys.onInterrupted = { [weak self] message in
            guard let self else { return }
            // The monitor stays active; the next physical press starts normally.
            self.isHeld = false
            self.ignoreUntilRelease = false
            if self.isRecording { self.abort(message: message) }
            // Clears the coordinator's key state in every phase. After abort it is
            // idle, otherwise already processing, so this cannot submit audio.
            _ = self.sessions.handleRightOption(isPressed: false, readiness: self.readinessProvider(), selectedMode: self.modeProvider())
        }
        audio.onFailure = { [weak self] sessionID, message in
            Task { @MainActor in
                guard let self, self.sessions.activeSession?.id == sessionID else { return }
                self.abort(message: message)
            }
        }
    }

    var isBusy: Bool { phase != .idle || sessions.activeSession != nil }
    var hasFinishedRecording: Bool { phase == .formatting || phase == .inserting || phase == .awaitingResult }
    var isRecording: Bool { phase == .preparing || phase == .recording }
    var idleTitle: String {
        let readiness = readinessProvider()
        if readiness.canStart { return "Rechte ⌥ gedrückt halten" }
        if readiness.microphoneGranted && readiness.accessibilityGranted && !readiness.modelInstalled {
            return modelReadinessTitleProvider()
        }
        return "Einrichtung erforderlich"
    }

    func prepareTemporaryStorage() { audio.prepareTemporaryStorage() }

    func refreshMonitoring(accessibilityGranted: Bool) {
        guard !terminated else { return }
        if !accessibilityGranted {
            hotkeys.stop()
            hotkeyAvailable = false
            ignoreUntilRelease = true
            if isBusy && !hasFinishedRecording { abort(message: "Bedienungshilfen-Zugriff wurde unterbrochen.") }
            notifyPresentation()
            return
        }
        guard !hotkeys.isRunning else { return }
        if hotkeys.start() {
            hotkeyAvailable = true
            isHeld = hotkeys.isRightOptionDown
            ignoreUntilRelease = isHeld
            sessions.resynchronizeKeyState(isPressed: isHeld)
            if !isBusy { message = nil }
        } else {
            hotkeyAvailable = false
        }
        notifyPresentation()
    }

    private func receiveOption(isPressed: Bool) {
        guard !terminated else { return }
        isHeld = isPressed
        if !isPressed, let sessionID = sessions.activeSession?.id {
            audio.closeCaptureGate(sessionID: sessionID)
        }
        if ignoreUntilRelease {
            if !isPressed {
                ignoreUntilRelease = false
                _ = sessions.handleRightOption(isPressed: false, readiness: readinessProvider(), selectedMode: modeProvider())
            }
            return
        }
        if isPressed {
            let readiness = readinessProvider()
            let allowed = !isBusy ? readiness : Readiness(
                microphoneGranted: false, accessibilityGranted: false, hotkeyAvailable: false, modelInstalled: false)
            let mode = modeProvider()
            let snippets: SnippetSnapshot = mode == .standard && allowed.canStart ? snippetsProvider() : .empty
            let requestyModelID = mode == .coding && allowed.canStart ? requestyModelProvider() : nil
            guard let id = sessions.handleRightOption(isPressed: true, readiness: allowed, selectedMode: mode, dictionary: dictionaryProvider(), snippets: snippets, requestyModelID: requestyModelID, requestyModel: mode == .coding && allowed.canStart ? requestyMetadataProvider() : nil) else {
                if isBusy { message = "Beschäftigt – bitte nach Abschluss erneut drücken." }
                else if !readiness.microphoneGranted { message = "Bitte zuerst den Mikrofonzugriff einrichten." }
                else if !readiness.modelInstalled { message = modelReadinessTitleProvider() + ". Es wird nichts aufgenommen." }
                else { message = "Bitte zuerst die Einrichtung abschließen." }
                notifyPresentation()
                return
            }
            beginCapture(sessionID: id)
        } else {
            _ = sessions.handleRightOption(isPressed: false, readiness: readinessProvider(), selectedMode: modeProvider())
            guard let id = sessions.activeSession?.id, isRecording else {
                if !isBusy { message = nil; notifyPresentation() }
                return
            }
            finishCapture(sessionID: id)
        }
    }

    private func beginCapture(sessionID: UUID) {
        activeMode = sessions.activeSession?.mode ?? modeProvider()
        message = nil
        quietMessage = nil
        elapsedSeconds = 0
        level = 0
        startedAt = ContinuousClock().now
        phase = .preparing
        // Prepare synchronously in the press callback. A release can close this
        // gate before the asynchronous hardware initialization even starts.
        audio.prepare(sessionID: sessionID)
        onSessionStarted?(sessionID)
        let captureService = audio
        let task = Task { try await captureService.start(sessionID: sessionID) }
        startTask = task
        startMeter()
        notifyPresentation()
        Task { [weak self] in
            do {
                try await task.value
                guard let self, self.sessions.activeSession?.id == sessionID,
                      self.isHeld, self.phase == .preparing else { return }
                self.phase = .recording
                self.notifyPresentation()
            } catch {
                guard let self, self.sessions.activeSession?.id == sessionID, self.isHeld else { return }
                self.abort(message: "Aufnahme konnte nicht gestartet werden. \(error.localizedDescription)")
            }
        }
    }

    private func finishCapture(sessionID: UUID) {
        onRecordingStopped?(sessionID)
        phase = .finishing
        meterTask?.cancel()
        level = 0
        let pendingStart = startTask
        notifyPresentation()
        finishTask = Task { [weak self] in
            guard let self else { return }
            // Even a cancelled, too-short start must reach stop to clean up its file.
            _ = try? await pendingStart?.value
            guard !Task.isCancelled, self.sessions.activeSession?.id == sessionID else { return }
            do {
                let captured = try await self.audio.stop(sessionID: sessionID)
                guard !Task.isCancelled, self.sessions.mayDeliver(sessionID: sessionID) else {
                    if let captured { await Self.discard(captured) }
                    return
                }
                if let captured, let consumer = self.onCapturedAudio {
                    consumer(captured)
                    // Ownership now belongs to the processing pipeline. It calls
                    // complete(sessionID:) after consuming/deleting the file.
                    return
                } else {
                    if let captured { await Self.discard(captured) }
                    guard !Task.isCancelled, self.sessions.activeSession?.id == sessionID else { return }
                    self.onSessionCancelled?(sessionID)
                    self.sessions.invalidate()
                    self.phase = .idle
                    self.message = captured == nil ? "Keine Aufnahme vorhanden." : "Aufnahme beendet. Transkription ist noch nicht eingerichtet."
                }
            } catch {
                guard !Task.isCancelled, self.sessions.activeSession?.id == sessionID else { return }
                await self.audio.cancel(sessionID: sessionID)
                guard !Task.isCancelled, self.sessions.activeSession?.id == sessionID else { return }
                self.onSessionCancelled?(sessionID)
                self.sessions.invalidate()
                self.phase = .idle
                self.message = "Aufnahme wurde unterbrochen. \(error.localizedDescription)"
            }
            // Every path arriving here just finished its own guarded session;
            // there is no suspension between the guard and this cleanup.
            self.startTask = nil
            self.level = 0
            self.notifyPresentation()
        }
    }

    func markTranscribing(sessionID: UUID) {
        guard phase == .finishing, sessions.mayDeliver(sessionID: sessionID) else { return }
        phase = .transcribing
        notifyPresentation()
    }

    func complete(sessionID: UUID, message: String? = nil, quiet: Bool = false) {
        guard (phase == .finishing || phase == .transcribing || hasFinishedRecording), sessions.mayDeliver(sessionID: sessionID) else { return }
        sessions.invalidate()
        phase = .idle
        level = 0
        startTask = nil
        finishTask = nil
        self.message = message
        quietMessage = quiet ? message : nil
        notifyPresentation()
    }

    func markFormatting(sessionID: UUID, pendingMessage: String? = nil) {
        guard sessions.mayDeliver(sessionID: sessionID), phase == .transcribing || hasFinishedRecording else { return }
        phase = pendingMessage == nil ? .formatting : .awaitingResult
        message = pendingMessage
        notifyPresentation()
    }

    func markDelivery(sessionID: UUID, awaitingResult: Bool) {
        guard sessions.mayDeliver(sessionID: sessionID),
              phase == .transcribing || hasFinishedRecording else { return }
        phase = awaitingResult ? .awaitingResult : .inserting
        message = awaitingResult ? "Ergebnis bereit – in typingRT kopieren oder verwerfen." : nil
        notifyPresentation()
    }

    func abort(message: String) {
        guard !terminated else { return }
        self.message = message
        quietMessage = nil
        let cancelledID = sessions.activeSession?.id
        if let cancelledID { audio.closeCaptureGate(sessionID: cancelledID) }
        if let cancelledID { onSessionCancelled?(cancelledID) }
        startTask?.cancel()
        finishTask?.cancel()
        meterTask?.cancel()
        level = 0
        sessions.invalidate()
        guard phase != .cancelling else { notifyPresentation(); return }
        guard let cancelledID else {
            phase = .idle
            notifyPresentation()
            return
        }
        phase = .cancelling
        cancellationTask = Task { [weak self] in
            guard let self else { return }
            await self.audio.cancel(sessionID: cancelledID)
            guard !self.terminated else { return }
            self.phase = .idle
            self.startTask = nil
            self.notifyPresentation()
        }
        notifyPresentation()
    }

    func prepareForShutdown() {
        terminated = true
        if let id = sessions.activeSession?.id { onSessionCancelled?(id) }
        hotkeys.stop()
        hotkeyAvailable = false
        audio.closeCaptureGate()
        sessions.shutDown()
        startTask?.cancel()
        finishTask?.cancel()
        meterTask?.cancel()
    }

    func finishShutdown() async {
        await audio.cancel()
        await cancellationTask?.value
    }

    private func startMeter() {
        meterTask?.cancel()
        meterTask = Task { [weak self] in
            var healthTicks = 0
            while !Task.isCancelled {
                guard let self, self.isRecording else { return }
                // Recheck only while capturing. No new idle timer or permission prompt.
                if healthTicks % 20 == 0 {
                    self.captureHealthCheck?()
                    self.hotkeys.verifyCaptureHealth()
                    guard self.isRecording, !Task.isCancelled else { return }
                }
                healthTicks += 1
                if let startedAt = self.startedAt {
                    let duration = startedAt.duration(to: ContinuousClock().now).components
                    self.elapsedSeconds = Double(duration.seconds) + Double(duration.attoseconds) / 1e18
                }
                let measuredLevel = self.audio.level
                self.level = measuredLevel.isFinite ? min(1, max(0, measuredLevel)) : 0
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    private func notifyPresentation() {
        // Event-tap callbacks return promptly; menu and panel work happens later.
        Task { @MainActor [weak self] in self?.onStateChanged?() }
    }

    private static func discard(_ captured: CapturedAudio) async {
        let url = captured.url
        await Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }.value
    }
}
