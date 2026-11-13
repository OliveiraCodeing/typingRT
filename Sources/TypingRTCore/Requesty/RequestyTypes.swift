import Foundation

public struct RequestyModel: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let contextWindow: Int?
    public let maxOutputTokens: Int?

    public init(id: String, contextWindow: Int? = nil, maxOutputTokens: Int? = nil) {
        self.id = id
        self.contextWindow = contextWindow
        self.maxOutputTokens = maxOutputTokens
    }
}

public struct RequestyCompletion: Sendable, Equatable {
    public let sessionID: UUID
    public let text: String
    public init(sessionID: UUID, text: String) { self.sessionID = sessionID; self.text = text }
}

public protocol RequestyServing: Sendable {
    func models(apiKey: String) async throws -> [RequestyModel]
    func complete(sessionID: UUID, modelID: String, system: String, text: String,
                  maxOutputTokens: Int, apiKey: String) async throws -> RequestyCompletion
}

/// Fixed messages only: never surface provider responses or URLSession userInfo.
public enum RequestyError: Error, LocalizedError, Sendable, Equatable {
    case unauthorized, insufficientCredits, forbidden, modelUnavailable, rateLimited, spendingLimit
    case timeout, network, server, invalidResponse, incompleteResponse, emptyResponse
    case invalidConfiguration, tooLarge, redirectRejected

    public var errorDescription: String? {
        switch self {
        case .unauthorized: "Requesty-Zugang ungültig. Bitte den Schlüssel prüfen."
        case .insufficientCredits: "Requesty-Guthaben reicht nicht aus. Bitte das Konto prüfen."
        case .spendingLimit: "Das monatliche Requesty-Ausgabenlimit wurde erreicht. Bitte das Konto prüfen."
        case .forbidden: "Für diese Requesty-Anfrage fehlt die Berechtigung."
        case .modelUnavailable: "Das gewählte Requesty-Modell ist nicht verfügbar. Bitte ein anderes wählen."
        case .rateLimited: "Requesty-Anfragelimit erreicht. Bitte später erneut versuchen."
        case .timeout: "Requesty antwortet nicht rechtzeitig. Bitte erneut versuchen."
        case .network: "Requesty ist nicht erreichbar. Bitte die Internetverbindung prüfen."
        case .server: "Requesty meldet einen Serverfehler. Bitte später erneut versuchen."
        case .invalidResponse: "Requesty hat keine verwertbare Antwort geliefert."
        case .incompleteResponse: "Die Requesty-Antwort ist unvollständig und wird nicht übernommen."
        case .emptyResponse: "Requesty hat keinen Text geliefert."
        case .invalidConfiguration: "Bitte einen gültigen Requesty-Schlüssel und eine Modell-ID einrichten."
        case .tooLarge: "Die Requesty-Anfrage oder Antwort überschreitet die unterstützte Größe."
        case .redirectRejected: "Requesty hat die Anfrage umgeleitet. Die Verbindung wurde aus Sicherheitsgründen beendet."
        }
    }
}

public enum RequestyValidation {
    public static func modelID(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({ !$0.properties.isWhitespace && !CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    public static func apiKey(_ input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 4_096,
              value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else { return nil }
        return value
    }
}
