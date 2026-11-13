import AVFoundation
import Foundation

/// A conservative digital-silence gate, not a speech classifier. Reads at most
/// 4096 frames at once. Must run on the worker/utility executor, never the UI.
public enum AudioSignalInspection {
    public static func hasSignal(at url: URL) throws -> Bool {
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard (1...8).contains(format.channelCount), format.sampleRate.isFinite, format.sampleRate > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        while file.framePosition < file.length {
            try Task.checkCancellation()
            try file.read(into: buffer)
            guard buffer.frameLength > 0, let samples = buffer.floatChannelData else {
                throw CocoaError(.fileReadCorruptFile)
            }
            for channel in 0..<Int(format.channelCount) {
                for frame in 0..<Int(buffer.frameLength) {
                    let sample = samples[channel][frame]
                    guard sample.isFinite else { throw CocoaError(.fileReadCorruptFile) }
                    // -120 dBFS: only numerical silence, deliberately preserves
                    // quiet voices. Whisper's no-speech/VAD handles real noise.
                    if abs(sample) > 0.000_001 { return true }
                }
            }
        }
        return false
    }
}
