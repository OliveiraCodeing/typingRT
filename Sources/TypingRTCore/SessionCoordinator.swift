import Foundation

public struct DictationSnapshot: Sendable, Equatable {
    public let id: UUID
    public let mode: DictationMode
    public let dictionary: DictionarySnapshot
    public let snippets: SnippetSnapshot
    public let requestyModelID: String?
    public let requestyModel: RequestyModel?

    public init(id: UUID, mode: DictationMode, dictionary: DictionarySnapshot = .empty, snippets: SnippetSnapshot = .empty, requestyModelID: String? = nil, requestyModel: RequestyModel? = nil) {
        self.id = id
        self.mode = mode
        self.dictionary = dictionary
        self.snippets = mode == .standard ? snippets : .empty
        self.requestyModelID = mode == .coding ? requestyModelID.flatMap(RequestyValidation.modelID) : nil
        self.requestyModel = mode == .coding && requestyModel?.id == self.requestyModelID ? requestyModel : nil
    }
}

/// Logical session ownership only. Native key events and audio are separate adapters.
@MainActor
public final class SessionCoordinator {
    private enum Phase {
        case idle
        case recording
        case processing
    }

    public private(set) var activeSession: DictationSnapshot?

    // Assume held until an initial released state or a real release is observed.
    private var isRightOptionPressed = true
    private var hasReceivedKeyState = false
    private var phase: Phase = .idle
    private var isShutDown = false

    public init() {}

    /// Seeds the initial physical state once; it never starts or resumes a session.
    public func seedKeyState(isPressed: Bool) {
        guard !hasReceivedKeyState, !isShutDown else { return }
        isRightOptionPressed = isPressed
        hasReceivedKeyState = true
    }

    /// An interrupted monitor can lose the release event. Only an idle session
    /// may accept a fresh physical state, and this never starts a recording.
    public func resynchronizeKeyState(isPressed: Bool) {
        guard !isShutDown, phase == .idle, activeSession == nil else { return }
        isRightOptionPressed = isPressed
        hasReceivedKeyState = true
    }

    /// Returns an ID only for a newly accepted press. Release retains ownership
    /// while processing; callers finish or discard that session with invalidate().
    public func handleRightOption(
        isPressed: Bool,
        readiness: Readiness,
        selectedMode: DictationMode,
        dictionary: DictionarySnapshot = .empty,
        snippets: SnippetSnapshot = .empty,
        requestyModelID: String? = nil,
        requestyModel: RequestyModel? = nil
    ) -> UUID? {
        guard !isShutDown else { return nil }

        let wasPressed = isRightOptionPressed
        isRightOptionPressed = isPressed
        hasReceivedKeyState = true

        guard isPressed else {
            if wasPressed {
                markProcessing()
            }
            return nil
        }

        guard !wasPressed, phase == .idle, readiness.canStart else { return nil }

        let snapshot = DictationSnapshot(id: UUID(), mode: selectedMode, dictionary: dictionary, snippets: snippets, requestyModelID: requestyModelID, requestyModel: requestyModel)
        activeSession = snapshot
        phase = .recording
        return snapshot.id
    }

    /// Processing cannot begin before the accepted hold has been released.
    public func markProcessing() {
        guard !isShutDown, !isRightOptionPressed,
              activeSession != nil, phase == .recording else { return }
        phase = .processing
    }

    /// Does not reset physical key state: a held key cannot start a new session.
    public func invalidate() {
        activeSession = nil
        phase = .idle
    }

    /// Permanent for this coordinator instance; invalidates all late callbacks.
    public func shutDown() {
        isShutDown = true
        invalidate()
    }

    public func mayDeliver(sessionID: UUID) -> Bool {
        !isShutDown && phase == .processing && activeSession?.id == sessionID
    }
}
