import Foundation
import Testing
@testable import TypingRTCore

@Suite struct ConservativeTextCleanerTests {
    @Test(arguments: [
        ["Ähm, bitte prüfe den Login.", "Bitte prüfe den Login."],
        ["Bitte, ähm, prüfe den Login.", "Bitte, prüfe den Login."],
        ["Bitte ähm prüfe den Login.", "Bitte prüfe den Login."],
        ["Bitte ähm, prüfe den Login.", "Bitte prüfe den Login."],
        ["Hallo ähm.", "Hallo."],
        ["Hallo, ähm.", "Hallo."],
        ["Hallo. Ähm. Weiter.", "Hallo. Weiter."],
        ["Hallo. Ähm... Weiter.", "Hallo. Weiter."],
        ["Hallo (ähm) Welt", "Hallo Welt"],
        ["Hallo, (ähm).", "Hallo."],
        ["Hallo, (ähm), Welt", "Hallo, Welt"],
        ["Bitte ähm „Hallo“ sagen.", "Bitte „Hallo“ sagen."],
        ["Hallo ähm (bitte prüfen).", "Hallo (bitte prüfen)."],
        ["Äh, ähm …", ""],
        ["(ähm)", ""],
        ["ÄHM, ÄH!!!", ""],
        ["  ähm , äh ; …\n\n", ""],
        ["Erstens.\n\nÄhm, bitte zweitens.", "Erstens.\n\nBitte zweitens."],
        ["Erstens.\r\n\r\nÄhm, bitte zweitens.", "Erstens.\r\n\r\nBitte zweitens."],
        ["Nicht ähm 13, sondern 30 Einträge.", "Nicht 13, sondern 30 Einträge."],
        ["Ähm, iOS benötigt npm und eBay.", "iOS benötigt npm und eBay."],
        ["Ähm, bitte-helper benötigt bitte.swift.", "bitte-helper benötigt bitte.swift."],
        ["Prüfe ähm den refreshToken im API client.", "Prüfe den refreshToken im API client."],
        ["a\u{308}hm, bitte testen.", "Bitte testen."]
    ])
    func removesOnlyDocumentedFillers(_ example: [String]) {
        #expect(ConservativeTextCleaner.clean(example[0]) == example[1])
    }

    @Test(arguments: [
        "Das ist eigentlich richtig", "Also folgt daraus X", "Genau drei Einträge",
        "Bitte um Hilfe. Hm, eh klar.", "Nein, nein, doch nicht.",
        "Nicht 13, sondern 30 Einträge.", "  Ein Absatz.\n\n  Zweiter Absatz.  ",
        "ÄhmService ähm_count xähm ähm2 Ähms",
        "foo.ähm ähm.swift ähm-Adapter /ähm \\ähm +ähm ähm+",
        "https://ähm.example/test test@ähm.de", "l’ähm d'ähm", "foo::ähm #ähm",
        "Das Wort „ähm“ bleibt.", "Das Wort \"ähm\" bleibt.",
        "Das Wort «ähm» bleibt.", "Das Wort “ähm” bleibt.",
        "`ähm` und ```swift\nlet ähm = 42\n```", "🙂", "42", "", "\n\n"
    ])
    func preservesMeaningAndLiterals(_ text: String) {
        #expect(ConservativeTextCleaner.clean(text) == text)
    }

    @Test func protectsExactUTF16SpansIncludingEmojiOffsets() {
        let text = "🙂 Ähm, ähm, bitte prüfen."
        let range = (text as NSString).range(of: "Ähm")
        #expect(ConservativeTextCleaner.clean(text, protecting: [range]) == "🙂 Ähm, bitte prüfen.")
        #expect(ConservativeTextCleaner.clean("Ähm", protecting: [NSRange(location: 0, length: 3)]) == "Ähm")
        let template = "Ähm,   exakt!\n\näh, nicht ändern."
        #expect(ConservativeTextCleaner.clean(template, protecting: [NSRange(location: 0, length: (template as NSString).length)]) == template)
    }

    @Test func invalidProtectionFailsClosed() {
        #expect(ConservativeTextCleaner.clean("Ähm, bitte.", protecting: [NSRange(location: 99, length: 1)]) == "Ähm, bitte.")
        #expect(ConservativeTextCleaner.clean("🙂 ähm", protecting: [NSRange(location: 1, length: 1)]) == "🙂 ähm")
    }

    @Test func onlyChangedWhitespaceIsRepaired() {
        #expect(ConservativeTextCleaner.clean("Links  bleibt. Ähm, bitte  prüfen.") == "Links  bleibt. bitte  prüfen.")
        #expect(ConservativeTextCleaner.clean("\tÄhm, bitte prüfen.\n\nText  bleibt.") == "Bitte prüfen.\n\nText  bleibt.")
    }

    @Test func multiMinuteSizedTranscriptPreservesParagraphOrder() {
        let raw = String(repeating: "Ähm, bitte prüfe 42 API tokens, nicht 13.\n\n", count: 300)
        let expected = String(repeating: "Bitte prüfe 42 API tokens, nicht 13.\n\n", count: 300)
        #expect(ConservativeTextCleaner.clean(raw) == expected)
    }
}
