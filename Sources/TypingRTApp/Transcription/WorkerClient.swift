import Foundation
import TypingRTCore

enum WorkerClientError: LocalizedError {
    case unavailable, disconnected, malformed, busy, remote, incompleteTranscription
    var errorDescription: String? {
        switch self {
        case .unavailable: "Der lokale Erkennungsdienst ist in diesem Build noch nicht enthalten."
        case .disconnected: "Der Erkennungsdienst wurde unterbrochen. Bitte erneut diktieren."
        case .malformed: "Der Erkennungsdienst hat keine gültige Antwort geliefert."
        case .busy: "Der Erkennungsdienst verarbeitet bereits ein Diktat."
        case .remote: "Die lokale Erkennung ist fehlgeschlagen. Bitte Modellinstallation prüfen."
        case .incompleteTranscription: "Die Erkennung hat ihr Textlimit erreicht. Es wird kein unvollständiger Text eingefügt. Bitte in kürzeren Abschnitten erneut diktieren."
        }
    }
}

/// One connection per dictation, explicitly discarded on abort/crash. Every
/// callback must still match the active generation, including inspect replies.
@MainActor
final class WorkerClient {
    var onDisconnection: (() -> Void)?
    private var connection: NSXPCConnection?
    private var generation = UUID()
    private var pendingToken: UUID?
    private var pending: CheckedContinuation<Data, Error>?
    private var timeout: Task<Void, Never>?

    static var isBundled: Bool {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/XPCServices/\(AppIdentity.current.workerServiceName).xpc/Contents/MacOS/TranscriptionWorker")
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    func inspect() async throws -> WorkerCapabilities {
        let data = try await call(timeoutSeconds: 10) { proxy, reply in proxy.inspect(withReply: reply) }
        guard let value = try? JSONDecoder().decode(WorkerCapabilities.self, from: data), value.backendAvailable else {
            throw WorkerClientError.unavailable
        }
        return value
    }

    func prepare(_ request: WorkerRequest) async throws -> WorkerReply {
        let data = try JSONEncoder().encode(request)
        return try decode(await call(timeoutSeconds: 180) { $0.prepare(data, withReply: $1) }, for: request.sessionID)
    }

    func transcribe(_ request: WorkerRequest) async throws -> WorkerReply {
        let data = try JSONEncoder().encode(request)
        return try decode(await call(timeoutSeconds: 1800) { $0.transcribe(data, withReply: $1) }, for: request.sessionID)
    }

    func decode(_ data: Data, for id: UUID) throws -> WorkerReply {
        guard let value = try? JSONDecoder().decode(WorkerReply.self, from: data), value.sessionID == id else {
            throw WorkerClientError.malformed
        }
        if value.errorCode == .incompleteTranscription { throw WorkerClientError.incompleteTranscription }
        guard value.error == nil, value.errorCode == nil else { throw WorkerClientError.remote }
        return value
    }

    func cancel(sessionID: UUID? = nil) {
        if let sessionID, let proxy = connection?.remoteObjectProxy as? TranscriptionWorkerProtocol {
            proxy.cancel(sessionID.uuidString, withReply: { @Sendable in })
        }
        fail(CancellationError())
    }

    private func disconnected(generation token: UUID) {
        guard generation == token else { return }
        fail(WorkerClientError.disconnected)
        // Also signal a crash between prepare and transcribe, when no reply is pending.
        onDisconnection?()
    }

    private func fail(_ error: Error) {
        timeout?.cancel()
        timeout = nil
        generation = UUID()
        let continuation = pending
        pending = nil
        pendingToken = nil
        let previous = connection
        connection = nil
        previous?.invalidationHandler = nil
        previous?.interruptionHandler = nil
        previous?.invalidate()
        continuation?.resume(throwing: error)
    }

    private func call(timeoutSeconds: Double, _ send: (TranscriptionWorkerProtocol, @escaping (Data) -> Void) -> Void) async throws -> Data {
        guard pending == nil else { throw WorkerClientError.busy }
        guard Self.isBundled else { throw WorkerClientError.unavailable }
        let token = generation
        let operation = UUID()
        if connection == nil {
            let connection = NSXPCConnection(serviceName: AppIdentity.current.workerServiceName)
            connection.remoteObjectInterface = WorkerWire.interface()
            connection.invalidationHandler = { @Sendable [weak self] in
                Task { @MainActor in
                    guard let self, self.generation == token else { return }
                    self.disconnected(generation: token)
                }
            }
            connection.interruptionHandler = connection.invalidationHandler
            self.connection = connection
            connection.resume()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(throwing: CancellationError()); return }
                pending = continuation
                pendingToken = operation
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeoutSeconds)) } catch { return }
                    guard let self, self.pendingToken == operation else { return }
                    self.disconnected(generation: token)
                }
                guard let proxy = connection?.remoteObjectProxyWithErrorHandler({ @Sendable [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.pendingToken == operation else { return }
                        self.disconnected(generation: token)
                    }
                }) as? TranscriptionWorkerProtocol else { fail(WorkerClientError.disconnected); return }
                send(proxy) { @Sendable [weak self] data in
                    Task { @MainActor in
                        guard let self, self.generation == token, self.pendingToken == operation, let pending = self.pending else { return }
                        self.pending = nil
                        self.pendingToken = nil
                        self.timeout?.cancel()
                        self.timeout = nil
                        pending.resume(returning: data)
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.generation == token, self.pendingToken == operation else { return }
                self.fail(CancellationError())
            }
        }
    }
}
