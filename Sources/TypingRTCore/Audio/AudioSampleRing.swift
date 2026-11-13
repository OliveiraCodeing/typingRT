import AVFoundation
import Synchronization

/// One audio-callback producer, one file-writer consumer. Indices are monotonically
/// increasing; publishing an index transfers ownership of the corresponding slots.
final class AudioSampleRing: @unchecked Sendable {
    let capacityFrames: Int
    let channelCount: Int
    let allocatedSampleCount: Int
    private let samples: UnsafeMutablePointer<Float>
    private let writeIndex = Atomic<UInt64>(0)
    private let readIndex = Atomic<UInt64>(0)

    init(capacityFrames: Int = 65_536, channelCount: Int) {
        precondition(capacityFrames > 0 && capacityFrames.nonzeroBitCount == 1)
        precondition((1...8).contains(channelCount))
        self.capacityFrames = capacityFrames
        self.channelCount = channelCount
        allocatedSampleCount = capacityFrames * channelCount
        samples = .allocate(capacity: allocatedSampleCount)
        samples.initialize(repeating: 0, count: allocatedSampleCount)
    }

    deinit {
        samples.deinitialize(count: allocatedSampleCount)
        samples.deallocate()
    }

    var availableFrames: Int {
        Int(writeIndex.load(ordering: .acquiring) &- readIndex.load(ordering: .acquiring))
    }

    /// All-or-nothing: failure never publishes a partially copied audio buffer.
    func push(channels: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int) -> Bool {
        guard frames >= 0, frames <= capacityFrames else { return false }
        let write = writeIndex.load(ordering: .relaxed)
        let read = readIndex.load(ordering: .acquiring)
        guard UInt64(frames) <= UInt64(capacityFrames) - (write &- read) else { return false }

        for frame in 0..<frames {
            let slot = Int((write &+ UInt64(frame)) & UInt64(capacityFrames - 1)) * channelCount
            for channel in 0..<channelCount {
                samples[slot + channel] = channels[channel][frame]
            }
        }
        writeIndex.store(write &+ UInt64(frames), ordering: .releasing)
        return true
    }

    /// The destination is allocated once by the writer, never by the audio callback.
    func pop(into buffer: AVAudioPCMBuffer) -> Int {
        guard Int(buffer.format.channelCount) == channelCount,
              let channels = buffer.floatChannelData else { return 0 }
        let read = readIndex.load(ordering: .relaxed)
        let write = writeIndex.load(ordering: .acquiring)
        let frames = min(Int(write &- read), Int(buffer.frameCapacity))

        for frame in 0..<frames {
            let slot = Int((read &+ UInt64(frame)) & UInt64(capacityFrames - 1)) * channelCount
            for channel in 0..<channelCount {
                channels[channel][frame] = samples[slot + channel]
            }
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        readIndex.store(read &+ UInt64(frames), ordering: .releasing)
        return frames
    }
}

/// Accessed only by the serial writer (or synchronously by synthetic writer tests).
final class PCMFileWriter {
    let buffer: AVAudioPCMBuffer
    private var file: AVAudioFile?
    private(set) var writtenFrames: Int64 = 0

    init(url: URL, format: AVAudioFormat, bufferFrames: AVAudioFrameCount = 1_024) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: bufferFrames) else {
            throw AudioCaptureError.unsupportedFormat
        }
        self.buffer = buffer
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ]
        file = try AVAudioFile(
            forWriting: url, settings: settings,
            commonFormat: .pcmFormatFloat32, interleaved: false
        )
    }

    func drain(_ ring: AudioSampleRing) throws {
        guard let file else { throw AudioCaptureError.fileWriteFailed }
        while ring.pop(into: buffer) > 0 {
            try file.write(from: buffer)
            writtenFrames += Int64(buffer.frameLength)
        }
    }

    func close() {
        file = nil
    }
}
