/// Decides what a periodic check during a held recording may conclude.
/// A single polled key state is not trusted on its own. A "not held" reading
/// ends the recording only when the event tap had to be re-enabled (a release
/// may have been missed), or when the poll has proven itself during this hold
/// by reporting the key down and then reports it up several times in a row.
public enum CaptureHealth: Sendable, Equatable {
    case healthy
    case permissionLost
    case tapUnavailable
    case releaseMissed

    public static let negativePollLimit = 3

    public static func evaluate(accessibilityTrusted: Bool, tapEnabled: Bool,
                                tapWasReenabled: Bool, keyReportedDown: Bool,
                                pollConfirmedDownThisHold: Bool = false,
                                consecutiveNegativePolls: Int = 0) -> Self {
        guard accessibilityTrusted else { return .permissionLost }
        guard tapEnabled else { return .tapUnavailable }
        if tapWasReenabled && !keyReportedDown { return .releaseMissed }
        if pollConfirmedDownThisHold && consecutiveNegativePolls >= negativePollLimit { return .releaseMissed }
        return .healthy
    }
}
