import Foundation
import Observation

@Observable
@MainActor
public final class PreferencesStore {
    private static let wpmKey = "typingRT.typingWordsPerMinute"
    private static let modeKey = "typingRT.selectedMode"
    private static let requestyModelKey = "typingRT.requestyModelID"

    @ObservationIgnored
    private let defaults: UserDefaults

    public var selectedMode: DictationMode {
        didSet {
            defaults.set(selectedMode.rawValue, forKey: Self.modeKey)
        }
    }

    /// Nonsecret identifier only; credentials never enter preferences.
    public private(set) var requestyModelID: String?

    @discardableResult
    public func selectRequestyModel(_ value: String) -> Bool {
        guard let id = RequestyValidation.modelID(value) else { return false }
        requestyModelID = id
        defaults.set(id, forKey: Self.requestyModelKey)
        return true
    }

    public private(set) var typingWordsPerMinute: Double

    @discardableResult
    public func setTypingWordsPerMinute(_ input: String) -> Bool {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let value = Double(normalized), value.isFinite, value > 0 else { return false }
        typingWordsPerMinute = value
        defaults.set(value, forKey: Self.wpmKey)
        return true
    }

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let storedWPM = defaults.double(forKey: Self.wpmKey)
        typingWordsPerMinute = storedWPM.isFinite && storedWPM > 0 ? storedWPM : 40
        selectedMode = defaults.string(forKey: Self.modeKey)
            .flatMap(DictationMode.init(rawValue:)) ?? .standard
        requestyModelID = defaults.string(forKey: Self.requestyModelKey).flatMap(RequestyValidation.modelID)
    }
}
