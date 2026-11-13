import AppKit
import ApplicationServices
import os
import TypingRTCore

/// Observes the session event stream without swallowing or changing any event.
/// All callbacks are delivered synchronously on the main run loop.
@MainActor
final class GlobalHotkeyMonitor {
    var onRightOptionChanged: ((Bool) -> Void)?
    var onEscape: (() -> Void)?
    var onFailure: ((String) -> Void)?
    /// The current hold can no longer be trusted, but monitoring keeps running.
    var onInterrupted: ((String) -> Void)?

    private static let log = Logger(subsystem: AppIdentity.current.namespace, category: "hotkey")

    private(set) var isRunning = false
    private(set) var isRightOptionDown = false

    private var resources: HotkeyTapResources?
    // Per hold: whether the key-state poll ever agreed with the tap, and how
    // many polls in a row have since reported the key as up.
    private var pollConfirmedDown = false
    private var negativePolls = 0

    init() {}

    /// Installation never requests a permission and never emits a synthetic
    /// press. The caller must prime its session state from isRightOptionDown.
    @discardableResult
    func start() -> Bool {
        guard !isRunning else { return true }

        guard AXIsProcessTrusted() else {
            onFailure?("Für die rechte Option-Taste fehlen die Bedienungshilfenrechte.")
            return false
        }

        let context = HotkeyTapContext(monitor: self)
        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyTapCallback,
            userInfo: Unmanaged.passUnretained(context).toOpaque()
        ) else {
            onFailure?("Die globale Tastenerkennung konnte nicht gestartet werden. Bitte prüfe die Bedienungshilfenrechte.")
            return false
        }

        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            onFailure?("Die globale Tastenerkennung konnte nicht eingerichtet werden.")
            return false
        }

        resources = HotkeyTapResources(tap: tap, source: source, context: context)
        isRightOptionDown = CGEventSource.keyState(.hidSystemState, key: RightOptionEvent.keyCode)
        isRunning = true
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        guard CGEvent.tapIsEnabled(tap: tap) else {
            fail("Die globale Tastenerkennung ist nicht aktiv. Bitte prüfe die Bedienungshilfenrechte.")
            return false
        }
        return true
    }

    /// No synthetic release is delivered: stopping a tap must not finalize an
    /// interrupted recording as if the user had deliberately released the key.
    func stop() {
        isRunning = false
        isRightOptionDown = false
        resources = nil
    }

    /// Runs periodically during a capture. A disabled tap is re-enabled instead
    /// of ending the recording. The polled key state ends a recording only after
    /// a re-enabled tap or repeated negatives from a poll that saw this hold
    /// (see CaptureHealth). No release is synthesized.
    func verifyCaptureHealth() {
        guard isRunning, let resources else { return }
        let trusted = AXIsProcessTrusted()
        var enabled = CGEvent.tapIsEnabled(tap: resources.tap)
        var reenabled = false
        if trusted && !enabled {
            CGEvent.tapEnable(tap: resources.tap, enable: true)
            enabled = CGEvent.tapIsEnabled(tap: resources.tap)
            reenabled = enabled
        }
        let keyDown = Self.polledRightOptionDown()
        if keyDown { pollConfirmedDown = true; negativePolls = 0 } else { negativePolls += 1 }
        if !trusted || !enabled || reenabled || !keyDown {
            // State flags only; never key contents.
            Self.log.notice("capture health trusted=\(trusted) tapEnabled=\(enabled) reenabled=\(reenabled) polledKeyDown=\(keyDown) pollConfirmed=\(self.pollConfirmedDown)")
        }
        apply(CaptureHealth.evaluate(accessibilityTrusted: trusted, tapEnabled: enabled,
                                     tapWasReenabled: reenabled, keyReportedDown: keyDown,
                                     pollConfirmedDownThisHold: pollConfirmedDown,
                                     consecutiveNegativePolls: negativePolls))
    }

    private static func polledRightOptionDown() -> Bool {
        CGEventSource.keyState(.hidSystemState, key: RightOptionEvent.keyCode)
            || CGEventSource.keyState(.combinedSessionState, key: RightOptionEvent.keyCode)
    }

    private func apply(_ health: CaptureHealth) {
        switch health {
        case .healthy:
            break
        case .permissionLost:
            fail("Für die rechte Option-Taste fehlen die Bedienungshilfenrechte.")
        case .tapUnavailable:
            fail("Die globale Tastenerkennung ist nicht aktiv. Bitte prüfe die Bedienungshilfenrechte.")
        case .releaseMissed:
            guard isRightOptionDown else { return }
            isRightOptionDown = false
            onInterrupted?("Die Tastenerfassung wurde unterbrochen. Bitte erneut bewusst drücken.")
        }
    }

    /// macOS disables a tap after a slow callback or secure input. Re-enable it
    /// and keep monitoring instead of requiring a new setup.
    private func recoverDisabledTap() {
        guard let resources else { return }
        let trusted = AXIsProcessTrusted()
        if trusted { CGEvent.tapEnable(tap: resources.tap, enable: true) }
        let enabled = CGEvent.tapIsEnabled(tap: resources.tap)
        let keyDown = Self.polledRightOptionDown()
        Self.log.notice("tap disabled by system trusted=\(trusted) reenabled=\(enabled) polledKeyDown=\(keyDown)")
        apply(CaptureHealth.evaluate(accessibilityTrusted: trusted, tapEnabled: enabled,
                                     tapWasReenabled: enabled, keyReportedDown: keyDown))
    }

    fileprivate func receive(typeRawValue: UInt32, keyCode rawKeyCode: Int64, flags: UInt64) {
        guard isRunning else { return }

        switch typeRawValue {
        case CGEventType.tapDisabledByTimeout.rawValue, CGEventType.tapDisabledByUserInput.rawValue:
            recoverDisabledTap()
        case CGEventType.flagsChanged.rawValue:
            guard let keyCode = UInt16(exactly: rawKeyCode),
                  let transition = RightOptionEvent.decode(keyCode: keyCode, flags: flags),
                  transition.isPressed != isRightOptionDown else { return }
            isRightOptionDown = transition.isPressed
            pollConfirmedDown = false
            negativePolls = 0
            onRightOptionChanged?(transition.isPressed)
        case CGEventType.keyDown.rawValue:
            // HIToolbox/Events.h: kVK_Escape = 0x35. The controller decides
            // whether an active recording/processing session should be cancelled.
            if rawKeyCode == 53 {
                onEscape?()
            }
        default:
            break
        }
    }

    private func fail(_ message: String) {
        stop()
        onFailure?(message)
    }
}

/// The tap does not retain the monitor. Keeping this context alive separately
/// avoids a monitor → tap → monitor retain cycle.
private final class HotkeyTapContext: Sendable {
    @MainActor weak var monitor: GlobalHotkeyMonitor?

    @MainActor init(monitor: GlobalHotkeyMonitor) {
        self.monitor = monitor
    }
}

/// Owns all CF resources and the callback context through invalidation. It has no
/// actor-isolated operations, so final release also safely cleans up the source
/// if its owner is deallocated without an explicit stop().
private final class HotkeyTapResources {
    let tap: CFMachPort
    let source: CFRunLoopSource
    private let context: HotkeyTapContext

    init(tap: CFMachPort, source: CFRunLoopSource, context: HotkeyTapContext) {
        self.tap = tap
        self.source = source
        self.context = context
    }

    deinit {
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        CFMachPortInvalidate(tap)
    }
}

private func hotkeyTapCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    if let userInfo {
        let context = Unmanaged<HotkeyTapContext>.fromOpaque(userInfo).takeUnretainedValue()
        // Transfer only immutable value data into the actor-isolated handler.
        // The original CGEvent stays entirely within this C callback.
        let typeRawValue = type.rawValue
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags.rawValue
        // Apple guarantees that a tap callback runs on the loop where its source
        // was installed. This source is installed only on CFRunLoopGetMain().
        withExtendedLifetime(context) {
            MainActor.assumeIsolated {
                context.monitor?.receive(typeRawValue: typeRawValue, keyCode: keyCode, flags: flags)
            }
        }
    }
    return Unmanaged.passUnretained(event)
}
