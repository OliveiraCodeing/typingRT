import Testing
@testable import TypingRTCore

@Suite struct CaptureHealthTests {
    @Test func heldRecordingSurvivesNegativeKeyPollWhileTapIsHealthy() {
        #expect(CaptureHealth.evaluate(accessibilityTrusted: true, tapEnabled: true,
                                       tapWasReenabled: false, keyReportedDown: false) == .healthy)
    }

    @Test func reenabledTapContinuesOnlyWhileKeyIsStillReportedDown() {
        #expect(CaptureHealth.evaluate(accessibilityTrusted: true, tapEnabled: true,
                                       tapWasReenabled: true, keyReportedDown: true) == .healthy)
        #expect(CaptureHealth.evaluate(accessibilityTrusted: true, tapEnabled: true,
                                       tapWasReenabled: true, keyReportedDown: false) == .releaseMissed)
    }

    @Test func lostReleaseEndsCaptureOnlyAfterRepeatedNegativesFromAProvenPoll() {
        func health(confirmed: Bool, negatives: Int) -> CaptureHealth {
            CaptureHealth.evaluate(accessibilityTrusted: true, tapEnabled: true, tapWasReenabled: false,
                                   keyReportedDown: false, pollConfirmedDownThisHold: confirmed,
                                   consecutiveNegativePolls: negatives)
        }
        #expect(health(confirmed: true, negatives: CaptureHealth.negativePollLimit - 1) == .healthy)
        #expect(health(confirmed: true, negatives: CaptureHealth.negativePollLimit) == .releaseMissed)
        // A poll that never saw the held key is unusable on this system.
        #expect(health(confirmed: false, negatives: 100) == .healthy)
    }

    @Test(arguments: [true, false], [true, false])
    func lostPermissionOrTapAlwaysEndsCapture(reenabled: Bool, keyDown: Bool) {
        #expect(CaptureHealth.evaluate(accessibilityTrusted: false, tapEnabled: true,
                                       tapWasReenabled: reenabled, keyReportedDown: keyDown) == .permissionLost)
        #expect(CaptureHealth.evaluate(accessibilityTrusted: true, tapEnabled: false,
                                       tapWasReenabled: false, keyReportedDown: keyDown) == .tapUnavailable)
    }
}
