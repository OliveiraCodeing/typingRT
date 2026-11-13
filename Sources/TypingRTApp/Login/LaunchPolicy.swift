import AppKit
import CoreServices

/// Login never opens or activates a window, even on an otherwise first launch.
/// This policy is separate from the event adapter so it can be tested without
/// launching an app or changing the user's actual Login Items.
struct LaunchPolicy: Sendable, Equatable {
    let isLoginLaunch: Bool
    let isSmokeTest: Bool
    let explicitWindow: Bool
    let hasOpened: Bool

    var shouldShowMainWindow: Bool {
        !isLoginLaunch && (isSmokeTest || explicitWindow || !hasOpened)
    }

    var shouldNotifyExistingInstance: Bool { !isLoginLaunch }

    @MainActor
    static func isCurrentLoginLaunch() -> Bool {
        isLoginEvent(NSAppleEventManager.shared().currentAppleEvent)
    }

    @MainActor
    static func isLoginEvent(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventClass == kCoreEventClass && event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
