import Foundation

/// XPC carries data rather than paths/text in logs or mutable shared state.
@objc public protocol TranscriptionWorkerProtocol {
    func inspect(withReply reply: @escaping (Data) -> Void)
    func prepare(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func transcribe(_ request: Data, withReply reply: @escaping (Data) -> Void)
    func cancel(_ sessionID: String, withReply reply: @escaping () -> Void)
}

public struct WorkerCapabilities: Codable, Sendable {
    public let backendAvailable: Bool
    public let version: String
    public init(backendAvailable: Bool, version: String) {
        self.backendAvailable = backendAvailable; self.version = version
    }
}

public struct WorkerRequest: Codable, Sendable {
    public let sessionID: UUID
    public let audioPath: String
    public let modelPath: String
    public let tokenizerPath: String
    public let canonicalTerms: [String]
    public init(sessionID: UUID, audioPath: String, modelPath: String, tokenizerPath: String, canonicalTerms: [String] = []) {
        self.sessionID = sessionID; self.audioPath = audioPath
        self.modelPath = modelPath; self.tokenizerPath = tokenizerPath
        self.canonicalTerms = canonicalTerms
    }
}

public enum WorkerErrorCode: String, Codable, Sendable { case incompleteTranscription }

public struct WorkerReply: Codable, Sendable {
    public let sessionID: UUID
    public let text: String?
    public let error: String?
    public let errorCode: WorkerErrorCode?
    public let loadSeconds: Double
    public let inferenceSeconds: Double
    public init(sessionID: UUID, text: String?, error: String?, loadSeconds: Double, inferenceSeconds: Double, errorCode: WorkerErrorCode? = nil) {
        self.sessionID = sessionID; self.text = text; self.error = error
        self.loadSeconds = loadSeconds; self.inferenceSeconds = inferenceSeconds
        self.errorCode = errorCode
    }
}

public enum WorkerWire {
    public static let serviceName = "dev.typingrt.mac.TranscriptionWorker"
    public static func interface() -> NSXPCInterface { NSXPCInterface(with: TranscriptionWorkerProtocol.self) }
}
