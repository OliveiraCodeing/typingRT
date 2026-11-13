import Foundation

public enum WorkerOperation: Sendable {
    case prepare
    case transcribe
}

/// Serializes work across XPC connections, including actor reentrancy while a
/// Core ML call is suspended. Cancellation never frees an executing slot early.
public actor WorkerCoordinator {
    private let perform: @Sendable (WorkerRequest, WorkerOperation) async -> WorkerReply

    public init(perform: @escaping @Sendable (WorkerRequest, WorkerOperation) async -> WorkerReply) {
        self.perform = perform
    }
    private var activeSession: UUID?
    private var activeOwner: UUID?
    private var inFlight: Task<WorkerReply, Never>?
    private var terminalSessions: Set<UUID> = []
    private var terminalOrder: [UUID] = []

    public func run(_ data: Data, owner: UUID, lifetime: WorkerConnectionLifetime, kind: WorkerOperation) async -> Data {
        guard let request = try? JSONDecoder().decode(WorkerRequest.self, from: data) else {
            return encode(errorReply(sessionID: UUID(), message: "Die Worker-Anfrage ist ungültig."))
        }
        guard !lifetime.isClosed, !terminalSessions.contains(request.sessionID) else {
            return encode(errorReply(sessionID: request.sessionID, message: "Das Diktat wurde bereits beendet oder verworfen."))
        }
        guard inFlight == nil,
              activeSession == nil || (activeSession == request.sessionID && activeOwner == owner) else {
            return encode(errorReply(sessionID: request.sessionID, message: "Die lokale Erkennung ist noch beschäftigt."))
        }

        activeSession = request.sessionID
        activeOwner = owner
        let perform = self.perform
        let task = Task { await perform(request, kind) }
        inFlight = task
        let result = await task.value

        let cancelled = task.isCancelled || lifetime.isClosed || terminalSessions.contains(request.sessionID)
        inFlight = nil
        if cancelled || result.error != nil || kind == .transcribe {
            rememberTerminal(request.sessionID)
            activeSession = nil
            activeOwner = nil
        }

        if cancelled {
            return encode(errorReply(sessionID: request.sessionID, message: "Das Diktat wurde verworfen."))
        }
        return encode(result)
    }

    public func cancel(sessionID: UUID?, owner: UUID) {
        guard let sessionID else { return }
        // Also reject a request that was queued on the task executor just before
        // its matching cancel message reached this actor.
        guard activeSession == nil || (activeSession == sessionID && activeOwner == owner) else { return }
        rememberTerminal(sessionID)
        if activeSession == sessionID {
            inFlight?.cancel()
            if inFlight == nil {
                activeSession = nil
                activeOwner = nil
            }
        }
    }

    public func connectionClosed(_ owner: UUID) {
        guard activeOwner == owner, let activeSession else { return }
        cancel(sessionID: activeSession, owner: owner)
    }

    private func rememberTerminal(_ sessionID: UUID) {
        guard terminalSessions.insert(sessionID).inserted else { return }
        terminalOrder.append(sessionID)
        if terminalOrder.count > 128 {
            terminalSessions.remove(terminalOrder.removeFirst())
        }
    }

    private func errorReply(sessionID: UUID, message: String) -> WorkerReply {
        WorkerReply(sessionID: sessionID, text: nil, error: message, loadSeconds: 0, inferenceSeconds: 0)
    }

    private func encode(_ reply: WorkerReply) -> Data {
        (try? JSONEncoder().encode(reply)) ?? Data()
    }
}

/// Closed synchronously by XPC callbacks before actor cleanup is queued.
/// Outstanding calls retain this token; no registry of dead connections needed.
public final class WorkerConnectionLifetime: @unchecked Sendable {
    private let lock = NSLock()
    private var closed = false
    public init() {}
    public var isClosed: Bool { lock.withLock { closed } }
    public func close() { lock.withLock { closed = true } }
}
