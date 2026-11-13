import Foundation

public struct ModelDescriptor: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public let displayName: String
    public let repository: String
    public let revision: String
    public let subdirectory: String
    public let tokenizerRepository: String
    public let tokenizerRevision: String

    public init(
        id: String, displayName: String, repository: String, revision: String,
        subdirectory: String, tokenizerRepository: String, tokenizerRevision: String
    ) {
        self.id = id
        self.displayName = displayName
        self.repository = repository
        self.revision = revision
        self.subdirectory = subdirectory
        self.tokenizerRepository = tokenizerRepository
        self.tokenizerRevision = tokenizerRevision
    }
}

public enum ModelCatalog {
    /// Pinned repository snapshots, never a moving "main" download.
    public static let compressedTurbo = ModelDescriptor(
        id: "whisper-large-v3-turbo-626mb",
        displayName: "Whisper Large v3 Turbo · Kompakt",
        repository: "argmaxinc/whisperkit-coreml",
        revision: "7235bbd38ae9ab5476bee007313c0bb327387b84",
        subdirectory: "openai_whisper-large-v3-v20240930_626MB",
        tokenizerRepository: "openai/whisper-large-v3",
        tokenizerRevision: "06f233fe06e710322aca913c1bc4249a0d71fce1"
    )

    public static let models = [compressedTurbo]

    public static var defaultRoot: URL {
        AppIdentity.current.applicationSupport.appendingPathComponent("Models", isDirectory: true)
    }
}

public struct InstalledModelAsset: Codable, Sendable, Equatable {
    public let path: String
    public let byteCount: Int64
    public let sha256: String
}

public struct InstalledModelManifest: Codable, Sendable, Equatable {
    public let schemaVersion: Int
    public let installationID: UUID
    public let descriptor: ModelDescriptor
    public let installedAt: Date
    public let assets: [InstalledModelAsset]
    public let inventorySHA256: String
}

public struct InstalledModel: Sendable {
    public let manifest: InstalledModelManifest
    public let directory: URL
    public var modelPath: URL { directory.appendingPathComponent("model", isDirectory: true) }
    public var tokenizerPath: URL { directory.appendingPathComponent("tokenizer", isDirectory: true) }
}

public enum ModelInstallPhase: Sendable {
    case resolving
    case downloading
    case verifying
    case activating
}

public struct ModelInstallProgress: Sendable {
    public let phase: ModelInstallPhase
    public let completedBytes: Int64
    public let totalBytes: Int64
    public var fraction: Double {
        totalBytes > 0 ? min(1, max(0, Double(completedBytes) / Double(totalBytes))) : 0
    }
}

public protocol ModelInstallerProtocol: Sendable {
    func installedModel(for descriptor: ModelDescriptor) async throws -> InstalledModel?
    func install(
        _ descriptor: ModelDescriptor,
        progress: @escaping @Sendable (ModelInstallProgress) -> Void
    ) async throws -> InstalledModel
}

public enum ModelInstallationError: Error, LocalizedError, Sendable {
    case invalidDescriptor
    case invalidInventory
    case invalidPath
    case missingRequiredAssets
    case unsupportedDigest
    case integrityFailure
    case invalidInstallation
    case invalidResponse
    case busy

    public var errorDescription: String? {
        switch self {
        case .invalidDescriptor: "Die lokale Modellbeschreibung ist ungültig."
        case .invalidInventory: "Die Dateiliste des Modellanbieters ist unvollständig oder ungültig."
        case .invalidPath: "Die Modellinstallation enthält einen ungültigen Dateipfad."
        case .missingRequiredAssets: "Erforderliche Modell- oder Tokenizerdateien fehlen."
        case .unsupportedDigest: "Für eine Modelldatei fehlt ein prüfbarer Integritätswert."
        case .integrityFailure: "Eine Modelldatei ist unvollständig oder stimmt nicht mit der gepinnten Quelle überein."
        case .invalidInstallation: "Die gespeicherte Modellinstallation ist ungültig. Bitte erneut installieren."
        case .invalidResponse: "Der Modellanbieter hat keine gültige Antwort geliefert."
        case .busy: "Eine Modellinstallation läuft bereits."
        }
    }
}
