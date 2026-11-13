import Foundation

public enum DictionaryError: Error, LocalizedError, Sendable, Equatable {
    case invalidSpelling
    case tooManyAliases
    case duplicateEntry
    case conflictingVariant(existingID: UUID)
    case missingEntry
    case unsupportedSchema
    case invalidStoredData
    case storageFailure

    public var errorDescription: String? {
        switch self {
        case .invalidSpelling: "Bitte eine einzeilige Schreibweise mit höchstens 256 Zeichen eingeben. Leere Varianten sind nicht erlaubt."
        case .tooManyAliases: "Pro Begriff sind höchstens 64 Aussprachevarianten möglich."
        case .duplicateEntry: "Dieser Wörterbucheintrag ist bereits vorhanden."
        case .conflictingVariant: "Eine Schreibweise oder Variante ist bereits einem anderen Begriff zugeordnet. Bitte eine eindeutige Variante verwenden."
        case .missingEntry: "Der Wörterbucheintrag ist nicht mehr vorhanden. Bitte die Liste neu laden."
        case .unsupportedSchema: "Diese Wörterbuchdatei benötigt eine neuere App-Version."
        case .invalidStoredData: "Das gespeicherte Wörterbuch ist ungültig. Die Datei wurde nicht verändert."
        case .storageFailure: "Das Wörterbuch konnte nicht gespeichert oder gelesen werden. Der bisherige Stand bleibt erhalten."
        }
    }
}

public enum DictionaryNormalization {
    /// Case-insensitive Unicode matching, without removing punctuation or accents.
    public static func key(_ text: String) -> String {
        text.split(whereSeparator: { $0.unicodeScalars.allSatisfy(CharacterSet.whitespaces.contains) })
            .map { String($0).folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping }
            .joined(separator: " ")
    }

    static func validated(_ text: String) throws -> String {
        guard !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\t" }),
              !text.unicodeScalars.contains(where: CharacterSet.newlines.contains) else { throw DictionaryError.invalidSpelling }
        let spelling = text.trimmingCharacters(in: .whitespaces)
        guard !spelling.isEmpty, spelling.count <= 256, !key(spelling).isEmpty else { throw DictionaryError.invalidSpelling }
        return spelling
    }
}

public struct DictionaryEntry: Sendable, Equatable, Identifiable {
    public let id: UUID
    public let canonical: String
    public let aliases: [String]
    public let isProtected: Bool

    public init(id: UUID = UUID(), canonical: String, aliases: [String] = [], isProtected: Bool = false) throws {
        guard aliases.count <= 64 else { throw DictionaryError.tooManyAliases }
        self.id = id
        self.canonical = try DictionaryNormalization.validated(canonical)
        var seen = Set<String>([DictionaryNormalization.key(self.canonical)])
        var unique: [String] = []
        for alias in aliases {
            let value = try DictionaryNormalization.validated(alias)
            if seen.insert(DictionaryNormalization.key(value)).inserted { unique.append(value) }
        }
        self.aliases = unique
        self.isProtected = isProtected
    }

    public func matches(search: String) -> Bool {
        let query = DictionaryNormalization.key(search)
        return query.isEmpty || ([canonical] + aliases).contains { DictionaryNormalization.key($0).contains(query) }
    }
}
