import Foundation
import Testing
@testable import TypingRTCore
@testable import TypingRTApp

@Suite(.timeLimit(.minutes(1))) @MainActor
struct CodingIntegrationTests {
    @Test func capturedLimitsAndDictionarySurvivePreferenceChangesAndOneHandoff() async throws {
        let defaults = try #require(UserDefaults(suiteName: "coding-integration-\(UUID())"))
        let preferences = PreferencesStore(defaults: defaults)
        let client = IntegrationRequesty()
        let coding = CodingPipeline(credentials: IntegrationCredentials(), client: client)
        let insertion = IntegrationInsertion()
        let delivery = TextDelivery(client: insertion)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coding-integration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = AppModel(preferences: preferences, nativeMonitoringEnabled: false,
            dictionaryURL: root.appendingPathComponent("dictionary.sqlite"), snippetsURL: root.appendingPathComponent("snippets.sqlite"), coding: coding, delivery: delivery)
        let ready = Readiness(microphoneGranted: true, accessibilityGranted: true, hotkeyAvailable: true, modelInstalled: true)
        let metadata = RequestyModel(id: "fixture/original", contextWindow: 100_000, maxOutputTokens: 16_000)
        let dictionary = try DictionarySnapshot(entries: [DictionaryEntry(canonical: "UserStore", aliases: ["user store"], isProtected: true)])
        let snippets = try SnippetSnapshot(entries: [SnippetEntry(name: "Privat", trigger: "Signatur", template: "NEVER SEND TEMPLATE")])
        model.sessions.seedKeyState(isPressed: false)
        let id = try #require(model.sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding, dictionary: dictionary, snippets: snippets, requestyModelID: metadata.id, requestyModel: metadata))
        _ = model.sessions.handleRightOption(isPressed: false, readiness: ready, selectedMode: .standard)
        let snapshot = try #require(model.sessions.activeSession)
        #expect(snapshot.snippets == .empty)
        #expect(snapshot.requestyModel == metadata)
        #expect(DictationSnapshot(id: UUID(), mode: .standard, requestyModelID: metadata.id, requestyModel: metadata).requestyModel == nil)
        #expect(DictationSnapshot(id: UUID(), mode: .coding, requestyModelID: "different", requestyModel: metadata).requestyModel == nil)
        let transcript = LocalTranscript(session: snapshot, rawText: "Ähm, prüfe UserStore.", cleanedText: "Prüfe UserStore.", loadSeconds: 0, inferenceSeconds: 0.1, relevantCanonicalSpellings: ["UserStore"], protectedCanonicalSpellings: ["UserStore"])
        preferences.selectRequestyModel("fixture/changed")
        model.selectedMode = .standard
        delivery.start(sessionID: id)
        coding.start(transcript, model: transcript.requestyModel)
        coding.start(transcript, model: metadata)
        while delivery.phase != .awaitingResult { await Task.yield() }
        #expect(await client.calls == 1)
        #expect(await client.selectedModel == metadata.id)
        #expect(await insertion.texts == ["Check UserStore."])
        #expect(delivery.result?.requestyModel == metadata)
        #expect(delivery.result?.rawText == transcript.rawText)
        #expect(model.sessions.mayDeliver(sessionID: id))
        #expect(model.sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard) == nil)
        model.dictation.abort(message: "Verworfen")
        #expect(model.sessions.activeSession == nil && delivery.result == nil)
        await model.finishShutdown()
    }
}

private actor IntegrationCredentials: RequestyCredentialStoring {
    func read() async throws -> String? { "synthetic-fixture" }
    func save(_ value: String) async throws {}
    func delete() async throws {}
}
private actor IntegrationRequesty: RequestyServing {
    private(set) var calls = 0
    private(set) var selectedModel: String?
    func models(apiKey: String) async throws -> [RequestyModel] { [] }
    func complete(sessionID: UUID, modelID: String, system: String, text: String, maxOutputTokens: Int, apiKey: String) async throws -> RequestyCompletion {
        calls += 1; selectedModel = modelID
        #expect(!text.contains("NEVER SEND TEMPLATE"))
        return RequestyCompletion(sessionID: sessionID, text: "Check UserStore.")
    }
}
private actor IntegrationInsertion: TextInsertionClient {
    private(set) var texts: [String] = []
    func insert(_ text: String, cancellation: DeliveryCancellation) async -> TextDeliveryOutcome { texts.append(text); return .uncertain }
    func copy(_ text: String, cancellation: DeliveryCancellation) async -> Bool { false }
}
