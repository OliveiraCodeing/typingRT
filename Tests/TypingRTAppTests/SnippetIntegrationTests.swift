import Foundation
import Testing
@testable import TypingRTCore
@testable import TypingRTApp

@Suite(.timeLimit(.minutes(1))) @MainActor
struct SnippetIntegrationTests {
    @Test func rawCallsSurviveDictionaryAndCleanerWithoutTemplateReprocessing() async throws {
        let template = "Ähm, Snippet Signatur\r\nNext js; $HOME\n  Genau SO.  "
        let snippets = try SnippetSnapshot(entries: [SnippetEntry(name: "Signatur", trigger: "ähm", aliases: ["Signatur"], template: template)])
        let dictionary = try DictionarySnapshot(entries: [DictionaryEntry(canonical: "Changed", aliases: ["Snippet", "Signatur", "Next js"], isProtected: false)])
        let raw = "Ähm, Snippet Signatur und snippet ähm."
        let result = try await process(raw, mode: .standard, dictionary: dictionary, snippets: snippets)
        #expect(result.rawText == raw)
        #expect(result.cleanedText == template + " und " + template + ".")
    }
    @Test func dictionaryCannotCreateNewCallsAndCodingNeverUsesSnippetCollection() async throws {
        let snippets = try SnippetSnapshot(entries: [SnippetEntry(name: "Privat", trigger: "Signatur", template: "PRIVATE TEMPLATE")])
        let dictionary = try DictionarySnapshot(entries: [DictionaryEntry(canonical: "Snippet Signatur", aliases: ["Zauberwort"], isProtected: false)])
        #expect(try await process("Zauberwort", mode: .standard, dictionary: dictionary, snippets: snippets).cleanedText == "Snippet Signatur")
        let coding = DictationSnapshot(id: UUID(), mode: .coding, snippets: snippets)
        #expect(coding.snippets == .empty)
        let result = try await process("Snippet Signatur", mode: .coding, dictionary: dictionary, snippets: snippets)
        #expect(result.cleanedText == "Snippet Signatur")
    }
    @Test func corruptProcessingMarkersFailWithoutResultOrFatalWorkerState() async throws {
        let snippets = try SnippetSnapshot(entries: [SnippetEntry(name: "Test", trigger: "Test", template: "Must never insert")])
        let pipeline = TranscriptionPipeline(worker: SnippetWorker(text: "Snippet Test"), clean: { _ in "changed" })
        var recovered = false
        var fatal = false
        pipeline.onRecoverableFailure = { _, _ in recovered = true }
        pipeline.onFailure = { _, _ in fatal = true }
        let session = DictationSnapshot(id: UUID(), mode: .standard, snippets: snippets)
        pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        pipeline.consume(try audio(session.id))
        while !recovered && !fatal { await Task.yield() }
        #expect(recovered && !fatal)
        #expect(pipeline.result == nil)
        await pipeline.finishShutdown()
    }
    @Test func libraryPersistsAndCaptureUsesStartVersionDespiteLaterEdit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-library-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = SnippetLibrary(url: root.appendingPathComponent("snippets.sqlite"))
        await library.load()
        #expect(await library.save(id: nil, name: "Signatur", trigger: "Signatur", aliases: [], template: "ALT\nText"))
        let sessions = SessionCoordinator()
        sessions.seedKeyState(isPressed: false)
        let ready = Readiness(microphoneGranted: true, accessibilityGranted: true, hotkeyAvailable: true, modelInstalled: true)
        _ = sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: .standard, snippets: library.snapshot)
        let start = try #require(sessions.activeSession)
        let id = try #require(library.snapshot.entries.first?.id)
        library.editor.edit(library.snapshot.entries.first)
        library.editor.template = "Entwurf"
        _ = SnippetView(library: library); _ = SnippetView(library: library)
        #expect(library.editor.template == "Entwurf")
        #expect(await library.save(id: id, name: "Signatur", trigger: "Signatur", aliases: [], template: "NEU"))
        let protected = try start.snippets.protectCalls(in: "Snippet Signatur")
        #expect(try protected.expand(in: protected.text) == "ALT\nText")
        #expect(!(await library.save(id: nil, name: "", trigger: "X", aliases: [], template: "X")))
        #expect(library.fieldError == "name")
        let export = root.appendingPathComponent("backup.json")
        await library.exportFile(export)
        let other = SnippetLibrary(url: root.appendingPathComponent("other.sqlite"))
        await other.load(); await other.importFile(export)
        #expect(other.snapshot.entries == library.snapshot.entries)
        let before = other.snapshot
        await other.importFile(export)
        #expect(other.errorMessage != nil && other.snapshot == before)
        let restarted = SnippetLibrary(url: root.appendingPathComponent("other.sqlite"))
        await restarted.load()
        #expect(restarted.snapshot.entries == before.entries)
        #expect(await other.delete(id: id))
        #expect(other.snapshot.entries.isEmpty)
    }
    private func process(_ text: String, mode: DictationMode, dictionary: DictionarySnapshot, snippets: SnippetSnapshot) async throws -> LocalTranscript {
        let worker = SnippetWorker(text: text)
        let pipeline = TranscriptionPipeline(worker: worker)
        var done = false
        var failed = false
        pipeline.onFinished = { _, _ in done = true }
        pipeline.onFailure = { _, _ in failed = true }
        pipeline.onRecoverableFailure = { _, _ in failed = true }
        let session = DictationSnapshot(id: UUID(), mode: mode, dictionary: dictionary, snippets: snippets)
        pipeline.start(session: session, modelURL: URL(fileURLWithPath: "/model"), tokenizerURL: URL(fileURLWithPath: "/tokenizer"))
        let capture = try audio(session.id)
        pipeline.consume(capture); pipeline.consume(capture)
        while !done && !failed { await Task.yield() }
        #expect(!failed)
        #expect(worker.calls == 1)
        #expect(worker.terms == dictionary.entries.map(\.canonical))
        let result = try #require(pipeline.result)
        await pipeline.finishShutdown()
        return result
    }
    private func audio(_ id: UUID) throws -> CapturedAudio {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("snippet-test-\(UUID()).wav")
        try Data().write(to: url)
        return CapturedAudio(sessionID: id, url: url, duration: 1, frames: 16000, sampleRate: 16000)
    }
}
@MainActor private final class SnippetWorker: TranscriptionWorkerClient {
    var onDisconnection: (() -> Void)?
    let text: String
    var calls = 0
    var terms: [String] = []
    init(text: String) { self.text = text }
    func prepare(_ request: WorkerRequest) async throws -> WorkerReply {
        terms = request.canonicalTerms
        return reply(request.sessionID)
    }
    func transcribe(_ request: WorkerRequest) async throws -> WorkerReply {
        calls += 1; terms = request.canonicalTerms
        return reply(request.sessionID)
    }
    func cancel(sessionID: UUID?) {}
    private func reply(_ id: UUID) -> WorkerReply { WorkerReply(sessionID: id, text: text, error: nil, loadSeconds: 0, inferenceSeconds: 0) }
}
