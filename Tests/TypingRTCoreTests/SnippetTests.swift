import Foundation
import Testing
@testable import TypingRTCore

@Suite struct SnippetTests {
    private func entry(_ trigger: String = "Signatur", template: String = "Viele Grüße\nTest") throws -> SnippetEntry {
        try SnippetEntry(name: "Meine Signatur", trigger: trigger, aliases: ["Unterschrift"], template: template)
    }
    @Test func validationAndExactTemplate() throws {
        let text = "  Gruß\r\n\tÄhm, Snippet Anderes 🙂\n  "
        let value = try SnippetEntry(name: " Name ", trigger: " Gruß ", aliases: ["GRUSS", " gruss ", "Gruß"], template: text)
        #expect(value.template == text)
        #expect(value.name == "Name")
        #expect(value.aliases.isEmpty)
        #expect(value.matches(search: "NAME"))
        #expect(value.matches(search: "gruss"))
        #expect(!value.matches(search: "unbekannt"))
        for invalid in ["", "  ", "a\nb", "a\0b", String(repeating: "x", count: 257)] {
            #expect(throws: SnippetError.invalidName) { try SnippetEntry(name: invalid, trigger: "a", template: "a") }
            #expect(throws: SnippetError.invalidTrigger) { try SnippetEntry(name: "a", trigger: invalid, template: "a") }
            #expect(throws: SnippetError.invalidAliases) { try SnippetEntry(name: "a", trigger: "a", aliases: [invalid], template: "a") }
        }
        for invalid in ["", " \n\t ", "a\0b", String(repeating: "x", count: 65_537)] {
            #expect(throws: SnippetError.invalidTemplate) { try SnippetEntry(name: "a", trigger: "a", template: invalid) }
        }
    }
    @Test func detectsNormalizedAndAmbiguousPrefixConflicts() throws {
        let first = try entry()
        for trigger in ["SIGNATUR", "Signatur geschäftlich", "Unterschrift lang", "Signatur.", "Signatur!", "Signatur: fertig"] {
            #expect(throws: SnippetError.self) { try SnippetSnapshot(entries: [first, SnippetEntry(name: "Other", trigger: trigger, template: "Other")]) }
        }
        #expect(throws: SnippetError.self) { try SnippetSnapshot(entries: [first, first]) }
        _ = try SnippetSnapshot(entries: [first, SnippetEntry(name: "Other", trigger: "Signaturen", template: "Other")])
        _ = try SnippetSnapshot(entries: [SnippetEntry(name: "One", trigger: "Sign", aliases: ["Sign now"], template: "One")])
    }
    @Test func explicitCaseInsensitiveCallsAndOuterPunctuation() throws {
        let snapshot = try SnippetSnapshot(entries: [entry()])
        for (raw, expected) in [("Snippet Signatur", "Viele Grüße\nTest"), ("SNIPPET SIGNATUR", "Viele Grüße\nTest"), ("snippet\t  Unterschrift", "Viele Grüße\nTest"), ("Snippet Signatur!", "Viele Grüße\nTest!"), ("(Snippet Signatur)", "(Viele Grüße\nTest)"), ("'Snippet Signatur'", "'Viele Grüße\nTest'"), ("Snippet Signatur: fertig", "Viele Grüße\nTest: fertig")] {
            let plan = try snapshot.protectCalls(in: raw)
            #expect(plan.callCount == 1)
            #expect(try plan.expand(in: plan.text) == expected)
        }
        let plan = try snapshot.protectCalls(in: "🙂 (SNIPPET Unterschrift), weiter.")
        #expect(try plan.expand(in: plan.text) == "🙂 (Viele Grüße\nTest), weiter.")
    }
    @Test func unknownBareAndEmbeddedCallsRemainOrdinaryText() throws {
        let snapshot = try SnippetSnapshot(entries: [entry()])
        for raw in ["Signatur", "Snippet Unbekannt", "XSnippet Signatur", "/Snippet Signatur", "foo.Snippet Signatur", "Snippet SignaturX", "Snippet Signatur-dev", "Snippet Signatur.swift", "Snippet\nSignatur", "Snippet Signatur's", "Snippet Signatur:port"] {
            let plan = try snapshot.protectCalls(in: raw)
            #expect(plan.callCount == 0)
            #expect(try plan.expand(in: plan.text) == raw)
        }
    }
    @Test func unicodeCompositionAndWholeGraphemes() throws {
        let snapshot = try SnippetSnapshot(entries: [SnippetEntry(name: "Ü", trigger: "Müller", template: "Exact")])
        let plan = try snapshot.protectCalls(in: "Snippet MU\u{0308}LLER")
        #expect(try plan.expand(in: plan.text) == "Exact")
        let one = try SnippetSnapshot(entries: [SnippetEntry(name: "S", trigger: "s", template: "S")])
        #expect(try one.protectCalls(in: "Snippet ß").callCount == 0)
    }
    @Test func dictionaryAndCleanerCannotModifyProtectedCallsOrTemplates() throws {
        let template = "Ähm,\nSnippet Signatur\nNext JS \t"
        let snippets = try SnippetSnapshot(entries: [entry(template: template)])
        let dictionary = try DictionarySnapshot(entries: [DictionaryEntry(canonical: "Changed", aliases: ["Signatur", "Snippet", "Next JS"])])
        let plan = try snippets.protectCalls(in: "Ähm, Snippet Signatur und Next JS.")
        let application = dictionary.apply(to: plan.text, protecting: plan.protectedRanges)
        let clean = ConservativeTextCleaner.clean(application.text, protecting: application.protectedRanges)
        #expect(try plan.expand(in: clean) == template + " und Changed.")
    }
    @Test func multipleCallsExpandOnceWithoutRecursionAndSnapshotsStayImmutable() throws {
        let first = try entry(template: "Snippet Signatur\nOriginal")
        let old = try SnippetSnapshot(entries: [first])
        let edited = try SnippetSnapshot(entries: [SnippetEntry(id: first.id, name: first.name, trigger: first.trigger, template: "New")])
        let plan = try old.protectCalls(in: "Snippet Signatur; Snippet Signatur")
        #expect(plan.callCount == 2)
        #expect(try plan.expand(in: plan.text) == "Snippet Signatur\nOriginal; Snippet Signatur\nOriginal")
        let updated = try edited.protectCalls(in: "Snippet Signatur")
        #expect(try updated.expand(in: updated.text) == "New")
        #expect(throws: SnippetError.invalidProcessing) { try plan.expand(in: updated.text) }
    }
    @Test func opaqueMarkersFailClosedOnMissingOrDuplicateAndDoNotConsumeRawMarkers() throws {
        let rawMarker = "\u{E000}fake:0\u{E001}"
        let plan = try SnippetSnapshot(entries: [entry()]).protectCalls(in: rawMarker + " Snippet Signatur")
        #expect(try plan.expand(in: plan.text) == rawMarker + " Viele Grüße\nTest")
        let marker = (plan.text as NSString).substring(with: plan.protectedRanges[0])
        #expect(throws: SnippetError.invalidProcessing) { try plan.expand(in: plan.text.replacingOccurrences(of: marker, with: "")) }
        #expect(throws: SnippetError.invalidProcessing) { try plan.expand(in: plan.text + marker) }
    }
    @Test func thousandsOfCallsUseOneProtectionAndExpansionPass() throws {
        let snapshot = try SnippetSnapshot(entries: [SnippetEntry(name: "A", trigger: "A", template: "X")])
        for count in [1_000, 8_000] {
            let raw = Array(repeating: "Snippet A", count: count).joined(separator: " ")
            let plan = try snapshot.protectCalls(in: raw)
            #expect(plan.callCount == count)
            #expect(try plan.expand(in: plan.text) == Array(repeating: "X", count: count).joined(separator: " "))
        }
    }
    @Test func boundedInputsAndExpandedOutput() throws {
        let snapshot = try SnippetSnapshot(entries: [entry(template: String(repeating: "x", count: 65_536))])
        #expect(throws: SnippetError.tooLarge) { try snapshot.protectCalls(in: String(repeating: "x", count: 1_048_577)) }
        let plan = try snapshot.protectCalls(in: Array(repeating: "Snippet Signatur", count: 17).joined(separator: " "))
        #expect(throws: SnippetError.tooLarge) { try plan.expand(in: plan.text) }
    }
}
