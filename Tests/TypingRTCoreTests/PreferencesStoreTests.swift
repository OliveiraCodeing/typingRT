import Foundation
import Testing
@testable import TypingRTCore

@MainActor
struct PreferencesStoreTests {
    private let modeKey = "typingRT.selectedMode"

    @Test
    func firstLaunchUsesStandardWithoutWritingDefaults() throws {
        let suite = "typingRT.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = PreferencesStore(defaults: defaults)

        #expect(preferences.selectedMode == .standard)
        #expect(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
    }

    @Test
    func selectedModeIsRestoredByANewStore() throws {
        let suite = "typingRT.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = PreferencesStore(defaults: defaults)
        first.selectedMode = .coding

        #expect(PreferencesStore(defaults: defaults).selectedMode == .coding)

        first.selectedMode = .standard
        #expect(PreferencesStore(defaults: defaults).selectedMode == .standard)
    }

    @Test
    func unknownStoredModeFallsBackToStandard() throws {
        let suite = "typingRT.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("removed-mode", forKey: modeKey)

        let preferences = PreferencesStore(defaults: defaults)

        #expect(preferences.selectedMode == .standard)
        preferences.selectedMode = .coding
        #expect(PreferencesStore(defaults: defaults).selectedMode == .coding)
    }

    @Test
    func changingModePersistsOnlyTheNonsecretModeKey() throws {
        let suite = "typingRT.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let preferences = PreferencesStore(defaults: defaults)
        preferences.selectedMode = .coding
        let saved = try #require(defaults.persistentDomain(forName: suite))

        #expect(Set(saved.keys) == Set([modeKey]))
        #expect(saved[modeKey] as? String == DictationMode.coding.rawValue)
    }
    @Test func typingSpeedValidationAndPersistence() throws {
        let suite = "wpm-tests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PreferencesStore(defaults: defaults)
        #expect(preferences.typingWordsPerMinute == 40)
        for invalid in ["", " ", "0", "-1", "nan", "inf", "one", "1e9999"] {
            #expect(!preferences.setTypingWordsPerMinute(invalid))
            #expect(preferences.typingWordsPerMinute == 40)
        }
        #expect(preferences.setTypingWordsPerMinute("52,5"))
        #expect(PreferencesStore(defaults: defaults).typingWordsPerMinute == 52.5)
        defaults.set(Double.infinity, forKey: "typingRT.typingWordsPerMinute")
        #expect(PreferencesStore(defaults: defaults).typingWordsPerMinute == 40)
    }

}
