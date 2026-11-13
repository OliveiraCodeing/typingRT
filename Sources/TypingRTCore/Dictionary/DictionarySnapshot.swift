import Foundation

public struct DictionaryApplication: Sendable, Equatable {
    public let text: String
    /// UTF-16 ranges in `text`, to pass directly to the conservative cleaner.
    public let protectedRanges: [NSRange]
    public let relevantCanonicalSpellings: [String]
    public let protectedCanonicalSpellings: [String]

    /// S09 uses this gate before automatic insertion. Exact case and punctuation matter.
    public func preservesProtectedNames(in output: String) -> Bool {
        protectedCanonicalSpellings.allSatisfy { DictionarySnapshot.containsExact($0, in: output) }
    }
}

public struct DictionarySnapshot: Sendable, Equatable {
    private struct Node: Sendable, Equatable {
        var children: [Character: Int] = [:]
        var entry: Int?
    }
    private struct Unit {
        let character: Character
        let range: NSRange
        let first: Bool
        let last: Bool
    }
    private struct Replacement {
        let range: NSRange
        let entry: Int
    }

    public let entries: [DictionaryEntry]
    public let revision: UUID
    private let nodes: [Node]
    public static let empty = try! DictionarySnapshot(entries: [], revision: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)

    public init(entries: [DictionaryEntry], revision: UUID = UUID()) throws {
        guard Set(entries.map(\.id)).count == entries.count else { throw DictionaryError.duplicateEntry }
        // Report the previously supplied owner, before presentation sorting.
        // Store appends a new entry after its already persisted collection.
        var owners: [String: UUID] = [:]
        for entry in entries {
            for variant in [entry.canonical] + entry.aliases {
                let key = DictionaryNormalization.key(variant)
                if let owner = owners[key], owner != entry.id {
                    throw DictionaryError.conflictingVariant(existingID: owner)
                }
                owners[key] = entry.id
            }
        }
        self.entries = entries.sorted {
            let left = DictionaryNormalization.key($0.canonical), right = DictionaryNormalization.key($1.canonical)
            return left == right ? $0.id.uuidString < $1.id.uuidString : left < right
        }
        self.revision = revision
        var nodes = [Node()]
        for (entryIndex, entry) in self.entries.enumerated() {
            for variant in [entry.canonical] + entry.aliases {
                var current = 0
                for character in DictionaryNormalization.key(variant) {
                    if let child = nodes[current].children[character] { current = child }
                    else {
                        let child = nodes.count
                        nodes.append(Node())
                        nodes[current].children[character] = child
                        current = child
                    }
                }
                nodes[current].entry = entryIndex
            }
        }
        self.nodes = nodes
    }

    /// A trie scans the original input once. Inserted canonical text is never rescanned.
    /// Explicit ranges refer to this exact input; malformed ranges fail closed.
    public func apply(to text: String, protecting ranges: [NSRange] = []) -> DictionaryApplication {
        let source = text as NSString
        var boundaries = Set<Int>([0]), offset = 0
        for character in text { offset += character.utf16.count; boundaries.insert(offset) }
        guard ranges.allSatisfy({ $0.location >= 0 && $0.length >= 0 && $0.location <= source.length &&
            $0.length <= source.length - $0.location && boundaries.contains($0.location) && boundaries.contains(NSMaxRange($0)) }) else {
            return DictionaryApplication(text: text, protectedRanges: [NSRange(location: 0, length: source.length)],
                relevantCanonicalSpellings: [], protectedCanonicalSpellings: [])
        }
        let units = Self.units(text)
        var replacements: [Replacement] = []
        var cursor = 0
        while cursor < units.count {
            guard units[cursor].first, Self.boundaryBefore(units, cursor) else { cursor += 1; continue }
            var node = 0, end = cursor
            var longest: Replacement?
            var longestEnd = cursor
            while end < units.count, let next = nodes[node].children[units[end].character] {
                node = next
                if let entry = nodes[node].entry, units[end].last, Self.boundaryAfter(units, end) {
                    let span = NSRange(location: units[cursor].range.location,
                        length: NSMaxRange(units[end].range) - units[cursor].range.location)
                    if !ranges.contains(where: { NSIntersectionRange($0, span).length > 0 }) {
                        longest = Replacement(range: span, entry: entry)
                        longestEnd = end
                    }
                }
                end += 1
            }
            if let longest { replacements.append(longest); cursor = longestEnd + 1 }
            else { cursor += 1 }
        }
        var output = "", previousEnd = 0, outputOffset = 0
        var protected: [NSRange] = []
        var relevant = Set<Int>()
        for replacement in replacements {
            let prefix = source.substring(with: NSRange(location: previousEnd, length: replacement.range.location - previousEnd))
            output += prefix
            outputOffset += prefix.utf16.count
            let canonical = entries[replacement.entry].canonical
            output += canonical
            protected.append(NSRange(location: outputOffset, length: canonical.utf16.count))
            outputOffset += canonical.utf16.count
            previousEnd = NSMaxRange(replacement.range)
            relevant.insert(replacement.entry)
        }
        output += source.substring(from: previousEnd)
        for range in ranges {
            let delta = replacements.filter { NSMaxRange($0.range) <= range.location }
                .reduce(0) { $0 + entries[$1.entry].canonical.utf16.count - $1.range.length }
            protected.append(NSRange(location: range.location + delta, length: range.length))
        }
        let ordered = relevant.sorted().map { entries[$0] }
        return DictionaryApplication(text: output, protectedRanges: protected.sorted { $0.location < $1.location },
            relevantCanonicalSpellings: ordered.map(\.canonical),
            protectedCanonicalSpellings: ordered.filter(\.isProtected).map(\.canonical))
    }

    public static func containsExact(_ spelling: String, in text: String) -> Bool {
        guard !spelling.isEmpty else { return false }
        let source = text as NSString
        let units = Self.units(text)
        var search = NSRange(location: 0, length: source.length)
        while search.length > 0 {
            let range = source.range(of: spelling, options: .literal, range: search)
            guard range.location != NSNotFound else { return false }
            if let start = units.firstIndex(where: { $0.first && $0.range.location == range.location }),
               let end = units.lastIndex(where: { $0.last && NSMaxRange($0.range) == NSMaxRange(range) }),
               boundaryBefore(units, start), boundaryAfter(units, end) { return true }
            search = NSRange(location: NSMaxRange(range), length: source.length - NSMaxRange(range))
        }
        return false
    }

    private static func units(_ text: String) -> [Unit] {
        var result: [Unit] = [], offset = 0
        for character in text {
            let length = character.utf16.count
            let space = character.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains)
            if space, let previous = result.last, previous.character == " " {
                result[result.count - 1] = Unit(character: " ", range: NSRange(location: previous.range.location,
                    length: offset + length - previous.range.location), first: true, last: true)
            } else {
                let folded = space ? [Character(" ")] : Array(String(character)
                    .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                    .precomposedStringWithCanonicalMapping)
                for (index, value) in folded.enumerated() {
                    result.append(Unit(character: value, range: NSRange(location: offset, length: length),
                        first: index == 0, last: index == folded.count - 1))
                }
            }
            offset += length
        }
        return result
    }

    private static func word(_ character: Character) -> Bool {
        character.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || $0 == "_" }
    }
    private static func joined(_ character: Character) -> Bool {
        word(character) || character.unicodeScalars.contains { "/\\@+#-".unicodeScalars.contains($0) }
    }
    private static func boundaryBefore(_ units: [Unit], _ start: Int) -> Bool {
        guard start > 0 else { return true }
        if joined(units[start - 1].character) { return false }
        let previous = units[start - 1].character
        if ["'", "’", ":", "."].contains(previous), start > 1, word(units[start - 2].character) { return false }
        return true
    }
    private static func boundaryAfter(_ units: [Unit], _ end: Int) -> Bool {
        guard end + 1 < units.count else { return true }
        if joined(units[end + 1].character) { return false }
        let next = units[end + 1].character
        if ["'", "’", ":", "."].contains(next), end + 2 < units.count, word(units[end + 2].character) { return false }
        return true
    }
}
