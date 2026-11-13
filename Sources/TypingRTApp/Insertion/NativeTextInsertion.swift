import AppKit
@preconcurrency import ApplicationServices
import Carbon.HIToolbox
import TypingRTCore

/// AX references and pasteboard transactions never leave this serial actor.
struct NativeTextInsertion: TextInsertionClient {
    private let driver = NativeInsertionDriver()

    func insert(_ text: String, cancellation: DeliveryCancellation) async -> TextDeliveryOutcome {
        await driver.insert(text, cancellation: cancellation)
    }

    func copy(_ text: String, cancellation: DeliveryCancellation) async -> Bool {
        await driver.copy(text, cancellation: cancellation)
    }
}

private struct ForegroundApplication: Sendable, Equatable {
    let pid: pid_t
    let bundleID: String?

    @MainActor static func current() -> Self? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Self(pid: app.processIdentifier, bundleID: app.bundleIdentifier)
    }
}

private actor NativeInsertionDriver {
    private let clipboard = ClipboardTransactionDriver()
    private var busy = false

    func copy(_ text: String, cancellation: DeliveryCancellation) -> Bool {
        // An explicit Copy action takes ownership intentionally; a pending
        // automatic transaction must finish before a different session starts.
        guard !cancellation.isCancelled, !Task.isCancelled else { return false }
        return clipboard.copy(text, cancellation: cancellation)
    }

    func insert(_ text: String, cancellation: DeliveryCancellation) async -> TextDeliveryOutcome {
        guard !busy else { return .unavailable("Eine Textübergabe läuft bereits.") }
        busy = true
        defer { busy = false }
        guard !cancellation.isCancelled, !Task.isCancelled else { return .cancelled }
        guard !text.isEmpty, text.utf8.count <= 1_048_576,
              !text.unicodeScalars.contains(where: Self.isUnsafeControl) else {
            return .unavailable("Der Text kann nicht automatisch übergeben werden. Bitte kopieren.")
        }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            return .unavailable("Kein Zugriff auf ein sicheres bearbeitbares Textfeld. Bitte kopieren.")
        }
        guard let app = await ForegroundApplication.current(),
              app.pid != ProcessInfo.processInfo.processIdentifier else {
            return .unavailable("Kein unterstütztes Textfeld fokussiert. Das Ergebnis bleibt zum Kopieren bereit.")
        }
        guard app.bundleID != nil else {
            return .unavailable("Die aktive App ist nicht eindeutig erkennbar. Bitte kopieren.")
        }
        // Terminals expose no editable AX text. They receive one Paste of a
        // single-line text, which cannot submit the command line.
        if Self.isTerminal(app.bundleID) {
            return await pasteHandoff(TerminalPaste.singleLine(text), app: app, cancellation: cancellation)
        }
        // Browsers (notably Chrome) often build no AX tree for web content,
        // so editors such as Google Docs expose no focused text element.
        // Before any AX mutation, such targets get one Paste instead (E36).
        let browser = Self.isBrowser(app.bundleID)
        guard let target = focusedTarget(pid: app.pid) else {
            if browser, !focusIsSecureField() { return await pasteHandoff(text, app: app, cancellation: cancellation) }
            return .unavailable("Kein unterstütztes Textfeld fokussiert. Das Ergebnis bleibt zum Kopieren bereit.")
        }

        if isSettable(target.element, kAXSelectedTextAttribute) {
            guard let before = selectedRange(target.element),
                  await ForegroundApplication.current() == app,
                  !IsSecureEventInputEnabled(), stillFocused(target) else {
                return .unavailable("Der Textfokus hat sich geändert. Bitte kopieren.")
            }
            guard !cancellation.isCancelled, !Task.isCancelled else { return .cancelled }
            // From this point onward a failed IPC call may still have mutated
            // the target. Never fall back to Paste or retry this operation.
            let error = AXUIElementSetAttributeValue(target.element,
                                                     kAXSelectedTextAttribute as CFString,
                                                     text as CFString)
            guard error == .success else { return .uncertain }
            guard !cancellation.isCancelled, !Task.isCancelled else { return .uncertain }
            return verifyInsertion(text, originalRange: before, target: target) ? .confirmed : .uncertain
        }

        // Selection alone is insufficient (e.g. terminal output / read-only
        // documents). Require a writable value as additional editing evidence.
        // We never actually overwrite AXValue.
        guard isSettable(target.element, kAXValueAttribute),
              isSettable(target.element, kAXSelectedTextRangeAttribute),
              selectedRange(target.element) != nil else {
            if browser { return await pasteHandoff(text, app: app, cancellation: cancellation) }
            return .unavailable("Dieses Textfeld unterstützt keine sichere automatische Übergabe. Bitte kopieren.")
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .unavailable("Die Einfügeaktion konnte nicht vorbereitet werden. Bitte kopieren.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        guard !cancellation.isCancelled, !Task.isCancelled else { return .cancelled }
        guard let transaction = clipboard.prepare(text, cancellation: cancellation) else {
            if cancellation.isCancelled || Task.isCancelled { return .cancelled }
            return .unavailable("Die Zwischenablage kann nicht vollständig gesichert werden. Bitte kopieren.")
        }
        // No await between the last focus check and event submission. The OS
        // can still change focus concurrently; this residual race is documented.
        let characterCountBefore = characterCount(target.element)
        guard let before = selectedRange(target.element),
              await ForegroundApplication.current() == app,
              !IsSecureEventInputEnabled(), stillFocused(target) else {
            clipboard.restore(transaction)
            return .unavailable("Der Textfokus hat sich geändert. Bitte kopieren.")
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            clipboard.restore(transaction)
            return .cancelled
        }
        down.postToPid(app.pid)
        up.postToPid(app.pid)
        // This grace period is not a delivery acknowledgement. Cancellation
        // must not prevent restoration after an attempted Paste.
        let gracePeriod = Task.detached {
            try? await Task.sleep(for: .milliseconds(500))
        }
        await gracePeriod.value
        clipboard.restore(transaction)
        guard !cancellation.isCancelled, !Task.isCancelled else { return .uncertain }
        let verified: Bool
        if let oldCount = characterCountBefore, oldCount >= before.length,
           oldCount - before.length <= Int.max - text.utf16.count,
           characterCount(target.element) == oldCount - before.length + text.utf16.count {
            verified = verifyInsertion(text, originalRange: before, target: target)
        } else {
            verified = false
        }
        return verified ? .confirmed : .uncertain
    }

    /// One Paste into a target whose text cannot be read back (terminal or
    /// web content without AX tree); the outcome is a handoff, not a
    /// confirmation. Terminal callers pass single-line text, because a pasted
    /// newline can execute shell input even without a Return event.
    private func pasteHandoff(_ line: String, app: ForegroundApplication,
                              cancellation: DeliveryCancellation) async -> TextDeliveryOutcome {
        guard !line.isEmpty else {
            return .unavailable("Der Text kann nicht automatisch übergeben werden. Bitte kopieren.")
        }
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else {
            return .unavailable("Die Einfügeaktion konnte nicht vorbereitet werden. Bitte kopieren.")
        }
        down.flags = .maskCommand
        up.flags = .maskCommand
        guard !cancellation.isCancelled, !Task.isCancelled else { return .cancelled }
        guard let transaction = clipboard.prepare(line, cancellation: cancellation) else {
            if cancellation.isCancelled || Task.isCancelled { return .cancelled }
            return .unavailable("Die Zwischenablage kann nicht vollständig gesichert werden. Bitte kopieren.")
        }
        guard await ForegroundApplication.current() == app, !IsSecureEventInputEnabled() else {
            clipboard.restore(transaction)
            return .unavailable("Der Textfokus hat sich geändert. Bitte kopieren.")
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            clipboard.restore(transaction)
            return .cancelled
        }
        down.postToPid(app.pid)
        up.postToPid(app.pid)
        // Deliberately no restore after the Paste was sent: a target that
        // handles the key late would otherwise paste the previous, unfiltered
        // clipboard (in a terminal possibly several command lines). Keeping the dictated
        // line there also lets the user paste it manually if nothing arrived.
        guard !cancellation.isCancelled, !Task.isCancelled else { return .uncertain }
        return .handedOff
    }

    private struct Target {
        let pid: pid_t
        let element: AXUIElement
    }

    private func focusedTarget(pid: pid_t) -> Target? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let raw = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.2)
        var actualPID: pid_t = 0
        guard AXUIElementGetPid(element, &actualPID) == .success, actualPID == pid,
              let role = attribute(element, kAXRoleAttribute) as? String,
              [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role),
              let enabled = attribute(element, kAXEnabledAttribute) as? Bool, enabled else { return nil }
        var subrole: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
        guard subroleError == .success || subroleError == .attributeUnsupported || subroleError == .noValue else { return nil }
        guard (subrole as? String) != kAXSecureTextFieldSubrole else { return nil }
        return Target(pid: pid, element: element)
    }

    /// Secure Input normally covers password fields; an AX-visible secure
    /// subrole is an additional reason never to paste blindly.
    private func focusIsSecureField() -> Bool {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let raw = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let element = unsafeBitCast(raw, to: AXUIElement.self)
        AXUIElementSetMessagingTimeout(element, 0.2)
        return (attribute(element, kAXSubroleAttribute) as? String) == kAXSecureTextFieldSubrole
    }

    private func stillFocused(_ target: Target) -> Bool {
        guard AXIsProcessTrusted(), let current = focusedTarget(pid: target.pid) else { return false }
        guard CFEqual(target.element, current.element) else { return false }
        // Re-read identity after the slower role/enabled/security queries.
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        guard let raw = attribute(system, kAXFocusedUIElementAttribute),
              CFGetTypeID(raw) == AXUIElementGetTypeID() else { return false }
        let finalElement = unsafeBitCast(raw, to: AXUIElement.self)
        return CFEqual(target.element, finalElement)
    }

    private func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
    }

    private func isSettable(_ element: AXUIElement, _ key: String) -> Bool {
        var writable: DarwinBoolean = false
        return AXUIElementIsAttributeSettable(element, key as CFString, &writable) == .success && writable.boolValue
    }

    private func selectedRange(_ element: AXUIElement) -> CFRange? {
        guard let raw = attribute(element, kAXSelectedTextRangeAttribute),
              CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let value = unsafeBitCast(raw, to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return range
    }

    private func characterCount(_ element: AXUIElement) -> Int? {
        guard let count = attribute(element, kAXNumberOfCharactersAttribute) as? NSNumber,
              count.intValue >= 0 else { return nil }
        return count.intValue
    }

    private func verifyInsertion(_ text: String, originalRange: CFRange, target: Target) -> Bool {
        let count = text.utf16.count
        guard originalRange.location <= Int.max - count,
              let after = selectedRange(target.element), after.length == 0,
              after.location == originalRange.location + count else { return false }
        var inserted = CFRange(location: originalRange.location, length: count)
        guard let parameter = AXValueCreate(.cfRange, &inserted) else { return false }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(target.element,
                kAXStringForRangeParameterizedAttribute as CFString, parameter, &value) == .success,
              let actual = value as? String else { return false }
        return actual == text
    }

    private static func isUnsafeControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 32 && scalar != "\n" && scalar != "\t" || scalar.value == 127
    }

    private static func isTerminal(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return ["com.apple.terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
                "org.alacritty", "org.wezfurlong.wezterm", "com.github.wez.wezterm", "com.mitchellh.ghostty"].contains(id)
            || id.hasPrefix("dev.warp.")
    }

    private static func isBrowser(_ bundleID: String?) -> Bool {
        guard let id = bundleID?.lowercased() else { return false }
        return ["com.google.chrome", "com.google.chrome.beta", "com.google.chrome.dev",
                "com.google.chrome.canary", "org.chromium.chromium", "com.apple.safari",
                "com.apple.safaritechnologypreview", "com.brave.browser", "com.microsoft.edgemac",
                "company.thebrowser.browser", "company.thebrowser.dia", "com.vivaldi.vivaldi",
                "com.operasoftware.opera", "org.mozilla.firefox", "app.zen-browser.zen"].contains(id)
    }
}

/// Test boundaries require no running pbs service. Production wrappers touch
/// AppKit only when a dictation is actually handed off or copied.
protocol ClipboardItemAccess {
    var types: [NSPasteboard.PasteboardType] { get }
    func data(forType type: NSPasteboard.PasteboardType) -> Data?
}

protocol ClipboardBoardAccess {
    var permitsReading: Bool { get }
    var changeCount: Int { get }
    var items: [any ClipboardItemAccess]? { get }
    var types: [NSPasteboard.PasteboardType]? { get }
    func clear(currentHostOnly: Bool) -> Int
    func setString(_ text: String) -> Bool
    func makeItem(_ representations: [NSPasteboard.PasteboardType: Data]) -> any ClipboardItemAccess
    func writeItems(_ items: [any ClipboardItemAccess]) -> Bool
}

private final class SystemClipboardItem: ClipboardItemAccess {
    let item: NSPasteboardItem
    init(_ item: NSPasteboardItem) { self.item = item }
    var types: [NSPasteboard.PasteboardType] { item.types }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? { item.data(forType: type) }
}

final class SystemClipboardBoard: ClipboardBoardAccess {
    private let suppliedBoard: NSPasteboard?
    // No general pasteboard access during app initialization.
    private var board: NSPasteboard { suppliedBoard ?? NSPasteboard.general }
    init(board: NSPasteboard? = nil) { suppliedBoard = board }
    var permitsReading: Bool {
        if #available(macOS 15.4, *) { return board.accessBehavior != .alwaysDeny }
        return true
    }
    var changeCount: Int { board.changeCount }
    var items: [any ClipboardItemAccess]? {
        board.pasteboardItems?.map { SystemClipboardItem($0) }
    }
    var types: [NSPasteboard.PasteboardType]? { board.types }
    func clear(currentHostOnly: Bool) -> Int {
        currentHostOnly ? board.prepareForNewContents(with: .currentHostOnly) : board.clearContents()
    }
    func setString(_ text: String) -> Bool { board.setString(text, forType: .string) }
    func makeItem(_ representations: [NSPasteboard.PasteboardType: Data]) -> any ClipboardItemAccess {
        let item = NSPasteboardItem()
        for (type, data) in representations { item.setData(data, forType: type) }
        return SystemClipboardItem(item)
    }
    func writeItems(_ items: [any ClipboardItemAccess]) -> Bool {
        let nativeItems = items.compactMap { ($0 as? SystemClipboardItem)?.item }
        guard nativeItems.count == items.count else { return false }
        return board.writeObjects(nativeItems)
    }
}

/// Synchronous driver confined to its owner's actor; injectable for tests.
final class ClipboardTransactionDriver {
    struct Snapshot {
        let items: [[NSPasteboard.PasteboardType: Data]]
        let changeCount: Int
    }

    struct Transaction {
        let previous: Snapshot
        let ownChangeCount: Int
    }

    private let board: any ClipboardBoardAccess
    private let maximumBytes: Int

    init(board: any ClipboardBoardAccess = SystemClipboardBoard(), maximumBytes: Int = 16 * 1_024 * 1_024) {
        self.board = board
        self.maximumBytes = maximumBytes
    }

    func snapshot() -> Snapshot? {
        guard board.permitsReading else { return nil }
        let generation = board.changeCount
        guard let sourceItems = board.items else {
            // nil can also mean unavailable/denied access, not an empty board.
            return board.types?.isEmpty == true && board.permitsReading && board.changeCount == generation
                ? Snapshot(items: [], changeCount: generation) : nil
        }
        guard sourceItems.count <= 64 else { return nil }
        var size = 0
        var items: [[NSPasteboard.PasteboardType: Data]] = []
        for source in sourceItems {
            guard !source.types.isEmpty, source.types.count <= 128 else { return nil }
            var representations: [NSPasteboard.PasteboardType: Data] = [:]
            for type in source.types {
                // File promises cannot be restored faithfully from their
                // descriptor bytes; never claim a complete backup for them.
                guard !type.rawValue.lowercased().contains("promise"),
                      let data = source.data(forType: type),
                      data.count <= maximumBytes - size else { return nil }
                size += data.count
                representations[type] = data
            }
            items.append(representations)
        }
        guard board.permitsReading, board.changeCount == generation else { return nil }
        return Snapshot(items: items, changeCount: generation)
    }

    func prepare(_ text: String, cancellation: DeliveryCancellation) -> Transaction? {
        guard !cancellation.isCancelled, !Task.isCancelled,
              let previous = snapshot(), board.changeCount == previous.changeCount,
              !cancellation.isCancelled, !Task.isCancelled else { return nil }
        let clearedGeneration = board.clear(currentHostOnly: true)
        let transaction = Transaction(previous: previous, ownChangeCount: clearedGeneration)
        guard board.changeCount == clearedGeneration else { return nil }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            restore(transaction)
            return nil
        }
        guard board.setString(text) else {
            restore(transaction)
            return nil
        }
        // Writing the existing owner's representation does not transfer
        // ownership. Never adopt a concurrent user's generation as our own.
        guard board.changeCount == clearedGeneration else { return nil }
        return transaction
    }

    @discardableResult
    func restore(_ transaction: Transaction) -> Bool {
        guard board.changeCount == transaction.ownChangeCount else { return false }
        let items = transaction.previous.items.map { board.makeItem($0) }
        // Item reconstruction can take time; do not overwrite a user copy
        // that happened after the initial check but before clear.
        guard board.changeCount == transaction.ownChangeCount else { return false }
        let clearedGeneration = board.clear(currentHostOnly: false)
        guard board.changeCount == clearedGeneration else { return false }
        return items.isEmpty || board.writeItems(items)
    }

    func copy(_ text: String, cancellation: DeliveryCancellation) -> Bool {
        guard !cancellation.isCancelled, !Task.isCancelled else { return false }
        let clearedGeneration = board.clear(currentHostOnly: true)
        // Explicit Copy commits at clear. Complete that write even if Esc
        // arrives afterward; otherwise it could leave an empty clipboard.
        guard board.changeCount == clearedGeneration else { return false }
        return board.setString(text)
    }
}
