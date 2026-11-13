import Foundation
import Testing
@testable import TypingRTCore

struct ReadinessTests {
    @Test(arguments: 0..<16)
    func everyReadinessConditionIsRequired(mask: Int) {
        let readiness = Readiness(
            microphoneGranted: mask & 1 != 0,
            accessibilityGranted: mask & 2 != 0,
            hotkeyAvailable: mask & 4 != 0,
            modelInstalled: mask & 8 != 0
        )

        #expect(readiness.canStart == (mask == 15))
    }
}

@MainActor
struct SessionCoordinatorTests {
    private var ready: Readiness {
        Readiness(
            microphoneGranted: true,
            accessibilityGranted: true,
            hotkeyAvailable: true,
            modelInstalled: true
        )
    }

    private var missingMicrophone: Readiness {
        Readiness(
            microphoneGranted: false,
            accessibilityGranted: true,
            hotkeyAvailable: true,
            modelInstalled: true
        )
    }

    @Test
    func startupWithoutKnownReleaseDoesNotAcceptAHeldKey() {
        let coordinator = SessionCoordinator()

        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) == nil)
        #expect(coordinator.activeSession == nil)
        #expect(coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard) == nil)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) != nil)
    }

    @Test
    func anInitiallyHeldSeedRequiresReleaseAndANewPress() {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: true)

        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) == nil)
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) != nil)
    }

    @Test
    func modeIsAnImmutableSessionSnapshot() throws {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)
        var selectedMode = DictationMode.standard
        let firstID = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: selectedMode))
        selectedMode = .coding

        #expect(coordinator.activeSession == DictationSnapshot(id: firstID, mode: .standard))
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: selectedMode) == nil)
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: selectedMode)
        #expect(coordinator.activeSession?.mode == .standard)

        coordinator.invalidate()
        let nextID = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: selectedMode))
        #expect(nextID != firstID)
        #expect(coordinator.activeSession?.mode == .coding)
    }

    @Test
    func grantingReadinessDuringAHoldDoesNotStartLate() {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)

        #expect(coordinator.handleRightOption(isPressed: true, readiness: missingMicrophone, selectedMode: .standard) == nil)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) == nil)
        #expect(coordinator.activeSession == nil)

        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) != nil)
    }

    @Test
    func invalidatingWhileHeldDoesNotRearmTheSameHold() throws {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)
        let oldID = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard))

        coordinator.invalidate()

        #expect(coordinator.activeSession == nil)
        #expect(!coordinator.mayDeliver(sessionID: oldID))
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding) == nil)

        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .coding)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding) != nil)
    }

    @Test
    func deliveryIsForbiddenUntilReleaseAndForUnrelatedIDs() throws {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)
        let sessionID = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard))

        coordinator.markProcessing()
        #expect(!coordinator.mayDeliver(sessionID: sessionID))
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)
        #expect(coordinator.mayDeliver(sessionID: sessionID))
        #expect(!coordinator.mayDeliver(sessionID: UUID()))
    }

    @Test
    func processingKeepsTheSessionBusyWithoutQueuingAnotherHold() throws {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)
        let sessionID = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard))
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)

        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding) == nil)
        #expect(coordinator.activeSession?.id == sessionID)
        #expect(coordinator.mayDeliver(sessionID: sessionID))

        coordinator.invalidate()
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding) == nil)
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .coding)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding) != nil)
    }

    @Test
    func lateResultForInvalidatedSessionCannotDeliverIntoANewSession() throws {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)
        let oldID = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard))
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)
        coordinator.invalidate()
        let newID = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding))
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .coding)

        #expect(!coordinator.mayDeliver(sessionID: oldID))
        #expect(coordinator.mayDeliver(sessionID: newID))
    }

    @Test
    func shutdownPermanentlyRejectsStartsAndLateResults() throws {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)
        let sessionID = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard))
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)
        #expect(coordinator.mayDeliver(sessionID: sessionID))

        coordinator.shutDown()

        #expect(coordinator.activeSession == nil)
        #expect(!coordinator.mayDeliver(sessionID: sessionID))
        coordinator.seedKeyState(isPressed: false)
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .coding)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding) == nil)
        coordinator.invalidate()
        coordinator.markProcessing()
        #expect(!coordinator.mayDeliver(sessionID: sessionID))
    }

    @Test
    func monitorRecoveryAcceptsANewPressAfterALostRelease() throws {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)
        _ = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard))
        coordinator.invalidate()
        // Physical release happened while no monitor was installed.
        coordinator.resynchronizeKeyState(isPressed: false)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding) != nil)
    }

    @Test
    func monitorRecoveryWithHeldKeyStillRequiresRelease() {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)
        coordinator.resynchronizeKeyState(isPressed: true)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) == nil)
        _ = coordinator.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) != nil)
    }

    @Test
    func resynchronizationCannotRearmABusyOrShutdownSession() throws {
        let coordinator = SessionCoordinator()
        coordinator.seedKeyState(isPressed: false)
        let id = try #require(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard))
        coordinator.resynchronizeKeyState(isPressed: false)
        #expect(coordinator.activeSession?.id == id)
        coordinator.invalidate()
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding) == nil)
        coordinator.shutDown()
        coordinator.resynchronizeKeyState(isPressed: false)
        #expect(coordinator.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding) == nil)
    }
}
