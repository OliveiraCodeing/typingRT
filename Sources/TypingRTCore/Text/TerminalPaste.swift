import Foundation

/// Text handed to a terminal must never be able to submit a command line.
/// Line breaks and tabs (shell completion) are collapsed to single spaces and
/// C1 control characters (8-bit terminal sequences) are dropped, so a paste
/// can only ever add characters to the current input line.
public enum TerminalPaste {
    public static func singleLine(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in text.unicodeScalars {
            if CharacterSet.newlines.contains(scalar) || scalar == "\t" {
                pendingSpace = true
                continue
            }
            if (0x80...0x9F).contains(scalar.value) { continue }
            if pendingSpace && !result.isEmpty && result.last != " " && scalar != " " { result.append(" ") }
            pendingSpace = false
            result.append(scalar)
        }
        return String(result).trimmingCharacters(in: .whitespaces)
    }
}
