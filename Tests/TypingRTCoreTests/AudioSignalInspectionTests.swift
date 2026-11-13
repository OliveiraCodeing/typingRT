import AVFoundation
import Foundation
import Testing
@testable import TypingRTCore

struct AudioSignalInspectionTests {
    @Test func digitalSilenceDoesNotReachRecognition() throws {
        let url = try audio(secondChannelSample: 0)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try !AudioSignalInspection.hasSignal(at: url))
    }

    @Test func quietSignalInSecondChannelIsPreserved() throws {
        let url = try audio(secondChannelSample: 0.000_01)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(try AudioSignalInspection.hasSignal(at: url))
    }

    @Test func damagedAudioFailsInsteadOfProducingText() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid synthetic audio".utf8).write(to: url)
        #expect(throws: (any Error).self) { try AudioSignalInspection.hasSignal(at: url) }
    }

    private func audio(secondChannelSample: Float) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8192)!
        buffer.frameLength = 8192
        for channel in 0..<2 { buffer.floatChannelData![channel].initialize(repeating: 0, count: 8192) }
        buffer.floatChannelData![1][8191] = secondChannelSample
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            try file.write(from: buffer)
        }
        return url
    }
}
