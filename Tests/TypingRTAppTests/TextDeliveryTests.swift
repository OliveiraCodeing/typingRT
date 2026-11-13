import Foundation
import Testing
@testable import TypingRTCore
@testable import TypingRTApp

@Suite(.timeLimit(.minutes(1))) @MainActor
struct TextDeliveryTests {
    @Test func duplicateResultsAndFocusChangesNeverRetryAnUncertainHandoff() async throws {
        let client = HeldInsertion()
        let delivery = TextDelivery(client: client)
        let sessions = SessionCoordinator()
        sessions.seedKeyState(isPressed: false)
        let ready = Readiness(microphoneGranted: true, accessibilityGranted: true, hotkeyAvailable: true, modelInstalled: true)
        let id = try #require(sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard))
        _ = sessions.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)
        delivery.start(sessionID: id)
        let transcript = makeTranscript(id)
        let pending = DeliveryProbe()
        delivery.onStateChanged = { _, phase in if phase == .awaitingResult { pending.signal() } }
        delivery.onFinished = { id, _ in if sessions.mayDeliver(sessionID: id) { sessions.invalidate() } }
        delivery.submit(transcript)
        delivery.submit(transcript)
        await client.waitForInsertions(1)
        await client.releaseInsertion(0, outcome: .uncertain)
        await pending.wait()
        #expect(delivery.outcome == .uncertain)
        #expect(delivery.result == transcript)
        // A new press is busy even after recognition. An unchanged answer/focus
        // cannot claim another attempt, and finishing while held cannot record.
        #expect(sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) == nil)
        delivery.submit(transcript)
        #expect(await client.insertionCount == 1)
        delivery.discard(sessionID: id)
        #expect(delivery.result == nil)
        #expect(sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) == nil)
        _ = sessions.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)
        #expect(sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) != nil)
    }

    @Test func escapeDuringPreflightPreventsMutationAndLateReplyCannotTouchNextSession() async {
        let client = HeldInsertion()
        let delivery = TextDelivery(client: client)
        let old = UUID(), next = UUID()
        var finished: [UUID] = []
        delivery.onFinished = { id, _ in finished.append(id) }
        delivery.start(sessionID: old)
        delivery.submit(makeTranscript(old))
        await client.waitForInsertions(1)
        delivery.cancel(sessionID: old)
        delivery.start(sessionID: next)
        delivery.submit(makeTranscript(next))
        await client.waitForInsertions(2)
        let pending = DeliveryProbe()
        delivery.onStateChanged = { id, phase in if id == next && phase == .awaitingResult { pending.signal() } }
        await client.releaseInsertion(0, outcome: .confirmed)
        await client.releaseInsertion(1, outcome: .unavailable("Kein Textfeld."))
        await pending.wait()
        #expect(await client.mutationCount == 1)
        #expect(delivery.result?.sessionID == next)
        #expect(finished.isEmpty)
        delivery.cancel(sessionID: old)
        #expect(delivery.result?.sessionID == next)
        delivery.cancel(sessionID: next)
        #expect(delivery.result == nil)
    }

    @Test func terminalHandoffFinishesWithoutPendingResultOrConfirmedSaving() async {
        let client = HeldInsertion()
        let delivery = TextDelivery(client: client)
        let id = UUID(), done = DeliveryProbe()
        var completions = 0, confirmations = 0
        delivery.onFinished = { _, _ in completions += 1; done.signal() }
        delivery.onConfirmedInsertion = { _, _, _ in confirmations += 1 }
        delivery.start(sessionID: id)
        delivery.submit(makeTranscript(id))
        await client.waitForInsertions(1)
        await client.releaseInsertion(0, outcome: .handedOff)
        await done.wait()
        #expect(completions == 1)
        #expect(confirmations == 0)
        #expect(delivery.phase == .idle)
        #expect(delivery.result == nil)
    }

    @Test func confirmedReceiptFinishesOnceAndReleasesText() async {
        let client = HeldInsertion()
        let delivery = TextDelivery(client: client)
        let id = UUID(), done = DeliveryProbe()
        var completions = 0
        delivery.onFinished = { _, _ in completions += 1; done.signal() }
        delivery.start(sessionID: id)
        delivery.submit(makeTranscript(id))
        await client.waitForInsertions(1)
        await client.releaseInsertion(0, outcome: .confirmed)
        await done.wait()
        delivery.submit(makeTranscript(id))
        #expect(completions == 1)
        #expect(delivery.result == nil && delivery.phase == .idle)
        #expect(delivery.outcome == .confirmed)
        #expect(await client.insertionCount == 1)
    }

    @Test func unavailableTargetKeepsResultAndFailedCopyCanBeRetriedExplicitly() async {
        let client = HeldInsertion()
        let delivery = TextDelivery(client: client)
        let id = UUID(), pending = DeliveryProbe(), done = DeliveryProbe()
        var completions = 0
        delivery.onStateChanged = { _, phase in if phase == .awaitingResult { pending.signal() } }
        delivery.onFinished = { _, _ in completions += 1; done.signal() }
        delivery.start(sessionID: id)
        delivery.submit(makeTranscript(id))
        await client.waitForInsertions(1)
        await client.releaseInsertion(0, outcome: .unavailable("Kein Zugriff."))
        await pending.wait()
        delivery.copy(sessionID: id)
        await client.waitForCopies(1)
        await client.releaseCopy(0, success: false)
        await pending.wait()
        #expect(delivery.phase == .awaitingResult && delivery.result != nil)
        #expect(completions == 0)
        delivery.copy(sessionID: id)
        delivery.copy(sessionID: id) // double click is still one clipboard write
        await client.waitForCopies(2)
        await client.releaseCopy(1, success: true)
        await done.wait()
        #expect(completions == 1 && delivery.result == nil)
        #expect(delivery.outcome != .confirmed) // copying is not proof of insertion
        #expect(await client.copyCount == 2)
    }

    @Test func codingPreviewNeverAutomaticallyInsertsLocalGermanText() async {
        let client = HeldInsertion(), id = UUID()
        let delivery = TextDelivery(client: client)
        delivery.start(sessionID: id)
        delivery.submit(makeTranscript(id, mode: .coding), automatic: false)
        #expect(delivery.phase == .awaitingResult)
        #expect(await client.insertionCount == 0)
        delivery.discard(sessionID: UUID())
        #expect(delivery.result != nil)
        delivery.discard(sessionID: id)
        #expect(delivery.result == nil)
    }

    @Test func cancelledQueuedCopyDoesNotChangeClipboardOrFinishNewSession() async {
        let client = HeldInsertion(), old = UUID(), next = UUID()
        let delivery = TextDelivery(client: client)
        var completions = 0
        delivery.onFinished = { _, _ in completions += 1 }
        delivery.start(sessionID: old)
        delivery.submit(makeTranscript(old, mode: .coding), automatic: false)
        delivery.copy(sessionID: old)
        await client.waitForCopies(1)
        delivery.cancel(sessionID: old)
        delivery.start(sessionID: next)
        delivery.submit(makeTranscript(next, mode: .coding), automatic: false)
        await client.releaseCopy(0, success: true)
        // Await the old adapter's return, then give its MainActor continuation a turn.
        await Task.yield()
        #expect(await client.copyMutationCount == 0)
        #expect(completions == 0)
        #expect(delivery.result?.sessionID == next)
    }

    @Test func shutdownWaitsForCancelledAdaptersClipboardCleanup() async {
        let client = HeldInsertion(), id = UUID()
        let delivery = TextDelivery(client: client)
        delivery.start(sessionID: id)
        delivery.submit(makeTranscript(id))
        await client.waitForInsertions(1)
        delivery.cancel(sessionID: id)
        let shutdownStarted = DeliveryProbe()
        var shutdownFinished = false
        let shutdown = Task {
            shutdownStarted.signal()
            await delivery.finishShutdown()
            shutdownFinished = true
        }
        await shutdownStarted.wait()
        #expect(!shutdownFinished)
        await client.releaseInsertion(0, outcome: .uncertain)
        await shutdown.value
        #expect(shutdownFinished)
        #expect(await client.mutationCount == 0)
        #expect(delivery.result == nil)
    }

    @Test func systemInterruptionKeepsFinishedTextWithoutRetryingAfterWake() async {
        let client = HeldInsertion(), id = UUID()
        let delivery = TextDelivery(client: client)
        delivery.start(sessionID: id)
        delivery.submit(makeTranscript(id))
        await client.waitForInsertions(1)
        delivery.interrupt(sessionID: id)
        #expect(delivery.phase == .awaitingResult)
        #expect(delivery.result?.sessionID == id)
        delivery.interrupt(sessionID: id) // locking again does not discard text
        delivery.submit(makeTranscript(id)) // waking/focus never retries
        await client.releaseInsertion(0, outcome: .confirmed)
        await Task.yield()
        #expect(await client.mutationCount == 0)
        #expect(await client.insertionCount == 1)
        #expect(delivery.outcome == .uncertain)
        #expect(delivery.result?.sessionID == id)
        delivery.discard(sessionID: id)
        await delivery.finishShutdown()
    }

    private func makeTranscript(_ id: UUID, mode: DictationMode = .standard) -> LocalTranscript {
        LocalTranscript(session: DictationSnapshot(id: id, mode: mode), rawText: "Ähm, bitte prüfen.",
                        cleanedText: "Bitte prüfen.", loadSeconds: 0, inferenceSeconds: 0.1)
    }
}

private actor HeldInsertion: TextInsertionClient {
    private struct Insertion {
        let cancellation: DeliveryCancellation
        let continuation: CheckedContinuation<TextDeliveryOutcome, Never>
    }
    private struct Copy {
        let cancellation: DeliveryCancellation
        let continuation: CheckedContinuation<Bool, Never>
    }
    private var insertions: [Int: Insertion] = [:]
    private var copies: [Int: Copy] = [:]
    private(set) var insertionCount = 0
    private(set) var mutationCount = 0
    private(set) var copyCount = 0
    private(set) var copyMutationCount = 0
    private var insertionWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var copyWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func insert(_ text: String, cancellation: DeliveryCancellation) async -> TextDeliveryOutcome {
        let index = insertionCount
        insertionCount += 1
        return await withCheckedContinuation { continuation in
            insertions[index] = Insertion(cancellation: cancellation, continuation: continuation)
            let ready = insertionWaiters.filter { $0.0 <= insertionCount }
            insertionWaiters.removeAll { $0.0 <= insertionCount }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func copy(_ text: String, cancellation: DeliveryCancellation) async -> Bool {
        let index = copyCount
        copyCount += 1
        return await withCheckedContinuation { continuation in
            copies[index] = Copy(cancellation: cancellation, continuation: continuation)
            let ready = copyWaiters.filter { $0.0 <= copyCount }
            copyWaiters.removeAll { $0.0 <= copyCount }
            for (_, waiter) in ready { waiter.resume() }
        }
    }
    func waitForInsertions(_ count: Int) async {
        if insertionCount >= count { return }
        await withCheckedContinuation { insertionWaiters.append((count, $0)) }
    }
    func waitForCopies(_ count: Int) async {
        if copyCount >= count { return }
        await withCheckedContinuation { copyWaiters.append((count, $0)) }
    }
    func releaseInsertion(_ index: Int, outcome: TextDeliveryOutcome) {
        guard let insertion = insertions.removeValue(forKey: index) else { return }
        if insertion.cancellation.isCancelled { insertion.continuation.resume(returning: .cancelled) }
        else { mutationCount += 1; insertion.continuation.resume(returning: outcome) }
    }
    func releaseCopy(_ index: Int, success: Bool) {
        guard let copy = copies.removeValue(forKey: index) else { return }
        if success && !copy.cancellation.isCancelled { copyMutationCount += 1 }
        copy.continuation.resume(returning: success && !copy.cancellation.isCancelled)
    }
}

@MainActor private final class DeliveryProbe {
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
