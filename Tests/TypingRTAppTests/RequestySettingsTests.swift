import Foundation
import Testing
@testable import TypingRTCore
@testable import TypingRTApp

private actor CredentialsDouble: RequestyCredentialStoring {
    var key: String?
    var fail = false
    var reads = 0
    var holdRead = false
    var readContinuation: CheckedContinuation<String?, Never>?
    init(_ key: String? = nil) { self.key = key }
    func read() async throws -> String? {
        reads += 1
        if fail { throw RequestyCredentialError.unavailable }
        if holdRead { return await withCheckedContinuation { readContinuation = $0 } }
        return key
    }
    func blockRead() { holdRead = true }
    func isWaiting() -> Bool { readContinuation != nil }
    func releaseRead() { readContinuation?.resume(returning: key); readContinuation = nil; holdRead = false }
    func save(_ value: String) throws { if fail { throw RequestyCredentialError.unavailable }; key = value }
    func delete() throws { if fail { throw RequestyCredentialError.unavailable }; key = nil }
    func setFailure() { fail = true }
}

private actor CatalogDouble: RequestyServing {
    var calls = 0
    var blocked = false
    var continuation: CheckedContinuation<[RequestyModel], Error>?
    func models(apiKey: String) async throws -> [RequestyModel] {
        calls += 1
        if blocked { return try await withCheckedThrowingContinuation { continuation = $0 } }
        return [RequestyModel(id: "example/test-model", contextWindow: 8192, maxOutputTokens: 1024)]
    }
    func complete(sessionID: UUID, modelID: String, system: String, text: String, maxOutputTokens: Int, apiKey: String) async throws -> RequestyCompletion {
        throw RequestyError.invalidConfiguration
    }
    func block() { blocked = true }
    func release() { continuation?.resume(returning: [RequestyModel(id: "late/model")]); continuation = nil }
    func waiting() -> Bool { continuation != nil }
}

@MainActor struct RequestySettingsTests {
    private func fixture() throws -> (URL, UserDefaults, String, PreferencesStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-requesty-test-\(UUID())")
        let suite = "typingRT.requesty-tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        return (root, defaults, suite, PreferencesStore(defaults: defaults))
    }

    @Test func secureSaveEmptyInputFailureDeleteAndRestart() async throws {
        let (root, defaults, suite, prefs) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let credentials = CredentialsDouble()
        let client = CatalogDouble()
        let settings = RequestySettings(preferences: prefs, credentials: credentials, client: client, cacheURL: root.appendingPathComponent("cache.json"))
        await settings.load()
        #expect(settings.credentialState == .missing)
        // Deliberately synthetic, never a real provider credential.
        settings.editor.keyDraft = "synthetic-unit-test-value"
        await settings.saveKey()
        #expect(settings.credentialState == .stored)
        #expect(settings.editor.keyDraft.isEmpty)
        await settings.saveKey()
        #expect(try await credentials.read() == "synthetic-unit-test-value")
        #expect(settings.errorMessage != nil)
        settings.selectModel(" example/manual ")
        #expect(prefs.requestyModelID == "example/manual")
        #expect(settings.canUseCoding)
        let stored = try #require(defaults.persistentDomain(forName: suite))
        #expect(Set(stored.keys) == ["typingRT.requestyModelID"])
        #expect(!String(describing: stored).contains("synthetic-unit-test-value"))
        await settings.deleteKey()
        #expect(!settings.canUseCoding)
        let restarted = RequestySettings(preferences: prefs, credentials: credentials, client: client, cacheURL: root.appendingPathComponent("cache.json"))
        await restarted.load()
        #expect(restarted.credentialState == .missing)
        #expect(await client.calls == 0)
    }

    @Test func keychainFailureHasNoPlaintextFallback() async throws {
        let (root, defaults, suite, prefs) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let credentials = CredentialsDouble()
        await credentials.setFailure()
        let settings = RequestySettings(preferences: prefs, credentials: credentials, client: CatalogDouble(), cacheURL: root.appendingPathComponent("cache.json"))
        await settings.load()
        #expect(settings.credentialState == .unavailable)
        settings.editor.keyDraft = "synthetic-unit-test-value"
        await settings.saveKey()
        #expect(settings.errorMessage != nil)
        #expect(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func explicitConnectionCachesMinimalMetadataAndOfflineSelectionSurvives() async throws {
        let (root, defaults, suite, prefs) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let credentials = CredentialsDouble("synthetic-unit-test-value")
        let client = CatalogDouble()
        let cache = root.appendingPathComponent("cache.json")
        let settings = RequestySettings(preferences: prefs, credentials: credentials, client: client, cacheURL: cache)
        await settings.load()
        #expect(await client.calls == 0)
        await settings.checkConnection()
        #expect(settings.catalog?.models.count == 1)
        #expect(!settings.catalogIsCached)
        settings.selectModel("example/test-model")
        let raw = try String(contentsOf: cache, encoding: .utf8)
        #expect(!raw.contains("synthetic-unit-test-value"))
        let restarted = RequestySettings(preferences: PreferencesStore(defaults: defaults), credentials: credentials, client: client, cacheURL: cache)
        await restarted.load()
        #expect(restarted.catalogIsCached)
        #expect(restarted.catalog == settings.catalog)
        #expect(restarted.preferences.requestyModelID == "example/test-model")
        #expect(await client.calls == 1)
        restarted.editor.search = "missing"
        #expect(restarted.visibleModels.isEmpty)
        restarted.selectModel(" ")
        #expect(restarted.preferences.requestyModelID == "example/test-model")
    }

    @Test func cancellationDiscardsLateNetworkResponseAndDoesNotCacheIt() async throws {
        let (root, defaults, suite, prefs) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let client = CatalogDouble()
        await client.block()
        let settings = RequestySettings(preferences: prefs, credentials: CredentialsDouble("synthetic-unit-test-value"), client: client, cacheURL: root.appendingPathComponent("cache.json"))
        let task = Task { await settings.checkConnection() }
        for _ in 0..<1000 { if await client.waiting() { break }; await Task.yield() }
        #expect(await client.waiting())
        settings.cancel()
        await client.release()
        await task.value
        #expect(settings.catalog == nil)
        #expect(!settings.isWorking)
        #expect(!FileManager.default.fileExists(atPath: root.path))
    }

    @Test func standardNeedsNeitherCredentialsNorRequestyAndSnapshotRetainsModel() async throws {
        let (root, defaults, suite, prefs) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let credentials = CredentialsDouble()
        let client = CatalogDouble()
        let settings = RequestySettings(preferences: prefs, credentials: credentials, client: client, cacheURL: root.appendingPathComponent("cache.json"))
        let app = AppModel(preferences: prefs, nativeMonitoringEnabled: false, dictionaryURL: root.appendingPathComponent("dict.sqlite"), snippetsURL: root.appendingPathComponent("snip.sqlite"), requesty: settings)
        #expect(app.selectedMode == .standard)
        #expect(await credentials.reads == 0)
        #expect(await client.calls == 0)
        #expect(!settings.canUseCoding)
        let sessions = SessionCoordinator()
        sessions.seedKeyState(isPressed: false)
        let ready = Readiness(microphoneGranted: true, accessibilityGranted: true, hotkeyAvailable: true, modelInstalled: true)
        settings.selectModel("example/first")
        _ = sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding, requestyModelID: prefs.requestyModelID)
        settings.selectModel("example/second")
        #expect(sessions.activeSession?.requestyModelID == "example/first")
        #expect(DictationSnapshot(id: UUID(), mode: .standard, requestyModelID: "example/first").requestyModelID == nil)
        app.shutDown()
        await app.finishShutdown()
    }

    @Test func persistedCodingAndExplicitCodingChoiceRestoreWithoutOpeningSettings() async throws {
        let (root, defaults, suite, prefs) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let client = CatalogDouble()
        let credentials = CredentialsDouble("synthetic-unit-test-value")
        prefs.selectedMode = .coding
        prefs.selectRequestyModel("example/test")
        let settings = RequestySettings(preferences: prefs, credentials: credentials, client: client, cacheURL: root.appendingPathComponent("cache.json"))
        let app = AppModel(preferences: prefs, nativeMonitoringEnabled: false, dictionaryURL: root.appendingPathComponent("dict.sqlite"), snippetsURL: root.appendingPathComponent("snip.sqlite"), requesty: settings)
        for _ in 0..<1000 { if settings.canUseCoding { break }; await Task.yield() }
        #expect(settings.canUseCoding)
        #expect(await credentials.reads == 1)
        #expect(await client.calls == 0)
        app.shutDown()
        await app.finishShutdown()
        prefs.selectedMode = .standard
        let next = RequestySettings(preferences: prefs, credentials: credentials, client: client, cacheURL: root.appendingPathComponent("cache.json"))
        let second = AppModel(preferences: prefs, nativeMonitoringEnabled: false, dictionaryURL: root.appendingPathComponent("dict.sqlite"), snippetsURL: root.appendingPathComponent("snip.sqlite"), requesty: next)
        #expect(next.credentialState == .unknown)
        second.selectedMode = .coding
        for _ in 0..<1000 { if next.canUseCoding { break }; await Task.yield() }
        #expect(next.canUseCoding)
        #expect(await credentials.reads == 2)
        second.shutDown()
        await second.finishShutdown()
    }

    @Test func viewTaskCancellationDoesNotPoisonOwnedCredentialLoad() async throws {
        let (root, defaults, suite, prefs) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let credentials = CredentialsDouble("synthetic-unit-test-value")
        await credentials.blockRead()
        let settings = RequestySettings(preferences: prefs, credentials: credentials, client: CatalogDouble(), cacheURL: root.appendingPathComponent("cache.json"))
        let viewTask = Task { await settings.load() }
        for _ in 0..<1000 { if await credentials.isWaiting() { break }; await Task.yield() }
        #expect(await credentials.isWaiting())
        viewTask.cancel()
        let reopenedView = Task { await settings.load() }
        await credentials.releaseRead()
        await viewTask.value
        await reopenedView.value
        #expect(settings.credentialState == .stored)
        #expect(settings.errorMessage == nil)
        #expect(await credentials.reads == 1)
    }

    @Test func malformedOrOversizedCacheFailsWithoutNetwork() async throws {
        let (root, defaults, suite, prefs) = try fixture()
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cache = root.appendingPathComponent("cache.json")
        try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(to: cache)
        let client = CatalogDouble()
        let settings = RequestySettings(preferences: prefs, credentials: CredentialsDouble(), client: client, cacheURL: cache)
        await settings.load()
        #expect(settings.catalog == nil)
        #expect(settings.errorMessage != nil)
        #expect(settings.credentialState == .missing)
        #expect(await client.calls == 0)
    }
}
