import AppKit
@preconcurrency import ApplicationServices
import AVFoundation
import Observation
import TypingRTCore

enum MicrophoneAccess {
    case notRequested, granted, denied, restricted

    var label: String {
        switch self {
        case .notRequested: "Noch nicht angefragt"
        case .granted: "Erlaubt"
        case .denied: "Nicht erlaubt"
        case .restricted: "Vom System eingeschränkt"
        }
    }
}

enum AppSection: String, CaseIterable {
    case overview = "Übersicht"
    case general = "Allgemein"
    case models = "Modelle & API"
    case dictionary = "Wörterbuch"
    case snippets = "Snippets"
    var symbol: String {
        switch self { case .overview: "square.grid.2x2"; case .general: "slider.horizontal.3"; case .models: "cpu"; case .dictionary: "character.book.closed"; case .snippets: "text.badge.plus" }
    }
}

@MainActor
@Observable
final class AppModel {
    let preferences: PreferencesStore
    let sessions: SessionCoordinator
    let dictation: DictationController
    let localModels = LocalModelStore()
    let transcription = TranscriptionPipeline()
    let delivery: TextDelivery
    let monitoring: MonitoringController
    let coding: CodingPipeline
    let dictionary: DictionaryLibrary
    let snippets: SnippetLibrary
    let loginItem = LoginItemController()
    let requesty: RequestySettings
    var selectedSection: AppSection = .overview
    private(set) var microphone: MicrophoneAccess = .notRequested
    private(set) var accessibilityGranted = false
    private(set) var isRequestingMicrophone = false
    private(set) var systemMessage: String?
    private(set) var workerAvailable = false
    private(set) var isCheckingWorker = false
    private(set) var workerMessage = "Erkennungsdienst noch nicht geprüft"
    @ObservationIgnored private let nativeMonitoringEnabled: Bool
    @ObservationIgnored private let nativeDictationAllowed: Bool
    @ObservationIgnored var onChange: (() -> Void)?

    var selectedMode: DictationMode {
        get { preferences.selectedMode }
        set {
            preferences.selectedMode = newValue
            if newValue == .coding { Task { await requesty.load() } }
            onChange?()
        }
    }

    var readiness: Readiness {
        Readiness(
            microphoneGranted: microphone == .granted,
            accessibilityGranted: accessibilityGranted,
            hotkeyAvailable: dictation.hotkeyAvailable,
            modelInstalled: localModels.state == .installed && localModels.installedPath != nil && localModels.tokenizerPath != nil && workerAvailable && dictionary.isLoaded && (selectedMode == .coding || snippets.isLoaded) && (selectedMode == .standard || requesty.canUseCoding)
        )
    }

    var statusTitle: String {
        switch dictation.phase {
        case .preparing: "Mikrofon wird vorbereitet"
        case .recording: "Aufnahme · \(dictation.activeMode.title)"
        case .finishing: "Aufnahme wird abgeschlossen"
        case .transcribing: "Wird lokal transkribiert"
        case .formatting: "Englischer Prompt wird formuliert"
        case .inserting: "Text wird übergeben"
        case .awaitingResult: coding.phase == .awaitingDecision ? "Coding braucht deine Entscheidung" : "Ergebnis bereit · kopieren oder verwerfen"
        case .cancelling: "Diktat wird verworfen"
        case .idle: readiness.canStart ? "Bereit zum Diktieren" : "Einrichtung erforderlich"
        }
    }

    init(preferences: PreferencesStore? = nil, nativeMonitoringEnabled: Bool = true, dictionaryURL: URL? = nil, nativeDictationAllowed: Bool = true, snippetsURL: URL? = nil, requesty: RequestySettings? = nil, coding: CodingPipeline? = nil, delivery: TextDelivery? = nil, monitoring: MonitoringController? = nil) {
        self.coding = coding ?? CodingPipeline()
        self.delivery = delivery ?? TextDelivery()
        let preferences = preferences ?? PreferencesStore()
        self.monitoring = monitoring ?? MonitoringController(url: AppIdentity.current.applicationSupport.appendingPathComponent("monitoring.sqlite"), preferences: preferences)
        self.requesty = requesty ?? RequestySettings(preferences: preferences)
        snippets = SnippetLibrary(url: snippetsURL ?? AppIdentity.current.applicationSupport.appendingPathComponent("snippets.sqlite"))
        dictionary = DictionaryLibrary(url: dictionaryURL ?? AppIdentity.current.applicationSupport.appendingPathComponent("dictionary.sqlite"))
        let sessions = SessionCoordinator()
        self.sessions = sessions
        dictation = DictationController(sessions: sessions)
        self.preferences = preferences
        self.nativeMonitoringEnabled = nativeMonitoringEnabled
        self.nativeDictationAllowed = nativeDictationAllowed
        if !nativeDictationAllowed { systemMessage = "Eine andere typingRT-Version ist geöffnet. Zum Diktieren beide Apps beenden und nur die gewünschte Version starten." }
        self.requesty.onChange = { [weak self] in self?.onChange?() }
        dictation.readinessProvider = { [weak self] in self?.readiness ?? Readiness(
            microphoneGranted: false, accessibilityGranted: false, hotkeyAvailable: false, modelInstalled: false) }
        dictation.requestyMetadataProvider = { [weak self] in
            guard let self, let id = self.preferences.requestyModelID else { return nil }
            return self.requesty.catalog?.models.first { $0.id == id }
        }
        dictation.requestyModelProvider = { [weak self] in self?.preferences.requestyModelID }
        dictation.snippetsProvider = { [weak self] in self?.snippets.snapshot ?? .empty }
        dictation.dictionaryProvider = { [weak self] in self?.dictionary.snapshot ?? .empty }
        dictation.modeProvider = { [weak self] in self?.selectedMode ?? .standard }
        dictation.modelReadinessTitleProvider = { [weak self] in
            guard let self else { return "Einrichtung nicht bereit" }
            guard self.selectedMode == .standard || self.requesty.canUseCoding else { return self.requesty.setupMessage }
            guard self.dictionary.isLoaded else { return "Wörterbuch bitte laden" }
            guard self.selectedMode == .coding || self.snippets.isLoaded else { return "Snippets bitte laden" }
            guard self.localModels.state == .installed else { return "Lokales Modell nicht bereit" }
            switch WorkerClient.bundleState {
            case .bundled: return "Erkennungsdienst bitte prüfen"
            case .appMoved: return "App verschoben – bitte neu starten"
            case .notBundled: return "Erkennungsdienst fehlt in dieser Vorschau"
            }
        }
        dictation.captureHealthCheck = { [weak self] in self?.refreshPermissions() }
        dictation.onStateChanged = { [weak self] in self?.onChange?() }
        dictation.onRecordingStopped = { [weak self] id in self?.monitoring.stop(sessionID: id) }
        dictation.onSessionStarted = { [weak self] id in
            self?.monitoring.begin(sessionID: id)
            guard let self, let session = self.sessions.activeSession, session.id == id,
                  let model = self.localModels.installedPath, let tokenizer = self.localModels.tokenizerPath else { return }
            self.delivery.start(sessionID: id)
            self.transcription.start(session: session, modelURL: model, tokenizerURL: tokenizer)
        }
        dictation.onCapturedAudio = { [weak self] audio in
            guard let self else { return }
            self.dictation.markTranscribing(sessionID: audio.sessionID)
            self.transcription.consume(audio)
        }
        dictation.onSessionCancelled = { [weak self] id in
            self?.monitoring.finish(sessionID: id)
            self?.coding.cancel(sessionID: id)
            self?.delivery.cancel(sessionID: id)
            self?.transcription.cancel(sessionID: id)
        }
        transcription.onRecognized = { [weak self] id, rawText in
            guard let self, self.sessions.mayDeliver(sessionID: id) else { return }
            self.monitoring.recognized(sessionID: id, rawText: rawText)
        }
        transcription.onFinished = { [weak self] id, message in
            guard let self, self.sessions.mayDeliver(sessionID: id),
                  let result = self.transcription.result, result.sessionID == id else { return }
            if result.mode == .standard || result.cleanedText.isEmpty { self.monitoring.ready(sessionID: id) }
            if result.cleanedText.isEmpty {
                self.monitoring.finish(sessionID: id)
                self.delivery.cancel(sessionID: id)
                self.transcription.clearResult()
                self.dictation.complete(sessionID: id, message: message)
            } else {
                if result.mode == .standard { self.delivery.submit(result) }
                else { self.coding.start(result, model: result.requestyModel) }
            }
        }
        self.coding.onStateChanged = { [weak self] id, phase in
            guard let self, self.sessions.mayDeliver(sessionID: id) else { return }
            self.dictation.markFormatting(sessionID: id, pendingMessage: phase == .awaitingDecision ? self.coding.message ?? "Original bleibt verfügbar." : nil)
            self.onChange?()
        }
        self.coding.onReady = { [weak self] result, automatic in
            guard let self, self.sessions.mayDeliver(sessionID: result.sessionID) else { return }
            if automatic { self.monitoring.ready(sessionID: result.sessionID) }
            self.delivery.submit(result, automatic: automatic)
            if !automatic { self.delivery.copy(sessionID: result.sessionID) }
        }
        self.delivery.onStateChanged = { [weak self] id, phase in
            guard let self else { return }
            self.dictation.markDelivery(sessionID: id, awaitingResult: phase == .awaitingResult)
            self.onChange?()
        }
        self.delivery.onConfirmedInsertion = { [weak self] id, words, seconds in
            guard let self, self.sessions.mayDeliver(sessionID: id) else { return }
            self.monitoring.confirmed(sessionID: id, outputWords: words, insertionSeconds: seconds)
        }
        self.delivery.onFinished = { [weak self] id, message in
            guard let self, self.sessions.mayDeliver(sessionID: id) else { return }
            self.monitoring.finish(sessionID: id)
            self.coding.cancel(sessionID: id)
            self.transcription.clearResult()
            // Inserted, handed off, copied or discarded: nothing to announce.
            self.dictation.complete(sessionID: id, message: message, quiet: true)
        }
        transcription.onRecoverableFailure = { [weak self] id, message in
            guard let self, self.sessions.activeSession?.id == id else { return }
            self.dictation.abort(message: message)
        }
        transcription.onFailure = { [weak self] id, message in
            guard let self, self.sessions.activeSession?.id == id else { return }
            self.workerAvailable = false
            self.workerMessage = "Dienst unterbrochen – bitte erneut prüfen"
            self.dictation.abort(message: message)
        }
        refreshPermissions()
        if selectedMode == .coding {
            Task { [weak self] in await self?.requesty.load() }
        }
        if nativeMonitoringEnabled {
            dictation.prepareTemporaryStorage()
            self.monitoring.load()
            Task { [weak self] in
                guard let self else { return }
                await self.dictionary.load()
                await self.snippets.load()
                await self.localModels.refresh()
                if self.localModels.state == .installed, WorkerClient.isBundled {
                    await self.checkWorker()
                }
                self.onChange?()
            }
        }
    }

    func checkWorker() async {
        guard !isCheckingWorker, !dictation.isBusy else { return }
        isCheckingWorker = true
        let client = WorkerClient()
        defer { client.cancel(); isCheckingWorker = false; onChange?() }
        do {
            let capability = try await client.inspect()
            workerAvailable = true
            workerMessage = "WhisperKit \(capability.version) · bereit"
        } catch {
            workerAvailable = false
            workerMessage = error.localizedDescription
        }
    }

    func installLocalModel() async {
        guard !dictation.isBusy else { return }
        await localModels.install()
        if localModels.state == .installed, WorkerClient.isBundled { await checkWorker() }
        onChange?()
    }

    func refreshLocalModel() async {
        guard !dictation.isBusy else { return }
        await localModels.refresh()
        onChange?()
    }

    func refreshPermissions() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: microphone = .granted
        case .notDetermined: microphone = .notRequested
        case .denied: microphone = .denied
        case .restricted: microphone = .restricted
        @unknown default: microphone = .restricted
        }
        // This read never opens a system permission prompt.
        accessibilityGranted = AXIsProcessTrusted()
        if nativeMonitoringEnabled && nativeDictationAllowed { dictation.refreshMonitoring(accessibilityGranted: accessibilityGranted) }
        if microphone != .granted && dictation.isBusy && !dictation.hasFinishedRecording {
            dictation.abort(message: "Mikrofonzugriff wurde unterbrochen.")
        }
        onChange?()
    }

    func configureMicrophone() async {
        guard !isRequestingMicrophone else { return }
        systemMessage = nil
        if microphone == .notRequested {
            isRequestingMicrophone = true
            _ = await AVCaptureDevice.requestAccess(for: .audio)
            isRequestingMicrophone = false
            refreshPermissions()
        } else if microphone != .granted {
            openPrivacySettings("Privacy_Microphone")
        }
    }

    func configureAccessibility() {
        // AX cannot distinguish "never requested" from "denied". Do not invent that state.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacySettings("Privacy_Accessibility")
    }

    private func openPrivacySettings(_ pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"),
              NSWorkspace.shared.open(url) else {
            systemMessage = "Öffne Systemeinstellungen → Datenschutz & Sicherheit und prüfe dort den Zugriff für typingRT."
            return
        }
    }

    func shutDown() {
        requesty.shutDown()
        localModels.cancel()
        dictation.prepareForShutdown()
    }

    func interruptForSystem() {
        guard dictation.isBusy else { return }
        if dictation.hasFinishedRecording, let id = sessions.activeSession?.id {
            coding.interrupt(sessionID: id)
            delivery.interrupt(sessionID: id)
        } else {
            dictation.abort(message: "Aufnahme durch das System unterbrochen.")
        }
    }

    func finishShutdown() async {
        await coding.finishShutdown()
        await requesty.finishShutdown()
        await delivery.finishShutdown()
        await dictation.finishShutdown()
        await transcription.finishShutdown()
        await localModels.shutdown()
        await monitoring.flush()
    }
}

extension DictationMode {
    var title: String { self == .standard ? "Standard" : "Coding" }
}
