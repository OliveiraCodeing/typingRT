import Foundation

public enum SnippetError: Error, LocalizedError, Sendable, Equatable {
    case invalidName, invalidTrigger, invalidAliases, invalidTemplate
    case duplicateEntry, conflictingTrigger(existingID: UUID), missingEntry
    case unsupportedSchema, invalidFile, invalidStoredData, storageFailure
    case tooLarge, invalidProcessing

    public var field: String {
        switch self {
        case .invalidName: "name"
        case .invalidTrigger, .conflictingTrigger: "trigger"
        case .invalidAliases: "aliases"
        case .invalidTemplate: "template"
        case .unsupportedSchema, .invalidFile, .duplicateEntry, .tooLarge: "file"
        case .invalidProcessing, .missingEntry, .invalidStoredData, .storageFailure: "storage"
        }
    }
    public var errorDescription: String? {
        switch self {
        case .invalidName: "Bitte einen einzeiligen Namen mit höchstens 256 Zeichen eingeben."
        case .invalidTrigger: "Bitte einen einzeiligen Auslöser mit höchstens 256 Zeichen eingeben."
        case .invalidAliases: "Bitte höchstens 64 gültige, einzeilige Aussprachevarianten eingeben."
        case .invalidTemplate: "Bitte eine nicht leere Vorlage mit höchstens 64 KiB eingeben."
        case .duplicateEntry: "Ein Eintrag mit dieser Kennung ist bereits vorhanden."
        case .conflictingTrigger: "Ein Auslöser oder eine Variante ist bereits belegt oder überschneidet sich mit einem anderen Aufruf. Bitte einen eindeutigen Auslöser verwenden."
        case .missingEntry: "Das Snippet ist nicht mehr vorhanden. Bitte die Liste neu laden."
        case .unsupportedSchema: "Diese Snippet-Datei benötigt eine andere App-Version."
        case .invalidFile: "Die Datei enthält keine gültige Snippet-Sammlung. Es wurde nichts importiert."
        case .invalidStoredData: "Die gespeicherten Snippets sind ungültig. Die Datei wurde nicht verändert."
        case .storageFailure: "Die Snippets konnten nicht gespeichert oder gelesen werden. Der bisherige Stand bleibt erhalten."
        case .tooLarge: "Die Größenbegrenzung wurde überschritten. Es wurde nichts verändert oder eingefügt."
        case .invalidProcessing: "Die Snippet-Aufrufe konnten nicht sicher übernommen werden. Es wurde nichts eingefügt."
        }
    }
}

public struct SnippetEntry: Sendable, Equatable, Identifiable, Codable {
    public let id: UUID
    public let name: String
    public let trigger: String
    public let aliases: [String]
    public let template: String

    public init(id: UUID = UUID(), name: String, trigger: String, aliases: [String] = [], template: String) throws {
        self.id = id
        self.name = try Self.singleLine(name, error: .invalidName)
        self.trigger = try Self.singleLine(trigger, error: .invalidTrigger)
        guard aliases.count <= 64 else { throw SnippetError.invalidAliases }
        var seen = Set([DictionaryNormalization.key(self.trigger)])
        var unique: [String] = []
        for alias in aliases {
            let value = try Self.singleLine(alias, error: .invalidAliases)
            if seen.insert(DictionaryNormalization.key(value)).inserted { unique.append(value) }
        }
        self.aliases = unique
        guard !template.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              template.utf8.count <= 65_536,
              !template.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !["\t", "\n", "\r"].contains($0) }) else {
            throw SnippetError.invalidTemplate
        }
        self.template = template
    }

    public func matches(search: String) -> Bool {
        let query = DictionaryNormalization.key(search)
        return query.isEmpty || ([name, trigger] + aliases).contains { DictionaryNormalization.key($0).contains(query) }
    }

    private static func singleLine(_ text: String, error: SnippetError) throws -> String {
        let value = text.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty, value.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.newlines.contains($0) || (CharacterSet.controlCharacters.contains($0) && $0 != "\t") }) else { throw error }
        return value
    }

    private enum CodingKeys: String, CodingKey { case id, name, trigger, aliases, template }
    public init(from decoder: any Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(id: fields.decode(UUID.self, forKey: .id), name: fields.decode(String.self, forKey: .name),
            trigger: fields.decode(String.self, forKey: .trigger), aliases: fields.decode([String].self, forKey: .aliases),
            template: fields.decode(String.self, forKey: .template))
    }
}
