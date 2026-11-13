import Foundation
import TypingRTCore

/// Presentation only: never owns or changes the recording session.
struct OverlayPresentation {
    enum Style: Equatable { case dot, modes, recording, processing, notice }

    let phase: DictationController.Phase
    let mode: DictationMode
    let message: String?
    var isHovered = false
    /// A transient hint held by the overlay for a few seconds. It outlives
    /// the controller message, which is cleared as soon as the key is released.
    var notice: String?
    var isReady = true

    var style: Style {
        switch phase {
        case .preparing, .recording: .recording
        // E.g. "busy" after another press while a dictation is processed.
        case .finishing, .transcribing, .formatting, .inserting, .cancelling: notice == nil ? .processing : .notice
        // A pending decision blocks the next dictation and therefore stays visible.
        case .awaitingResult: .notice
        case .idle:
            if notice != nil { .notice } else { isHovered ? .modes : .dot }
        }
    }

    var showsMeter: Bool { phase == .recording }
    var isProcessing: Bool { style == .processing && phase != .cancelling }
    /// Only the dot and the mode switch take the pointer; everything else
    /// lets clicks pass through to the app underneath.
    var acceptsPointer: Bool { style == .dot || style == .modes }

    var noticeText: String? {
        switch phase {
        case .awaitingResult: notice ?? message ?? "Ergebnis bereit – in typingRT kopieren oder verwerfen."
        case .preparing, .recording: nil
        default: notice
        }
    }

    /// Spoken description; the visual stays free of permanent text.
    var title: String {
        switch phase {
        case .idle: isReady ? "Bereit. Rechte Option gedrückt halten." : "Einrichtung erforderlich"
        case .preparing: "Mikrofon wird vorbereitet"
        case .recording: "Aufnahme läuft"
        case .finishing: "Aufnahme wird abgeschlossen"
        case .transcribing: "Wird lokal transkribiert"
        case .formatting: "Wird übersetzt"
        case .inserting: "Text wird eingefügt"
        case .awaitingResult: "Entscheidung erforderlich"
        case .cancelling: "Diktat wird verworfen"
        }
    }

    var panelSize: CGSize {
        switch style {
        case .dot, .processing: CGSize(width: 30, height: 30)
        case .modes: CGSize(width: 236, height: 34)
        case .recording: CGSize(width: 76, height: 30)
        case .notice: CGSize(width: 380, height: 46)
        }
    }

    /// Maps a linear sample peak (0…1) to a visible meter value (0…1).
    /// Speech peaks are usually only 0.03–0.3; shown linearly they barely move
    /// a bar. On a decibel scale −48 dB is silence and −6 dB is full height.
    static func meterLevel(_ peak: Float) -> Double {
        guard peak.isFinite, peak > 0 else { return 0 }
        let decibels = 20 * log10(Double(min(peak, 1)))
        return min(1, max(0, (decibels + 48) / 42))
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let safe = seconds.isFinite ? max(0, min(seconds, Double(Int.max / 2))) : 0
        let value = Int(safe)
        return String(format: "%02d:%02d", value / 60, value % 60)
    }

    /// Supports negative origins and small visible frames without leaving the panel off-screen.
    static func frame(size: CGSize, visibleFrame: CGRect) -> CGRect {
        let width = min(max(0, size.width), max(0, visibleFrame.width))
        let height = min(max(0, size.height), max(0, visibleFrame.height))
        return CGRect(x: visibleFrame.midX - width / 2,
                      y: min(visibleFrame.minY + 8, visibleFrame.maxY - height),
                      width: width, height: height)
    }
}
