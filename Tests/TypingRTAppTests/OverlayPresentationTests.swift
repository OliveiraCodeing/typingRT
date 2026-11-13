import Foundation
import Testing
@testable import TypingRTApp
import TypingRTCore

@Suite @MainActor
struct OverlayPresentationTests {
    private static let phases: [DictationController.Phase] = [
        .idle, .preparing, .recording, .finishing, .transcribing, .formatting, .inserting, .awaitingResult, .cancelling]

    private func state(_ phase: DictationController.Phase, mode: DictationMode = .standard, message: String? = nil,
                       hovered: Bool = false, notice: String? = nil) -> OverlayPresentation {
        OverlayPresentation(phase: phase, mode: mode, message: message, isHovered: hovered, notice: notice)
    }

    @Test func idleIsOnlyADotAndAFinishedDictationLeavesNoText() {
        let idle = state(.idle)
        // A routine confirmation is never promoted to a notice by the overlay.
        let afterInsertion = state(.idle, message: "Text eingefügt.")
        for value in [idle, afterInsertion] {
            #expect(value.style == .dot)
            #expect(value.noticeText == nil)
            #expect(value.panelSize.width <= 30 && value.panelSize.height <= 30)
        }
    }

    @Test func hoverOffersModesOnlyWhileIdle() {
        #expect(state(.idle, hovered: true).style == .modes)
        for phase in Self.phases where phase != .idle {
            #expect(state(phase, hovered: true).style != .modes)
        }
    }

    @Test func meterAndProcessingIndicatorsHaveDisjointLifetimes() {
        for phase in Self.phases {
            let value = state(phase)
            #expect(value.showsMeter == (phase == .recording))
            #expect(!(value.showsMeter && value.isProcessing))
        }
        for phase: DictationController.Phase in [.preparing, .recording] { #expect(state(phase).style == .recording) }
        for phase: DictationController.Phase in [.finishing, .transcribing, .formatting, .inserting] {
            #expect(state(phase).style == .processing && state(phase).isProcessing)
        }
        #expect(!state(.cancelling).isProcessing)
    }

    @Test func hintsAreTransientButAPendingDecisionStaysVisible() {
        // The hint survives the controller clearing its message on key release.
        let shown = state(.idle, message: nil, notice: "Modell konnte nicht geladen werden.")
        let expired = state(.idle, message: "Modell konnte nicht geladen werden.")
        let pending = state(.awaitingResult, mode: .coding, message: "Requesty nicht erreichbar. In typingRT erneut versuchen.")
        #expect(shown.style == .notice && shown.noticeText?.contains("Modell") == true)
        #expect(expired.style == .dot && expired.noticeText == nil)
        #expect(pending.style == .notice && pending.noticeText?.contains("erneut versuchen") == true)
        #expect(state(.awaitingResult).noticeText != nil)
        // Another press during processing is answered visibly, then the spinner returns.
        let busy = state(.transcribing, notice: "Beschäftigt – bitte nach Abschluss erneut drücken.")
        #expect(busy.style == .notice && busy.noticeText?.contains("Beschäftigt") == true)
        #expect(state(.transcribing).style == .processing)
        #expect(state(.recording, notice: "alt").style == .recording && state(.recording, notice: "alt").noticeText == nil)
    }

    @Test func onlyDotAndModeSwitchTakeThePointer() {
        #expect(state(.idle).acceptsPointer && state(.idle, hovered: true).acceptsPointer)
        #expect(!state(.awaitingResult).acceptsPointer && !state(.recording).acceptsPointer)
        #expect(!state(.idle, notice: "Hinweis").acceptsPointer && !state(.inserting).acceptsPointer)
    }

    @Test func everyStateStaysCompact() {
        for phase in Self.phases {
            for hovered in [false, true] {
                let size = state(phase, message: "Hinweis", hovered: hovered, notice: "Hinweis").panelSize
                #expect(size.height <= 46 && size.width <= 380)
            }
        }
        #expect(state(.recording).panelSize.width <= 80)
    }

    @Test func displayGeometryFitsNegativeOriginsAndSmallVisibleAreas() {
        for size in [state(.recording).panelSize, state(.awaitingResult).panelSize] {
            for visible in [CGRect(x: -1600, y: -900, width: 1440, height: 870),
                            CGRect(x: 0, y: 0, width: 300, height: 40),
                            CGRect(x: 800, y: 400, width: 1200, height: 700)] {
                let result = OverlayPresentation.frame(size: size, visibleFrame: visible)
                #expect(result.minX >= visible.minX && result.maxX <= visible.maxX)
                #expect(result.minY >= visible.minY && result.maxY <= visible.maxY)
                #expect(result.midX == visible.midX)
            }
        }
    }

    @Test func meterMakesNormalSpeechClearlyVisibleAndSilenceFlat() {
        #expect(OverlayPresentation.meterLevel(0) == 0)
        #expect(OverlayPresentation.meterLevel(0.002) == 0)          // room noise
        #expect(OverlayPresentation.meterLevel(0.05) > 0.45)         // quiet speech
        #expect(OverlayPresentation.meterLevel(0.2) > 0.75)          // normal speech
        #expect(OverlayPresentation.meterLevel(1) == 1 && OverlayPresentation.meterLevel(7) == 1)
        #expect(OverlayPresentation.meterLevel(0.05) < OverlayPresentation.meterLevel(0.2))
        for value in [Float.nan, -.infinity, .infinity, -1] { #expect(OverlayPresentation.meterLevel(value) == 0) }
    }

    @Test func durationHandlesLongRecordingsAndInvalidValuesWithoutOverflow() {
        #expect(OverlayPresentation.duration(3723.9) == "62:03")
        for value in [Double.infinity, Double.nan, -1] {
            #expect(OverlayPresentation.duration(value) == "00:00")
        }
        #expect(!OverlayPresentation.duration(Double.greatestFiniteMagnitude).isEmpty)
    }
}
