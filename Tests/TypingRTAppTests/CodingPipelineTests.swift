import Foundation
import Testing
@testable import TypingRTCore
@testable import TypingRTApp

@MainActor struct CodingPipelineTests {
    private let model = RequestyModel(id: "example/coding", contextWindow: 100_000, maxOutputTokens: 10_000)

    private func transcript(_ id: UUID = UUID(), mode: DictationMode = .coding, text: String = "Prüfe die requestCache Implementierung.") -> LocalTranscript {
        LocalTranscript(session: DictationSnapshot(id: id, mode: mode, requestyModelID: "example/coding"),
            rawText: "Ähm, " + text, cleanedText: text, loadSeconds: 0.2, inferenceSeconds: 0.3,
            relevantCanonicalSpellings: ["requestCache"], protectedCanonicalSpellings: ["requestCache"])
    }

    @Test func successRetainsIdentityRawTextAndOnlyHandsOffOnce() async {
        let client = CodingClientDouble(), credentials = CodingCredentialsDouble()
        let subject = CodingPipeline(credentials: credentials, client: client)
        let original = transcript(), done = CodingProbe()
        var received: [(LocalTranscript, Bool)] = []
        subject.onReady = { received.append(($0, $1)); done.signal() }
        subject.start(original, model: model)
        subject.start(original, model: model)
        await client.waitForCalls(1)
        #expect(subject.phase == .formatting)
        #expect(await credentials.reads == 1)
        await client.release(0, text: "Review the requestCache implementation.")
        await done.wait()
        #expect(received.count == 1 && received[0].1)
        #expect(received[0].0.rawText == original.rawText)
        #expect(received[0].0.sessionID == original.sessionID)
        #expect(received[0].0.requestyModelID == original.requestyModelID)
        #expect(subject.original == nil && subject.phase == .idle)
        subject.start(original, model: model)
        #expect(await client.callCount == 1)
        await subject.finishShutdown()
    }

    @Test func failureAllowsOneExplicitRetryWithOriginalModelAndOneHandoff() async {
        let client = CodingClientDouble(), subject = CodingPipeline(credentials: CodingCredentialsDouble(), client: client)
        let original = transcript(), pending = CodingProbe(), done = CodingProbe()
        var delivered = 0
        subject.onStateChanged = { _, phase in if phase == .awaitingDecision { pending.signal() } }
        subject.onReady = { _, automatic in #expect(automatic); delivered += 1; done.signal() }
        subject.start(original, model: model)
        await client.waitForCalls(1)
        subject.retry(sessionID: original.sessionID) // no parallel request while busy
        await client.fail(0, error: .network)
        await pending.wait()
        #expect(subject.original == original && subject.message != nil)
        #expect(await client.callCount == 1)
        subject.retry(sessionID: UUID())
        subject.retry(sessionID: original.sessionID)
        subject.retry(sessionID: original.sessionID) // double click cannot bill twice
        await client.waitForCalls(2)
        #expect(await client.modelIDs == ["example/coding", "example/coding"])
        await client.release(1, text: "Review the requestCache implementation.")
        await done.wait()
        #expect(delivered == 1 && subject.original == nil)
        await subject.finishShutdown()
    }

    @Test func explicitOriginalTakeoverIsManualAndNeverChangesMode() async {
        let client = CodingClientDouble(), subject = CodingPipeline(credentials: CodingCredentialsDouble(), client: client)
        let original = transcript(), pending = CodingProbe()
        var received: [(LocalTranscript, Bool)] = []
        subject.onStateChanged = { _, phase in if phase == .awaitingDecision { pending.signal() } }
        subject.onReady = { received.append(($0, $1)) }
        subject.start(original, model: model)
        await client.waitForCalls(1)
        subject.takeOriginal(sessionID: original.sessionID) // must not race active request
        #expect(received.isEmpty)
        await client.fail(0, error: .timeout)
        await pending.wait()
        subject.takeOriginal(sessionID: original.sessionID)
        subject.takeOriginal(sessionID: original.sessionID)
        #expect(received.count == 1 && !received[0].1)
        #expect(received[0].0 == original && received[0].0.mode == .coding)
        #expect(subject.original == nil && subject.phase == .idle)
        await subject.finishShutdown()
    }

    @Test func cancellationAndLateResponseCannotAffectNextSession() async {
        let client = CodingClientDouble(), subject = CodingPipeline(credentials: CodingCredentialsDouble(), client: client)
        let old = transcript(), next = transcript(), done = CodingProbe()
        var received: [UUID] = []
        subject.onReady = { value, _ in received.append(value.sessionID); done.signal() }
        subject.start(old, model: model)
        await client.waitForCalls(1)
        subject.cancel(sessionID: old.sessionID)
        subject.start(next, model: model)
        await client.waitForCalls(2)
        subject.cancel(sessionID: old.sessionID)
        #expect(subject.original?.sessionID == next.sessionID)
        await client.release(0, text: "Review the requestCache implementation.")
        await client.release(1, text: "Review the requestCache implementation.")
        await done.wait()
        #expect(received == [next.sessionID])
        await subject.finishShutdown()
        #expect(received == [next.sessionID])
    }

    @Test func wrongReplyUUIDIsRejectedAndOriginalRemainsAvailable() async {
        let client = CodingClientDouble(), subject = CodingPipeline(credentials: CodingCredentialsDouble(), client: client)
        let original = transcript(), pending = CodingProbe()
        var delivered = false
        subject.onStateChanged = { _, phase in if phase == .awaitingDecision { pending.signal() } }
        subject.onReady = { _, _ in delivered = true }
        subject.start(original, model: model)
        await client.waitForCalls(1)
        await client.release(0, text: "Review the requestCache implementation.", sessionID: UUID())
        await pending.wait()
        #expect(!delivered && subject.original == original)
        subject.cancel(sessionID: original.sessionID)
        await subject.finishShutdown()
    }

    @Test func changedProtectedNameCannotBeDelivered() async {
        let client = CodingClientDouble(), subject = CodingPipeline(credentials: CodingCredentialsDouble(), client: client)
        let original = transcript(), pending = CodingProbe()
        var delivered = false
        subject.onStateChanged = { _, phase in if phase == .awaitingDecision { pending.signal() } }
        subject.onReady = { _, _ in delivered = true }
        subject.start(original, model: model)
        await client.waitForCalls(1)
        await client.release(0, text: "Review the cache implementation.")
        await pending.wait()
        #expect(!delivered && subject.original == original && subject.message != nil)
        #expect(subject.rejectedText == "Review the cache implementation.")
        subject.cancel(sessionID: original.sessionID)
        #expect(subject.rejectedText == nil)
        await subject.finishShutdown()
    }

    @Test func emptyAndStandardTranscriptsNeverReadCredentialsOrRequestNetwork() async {
        let client = CodingClientDouble(), credentials = CodingCredentialsDouble()
        let subject = CodingPipeline(credentials: credentials, client: client)
        subject.start(transcript(mode: .standard), model: model)
        subject.start(transcript(text: " \n\t"), model: model)
        #expect(subject.original == nil && subject.phase == .idle)
        #expect(await client.callCount == 0)
        #expect(await credentials.reads == 0)
        await subject.finishShutdown()
    }

    @Test func missingKeyAndUnknownLimitsFailWithoutNetworkAndKeepOriginal() async {
        let client = CodingClientDouble(), subject = CodingPipeline(credentials: CodingCredentialsDouble(key: nil), client: client)
        let original = transcript(), pending = CodingProbe()
        subject.onStateChanged = { _, phase in if phase == .awaitingDecision { pending.signal() } }
        subject.start(original, model: model)
        await pending.wait()
        #expect(subject.original == original && subject.message != nil)
        #expect(await client.callCount == 0)
        subject.cancel(sessionID: original.sessionID)
        let unknown = transcript()
        subject.start(unknown, model: nil)
        await pending.wait()
        #expect(subject.original == unknown && subject.message != nil)
        #expect(await client.callCount == 0)
        await subject.finishShutdown()
    }

    @Test func interruptPreservesOriginalAndLateAnswerCannotRaceExplicitRetry() async {
        let client = CodingClientDouble(), subject = CodingPipeline(credentials: CodingCredentialsDouble(), client: client)
        let original = transcript(), done = CodingProbe()
        var delivered = 0
        subject.onReady = { _, _ in delivered += 1; done.signal() }
        subject.start(original, model: model)
        await client.waitForCalls(1)
        subject.interrupt(sessionID: original.sessionID)
        #expect(subject.phase == .awaitingDecision && subject.original == original)
        subject.retry(sessionID: original.sessionID)
        await client.waitForCalls(2)
        await client.release(0, text: "Review the requestCache implementation.")
        await client.release(1, text: "Review the requestCache implementation.")
        await done.wait()
        await subject.finishShutdown()
        #expect(delivered == 1)
    }

    @Test func shutdownWaitsForRetiredUncooperativeRequestAndSuppressesHandoff() async {
        let client = CodingClientDouble(), subject = CodingPipeline(credentials: CodingCredentialsDouble(), client: client)
        let original = transcript(), started = CodingProbe()
        var delivered = false, finished = false
        subject.onReady = { _, _ in delivered = true }
        subject.start(original, model: model)
        await client.waitForCalls(1)
        let shutdown = Task { started.signal(); await subject.finishShutdown(); finished = true }
        await started.wait()
        #expect(!finished && subject.original == nil)
        await client.release(0, text: "Review the requestCache implementation.")
        await shutdown.value
        #expect(finished && !delivered)
        subject.start(transcript(), model: model)
        #expect(await client.callCount == 1)
    }
}

private actor CodingCredentialsDouble: RequestyCredentialStoring {
    let key: String?
    private(set) var reads = 0
    init(key: String? = "synthetic-test-only") { self.key = key }
    func read() -> String? { reads += 1; return key }
    func save(_ value: String) {}
    func delete() {}
}

private actor CodingClientDouble: RequestyServing {
    private struct Pending { let sessionID: UUID; let continuation: CheckedContinuation<RequestyCompletion, Error> }
    private var pending: [Int: Pending] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private(set) var callCount = 0
    private(set) var modelIDs: [String] = []
    func models(apiKey: String) throws -> [RequestyModel] { throw RequestyError.invalidConfiguration }
    func complete(sessionID: UUID, modelID: String, system: String, text: String, maxOutputTokens: Int, apiKey: String) async throws -> RequestyCompletion {
        let index = callCount
        callCount += 1
        modelIDs.append(modelID)
        return try await withCheckedThrowingContinuation { continuation in
            pending[index] = Pending(sessionID: sessionID, continuation: continuation)
            let ready = waiters.filter { $0.0 <= callCount }
            waiters.removeAll { $0.0 <= callCount }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitForCalls(_ count: Int) async {
        if callCount >= count { return }
        await withCheckedContinuation { waiters.append((count, $0)) }
    }
    func release(_ index: Int, text: String, sessionID: UUID? = nil) {
        guard let value = pending.removeValue(forKey: index) else { return }
        value.continuation.resume(returning: RequestyCompletion(sessionID: sessionID ?? value.sessionID, text: text))
    }
    func fail(_ index: Int, error: RequestyError) {
        pending.removeValue(forKey: index)?.continuation.resume(throwing: error)
    }
}

@MainActor private final class CodingProbe {
    private var signals = 0
    private var waiter: CheckedContinuation<Void, Never>?
    func signal() {
        if let waiter { self.waiter = nil; waiter.resume() }
        else { signals += 1 }
    }
    func wait() async {
        if signals > 0 { signals -= 1; return }
        await withCheckedContinuation { waiter = $0 }
    }
}
