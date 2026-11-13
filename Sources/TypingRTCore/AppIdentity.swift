import Foundation

/// Runtime domains follow the signed bundle identity, not the output filename.
/// Development and smoke builds never write the daily app's preferences or data.
public struct AppIdentity: Sendable, Equatable {
    public let identifier: String
    public let namespace: String
    public let applicationSupport: URL
    public var workerServiceName: String { identifier + ".TranscriptionWorker" }
    public var keychainService: String { namespace + ".Requesty" }

    public static let current = AppIdentity(
        identifier: Bundle.main.bundleIdentifier ?? "dev.typingrt.mac",
        smokeSession: CommandLine.arguments.contains("--smoke-test")
            ? String(ProcessInfo.processInfo.processIdentifier) : nil
    )

    public init(identifier: String, smokeSession: String? = nil,
                homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
                temporaryDirectory: URL = FileManager.default.temporaryDirectory) {
        self.identifier = identifier
        if let smokeSession {
            namespace = identifier + ".smoke." + smokeSession
            applicationSupport = temporaryDirectory.appendingPathComponent(namespace, isDirectory: true)
        } else {
            namespace = identifier
            let directory: String
            switch identifier {
            case "dev.typingrt.mac": directory = "typingRT"
            case "dev.typingrt.mac.development": directory = "typingRT-development"
            case "dev.typingrt.mac.preview": directory = "typingRT-preview"
            default: directory = identifier
            }
            applicationSupport = homeDirectory
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(directory, isDirectory: true)
        }
    }
}
