/// A side-specific modifier transition decoded without depending on AppKit.
public enum RightOptionEvent: Sendable, Equatable {
    case pressed
    case released

    /// HIToolbox/Events.h: kVK_RightOption = 0x3D.
    public static let keyCode: UInt16 = 61

    /// IOKit/hidsystem/IOLLEvent.h: NX_DEVICERALTKEYMASK = 0x00000040.
    /// The aggregate alternate flag cannot distinguish releasing the right key
    /// while the left Option key remains held.
    public static let deviceFlagMask: UInt64 = 0x0000_0040

    public var isPressed: Bool {
        self == .pressed
    }

    /// Call only for a flagsChanged event. Other modifier key codes are ignored,
    /// even when their event carries the current right-Option state.
    public static func decode(keyCode: UInt16, flags: UInt64) -> Self? {
        guard keyCode == Self.keyCode else { return nil }
        return flags & deviceFlagMask != 0 ? .pressed : .released
    }
}
