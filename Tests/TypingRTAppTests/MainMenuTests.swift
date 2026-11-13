import AppKit
import Testing
@testable import TypingRTApp

@Suite @MainActor
struct MainMenuTests {
    private func item(_ key: String, shift: Bool = false) -> NSMenuItem? {
        MainMenu.make().items.compactMap(\.submenu).flatMap(\.items).first {
            $0.keyEquivalent == key && $0.keyEquivalentModifierMask.contains(.shift) == shift
        }
    }

    @Test func editingShortcutsReachTextFieldsOfAMenuBarOnlyApp() {
        #expect(item("v")?.action == #selector(NSText.paste(_:)))
        #expect(item("c")?.action == #selector(NSText.copy(_:)))
        #expect(item("x")?.action == #selector(NSText.cut(_:)))
        #expect(item("a")?.action == #selector(NSText.selectAll(_:)))
        #expect(item("z")?.action == Selector(("undo:")))
        #expect(item("z", shift: true)?.action == Selector(("redo:")))
        // Targets stay nil so the focused field receives the action.
        #expect(MainMenu.make().items.compactMap(\.submenu).flatMap(\.items).allSatisfy { $0.target == nil })
    }

    @Test func windowShortcutsCloseWithoutQuittingTheDictationService() {
        #expect(item("w")?.action == #selector(NSWindow.performClose(_:)))
        #expect(item("q") == nil)
    }
}
