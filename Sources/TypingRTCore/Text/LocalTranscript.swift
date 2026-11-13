import Foundation

/// Ephemeral ASR-stage output; raw text remains available for later word counting.
/// Snippets, once expanded in S07, must bypass ConservativeTextCleaner entirely.
public struct LocalTranscript: Sendable, Equatable {
    public let sessionID: UUID
    public let mode: DictationMode
    public let requestyModelID: String?
    public let requestyModel: RequestyModel?
    public let rawText: String
    public let cleanedText: String
    public let loadSeconds: Double
    public let inferenceSeconds: Double
    public let dictionaryRevision: UUID
    public let relevantCanonicalSpellings: [String]
    public let protectedCanonicalSpellings: [String]

    /// S09 must pass this gate before automatic insertion of a remote result.
    public func preservesProtectedNames(in output: String) -> Bool {
        protectedCanonicalSpellings.allSatisfy { DictionarySnapshot.containsExact($0, in: output) }
    }

    public func replacingCleanedText(_ text: String) -> LocalTranscript {
        LocalTranscript(copying: self, cleanedText: text)
    }

    private init(copying original: LocalTranscript, cleanedText: String) {
        self.sessionID = original.sessionID
        self.mode = original.mode
        self.requestyModelID = original.requestyModelID
        self.requestyModel = original.requestyModel
        self.rawText = original.rawText
        self.cleanedText = cleanedText
        self.loadSeconds = original.loadSeconds
        self.inferenceSeconds = original.inferenceSeconds
        self.dictionaryRevision = original.dictionaryRevision
        self.relevantCanonicalSpellings = original.relevantCanonicalSpellings
        self.protectedCanonicalSpellings = original.protectedCanonicalSpellings
    }

    public init(session: DictationSnapshot, rawText: String, cleanedText: String,
                loadSeconds: Double, inferenceSeconds: Double,
                relevantCanonicalSpellings: [String] = [], protectedCanonicalSpellings: [String] = []) {
        self.sessionID = session.id
        self.mode = session.mode
        self.requestyModelID = session.requestyModelID
        self.requestyModel = session.requestyModel
        self.rawText = rawText
        self.cleanedText = cleanedText
        self.loadSeconds = loadSeconds
        self.inferenceSeconds = inferenceSeconds
        self.dictionaryRevision = session.dictionary.revision
        self.relevantCanonicalSpellings = relevantCanonicalSpellings
        self.protectedCanonicalSpellings = protectedCanonicalSpellings
    }
}
