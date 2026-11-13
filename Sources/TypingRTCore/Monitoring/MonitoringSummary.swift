import Foundation

/// All persisted monitoring values are content-free measurements.
public struct MonitoringSummary: Sendable, Equatable {
    public let periodID: UUID
    public let spokenWords: Int
    public let latencySampleCount: Int
    public let medianLatencySeconds: Double?
    /// Negative individual estimates remain part of the total.
    public let savedMinutes: Double
    public var savedHours: Double { max(0, savedMinutes / 60) }

    public init(periodID: UUID, spokenWords: Int = 0, latencySampleCount: Int = 0,
                medianLatencySeconds: Double? = nil, savedMinutes: Double = 0) {
        self.periodID = periodID
        self.spokenWords = spokenWords
        self.latencySampleCount = latencySampleCount
        self.medianLatencySeconds = medianLatencySeconds
        self.savedMinutes = savedMinutes
    }
}

public enum MonitoringError: Error, LocalizedError, Sendable, Equatable {
    case invalidMeasurement, storageFailure, unsupportedSchema, invalidStoredData

    public var errorDescription: String? {
        switch self {
        case .invalidMeasurement: "Die Statistikmessung ist ungültig."
        case .storageFailure: "Die Statistik konnte nicht gespeichert oder geladen werden. Das Diktat wird nicht wiederholt."
        case .unsupportedSchema: "Die Statistik stammt aus einer neueren App-Version."
        case .invalidStoredData: "Die gespeicherte Statistik ist ungültig."
        }
    }
}

/// Deterministic estimate shared by ASR and output counting. A word is a maximal
/// sequence of Unicode letters/numbers/combining marks. Apostrophes and hyphens
/// inside such sequences belong to the same word; all other punctuation splits.
/// This is an estimate of recognized words, not a language-specific tokenizer.
public enum WordSegmentation {
    public static func count(_ text: String) -> Int {
        var total = 0
        var inside = false
        var pendingJoiner = false
        for scalar in text.unicodeScalars {
            let kind = scalar.properties.generalCategory
            let base: Bool
            switch kind {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                base = true
            default:
                base = false
            }
            let mark = kind == .nonspacingMark || kind == .spacingMark || kind == .enclosingMark
            if base {
                if !inside { total += 1 }
                inside = true
                pendingJoiner = false
            } else if mark && inside && !pendingJoiner {
                continue
            } else if (scalar == "'" || scalar == "’" || scalar == "-"), inside, !pendingJoiner {
                pendingJoiner = true
            } else {
                inside = false
                pendingJoiner = false
            }
        }
        return total
    }
}
