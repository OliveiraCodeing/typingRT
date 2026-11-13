import Foundation
import Observation
import TypingRTCore

struct RequestyCatalog: Codable, Sendable, Equatable {
    let version: Int
    let fetchedAt: Date
    let models: [RequestyModel]
}

/// Only minimal, nonsecret metadata is persisted. No raw provider responses.
actor RequestyCatalogStore {
    private let url: URL
    init(url: URL) { self.url = url }

    func load() throws -> RequestyCatalog? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: 4 * 1_024 * 1_024 + 1) ?? Data()
        guard data.count <= 4 * 1_024 * 1_024 else { throw RequestyError.tooLarge }
        let catalog = try JSONDecoder().decode(RequestyCatalog.self, from: data)
        guard catalog.version == 1, catalog.models.count <= 10_000,
              catalog.models.allSatisfy({ RequestyValidation.modelID($0.id) == $0.id }),
              Set(catalog.models.map(\.id)).count == catalog.models.count else { throw RequestyError.invalidResponse }
        return catalog
    }

    func save(_ catalog: RequestyCatalog) throws {
        let data = try JSONEncoder().encode(catalog)
        guard data.count <= 4 * 1_024 * 1_024 else { throw RequestyError.tooLarge }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

@MainActor @Observable
final class RequestyEditor {
    // SecureField draft only. Never populated from the saved key.
    var keyDraft = ""
    var manualModelID = ""
    var search = ""
}

@MainActor @Observable
final class RequestySettings {
    enum CredentialState { case unknown, missing, stored, unavailable }
    let editor = RequestyEditor()
    let preferences: PreferencesStore
    private(set) var credentialState: CredentialState = .unknown
    private(set) var catalog: RequestyCatalog?
    private(set) var catalogIsCached = true
    private(set) var isWorking = false
    private(set) var isChecking = false
    private(set) var errorMessage: String?
    private(set) var notice: String?
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private let credentials: any RequestyCredentialStoring
    @ObservationIgnored private let client: any RequestyServing
    @ObservationIgnored private let store: RequestyCatalogStore
    @ObservationIgnored private var networkTask: Task<[RequestyModel], Error>?
    @ObservationIgnored private var operation: UUID?
    @ObservationIgnored private var cancelledOperation: UUID?
    @ObservationIgnored private var stopped = false
    @ObservationIgnored private var loaded = false

    init(preferences: PreferencesStore, credentials: any RequestyCredentialStoring = RequestyCredentials(service: AppIdentity.current.keychainService),
         client: any RequestyServing = RequestyClient(), cacheURL: URL = AppIdentity.current.applicationSupport.appendingPathComponent("requesty-models.json")) {
        self.preferences = preferences
        self.credentials = credentials
        self.client = client
        store = RequestyCatalogStore(url: cacheURL)
    }

    var canUseCoding: Bool { credentialState == .stored && preferences.requestyModelID != nil }
    var setupMessage: String {
        if credentialState != .stored { return "Requesty-Zugang für Coding bitte einrichten" }
        return "Requesty-Textmodell für Coding bitte auswählen"
    }
    var visibleModels: [RequestyModel] {
        let search = editor.search.trimmingCharacters(in: .whitespacesAndNewlines)
        return (catalog?.models ?? []).filter { search.isEmpty || $0.id.localizedCaseInsensitiveContains(search) }
    }

    /// A model-owned task survives SwiftUI view changes; shutdown still cancels it.
    /// Loading is local only and never starts a catalog request or inference.
    func load() async {
        if let loadTask { await loadTask.value; return }
        guard !isWorking, !stopped, !loaded else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        loadTask = nil
    }

    private func performLoad() async {
        guard !stopped else { return }
        isWorking = true
        defer { isWorking = false; onChange?() }
        do {
            let saved = try await store.load()
            try Task.checkCancellation()
            guard !stopped else { return }
            catalog = saved
        } catch is CancellationError { return }
        catch { errorMessage = "Die gespeicherte Modellliste ist nicht lesbar. Lade sie bei Bedarf erneut." }
        guard !stopped, !Task.isCancelled else { return }
        do {
            let value = try await credentials.read()
            try Task.checkCancellation()
            guard !stopped else { return }
            credentialState = value == nil ? .missing : .stored
            loaded = true
        } catch is CancellationError { return }
        catch {
            guard !stopped else { return }
            credentialState = .unavailable
            loaded = true
            errorMessage = "Der Schlüsselbund ist nicht zugänglich. Standard bleibt verfügbar."
        }
    }

    func saveKey() async {
        guard !isWorking, !stopped else { return }
        guard let key = RequestyValidation.apiKey(editor.keyDraft) else {
            errorMessage = "Bitte einen gültigen, nicht leeren Requesty-Schlüssel eingeben. Der gespeicherte Zugang bleibt erhalten."
            return
        }
        isWorking = true
        defer { isWorking = false; onChange?() }
        do {
            try await credentials.save(key)
            guard !stopped else { return }
            credentialState = .stored
            editor.keyDraft = ""
            catalogIsCached = true
            errorMessage = nil
            notice = "Im Schlüsselbund gespeichert. Verbindung noch nicht geprüft."
        } catch {
            errorMessage = "Der Schlüssel konnte nicht im Schlüsselbund gespeichert werden. Es gibt keinen ungeschützten Ersatzspeicher."
        }
    }

    func deleteKey() async {
        guard !isWorking, !stopped else { return }
        isWorking = true
        defer { isWorking = false; onChange?() }
        do {
            try await credentials.delete()
            guard !stopped else { return }
            credentialState = .missing
            editor.keyDraft = ""
            catalogIsCached = true
            errorMessage = nil
            notice = "Zugang gelöscht. Standard funktioniert weiterhin lokal."
        } catch { errorMessage = "Der Schlüssel konnte nicht gelöscht werden. Bitte den Schlüsselbund prüfen." }
    }

    func selectModel(_ id: String) {
        guard !stopped else { return }
        guard preferences.selectRequestyModel(id) else {
            errorMessage = "Bitte eine gültige, nicht leere Modell-ID eingeben."
            return
        }
        errorMessage = nil
        notice = "Textmodell gespeichert. Verfügbarkeit wird erst bei einer Anfrage bestätigt."
        onChange?()
    }

    /// Explicit authenticated GET. A cancelled/late reply never updates state or cache.
    func checkConnection() async {
        guard !isWorking, !stopped else { return }
        let id = UUID()
        operation = id
        cancelledOperation = nil
        isWorking = true
        isChecking = true
        errorMessage = nil
        notice = nil
        defer {
            if operation == id { operation = nil; networkTask = nil; isWorking = false; isChecking = false; onChange?() }
        }
        do {
            guard let key = try await credentials.read() else {
                guard isCurrent(id) else { return }
                credentialState = .missing
                errorMessage = "Bitte zuerst einen Requesty-Schlüssel speichern."
                return
            }
            guard isCurrent(id) else { return }
            credentialState = .stored
            let client = client
            let task = Task { try await client.models(apiKey: key) }
            networkTask = task
            let models = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            try Task.checkCancellation()
            guard isCurrent(id) else { return }
            let updated = RequestyCatalog(version: 1, fetchedAt: Date(), models: models)
            // The response is now accepted; cancellation ends at this commit boundary.
            isChecking = false
            // Store is serialized and bounded. No arbitrary network body is persisted.
            try await store.save(updated)
            guard isCurrent(id) else { return }
            catalog = updated
            catalogIsCached = false
            notice = models.isEmpty ? "Zugang bestätigt. Keine passenden Textmodelle gelistet; manuelle ID möglich." : "Verbindung bestätigt. Textmodelle aktualisiert."
        } catch is CancellationError {
            if isCurrent(id) { notice = "Anfrage abgebrochen." }
        } catch let error as RequestyError {
            guard isCurrent(id) else { return }
            errorMessage = error.localizedDescription
            if error == .unauthorized { credentialState = .unavailable }
        } catch {
            guard isCurrent(id) else { return }
            errorMessage = "Anfrage oder Schlüsselbundzugriff fehlgeschlagen. Bitte Zugang und Verbindung prüfen."
        }
    }

    private func isCurrent(_ id: UUID) -> Bool { !stopped && !Task.isCancelled && operation == id && cancelledOperation != id }

    func cancel() {
        guard isChecking, let id = operation else { return }
        cancelledOperation = id
        networkTask?.cancel()
        notice = "Anfrage abgebrochen. Eine bereits serverseitig erfolgte Verarbeitung kann trotzdem Kosten verursachen."
    }

    func shutDown() {
        stopped = true
        loadTask?.cancel()
        editor.keyDraft = ""
        cancel()
    }
    func finishShutdown() async {
        await loadTask?.value
        _ = try? await networkTask?.value
    }
}
