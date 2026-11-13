import AVFoundation
import Foundation
import Testing
@testable import TypingRTCore

struct AudioCaptureTests {
    @Test
    func ringPreservesStereoSamplesAcrossWraparound() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2))
        let ring = AudioSampleRing(capacityFrames: 8, channelCount: 2)
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 6))
        let destination = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        let channels = try #require(source.floatChannelData)
        for frame in 0..<6 {
            channels[0][frame] = Float(frame)
            channels[1][frame] = -Float(frame)
        }
        #expect(ring.push(channels: channels, frames: 6))
        #expect(ring.pop(into: destination) == 4)
        let output = try #require(destination.floatChannelData)
        for frame in 0..<4 {
            #expect(output[0][frame] == Float(frame))
            #expect(output[1][frame] == -Float(frame))
        }
        for frame in 0..<6 {
            channels[0][frame] = Float(frame + 6)
            channels[1][frame] = -Float(frame + 6)
        }
        #expect(ring.push(channels: channels, frames: 6))
        for offset in [4, 8] {
            #expect(ring.pop(into: destination) == 4)
            for frame in 0..<4 {
                #expect(output[0][frame] == Float(frame + offset))
                #expect(output[1][frame] == -Float(frame + offset))
            }
        }
        #expect(ring.availableFrames == 0)
        #expect(ring.pop(into: destination) == 0)
        #expect(ring.allocatedSampleCount == 16)
    }

    @Test
    func overflowRejectsTheEntireBufferWithoutDroppingExistingFrames() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        let channels = try #require(source.floatChannelData)
        for frame in 0..<8 { channels[0][frame] = Float(frame) }
        let ring = AudioSampleRing(capacityFrames: 8, channelCount: 1)
        #expect(ring.push(channels: channels, frames: 6))
        #expect(!ring.push(channels: channels, frames: 3))
        #expect(ring.availableFrames == 6)
        #expect(!ring.push(channels: channels, frames: 9))
        #expect(ring.availableFrames == 6)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8))
        #expect(ring.pop(into: output) == 6)
        let result = try #require(output.floatChannelData)
        for frame in 0..<6 { #expect(result[0][frame] == Float(frame)) }
    }

    @Test
    func wavWriterPreservesKnownSamplesAndFrameCount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("known.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 2))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2_048))
        let channels = try #require(source.floatChannelData)
        for frame in 0..<2_048 {
            channels[0][frame] = Float(frame % 128) / 128
            channels[1][frame] = -Float(frame % 128) / 128
        }
        let ring = AudioSampleRing(capacityFrames: 4_096, channelCount: 2)
        let writer = try PCMFileWriter(url: url, format: format)
        #expect(ring.push(channels: channels, frames: 2_048))
        try writer.drain(ring)
        #expect(writer.writtenFrames == 2_048)
        writer.close()

        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.length == 2_048)
        #expect(file.processingFormat.sampleRate == 16_000)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 2_048))
        try file.read(into: output)
        let actual = try #require(output.floatChannelData)
        for frame in 0..<2_048 {
            #expect(actual[0][frame] == channels[0][frame])
            #expect(actual[1][frame] == channels[1][frame])
        }
    }

    @Test
    func tenMinutesOfSyntheticAudioUsesConstantRingAndWriterCapacity() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ten-minutes.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_024))
        let channels = try #require(source.floatChannelData)
        let ring = AudioSampleRing(capacityFrames: 4_096, channelCount: 1)
        let writer = try PCMFileWriter(url: url, format: format)
        let totalFrames = 8_000 * 60 * 10
        var frameOffset = 0
        while frameOffset < totalFrames {
            let count = min(1_024, totalFrames - frameOffset)
            for frame in 0..<count {
                channels[0][frame] = Float((frameOffset + frame) % 256) / 256
            }
            guard ring.push(channels: channels, frames: count) else {
                Issue.record("Synthetic stream overflowed despite draining each fixed-size block")
                return
            }
            try writer.drain(ring)
            frameOffset += count
        }
        writer.close()
        #expect(writer.writtenFrames == Int64(totalFrames))
        #expect(ring.allocatedSampleCount == 4_096)
        #expect(writer.buffer.frameCapacity == 1_024)
        #expect(ring.availableFrames == 0)
        let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        #expect(file.length == Int64(totalFrames))
        let output = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1_024))
        file.framePosition = Int64(totalFrames - 1_024)
        try file.read(into: output)
        let actual = try #require(output.floatChannelData)
        for frame in 0..<1_024 {
            #expect(actual[0][frame] == Float((totalFrames - 1_024 + frame) % 256) / 256)
        }
    }

    @Test
    func releaseBeforeAsyncStartInvalidatesThePreparedGate() throws {
        let gate = AudioCaptureGate()
        let id = UUID()
        gate.prepare(sessionID: id)
        gate.close()
        #expect(throws: CancellationError.self) { try gate.claim(sessionID: id) }
    }

    @Test
    func releaseAfterClaimAndStaleTokenCannotReopenANewSession() throws {
        let gate = AudioCaptureGate()
        let firstID = UUID()
        gate.prepare(sessionID: firstID)
        let firstToken = try gate.claim(sessionID: firstID)
        #expect(gate.permits(firstToken))
        gate.close()
        #expect(!gate.permits(firstToken))
        gate.finish(sessionID: firstID)

        let nextID = UUID()
        gate.prepare(sessionID: nextID)
        let nextToken = try gate.claim(sessionID: nextID)
        gate.close(ifToken: firstToken)
        #expect(gate.permits(nextToken))
        #expect(!gate.permits(firstToken))
        gate.close()
        gate.finish(sessionID: nextID)
    }

    @Test
    func anActiveClaimPreventsAnotherPreparationOrStart() throws {
        let gate = AudioCaptureGate()
        let id = UUID()
        gate.prepare(sessionID: id)
        let token = try gate.claim(sessionID: id)
        gate.prepare(sessionID: UUID())
        #expect(gate.permits(token))
        #expect(throws: AudioCaptureError.self) { try gate.claim(sessionID: UUID()) }
        gate.close()
        gate.finish(sessionID: id)
    }

    @Test
    func staleStopOrCancelCannotCloseANewerPreparedSession() throws {
        let gate = AudioCaptureGate()
        let oldID = UUID()
        gate.prepare(sessionID: oldID)
        gate.close(sessionID: oldID)
        let newID = UUID()
        gate.prepare(sessionID: newID)

        // stop(oldID) closes only its session before enqueueing; cancel(oldID)
        // additionally finishes ownership on the lifecycle queue.
        gate.close(sessionID: oldID)
        gate.finish(sessionID: oldID)
        let newToken = try gate.claim(sessionID: newID)
        #expect(gate.permits(newToken))

        gate.close(sessionID: oldID)
        gate.finish(sessionID: oldID)
        #expect(gate.permits(newToken))
        gate.close(sessionID: newID)
        #expect(!gate.permits(newToken))
        gate.finish(sessionID: newID)
    }

    @Test
    func staleRealtimeFailureCannotCloseANewerGeneration() throws {
        let gate = AudioCaptureGate()
        let oldID = UUID()
        gate.prepare(sessionID: oldID)
        let oldToken = try gate.claim(sessionID: oldID)
        gate.close(sessionID: oldID)
        gate.finish(sessionID: oldID)
        let newID = UUID()
        gate.prepare(sessionID: newID)
        let newToken = try gate.claim(sessionID: newID)

        gate.rejectSamples(ifToken: oldToken)
        #expect(gate.permits(newToken))
        gate.rejectSamples(ifToken: newToken)
        #expect(!gate.permits(newToken))
        gate.finish(sessionID: newID)
    }

    @Test
    func peakUsesAllChannelsInTheSyntheticCapturePath() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("typingRT-audio-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 8_000, channels: 2))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        source.frameLength = 4
        let channels = try #require(source.floatChannelData)
        for frame in 0..<4 {
            channels[0][frame] = 0.125
            channels[1][frame] = -0.75
        }
        let gate = AudioCaptureGate()
        let id = UUID()
        gate.prepare(sessionID: id)
        let token = try gate.claim(sessionID: id)
        let writer = try CaptureWriter(
            url: directory.appendingPathComponent("peak.wav"), format: format,
            gate: gate, token: token, onFailure: { _ in }
        )
        writer.receive(source)
        #expect(gate.level == 0.75)
        gate.close(sessionID: id)
        let result = writer.finish(discard: false)
        #expect(result.frames == 4)
        #expect(result.failure == nil)
        gate.finish(sessionID: id)
    }

    @Test
    func aClosedOrUnpreparedServiceNeverTouchesMicrophoneHardware() async {
        let service = AudioCaptureService()
        do {
            try await service.start(sessionID: UUID())
            Issue.record("An unprepared service must reject before hardware initialization")
        } catch is CancellationError {} catch {
            Issue.record("Unexpected error for unprepared service: \(error)")
        }
        let id = UUID()
        service.prepare(sessionID: id)
        service.closeCaptureGate()
        do {
            try await service.start(sessionID: id)
            Issue.record("A released hold must not initialize microphone hardware")
        } catch is CancellationError {} catch {
            Issue.record("Unexpected error for released hold: \(error)")
        }
        #expect(service.level == 0)
        await service.cancel()
    }
}
