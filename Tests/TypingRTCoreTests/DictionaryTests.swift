import Foundation
import Testing
@testable import TypingRTCore

@Suite struct DictionaryTests {
    @Test func validatesSingleLineSpellingsAndDeduplicatesAliases() throws {
        let entry = try DictionaryEntry(canonical: " Next.js ", aliases: ["Next JS", " next   js ", "NEXT.JS"], isProtected: true)
        #expect(entry.canonical == "Next.js")
        #expect(entry.aliases == ["Next JS"])
        #expect(entry.isProtected)
        for invalid in ["", " \t ", "first\nsecond", "first\rsecond", "a\u{2028}b", "a\0b", String(repeating: "x", count: 257)] {
            #expect(throws: DictionaryError.invalidSpelling) { try DictionaryEntry(canonical: invalid) }
            #expect(throws: DictionaryError.invalidSpelling) { try DictionaryEntry(canonical: "Valid", aliases: [invalid]) }
        }
        #expect(throws: DictionaryError.tooManyAliases) { try DictionaryEntry(canonical: "Valid", aliases: Array(repeating: "Alias", count: 65)) }
    }

    @Test func rejectsAliasAndCanonicalCollisions() throws {
        let first = try DictionaryEntry(canonical: "Supabase", aliases: ["Supa Base"])
        let second = try DictionaryEntry(canonical: "Other", aliases: ["supa   BASE"])
        #expect(throws: DictionaryError.conflictingVariant(existingID: first.id)) {
            try DictionarySnapshot(entries: [first, second])
        }
        #expect(throws: DictionaryError.conflictingVariant(existingID: first.id)) {
            try DictionarySnapshot(entries: [first, DictionaryEntry(canonical: "SUPABASE")])
        }
        #expect(throws: DictionaryError.duplicateEntry) { try DictionarySnapshot(entries: [first, first]) }
    }

    @Test func longestMatchAndNoRecursiveReplacement() throws {
        let dictionary = try DictionarySnapshot(entries: [
            DictionaryEntry(canonical: "Supabase", aliases: ["Supa Base"]),
            DictionaryEntry(canonical: "Supabase Client", aliases: ["Supa Base Client"]),
            DictionaryEntry(canonical: "Next.js", aliases: ["Next JS"]),
            DictionaryEntry(canonical: "Final", aliases: ["Client"])
        ])
        #expect(dictionary.apply(to: "Nutze supa BASE client und Next   JS.").text == "Nutze Supabase Client und Next.js.")
    }

    @Test func preservesUnrelatedWordsAndTechnicalIdentifiers() throws {
        let dictionary = try DictionarySnapshot(entries: [
            DictionaryEntry(canonical: "Supabase", aliases: ["Supa Base"]),
            DictionaryEntry(canonical: "Next.js", aliases: ["Next JS"]),
            DictionaryEntry(canonical: "C++", aliases: ["C plus plus"]),
            DictionaryEntry(canonical: "Müller", aliases: ["Mueler"])
        ])
        let original = "XSupa Base Supa BaseX /Supa Base Supa Base-dev foo.Supa Base Supa Base.swift C+++ myNext.js"
        #expect(dictionary.apply(to: original).text == original)
        #expect(dictionary.apply(to: "(Supa Base), Next JS! C plus plus; Mueler.").text == "(Supabase), Next.js! C++; Müller.")
        #expect(dictionary.apply(to: "C++ und next.js").text == "C++ und Next.js")
        #expect(dictionary.apply(to: "Supa\nBase").text == "Supa\nBase")
        #expect(dictionary.apply(to: "MUE\u{006C}ER").text == "Müller")
    }

    @Test func sentenceColonsAndQuotesAreBoundariesButEmbeddedIdentifiersAreNot() throws {
        let dictionary = try DictionarySnapshot(entries: [DictionaryEntry(canonical: "Supabase", aliases: ["Supa Base"])])
        #expect(dictionary.apply(to: "Nutze Supa Base: fertig. 'Supa Base' und ’Supa Base’. ").text == "Nutze Supabase: fertig. 'Supabase' und ’Supabase’. ")
        let embedded = "prefix:Supa Base O'Supa Base Supa Base's Supa Base:port"
        #expect(dictionary.apply(to: embedded).text == embedded)
        #expect(DictionarySnapshot.containsExact("Next.js", in: "Use Next.js: keep it."))
        #expect(DictionarySnapshot.containsExact("Next.js", in: "Use 'Next.js'."))
        #expect(!DictionarySnapshot.containsExact("Next.js", in: "Use package:Next.js"))
    }

    @Test func handlesUnicodeCompositionAndWholeGraphemes() throws {
        let dictionary = try DictionarySnapshot(entries: [DictionaryEntry(canonical: "Müller"), DictionaryEntry(canonical: "Straße")])
        #expect(dictionary.apply(to: "MU\u{0308}LLER und STRASSE").text == "Müller und Straße")
        let single = try DictionarySnapshot(entries: [DictionaryEntry(canonical: "s", aliases: ["s"])])
        #expect(single.apply(to: "ß").text == "ß")
    }

    @Test func protectsSnippetSpansAndCanonicalNamesFromCleaning() throws {
        let dictionary = try DictionarySnapshot(entries: [
            DictionaryEntry(canonical: "Supabase", aliases: ["Supa Base"]),
            DictionaryEntry(canonical: "Ähm", aliases: ["Name"])
        ])
        let text = "🙂 Supa Base; Snippet Supa Base; Name, ähm, fertig."
        let protected = (text as NSString).range(of: "Snippet Supa Base")
        let application = dictionary.apply(to: text, protecting: [protected])
        #expect(application.text == "🙂 Supabase; Snippet Supa Base; Ähm, Ähm, fertig.")
        let cleaned = ConservativeTextCleaner.clean(application.text, protecting: application.protectedRanges)
        #expect(cleaned == "🙂 Supabase; Snippet Supa Base; Ähm, Ähm, fertig.")
        #expect(application.protectedRanges.contains { (application.text as NSString).substring(with: $0) == "Snippet Supa Base" })
        let malformed = dictionary.apply(to: text, protecting: [NSRange(location: 1, length: 1)])
        #expect(malformed.text == text)
        #expect(ConservativeTextCleaner.clean(malformed.text, protecting: malformed.protectedRanges) == text)
    }

    @Test func relevantCodingContextAndExactProtectedNameValidation() throws {
        let dictionary = try DictionarySnapshot(entries: [
            DictionaryEntry(canonical: "Next.js", aliases: ["Next JS"], isProtected: true),
            DictionaryEntry(canonical: "Supabase", aliases: ["Supa Base"]),
            DictionaryEntry(canonical: "Unused", isProtected: true)
        ])
        let application = dictionary.apply(to: "Nutze Next JS und Supa Base.")
        #expect(application.relevantCanonicalSpellings == ["Next.js", "Supabase"])
        #expect(application.protectedCanonicalSpellings == ["Next.js"])
        #expect(application.preservesProtectedNames(in: "Use Next.js with Supabase."))
        #expect(application.preservesProtectedNames(in: "Next.js uses next.js"))
        #expect(!application.preservesProtectedNames(in: "Use next.js with Supabase."))
        #expect(!application.preservesProtectedNames(in: "Use Nextjs with Supabase."))
        #expect(!application.preservesProtectedNames(in: "Use myNext.jsObject."))
        #expect(!application.preservesProtectedNames(in: "Use Next.js.ts."))
    }

    @Test func snapshotRemainsIndependentAndSearchesAliases() throws {
        let first = try DictionaryEntry(canonical: "Supabase", aliases: ["Supa Base"])
        let old = try DictionarySnapshot(entries: [first])
        let new = try DictionarySnapshot(entries: [DictionaryEntry(id: first.id, canonical: "NewName", aliases: ["Supa Base"])])
        #expect(old.apply(to: "Supa Base").text == "Supabase")
        #expect(new.apply(to: "Supa Base").text == "NewName")
        #expect(first.matches(search: "SUPA   BASE"))
        #expect(!first.matches(search: "unknown"))
    }

    @Test func largeListUsesDeterministicOrderAndHandlesLongTranscript() throws {
        let entries = try (0..<2_000).map { try DictionaryEntry(canonical: "Product\($0)", aliases: ["Produkt \($0)"]) }
        let forward = try DictionarySnapshot(entries: entries)
        let reverse = try DictionarySnapshot(entries: entries.reversed())
        #expect(forward.entries == reverse.entries)
        let raw = String(repeating: "Produkt 1999 und Produkt 42.\n", count: 300)
        #expect(forward.apply(to: raw).text == String(repeating: "Product1999 und Product42.\n", count: 300))
    }
}
