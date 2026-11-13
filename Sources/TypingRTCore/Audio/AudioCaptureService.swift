import AVFoundation
import Foundation
import Synchronization

public struct CapturedAudio: Sendable {
    public let sessionID: UUID
    public let url: URL
    public let duration: TimeInterval
    public let frames: Int64
    public let sampleRate: Double
}

public enum AudioCaptureError: Error, Sendable, LocalizedError {
    case busy
    case microphoneNotAuthorized
    case unsupportedFormat
    case bufferOverflow
    case formatChanged
    case fileWriteFailed
    case engineStartFailed

    public var errorDescription: String? {
        switch self {
        case .busy: "Eine Aufnahme wird bereits verarbeitet."
        case .microphoneNotAuthorized: "Der Mikrofonzugriff ist nicht freigegeben."
        case .unsupportedFormat: "Das Mikrofon liefert kein unterstütztes Audioformat."
        case .bufferOverflow: "Die Aufnahme wurde beendet, weil Audiodaten nicht schnell genug gespeichert werden konnten."
        case .formatChanged: "Das Mikrofonformat hat sich während der Aufnahme geändert."
        case .fileWriteFailed: "Die Aufnahme konnte nicht vollständig gespeichert werden."
        case .engineStartFailed: "Das Mikrofon konnte nicht gestartet werden."
        }
    }
}

/// Small synchronous control plane. Its lock is never used by the audio callback.
final class AudioCaptureGate: @unchecked Sendable {
    private let lock = NSLock()
    private var preparedID: UUID?
    private var activeID: UUID?
    // Odd values are open generation tokens; clearing bit zero closes that exact
    // generation. One atomic CAS can reject an old callback without closing a new one.
    private let state = Atomic<UInt64>(0)
    let levelBits = Atomic<UInt32>(0)

    func prepare(sessionID: UUID) {
        lock.withLock {
            guard activeID == nil else { return }
            let next = (state.load(ordering: .relaxed) &+ 2) | 1
            preparedID = sessionID
            levelBits.store(0, ordering: .relaxed)
            state.store(next, ordering: .releasing)
        }
    }

    func claim(sessionID: UUID) throws -> UInt64 {
        try lock.withLock {
            guard activeID == nil else { throw AudioCaptureError.busy }
            let token = state.load(ordering: .acquiring)
            guard preparedID == sessionID, token & 1 == 1 else {
                throw CancellationError()
            }
            activeID = sessionID
            return token
        }
    }

    func permits(_ token: UInt64) -> Bool {
        token & 1 == 1 && state.load(ordering: .acquiring) == token
    }

    /// Callback-safe failure path; generation/ownership cleanup stays off callback.
    func rejectSamples(ifToken token: UInt64) {
        close(ifToken: token)
    }

    func close(ifToken token: UInt64) {
        if state.compareExchange(
            expected: token, desired: token & ~UInt64(1), ordering: .acquiringAndReleasing
        ).exchanged {
            levelBits.store(0, ordering: .relaxed)
        }
    }

    func close(sessionID: UUID) {
        lock.withLock {
            guard activeID == sessionID || (activeID == nil && preparedID == sessionID) else { return }
            _ = state.bitwiseAnd(~UInt64(1), ordering: .acquiringAndReleasing)
            levelBits.store(0, ordering: .relaxed)
        }
    }

    func close() {
        // Explicit all-session shutdown path. Normal stop/cancel is session-scoped.
        _ = state.bitwiseAnd(~UInt64(1), ordering: .acquiringAndReleasing)
        levelBits.store(0, ordering: .relaxed)
        lock.withLock {
            _ = state.bitwiseAnd(~UInt64(1), ordering: .acquiringAndReleasing)
        }
    }

    func finish(sessionID: UUID) {
        lock.withLock {
            guard activeID == sessionID || (activeID == nil && preparedID == sessionID) else { return }
            activeID = nil
            preparedID = nil
            _ = state.bitwiseAnd(~UInt64(1), ordering: .acquiringAndReleasing)
            levelBits.store(0, ordering: .relaxed)
        }
    }

    var level: Float {
        state.load(ordering: .acquiring) & 1 == 1
            ? Float(bitPattern: levelBits.load(ordering: .relaxed)) : 0
    }
}

/// All hardware operations are serialized off MainActor. One bounded writer worker
/// drains each session; the callback only copies samples into preallocated storage.
public final class AudioCaptureService: @unchecked Sendable {
    private let queue = DispatchQueue(label: "typingRT.audio.lifecycle", qos: .userInitiated)
    private let gate = AudioCaptureGate()
    private let callbackLock = NSLock()
    private var failureCallback: (@Sendable (UUID, String) -> Void)?
    // queue-owned state
    private var context: CaptureContext?
    private var temporaryStoragePrepared = false
    private var pendingFailure: (sessionID: UUID, error: AudioCaptureError)?

    public init() {}

    deinit {
        gate.close()
        if let current = context {
            queue.async {
                if let observer = current.observer { NotificationCenter.default.removeObserver(observer) }
                current.engine.stop()
                current.engine.inputNode.removeTap(onBus: 0)
                _ = current.writer.finish(discard: true)
                try? FileManager.default.removeItem(at: current.url)
            }
        }
    }

    public var onFailure: (@Sendable (UUID, String) -> Void)? {
        get { callbackLock.withLock { failureCallback } }
        set { callbackLock.withLock { failureCallback = newValue } }
    }

    public var level: Float { gate.level }

    /// Enqueued at app startup while the instance lock is held. Runs before any
    /// later capture operation on the same serial lifecycle queue.
    public func prepareTemporaryStorage() {
        queue.async { [self] in _ = try? prepareTemporaryDirectory() }
    }

    private func prepareTemporaryDirectory() throws -> URL {
        let directory = try TemporaryAudioFiles.prepareDirectory(removeOrphans: !temporaryStoragePrepared)
        temporaryStoragePrepared = true
        return directory
    }

    /// Call synchronously in the accepted key-down event, before creating a Task.
    /// Does not initialize hardware, allocate audio buffers or request permissions.
    public func prepare(sessionID: UUID) {
        gate.prepare(sessionID: sessionID)
    }

    /// Release/Esc closes the gate synchronously, even if start() has not run yet.
    public func closeCaptureGate() {
        gate.close()
    }

    public func closeCaptureGate(sessionID: UUID) {
        gate.close(sessionID: sessionID)
    }

    public func start(sessionID: UUID) async throws {
        let token = try gate.claim(sessionID: sessionID)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    try startOnQueue(sessionID: sessionID, token: token)
                    continuation.resume()
                } catch {
                    gate.finish(sessionID: sessionID)
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    public func stop(sessionID: UUID) async throws -> CapturedAudio? {
        closeCaptureGate(sessionID: sessionID)
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                do { continuation.resume(returning: try finishOnQueue(sessionID: sessionID, discard: false)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    public func cancel(sessionID: UUID) async {
        closeCaptureGate(sessionID: sessionID)
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                _ = try? finishOnQueue(sessionID: sessionID, discard: true)
                gate.finish(sessionID: sessionID)
                if pendingFailure?.sessionID == sessionID { pendingFailure = nil }
                continuation.resume()
            }
        }
    }

    public func cancel() async {
        closeCaptureGate()
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                _ = try? finishOnQueue(sessionID: nil, discard: true)
                pendingFailure = nil
                continuation.resume()
            }
        }
    }

    private func startOnQueue(sessionID: UUID, token: UInt64) throws {
        guard context == nil else { throw AudioCaptureError.busy }
        guard gate.permits(token) else { throw CancellationError() }
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            throw AudioCaptureError.microphoneNotAuthorized
        }
        pendingFailure = nil
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.commonFormat == .pcmFormatFloat32, !format.isInterleaved,
              format.sampleRate.isFinite, format.sampleRate > 0,
              (1...8).contains(Int(format.channelCount)) else {
            throw AudioCaptureError.unsupportedFormat
        }

        let directory = try prepareTemporaryDirectory()
        let url = directory.appendingPathComponent("\(sessionID.uuidString)-\(UUID().uuidString).wav")
        let writer: CaptureWriter
        do {
            writer = try CaptureWriter(url: url, format: format, gate: gate, token: token) { [weak self] error in
                self?.handleWriterFailure(error, sessionID: sessionID)
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw AudioCaptureError.fileWriteFailed
        }

        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { [writer] buffer, _ in
            writer.receive(buffer)
        }
        context = CaptureContext(sessionID: sessionID, engine: engine, writer: writer, url: url, sampleRate: format.sampleRate)
        do {
            guard gate.permits(token) else { throw CancellationError() }
            engine.prepare()
            guard gate.permits(token) else { throw CancellationError() }
            try engine.start()
            guard gate.permits(token) else { throw CancellationError() }
            context?.observer = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                gate.close(ifToken: token)
                handleWriterFailure(.formatChanged, sessionID: sessionID)
            }
        } catch {
            _ = try? finishOnQueue(sessionID: sessionID, discard: true)
            if error is CancellationError { throw error }
            throw AudioCaptureError.engineStartFailed
        }
    }

    private func finishOnQueue(sessionID: UUID?, discard: Bool) throws -> CapturedAudio? {
        guard let current = context else {
            if !discard, let failure = pendingFailure,
               sessionID == nil || failure.sessionID == sessionID { throw failure.error }
            return nil
        }
        guard sessionID == nil || current.sessionID == sessionID else { return nil }
        context = nil
        if let observer = current.observer { NotificationCenter.default.removeObserver(observer) }
        current.engine.stop()
        current.engine.inputNode.removeTap(onBus: 0)
        let result = current.writer.finish(discard: discard)
        gate.finish(sessionID: current.sessionID)
        if discard || result.failure != nil || result.frames == 0 {
            try? FileManager.default.removeItem(at: current.url)
        }
        if let failure = result.failure {
            pendingFailure = (current.sessionID, failure)
            if !discard { throw failure }
        }
        guard !discard, result.frames > 0 else { return nil }
        return CapturedAudio(
            sessionID: current.sessionID, url: current.url,
            duration: Double(result.frames) / current.sampleRate,
            frames: result.frames, sampleRate: current.sampleRate
        )
    }

    private func handleWriterFailure(_ failure: AudioCaptureError, sessionID: UUID) {
        queue.async { [weak self] in
            guard let self, context?.sessionID == sessionID else { return }
            _ = try? finishOnQueue(sessionID: sessionID, discard: true)
            pendingFailure = (sessionID, failure)
            let callback = onFailure
            callback?(sessionID, failure.localizedDescription)
        }
    }
}

private final class CaptureContext: @unchecked Sendable {
    let sessionID: UUID
    let engine: AVAudioEngine
    let writer: CaptureWriter
    let url: URL
    let sampleRate: Double
    var observer: (any NSObjectProtocol)?

    init(sessionID: UUID, engine: AVAudioEngine, writer: CaptureWriter, url: URL, sampleRate: Double) {
        self.sessionID = sessionID
        self.engine = engine
        self.writer = writer
        self.url = url
        self.sampleRate = sampleRate
    }
}

final class CaptureWriter: @unchecked Sendable {
    private let ring: AudioSampleRing
    private let sink: PCMFileWriter
    private let sampleRate: Double
    private let channelCount: Int
    private let gate: AudioCaptureGate
    private let token: UInt64
    private let wake = DispatchSemaphore(value: 0)
    private let completion = DispatchGroup()
    private let wakePending = Atomic<Bool>(false)
    private let finishing = Atomic<Bool>(false)
    private let discarding = Atomic<Bool>(false)
    private let callbackCount = Atomic<Int32>(0)
    private let failureCode = Atomic<Int32>(0)
    private let onFailure: @Sendable (AudioCaptureError) -> Void
    // Written by the worker; read only after completion.wait().
    private var resultFailure: AudioCaptureError?

    init(
        url: URL, format: AVAudioFormat, gate: AudioCaptureGate, token: UInt64,
        onFailure: @escaping @Sendable (AudioCaptureError) -> Void
    ) throws {
        ring = AudioSampleRing(channelCount: Int(format.channelCount))
        sink = try PCMFileWriter(url: url, format: format)
        sampleRate = format.sampleRate
        channelCount = Int(format.channelCount)
        self.gate = gate
        self.token = token
        self.onFailure = onFailure
        completion.enter()
        DispatchQueue(label: "typingRT.audio.writer", qos: .userInitiated).async { [self] in run() }
    }

    /// Real-time path: no lock, file I/O, allocation or enqueued per-buffer task.
    func receive(_ buffer: AVAudioPCMBuffer) {
        _ = callbackCount.wrappingAdd(1, ordering: .acquiringAndReleasing)
        defer {
            _ = callbackCount.wrappingSubtract(1, ordering: .acquiringAndReleasing)
            signal()
        }
        guard gate.permits(token), !finishing.load(ordering: .acquiring),
              failureCode.load(ordering: .acquiring) == 0 else { return }
        guard buffer.format.sampleRate == sampleRate,
              Int(buffer.format.channelCount) == channelCount,
              buffer.format.commonFormat == .pcmFormatFloat32,
              !buffer.format.isInterleaved,
              let channels = buffer.floatChannelData else {
            fail(2)
            return
        }
        let frames = Int(buffer.frameLength)
        guard ring.push(channels: channels, frames: frames) else {
            fail(1)
            return
        }
        var peak: Float = 0
        for channel in 0..<channelCount {
            for frame in 0..<frames {
                peak = max(peak, abs(channels[channel][frame]))
            }
        }
        gate.levelBits.store(min(peak, 1).bitPattern, ordering: .relaxed)
    }

    private func fail(_ code: Int32) {
        _ = failureCode.compareExchange(expected: 0, desired: code, ordering: .acquiringAndReleasing)
        gate.rejectSamples(ifToken: token)
    }

    private func signal() {
        if !wakePending.exchange(true, ordering: .acquiringAndReleasing) { wake.signal() }
    }

    func finish(discard: Bool) -> (frames: Int64, failure: AudioCaptureError?) {
        discarding.store(discard, ordering: .releasing)
        finishing.store(true, ordering: .releasing)
        signal()
        completion.wait()
        return (sink.writtenFrames, resultFailure)
    }

    private func run() {
        defer {
            sink.close()
            completion.leave()
        }
        do {
            while true {
                wake.wait()
                wakePending.store(false, ordering: .releasing)
                switch failureCode.load(ordering: .acquiring) {
                case 1: throw AudioCaptureError.bufferOverflow
                case 2: throw AudioCaptureError.formatChanged
                default: break
                }
                if !discarding.load(ordering: .acquiring) {
                    do { try sink.drain(ring) }
                    catch { throw AudioCaptureError.fileWriteFailed }
                }
                if finishing.load(ordering: .acquiring),
                   callbackCount.load(ordering: .acquiring) == 0,
                   discarding.load(ordering: .acquiring) || ring.availableFrames == 0 {
                    return
                }
            }
        } catch let failure as AudioCaptureError {
            resultFailure = failure
            gate.close(ifToken: token)
            onFailure(failure)
        } catch {
            resultFailure = .fileWriteFailed
            gate.close(ifToken: token)
            onFailure(.fileWriteFailed)
        }
    }
}
