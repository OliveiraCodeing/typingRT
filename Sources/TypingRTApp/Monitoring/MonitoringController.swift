import Foundation
import Observation
import TypingRTCore

/// Raw ASR exists only in a short-lived off-main word-count task. The store
/// receives content-free values only. Capture/delivery never wait for SQLite.
@MainActor @Observable
final class MonitoringController {
    private(set) var summary: MonitoringSummary?
    private(set) var message: String?
    private(set) var isResetting = false
    private(set) var isLoading = false
    var resetConfirmation = false
    var wpmInput: String
    private(set) var wpmError: String?
    @ObservationIgnored private let store: MonitoringStore
    @ObservationIgnored private let preferences: PreferencesStore
    @ObservationIgnored private let now: () -> ContinuousClock.Instant
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var context: Context?

    private struct Context {
        let id: UUID
        let periodID: UUID
        let started: ContinuousClock.Instant
        var stopped: ContinuousClock.Instant?
        var ready: ContinuousClock.Instant?
        var asrRecorded = false
        var insertionRecorded = false
    }

    init(url: URL, preferences: PreferencesStore, now: @escaping () -> ContinuousClock.Instant = { ContinuousClock().now }) {
        store = MonitoringStore(url: url)
        self.preferences = preferences
        self.now = now
        wpmInput = String(preferences.typingWordsPerMinute)
    }

    func load() {
        guard !isLoading, !isResetting else { return }
        isLoading = true
        enqueue { [weak self, store] in
            do { self?.summary = try await store.load(); self?.message = nil }
            catch { self?.message = MonitoringError.storageFailure.localizedDescription }
            self?.isLoading = false
        }
    }

    func saveWPM() {
        guard preferences.setTypingWordsPerMinute(wpmInput) else {
            wpmError = "Gib eine endliche Zahl größer als 0 ein."
            return
        }
        wpmError = nil
        wpmInput = String(preferences.typingWordsPerMinute)
    }

    func begin(sessionID: UUID) {
        guard !isResetting, let period = summary?.periodID else {
            context = nil
            message = "Statistik noch nicht verfügbar. Dieses Diktat wird ohne Messung verarbeitet."
            return
        }
        context = Context(id: sessionID, periodID: period, started: now())
    }

    func stop(sessionID: UUID) {
        guard context?.id == sessionID, context?.stopped == nil else { return }
        context?.stopped = now()
    }

    func recognized(sessionID: UUID, rawText: String) {
        guard var current = context, current.id == sessionID, !current.asrRecorded else { return }
        current.asrRecorded = true
        context = current
        let period = current.periodID
        // Acceptance and period capture happen synchronously before cancellation
        // can clear the session. The accepted count survives later discard.
        let count = Task.detached(priority: .utility) { WordSegmentation.count(rawText) }
        enqueueMeasurement { [store] in
            let words = await count.value
            return try await store.recordASR(periodID: period, sessionID: sessionID, wordCount: words)
        }
    }

    func recognized(sessionID: UUID, wordCount: Int) {
        guard var current = context, current.id == sessionID, !current.asrRecorded else { return }
        current.asrRecorded = true
        context = current
        enqueueMeasurement { [store] in
            try await store.recordASR(periodID: current.periodID, sessionID: sessionID, wordCount: wordCount)
        }
    }

    func ready(sessionID: UUID) {
        guard var current = context, current.id == sessionID, current.ready == nil,
              let stopped = current.stopped else { return }
        let ready = now()
        current.ready = ready
        context = current
        let processing = Self.seconds(stopped.duration(to: ready))
        enqueueMeasurement { [store] in
            try await store.recordReady(periodID: current.periodID, sessionID: sessionID, processingSeconds: processing)
        }
    }

    func confirmed(sessionID: UUID, outputWords: Int, insertionSeconds: Double) {
        guard var current = context, current.id == sessionID, !current.insertionRecorded,
              let stopped = current.stopped, let ready = current.ready else { return }
        current.insertionRecorded = true
        context = current
        // Snapshot when the confirmed receipt arrives, before any database await.
        let wpm = preferences.typingWordsPerMinute
        let recording = Self.seconds(current.started.duration(to: stopped))
        let processing = Self.seconds(stopped.duration(to: ready))
        enqueueMeasurement { [store] in
            try await store.recordConfirmedInsertion(periodID: current.periodID, sessionID: sessionID,
                outputWords: outputWords, wpm: wpm, recordingSeconds: recording,
                processingSeconds: processing, insertionSeconds: insertionSeconds)
        }
    }

    func finish(sessionID: UUID) {
        if context?.id == sessionID { context = nil }
    }

    /// Called only by the confirmation action. A new session during the reset
    /// cannot borrow the old period; existing sessions keep their old token.
    func reset() {
        guard !isResetting, !isLoading else { return }
        isResetting = true
        enqueue { [weak self, store] in
            do { self?.summary = try await store.reset(); self?.message = nil }
            catch { self?.message = MonitoringError.storageFailure.localizedDescription }
            self?.isResetting = false
        }
    }

    func flush() async { await pending?.value }

    private func enqueueMeasurement(_ operation: @escaping @MainActor () async throws -> MonitoringSummary) {
        enqueue { [weak self] in
            do {
                let result = try await operation()
                // Serialized reset/write ordering and store-side period validation
                // prevent a retired session from restoring pre-reset measurements.
                self?.summary = result
            } catch { self?.message = MonitoringError.storageFailure.localizedDescription }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = pending
        pending = Task {
            await previous?.value
            await operation()
        }
    }

    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
