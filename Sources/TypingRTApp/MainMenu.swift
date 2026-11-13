import AppKit

/// A menu-bar-only app shows no main menu, but AppKit still routes Command-V,
/// Command-C and the other editing shortcuts through it. Without an Edit menu
/// those shortcuts do nothing in any text field of the main window.
@MainActor
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()

        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(withTitle: "Widerrufen", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Wiederholen", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem(title: "Bearbeiten", action: nil, keyEquivalent: "")
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "Fenster")
        window.addItem(withTitle: "Schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        window.addItem(withTitle: "Im Dock ablegen", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        let windowItem = NSMenuItem(title: "Fenster", action: nil, keyEquivalent: "")
        windowItem.submenu = window
        main.addItem(windowItem)
        return main
    }
}
