import Foundation
import Observation
import TypingRTCore

@MainActor @Observable
final class SnippetEditor {
    var search = ""
    var editingID: UUID?
    var name = ""
    var trigger = ""
    var aliases = ""
    var template = ""
    var showingEditor = false
    var pendingDeletion: SnippetEntry?
    var preview: SnippetEntry?
    func edit(_ entry: SnippetEntry?) {
        editingID = entry?.id
        name = entry?.name ?? ""
        trigger = entry?.trigger ?? ""
        aliases = entry?.aliases.joined(separator: "\n") ?? ""
        template = entry?.template ?? ""
        showingEditor = true
    }
}

/// Only committed snapshots reach capture. Store and file work run off the UI executor.
@MainActor @Observable
final class SnippetLibrary {
    let editor = SnippetEditor()
    private(set) var snapshot: SnippetSnapshot = .empty
    private(set) var isLoaded = false
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    private(set) var fieldError: String?
    private(set) var notice: String?
    @ObservationIgnored private let store: SnippetStore

    init(url: URL = AppIdentity.current.applicationSupport.appendingPathComponent("snippets.sqlite")) {
        store = SnippetStore(url: url)
    }
    func clearMessages() { errorMessage = nil; fieldError = nil; notice = nil }
    func load() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do { snapshot = try await store.load(); isLoaded = true; clearMessages() }
        catch { show(error) }
    }
    func save(id: UUID?, name: String, trigger: String, aliases: [String], template: String) async -> Bool {
        guard isLoaded, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let entry = try SnippetEntry(id: id ?? UUID(), name: name, trigger: trigger, aliases: aliases, template: template)
            snapshot = try await store.save(entry)
            clearMessages()
            return true
        } catch { show(error); return false }
    }
    func delete(id: UUID) async -> Bool {
        guard isLoaded, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do { snapshot = try await store.delete(id: id); clearMessages(); return true }
        catch { show(error); return false }
    }
    func importFile(_ url: URL) async {
        guard isLoaded, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await Task.detached(priority: .utility) {
                guard url.isFileURL else { throw CocoaError(.fileReadUnsupportedScheme) }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: 16 * 1024 * 1024 + 1) ?? Data()
                guard data.count <= 16 * 1024 * 1024 else { throw CocoaError(.fileReadTooLarge) }
                return data
            }.value
            snapshot = try await store.importJSON(data)
            clearMessages(); notice = "Snippets importiert. Änderungen gelten ab dem nächsten Diktat."
        } catch { show(error) }
    }
    func exportFile(_ url: URL) async {
        guard isLoaded, !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let data = try await store.exportJSON()
            try await Task.detached(priority: .utility) {
                guard url.isFileURL else { throw CocoaError(.fileWriteUnsupportedScheme) }
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try data.write(to: url, options: [.atomic])
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            }.value
            clearMessages(); notice = "Snippet-Sicherung exportiert. Sie enthält deine Vorlagentexte."
        } catch { show(error) }
    }
    private func show(_ error: Error) {
        notice = nil
        if let error = error as? SnippetError {
            errorMessage = error.localizedDescription
            fieldError = String(describing: error.field)
        } else {
            errorMessage = "Die Snippets konnten nicht verarbeitet werden. Der gespeicherte Stand bleibt erhalten."
            fieldError = nil
        }
    }
}
