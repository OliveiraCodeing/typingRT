import Foundation
import Testing
@testable import TypingRTCore

@Suite(.timeLimit(.minutes(1)))
struct WorkerCoordinatorTests {
    @Test func closedConnectionCannotStartAQueuedRequest() async throws {
        let engine = ControlledRecognition()
        let worker = WorkerCoordinator { request, _ in await engine.perform(request) }
        let lifetime = WorkerConnectionLifetime()
        lifetime.close()
        let reply = try await run(worker, UUID(), UUID(), lifetime, .prepare)
        #expect(reply.error != nil)
        #expect(await engine.calls == 0)
    }

    @Test func preparedSessionReservesSlotAndFinalResultCannotReplay() async throws {
        let engine = ControlledRecognition()
        let worker = WorkerCoordinator { request, _ in await engine.perform(request) }
        let session = UUID(), owner = UUID(), lifetime = WorkerConnectionLifetime()
        #expect(try await run(worker, session, owner, lifetime, .prepare).error == nil)
        #expect(try await run(worker, UUID(), UUID(), WorkerConnectionLifetime(), .transcribe).error != nil)
        #expect(try await run(worker, session, UUID(), WorkerConnectionLifetime(), .transcribe).error != nil)
        #expect(try await run(worker, session, owner, lifetime, .transcribe).error == nil)
        #expect(try await run(worker, session, owner, lifetime, .transcribe).error != nil)
        #expect(await engine.calls == 2)
    }

    @Test func cancellationDoesNotReleaseExecutingInferenceSlotEarly() async throws {
        let engine = ControlledRecognition(hold: true)
        let worker = WorkerCoordinator { request, _ in await engine.perform(request) }
        let session = UUID(), owner = UUID(), lifetime = WorkerConnectionLifetime()
        let first = Task { try await run(worker, session, owner, lifetime, .transcribe) }
        await engine.waitForCall()
        await worker.cancel(sessionID: session, owner: owner)
        #expect(try await run(worker, UUID(), UUID(), WorkerConnectionLifetime(), .transcribe).error != nil)
        await engine.release()
        let cancelled = try await first.value
        #expect(cancelled.error != nil)
        #expect(cancelled.text == nil)
        #expect(try await run(worker, UUID(), UUID(), WorkerConnectionLifetime(), .transcribe).error == nil)
    }

    @Test func disconnectedOwnersLateResultIsDiscarded() async throws {
        let engine = ControlledRecognition(hold: true)
        let worker = WorkerCoordinator { request, _ in await engine.perform(request) }
        let session = UUID(), owner = UUID(), lifetime = WorkerConnectionLifetime()
        let first = Task { try await run(worker, session, owner, lifetime, .transcribe) }
        await engine.waitForCall()
        lifetime.close()
        await worker.connectionClosed(owner)
        await engine.release()
        let reply = try await first.value
        #expect(reply.error != nil)
        #expect(reply.text == nil)
    }

    @Test func cancellationBeforeQueuedRequestPreventsInference() async throws {
        let engine = ControlledRecognition()
        let worker = WorkerCoordinator { request, _ in await engine.perform(request) }
        let session = UUID(), owner = UUID()
        await worker.cancel(sessionID: session, owner: owner)
        #expect(try await run(worker, session, owner, WorkerConnectionLifetime(), .prepare).error != nil)
        #expect(await engine.calls == 0)
    }

    private func run(_ worker: WorkerCoordinator, _ session: UUID, _ owner: UUID,
                     _ lifetime: WorkerConnectionLifetime, _ kind: WorkerOperation) async throws -> WorkerReply {
        let request = WorkerRequest(sessionID: session, audioPath: "/synthetic.wav", modelPath: "/synthetic", tokenizerPath: "/synthetic")
        let data = try JSONEncoder().encode(request)
        return try JSONDecoder().decode(WorkerReply.self, from: await worker.run(data, owner: owner, lifetime: lifetime, kind: kind))
    }
}

/// Deliberately ignores cancellation until released, like a suspended Core ML
/// operation. This is a concurrency test double, not speech recognition.
private actor ControlledRecognition {
    private var hold: Bool
    private var suspended: CheckedContinuation<Void, Never>?
    private var waiting: CheckedContinuation<Void, Never>?
    private(set) var calls = 0
    init(hold: Bool = false) { self.hold = hold }
    func perform(_ request: WorkerRequest) async -> WorkerReply {
        calls += 1
        waiting?.resume(); waiting = nil
        if hold { await withCheckedContinuation { suspended = $0 } }
        return WorkerReply(sessionID: request.sessionID, text: "synthetic result", error: nil, loadSeconds: 0, inferenceSeconds: 0)
    }
    func waitForCall() async {
        if calls == 0 { await withCheckedContinuation { waiting = $0 } }
    }
    func release() { hold = false; suspended?.resume(); suspended = nil }
}
