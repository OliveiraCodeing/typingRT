import Foundation
import Observation
import TypingRTCore

/// The UI sees only committed immutable snapshots. SQLite work belongs to its actor.
@MainActor @Observable
final class DictionaryLibrary {
    let editor = DictionaryEditor()
    private(set) var snapshot: DictionarySnapshot = .empty
    private(set) var isLoaded = false
    private(set) var isWorking = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let store: DictionaryStore

    init(url: URL = AppIdentity.current.applicationSupport.appendingPathComponent("dictionary.sqlite")) {
        store = DictionaryStore(url: url)
    }

    func load() async {
        guard !isWorking else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            snapshot = try await store.load()
            isLoaded = true
            errorMessage = nil
        } catch {
            errorMessage = "Das Wörterbuch konnte nicht geladen werden. Deine gespeicherten Einträge bleiben erhalten."
        }
    }

    func save(id: UUID?, canonical: String, aliases: [String], isProtected: Bool) async -> Bool {
        guard isLoaded, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            let entry = try DictionaryEntry(id: id ?? UUID(), canonical: canonical, aliases: aliases, isProtected: isProtected)
            snapshot = try await store.save(entry)
            errorMessage = nil
            return true
        } catch let error as DictionaryError {
            errorMessage = error.localizedDescription
            return false
        } catch {
            errorMessage = "Der Eintrag konnte nicht gespeichert werden. Der bisherige Stand bleibt erhalten."
            return false
        }
    }

    func delete(id: UUID) async -> Bool {
        guard isLoaded, !isWorking else { return false }
        isWorking = true
        defer { isWorking = false }
        do {
            snapshot = try await store.delete(id: id)
            errorMessage = nil
            return true
        } catch {
            errorMessage = "Der Eintrag konnte nicht gelöscht werden. Der bisherige Stand bleibt erhalten."
            return false
        }
    }
}
