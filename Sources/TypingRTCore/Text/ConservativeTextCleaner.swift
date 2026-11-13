import Foundation

/// A deterministic ASR-stage transform. Never run this on expanded templates.
/// Protection ranges use UTF-16 offsets in this exact input, as NSRegularExpression does.
public enum ConservativeTextCleaner {
    private static let fillers = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{M}\p{N}_/\\@'’+:#\-])(?<![\p{L}\p{M}\p{N}_]\.)(?:ähm|äh|a\u0308hm|a\u0308h)(?![\p{L}\p{M}\p{N}_/\\@'’+:#\-])(?!\.[\p{L}\p{M}\p{N}_])"#,
        options: .caseInsensitive)
    private static let literals = try! NSRegularExpression(
        pattern: #"`+[^`]*`+|"[^"\r\n]*"|„[^“\r\n]*“|“[^”\r\n]*”|«[^»\r\n]*»"#)
    private static let lines = try! NSRegularExpression(pattern: #"[^\r\n\u2028\u2029]+"#)

    public static func clean(_ text: String, protecting ranges: [NSRange] = []) -> String {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        // Stale/malformed protection must fail closed rather than damage a name.
        if !ranges.isEmpty {
            var boundaries: Set<Int> = [0]
            var offset = 0
            for character in text { offset += character.utf16.count; boundaries.insert(offset) }
            guard ranges.allSatisfy({ range in
                range.location >= 0 && range.location <= source.length && range.length >= 0 &&
                range.length <= source.length - range.location &&
                boundaries.contains(range.location) && boundaries.contains(NSMaxRange(range))
            }) else { return text }
        }
        var protected = [Bool](repeating: false, count: source.length)
        for range in ranges + literals.matches(in: text, range: whole).map(\.range) {
            for offset in range.location..<NSMaxRange(range) { protected[offset] = true }
        }
        let matches = fillers.matches(in: text, range: whole).map(\.range).filter {
            !protected[$0.location..<NSMaxRange($0)].contains(true)
        }
        guard !matches.isEmpty else { return text }
        let units = Array(text.utf16)
        var removed = [Bool](repeating: false, count: units.count)
        var capitalizedStarts: Set<Int> = []
        for range in matches { for i in range.location..<NSMaxRange(range) { removed[i] = true } }

        var matchIndex = 0
        for line in lines.matches(in: text, range: whole).map(\.range) {
            let start = line.location, end = NSMaxRange(line)
            guard removed[start..<end].contains(true) else { continue }
            let firstMatch = matchIndex
            while matchIndex < matches.count && matches[matchIndex].location < end { matchIndex += 1 }
            let lineMatches = matches[firstMatch..<matchIndex]
            for match in lineMatches {
                var right = NSMaxRange(match)
                while right < end && isSpace(units[right]) && !protected[right] { right += 1 }
                if right < end && units[right] == 44 && !protected[right] {
                    right += 1
                    while right < end && isSpace(units[right]) && !protected[right] { right += 1 }
                }
                for i in NSMaxRange(match)..<right { removed[i] = true }

                // Before a stop/semicolon/end, no space or comma should dangle.
                if right == end || isStop(units[right]) || units[right] == 59 {
                    var left = match.location
                    while left > start && (removed[left - 1] || isSpace(units[left - 1])) && !protected[left - 1] { left -= 1 }
                    if left > start && units[left - 1] == 44 && !protected[left - 1] { left -= 1 }
                    for i in left..<match.location { removed[i] = true }
                    // "Hallo. Ähm. Weiter" keeps the original sentence stop once.
                    if right < end && isStop(units[right]), left > start && isStop(units[left - 1]) && !protected[right] {
                        var after = right
                        while after < end && isStop(units[after]) && !protected[after] { removed[after] = true; after += 1 }
                        while after < end && isSpace(units[after]) && !protected[after] { removed[after] = true; after += 1 }
                        // Retain one original separator between the surviving words.
                        if left < match.location { removed[left] = false }
                    }
                }
            }

            // Remove empty bracket pairs only when their contents were removed here.
            var brackets: [Int] = []
            for i in start..<end where !protected[i] {
                if [40, 91, 123].contains(units[i]) { brackets.append(i) }
                else if let opening = brackets.last, paired(units[opening], units[i]) {
                    brackets.removeLast()
                    let inside = (opening + 1)..<i
                    if inside.contains(where: { removed[$0] }) && inside.allSatisfy({ !protected[$0] && (removed[$0] || isSpace(units[$0]) || isPunctuation(units[$0])) }) {
                        for j in opening...i { removed[j] = true }
                    }
                }
            }

            var cursor = start
            while cursor < end {
                guard removed[cursor] else { cursor += 1; continue }
                let beginning = cursor
                while cursor < end && removed[cursor] { cursor += 1 }
                var right = cursor
                while right < end && isSpace(units[right]) && !protected[right] { right += 1 }
                var left = beginning
                while left > start && isSpace(units[left - 1]) && !protected[left - 1] { left -= 1 }
                if left > start && units[left - 1] == 44 && !protected[left - 1],
                   right == end || closesPhrase(units[right]) {
                    // Empty parentheticals can expose a second comma or stop.
                    for i in (left - 1)..<beginning { removed[i] = true }
                }
                if beginning > start && isSpace(units[beginning - 1]) {
                    for i in cursor..<right { removed[i] = true }
                    if right == end || closesPhrase(units[right]) {
                        var left = beginning
                        while left > start && isSpace(units[left - 1]) && !protected[left - 1] { left -= 1 }
                        for i in left..<beginning { removed[i] = true }
                    }
                }
                cursor = right
            }

            // Clear only orphan punctuation at a changed line's start, never a list marker.
            var first = start
            while first < end && (removed[first] || isSpace(units[first]) || [44, 59, 46, 33, 63, 8230].contains(units[first])) && !protected[first] { first += 1 }
            if removed[start..<first].contains(true) {
                for i in start..<first { removed[i] = true }
                // Deliberately narrow: don't uppercase iOS, npm, eBay or identifiers.
                if first + 5 <= end, source.substring(with: NSRange(location: first, length: 5)) == "bitte",
                   (first + 5 == end || isSpace(units[first + 5])),
                   !protected[first..<(first + 5)].contains(true) {
                    // Applied while rebuilding below; no source offsets are shifted.
                    capitalizedStarts.insert(first)
                }
            }
            let survives = (start..<end).contains { !removed[$0] && (protected[$0] || (!isSpace(units[$0]) && !isPunctuation(units[$0]))) }
            if !survives { for i in start..<end where !protected[i] { removed[i] = true } }
        }
        var output: [UInt16] = []
        output.reserveCapacity(units.count)
        for i in units.indices where !removed[i] { output.append(capitalizedStarts.contains(i) ? 66 : units[i]) }
        let result = String(decoding: output, as: UTF16.self)
        return result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : result
    }

    private static func isSpace(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.whitespaces.contains(scalar)
    }
    private static func isStop(_ unit: UInt16) -> Bool { [46, 33, 63, 8230].contains(unit) }
    private static func closesPhrase(_ unit: UInt16) -> Bool { [44, 46, 59, 58, 33, 63, 41, 93, 125, 8230].contains(unit) }
    private static func isPunctuation(_ unit: UInt16) -> Bool {
        guard let scalar = UnicodeScalar(unit) else { return false }
        return CharacterSet.punctuationCharacters.contains(scalar)
    }
    private static func paired(_ opening: UInt16, _ closing: UInt16) -> Bool {
        (opening == 40 && closing == 41) || (opening == 91 && closing == 93) || (opening == 123 && closing == 125)
    }
}
