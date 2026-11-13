import Foundation
import TypingRTCore

final class WorkerListenerDelegate: NSObject, NSXPCListenerDelegate {
    // All connections share one inference slot and one local-model cache.
    private let coordinator: WorkerCoordinator

    override init() {
        let engine = WhisperEngine()
        coordinator = WorkerCoordinator { request, kind in
            await engine.perform(request, kind: kind)
        }
        super.init()
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let connectionID = UUID()
        let lifetime = WorkerConnectionLifetime()
        let coordinator = self.coordinator
        connection.exportedInterface = WorkerWire.interface()
        connection.exportedObject = WorkerService(coordinator: coordinator, connectionID: connectionID, lifetime: lifetime)
        connection.invalidationHandler = {
            lifetime.close()
            Task { await coordinator.connectionClosed(connectionID) }
        }
        connection.interruptionHandler = {
            lifetime.close()
            Task { await coordinator.connectionClosed(connectionID) }
        }
        connection.resume()
        return true
    }
}

final class WorkerService: NSObject, TranscriptionWorkerProtocol {
    private let coordinator: WorkerCoordinator
    private let connectionID: UUID
    private let lifetime: WorkerConnectionLifetime

    init(coordinator: WorkerCoordinator, connectionID: UUID, lifetime: WorkerConnectionLifetime) {
        self.coordinator = coordinator
        self.connectionID = connectionID
        self.lifetime = lifetime
    }

    func inspect(withReply reply: @escaping (Data) -> Void) {
        let capabilities = WorkerCapabilities(backendAvailable: true, version: "1.1.1")
        reply((try? JSONEncoder().encode(capabilities)) ?? Data())
    }

    func prepare(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let coordinator = self.coordinator
        let connectionID = self.connectionID
        let reply = DataReply(reply)
        let lifetime = self.lifetime
        Task {
            reply.send(await coordinator.run(request, owner: connectionID, lifetime: lifetime, kind: .prepare))
        }
    }

    func transcribe(_ request: Data, withReply reply: @escaping (Data) -> Void) {
        let coordinator = self.coordinator
        let connectionID = self.connectionID
        let reply = DataReply(reply)
        let lifetime = self.lifetime
        Task {
            reply.send(await coordinator.run(request, owner: connectionID, lifetime: lifetime, kind: .transcribe))
        }
    }

    func cancel(_ sessionID: String, withReply reply: @escaping () -> Void) {
        let coordinator = self.coordinator
        let connectionID = self.connectionID
        let reply = VoidReply(reply)
        Task {
            await coordinator.cancel(sessionID: UUID(uuidString: sessionID), owner: connectionID)
            reply.send()
        }
    }
}

// NSXPC completion blocks may be invoked from the worker's task executor. These
// boxes bridge the legacy ObjC block signature without marking the service or
// any mutable inference object as unchecked Sendable. Each is invoked once.
private final class DataReply: @unchecked Sendable {
    private let body: (Data) -> Void
    init(_ body: @escaping (Data) -> Void) { self.body = body }
    func send(_ data: Data) { body(data) }
}

private final class VoidReply: @unchecked Sendable {
    private let body: () -> Void
    init(_ body: @escaping () -> Void) { self.body = body }
    func send() { body() }
}
