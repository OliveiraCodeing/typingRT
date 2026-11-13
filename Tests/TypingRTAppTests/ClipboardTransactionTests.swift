import AppKit
import Testing
@testable import TypingRTApp

/// Tests the production transaction logic without WindowServer/pbs access.
/// No test reads or writes the user's clipboard.
@Suite(.timeLimit(.minutes(1)))
struct ClipboardTransactionTests {
    @Test func restoresEveryItemAndRepresentationAfterOwnPaste() throws {
        let custom = NSPasteboard.PasteboardType("dev.typingrt.test.binary")
        let board = MemoryClipboard(items: [
            [.string: Data("Original".utf8), custom: Data([0, 1, 2, 255])],
            [.html: Data("<b>Formatted</b>".utf8)]
        ])
        let driver = ClipboardTransactionDriver(board: board)
        let before = try #require(driver.snapshot())
        let transaction = try #require(driver.prepare("Diktat", cancellation: DeliveryCancellation()))
        #expect(board.text == "Diktat")
        #expect(driver.restore(transaction))
        #expect(driver.snapshot()?.items == before.items)
    }

    @Test func aNewUserClipboardGenerationIsNeverRestoredOver() throws {
        let board = MemoryClipboard(items: [[.string: Data("Vorher".utf8)]])
        let driver = ClipboardTransactionDriver(board: board)
        let transaction = try #require(driver.prepare("Diktat", cancellation: DeliveryCancellation()))
        board.userCopy("Neu vom Nutzer")
        #expect(!driver.restore(transaction))
        #expect(board.text == "Neu vom Nutzer")
    }

    @Test func userChangeWhileRebuildingRestoreObjectsIsPreserved() throws {
        let board = MemoryClipboard(items: [[.string: Data("Vorher".utf8)]])
        let driver = ClipboardTransactionDriver(board: board)
        let transaction = try #require(driver.prepare("Diktat", cancellation: DeliveryCancellation()))
        board.onMakeItem = { board.userCopy("Während Wiederherstellung kopiert") }
        #expect(!driver.restore(transaction))
        #expect(board.text == "Während Wiederherstellung kopiert")
    }

    @Test func incompleteOrOversizedBackupNeverClearsOriginal() {
        let custom = NSPasteboard.PasteboardType("dev.typingrt.test.binary")
        let board = MemoryClipboard(items: [[custom: Data(repeating: 42, count: 256)]])
        let generation = board.changeCount
        let driver = ClipboardTransactionDriver(board: board, maximumBytes: 128)
        #expect(driver.prepare("Diktat", cancellation: DeliveryCancellation()) == nil)
        #expect(board.changeCount == generation)
        let promised = MemoryClipboard(items: [[NSPasteboard.PasteboardType("com.apple.filepromise"): Data([1])]])
        #expect(ClipboardTransactionDriver(board: promised).prepare("Diktat", cancellation: DeliveryCancellation()) == nil)
        #expect(promised.changeCount == 0)
        let incomplete = MemoryClipboard(items: [])
        incomplete.stored = [MemoryClipboardItem([.string: Data()], missingData: true)]
        #expect(ClipboardTransactionDriver(board: incomplete).prepare("Diktat", cancellation: DeliveryCancellation()) == nil)
        #expect(incomplete.changeCount == 0)
    }

    @Test func cancellationBeforeMutationAndUserChangeDuringSnapshotDoNotClear() {
        let board = MemoryClipboard(items: [[.string: Data("Vorher".utf8)]])
        let driver = ClipboardTransactionDriver(board: board)
        let token = DeliveryCancellation()
        token.cancel()
        #expect(driver.prepare("Diktat", cancellation: token) == nil)
        #expect(!driver.copy("Diktat", cancellation: token))
        #expect(board.changeCount == 0)
        board.stored.first?.onRead = { board.userCopy("Während Snapshot kopiert") }
        #expect(driver.prepare("Diktat", cancellation: DeliveryCancellation()) == nil)
        #expect(board.text == "Während Snapshot kopiert")
    }

    @Test func emptyClipboardAndExplicitCopyHaveDistinctOwnership() throws {
        let board = MemoryClipboard(items: [])
        let driver = ClipboardTransactionDriver(board: board)
        let transaction = try #require(driver.prepare("Diktat", cancellation: DeliveryCancellation()))
        #expect(driver.copy("Bewusst kopiert", cancellation: DeliveryCancellation()))
        #expect(!driver.restore(transaction))
        #expect(board.text == "Bewusst kopiert")
        board.userClear()
        let emptyTransaction = try #require(driver.prepare("Diktat", cancellation: DeliveryCancellation()))
        #expect(driver.restore(emptyTransaction))
        #expect(board.stored.isEmpty)
    }

    @Test func deniedOrUnavailableClipboardIsNeverTreatedAsEmpty() {
        let board = MemoryClipboard(items: [[.string: Data("Vorher".utf8)]])
        board.permitsReading = false
        #expect(ClipboardTransactionDriver(board: board).prepare("Diktat", cancellation: DeliveryCancellation()) == nil)
        #expect(board.changeCount == 0)
        board.permitsReading = true
        board.unavailable = true
        #expect(ClipboardTransactionDriver(board: board).prepare("Diktat", cancellation: DeliveryCancellation()) == nil)
        #expect(board.changeCount == 0)
    }

    @Test func cancellationAfterPreparingClipboardRestoresPreviousContents() {
        let board = MemoryClipboard(items: [[.string: Data("Vorher".utf8)]])
        let token = DeliveryCancellation()
        board.onClear = { token.cancel() }
        #expect(ClipboardTransactionDriver(board: board).prepare("Diktat", cancellation: token) == nil)
        #expect(board.text == "Vorher")
    }
}

private final class MemoryClipboardItem: ClipboardItemAccess {
    let representations: [NSPasteboard.PasteboardType: Data]
    let missingData: Bool
    var onRead: (() -> Void)?
    init(_ representations: [NSPasteboard.PasteboardType: Data], missingData: Bool = false) {
        self.representations = representations
        self.missingData = missingData
    }
    var types: [NSPasteboard.PasteboardType] { Array(representations.keys) }
    func data(forType type: NSPasteboard.PasteboardType) -> Data? {
        onRead?()
        return missingData ? nil : representations[type]
    }
}

private final class MemoryClipboard: ClipboardBoardAccess {
    var stored: [MemoryClipboardItem]
    private(set) var changeCount = 0
    var onMakeItem: (() -> Void)?
    var onClear: (() -> Void)?
    var permitsReading = true
    var unavailable = false
    init(items: [[NSPasteboard.PasteboardType: Data]]) { stored = items.map { MemoryClipboardItem($0) } }
    var items: [any ClipboardItemAccess]? { unavailable ? nil : stored }
    var types: [NSPasteboard.PasteboardType]? { unavailable ? nil : stored.flatMap(\.types) }
    var text: String? { stored.first?.representations[.string].flatMap { String(data: $0, encoding: .utf8) } }
    func clear(currentHostOnly: Bool) -> Int {
        userClear()
        let callback = onClear
        onClear = nil
        callback?()
        return changeCount
    }
    func setString(_ text: String) -> Bool { stored = [MemoryClipboardItem([.string: Data(text.utf8)])]; return true }
    func makeItem(_ representations: [NSPasteboard.PasteboardType: Data]) -> any ClipboardItemAccess {
        onMakeItem?()
        return MemoryClipboardItem(representations)
    }
    func writeItems(_ items: [any ClipboardItemAccess]) -> Bool {
        stored = items.map { item in MemoryClipboardItem(Dictionary(uniqueKeysWithValues: item.types.compactMap { type in
            item.data(forType: type).map { (type, $0) }
        })) }
        return true
    }
    func userClear() { changeCount += 1; stored = [] }
    func userCopy(_ text: String) { userClear(); _ = setString(text) }
}
