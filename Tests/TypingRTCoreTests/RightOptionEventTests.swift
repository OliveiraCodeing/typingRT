import Testing
@testable import TypingRTCore

struct RightOptionEventTests {
    private let alternate: UInt64 = 0x0008_0000
    private let leftOption: UInt64 = 0x0000_0020
    private let rightOption: UInt64 = 0x0000_0040

    @Test
    func rightOptionPressUsesTheDeviceSpecificFlag() {
        #expect(RightOptionEvent.decode(keyCode: 61, flags: alternate | rightOption) == .pressed)
        #expect(RightOptionEvent.decode(keyCode: 61, flags: rightOption) == .pressed)
        #expect(RightOptionEvent.decode(keyCode: 61, flags: 0) == .released)
    }

    @Test
    func leftOptionDoesNotGenerateRightOptionEvents() {
        #expect(RightOptionEvent.decode(keyCode: 58, flags: alternate | leftOption) == nil)
        #expect(RightOptionEvent.decode(keyCode: 58, flags: 0) == nil)
        #expect(RightOptionEvent.decode(keyCode: 58, flags: alternate | leftOption | rightOption) == nil)
        #expect(RightOptionEvent.decode(keyCode: 58, flags: alternate | rightOption) == nil)
    }

    @Test
    func releasingRightOptionWhileLeftOptionRemainsHeldIsARelease() {
        #expect(RightOptionEvent.decode(keyCode: 61, flags: alternate | leftOption | rightOption) == .pressed)
        #expect(RightOptionEvent.decode(keyCode: 61, flags: alternate | leftOption) == .released)
    }

    @Test
    func aggregateAlternateFlagAloneCannotMeanRightOptionPressed() {
        #expect(RightOptionEvent.decode(keyCode: 61, flags: alternate) == .released)
    }

    @Test
    func otherModifiersDoNotStartOrStopRightOption() {
        for keyCode: UInt16 in [54, 55, 56, 57, 59, 60, 62, 63] {
            #expect(RightOptionEvent.decode(keyCode: keyCode, flags: alternate | rightOption) == nil)
            #expect(RightOptionEvent.decode(keyCode: keyCode, flags: 0) == nil)
        }
    }

    @Test
    func unrelatedFlagsDoNotChangeTheSideSpecificResult() {
        let unrelatedFlags: UInt64 = 0x0010_0000 | 0x0002_0000 | 0x0004_0000
        #expect(RightOptionEvent.decode(keyCode: 61, flags: unrelatedFlags | alternate | rightOption) == .pressed)
        #expect(RightOptionEvent.decode(keyCode: 61, flags: unrelatedFlags | alternate | leftOption) == .released)
    }
}
