import Foundation

/// A per-transcript protection plan. The opaque markers contain no template content.
/// Pass `text` and `protectedRanges` through dictionary/cleanup, then expand once.
public struct SnippetProtection: Sendable, Equatable {
    public let text: String
    public let protectedRanges: [NSRange]
    public var callCount: Int { replacements.count }
    private let replacements: [(marker: String, template: String)]

    fileprivate init(text: String, protectedRanges: [NSRange], replacements: [(String, String)]) {
        self.text = text; self.protectedRanges = protectedRanges; self.replacements = replacements
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text == rhs.text && lhs.protectedRanges == rhs.protectedRanges &&
            lhs.replacements.elementsEqual(rhs.replacements, by: { $0.marker == $1.marker && $0.template == $1.template })
    }

    private static let markers = try! NSRegularExpression(pattern: "\u{E000}[0-9A-F-]{36}:[0-9]+\u{E001}")

    public func expand(in cleaned: String) throws -> String {
        guard cleaned.utf8.count <= 1_048_576 else { throw SnippetError.tooLarge }
        let source = cleaned as NSString
        let templates = Dictionary(uniqueKeysWithValues: replacements.map { ($0.marker, $0.template) })
        var seen = Set<String>()
        var matches: [(NSRange, String)] = []
        for match in Self.markers.matches(in: cleaned, range: NSRange(location: 0, length: source.length)) {
            let marker = source.substring(with: match.range)
            guard let template = templates[marker] else { continue }
            guard seen.insert(marker).inserted else { throw SnippetError.invalidProcessing }
            matches.append((match.range, template))
        }
        guard seen.count == replacements.count else { throw SnippetError.invalidProcessing }
        var output = "", previous = 0, byteCount = 0
        for (range, template) in matches.sorted(by: { $0.0.location < $1.0.location }) {
            let prefix = source.substring(with: NSRange(location: previous, length: range.location - previous))
            byteCount += prefix.utf8.count + template.utf8.count
            guard byteCount <= 1_048_576 else { throw SnippetError.tooLarge }
            output += prefix
            output += template
            previous = NSMaxRange(range)
        }
        let suffix = source.substring(from: previous)
        guard byteCount + suffix.utf8.count <= 1_048_576 else { throw SnippetError.tooLarge }
        output += suffix
        return output
    }
}

public struct SnippetSnapshot: Sendable, Equatable {
    private struct Node: Sendable, Equatable { var children: [Character: Int] = [:]; var entry: Int? }
    private struct Unit { let value: Character; let range: NSRange; let first: Bool; let last: Bool }
    public let entries: [SnippetEntry]
    public let revision: UUID
    private let nodes: [Node]
    public static let empty = try! SnippetSnapshot(entries: [], revision: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!)

    public init(entries: [SnippetEntry], revision: UUID = UUID()) throws {
        guard entries.count <= 1_000 else { throw SnippetError.tooLarge }
        guard Set(entries.map(\.id)).count == entries.count else { throw SnippetError.duplicateEntry }
        guard entries.reduce(0, { $0 + $1.name.utf8.count + $1.trigger.utf8.count + $1.aliases.reduce(0, { $0 + $1.utf8.count }) + $1.template.utf8.count }) <= 4_194_304 else { throw SnippetError.tooLarge }
        self.entries = entries.sorted {
            let a = DictionaryNormalization.key($0.name), b = DictionaryNormalization.key($1.name)
            return a == b ? $0.id.uuidString < $1.id.uuidString : a < b
        }
        self.revision = revision
        var nodes = [Node()]
        // Validate before presentation sorting, so conflicts identify the existing owner.
        var owners: [String: UUID] = [:]
        for entry in entries {
            for variant in [entry.trigger] + entry.aliases {
                let key = DictionaryNormalization.key(variant)
                if let owner = owners[key], owner != entry.id { throw SnippetError.conflictingTrigger(existingID: owner) }
                owners[key] = entry.id
            }
        }
        var prefixes: [(String, UUID)] = []
        for (key, owner) in owners.sorted(by: { $0.key < $1.key }) {
            while let last = prefixes.last, !key.hasPrefix(last.0) { prefixes.removeLast() }
            let units = Self.units(key)
            if let conflict = prefixes.first(where: { prefix in
                guard prefix.1 != owner else { return false }
                let length = prefix.0.utf16.count
                guard let end = units.lastIndex(where: { NSMaxRange($0.range) == length && $0.last }) else { return false }
                return Self.after(units, end)
            }) { throw SnippetError.conflictingTrigger(existingID: conflict.1) }
            prefixes.append((key, owner))
        }
        for (entryIndex, entry) in self.entries.enumerated() {
            for variant in [entry.trigger] + entry.aliases {
                var current = 0
                for character in "snippet " + DictionaryNormalization.key(variant) {
                    if let child = nodes[current].children[character] { current = child }
                    else { let child = nodes.count; nodes.append(Node()); nodes[current].children[character] = child; current = child }
                }
                nodes[current].entry = entryIndex
            }
        }
        self.nodes = nodes
    }

    /// Only call in Standard mode, on the original ASR text before any replacement.
    public func protectCalls(in raw: String) throws -> SnippetProtection {
        guard raw.utf8.count <= 1_048_576 else { throw SnippetError.tooLarge }
        let source = raw as NSString, units = Self.units(raw)
        var spans: [(NSRange, Int)] = [], cursor = 0
        while cursor < units.count {
            guard units[cursor].first, Self.before(units, cursor) else { cursor += 1; continue }
            var node = 0, end = cursor, longest: (NSRange, Int)?, last = cursor
            while end < units.count, let next = nodes[node].children[units[end].value] {
                node = next
                if let entry = nodes[node].entry, units[end].last, Self.after(units, end) {
                    longest = (NSRange(location: units[cursor].range.location, length: NSMaxRange(units[end].range) - units[cursor].range.location), entry)
                    last = end
                }
                end += 1
            }
            if let longest { spans.append(longest); cursor = last + 1 } else { cursor += 1 }
        }
        guard !spans.isEmpty else { return SnippetProtection(text: raw, protectedRanges: [], replacements: []) }
        var nonce: String
        repeat { nonce = UUID().uuidString } while raw.contains(nonce) || entries.contains(where: { $0.template.contains(nonce) })
        var output = "", previous = 0, outputOffset = 0, byteCount = 0
        var protected: [NSRange] = [], replacements: [(String, String)] = []
        for (index, span) in spans.enumerated() {
            let prefix = source.substring(with: NSRange(location: previous, length: span.0.location - previous))
            output += prefix
            outputOffset += prefix.utf16.count
            byteCount += prefix.utf8.count
            let marker = "\u{E000}" + nonce + ":" + String(index) + "\u{E001}"
            byteCount += marker.utf8.count
            guard byteCount <= 1_048_576 else { throw SnippetError.tooLarge }
            protected.append(NSRange(location: outputOffset, length: marker.utf16.count))
            output += marker
            outputOffset += marker.utf16.count
            replacements.append((marker, entries[span.1].template))
            previous = NSMaxRange(span.0)
        }
        let suffix = source.substring(from: previous)
        guard byteCount + suffix.utf8.count <= 1_048_576 else { throw SnippetError.tooLarge }
        output += suffix
        return SnippetProtection(text: output, protectedRanges: protected, replacements: replacements)
    }

    private static func units(_ text: String) -> [Unit] {
        var result: [Unit] = [], offset = 0
        for character in text {
            let length = character.utf16.count
            let horizontal = character.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains)
            if horizontal, let last = result.last, last.value == " " {
                result[result.count - 1] = Unit(value: " ", range: NSRange(location: last.range.location, length: offset + length - last.range.location), first: true, last: true)
            } else {
                let values = horizontal ? [Character(" ")] : Array(String(character).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX")).precomposedStringWithCanonicalMapping)
                for (index, value) in values.enumerated() {
                    result.append(Unit(value: value, range: NSRange(location: offset, length: length), first: index == 0, last: index == values.count - 1))
                }
            }
            offset += length
        }
        return result
    }
    private static func word(_ c: Character) -> Bool { c.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) || $0 == "_" } }
    private static func joined(_ c: Character) -> Bool { word(c) || c.unicodeScalars.contains { "/\\@+#-".unicodeScalars.contains($0) } }
    private static func before(_ u: [Unit], _ start: Int) -> Bool {
        guard start > 0 else { return true }
        if joined(u[start - 1].value) { return false }
        return !(["'", "’", ":", "."].contains(u[start - 1].value) && start > 1 && word(u[start - 2].value))
    }
    private static func after(_ u: [Unit], _ end: Int) -> Bool {
        guard end + 1 < u.count else { return true }
        if joined(u[end + 1].value) { return false }
        return !(["'", "’", ":", "."].contains(u[end + 1].value) && end + 2 < u.count && word(u[end + 2].value))
    }
}
