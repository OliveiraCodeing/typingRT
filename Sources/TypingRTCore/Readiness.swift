public struct Readiness: Sendable {
    public let microphoneGranted: Bool
    public let accessibilityGranted: Bool
    public let hotkeyAvailable: Bool
    public let modelInstalled: Bool

    public init(
        microphoneGranted: Bool,
        accessibilityGranted: Bool,
        hotkeyAvailable: Bool,
        modelInstalled: Bool
    ) {
        self.microphoneGranted = microphoneGranted
        self.accessibilityGranted = accessibilityGranted
        self.hotkeyAvailable = hotkeyAvailable
        self.modelInstalled = modelInstalled
    }

    public var canStart: Bool {
        microphoneGranted && accessibilityGranted && hotkeyAvailable && modelInstalled
    }
}
