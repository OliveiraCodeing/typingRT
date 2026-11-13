import Testing
@testable import TypingRTCore

@Suite struct TerminalPasteTests {
    @Test(arguments: [
        ("eins\nzwei", "eins zwei"),
        ("rm -rf x\r\n", "rm -rf x"),
        ("a\n\n\nb", "a b"),
        ("a \n b", "a  b"),
        ("tab\tcompletion", "tab completion"),
        ("zeile\u{2028}absatz\u{2029}nel\u{85}ende", "zeile absatz nel ende"),
        ("\n\nnur text\n", "nur text"),
        ("c1\u{9B}201~ende\u{9D}", "c1201~ende"),
        ("unverändert ä ⌥ 🙂", "unverändert ä ⌥ 🙂")
    ])
    func neverLeavesALineBreakOrTab(input: String, expected: String) {
        let output = TerminalPaste.singleLine(input)
        #expect(output == expected)
        #expect(!output.unicodeScalars.contains { $0 == "\n" || $0 == "\r" || $0 == "\t" || $0 == "\u{2028}" || $0 == "\u{2029}" || $0 == "\u{85}" })
    }
}
