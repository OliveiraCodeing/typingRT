import Foundation
import Testing
@testable import TypingRTCore
@testable import TypingRTApp

@MainActor struct DictionaryLibraryTests {
    @Test func committedSnapshotsAndEditorSurviveViewUpdatesAndFailedSave() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-library-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DictionaryLibrary(url: root.appendingPathComponent("dictionary.sqlite"))
        #expect(!library.isLoaded)
        await library.load()
        #expect(library.isLoaded)
        #expect(await library.save(id: nil, canonical: "Supabase", aliases: ["Supa Base"], isProtected: true))
        let before = library.snapshot
        library.editor.edit(before.entries.first)
        library.editor.canonical = "Unfertiger Entwurf"
        _ = DictionaryView(library: library)
        _ = DictionaryView(library: library)
        #expect(library.editor.showingEditor)
        #expect(library.editor.canonical == "Unfertiger Entwurf")
        #expect(!(await library.save(id: nil, canonical: "Other", aliases: ["supa base"], isProtected: false)))
        #expect(library.errorMessage != nil)
        #expect(library.snapshot == before)
        let restarted = DictionaryLibrary(url: root.appendingPathComponent("dictionary.sqlite"))
        await restarted.load()
        #expect(restarted.snapshot.entries == before.entries)
        #expect(await library.delete(id: before.entries[0].id))
        #expect(library.snapshot.entries.isEmpty)
    }

    @Test func captureOwnsStartDictionaryDespiteLaterLibraryCommit() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-library-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let library = DictionaryLibrary(url: root.appendingPathComponent("dictionary.sqlite"))
        await library.load()
        #expect(await library.save(id: nil, canonical: "Supabase", aliases: ["Supa Base"], isProtected: false))
        let sessions = SessionCoordinator()
        sessions.seedKeyState(isPressed: false)
        let ready = Readiness(microphoneGranted: true, accessibilityGranted: true, hotkeyAvailable: true, modelInstalled: true)
        _ = sessions.handleRightOption(isPressed: true, readiness: ready, selectedMode: .coding, dictionary: library.snapshot)
        let start = try #require(sessions.activeSession)
        let entry = library.snapshot.entries[0]
        #expect(await library.save(id: entry.id, canonical: "NewName", aliases: ["Supa Base"], isProtected: false))
        #expect(start.dictionary.apply(to: "Supa Base").text == "Supabase")
        #expect(library.snapshot.apply(to: "Supa Base").text == "NewName")
        #expect(start.dictionary.revision != library.snapshot.revision)
        let transcript = LocalTranscript(session: start, rawText: "", cleanedText: "", loadSeconds: 0, inferenceSeconds: 0,
            relevantCanonicalSpellings: ["Next.js"], protectedCanonicalSpellings: ["Next.js"])
        #expect(transcript.preservesProtectedNames(in: "Use Next.js with next.js examples."))
        #expect(!transcript.preservesProtectedNames(in: "Use NextJS."))
    }
}
