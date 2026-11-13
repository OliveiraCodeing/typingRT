import Foundation
import Testing
import TypingRTCore
@testable import TranscriptionWorker

@Suite struct LevelNormalizerTests {
    /// Fixed sequence so every run sees the same noise.
    private struct Noise: RandomNumberGenerator {
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state
        }
    }

    /// Deterministic stand-in for speech: bursts of a tone separated by pauses.
    private func speech(seconds: Int, level: Float, noise: Float = 0) -> [Float] {
        var generator = Noise()
        return (0..<(seconds * 16_000)).map { index in
            let burst = (index / 8_000) % 3 != 2
            let tone = burst ? level * 1.414 * Float(sin(Double(index) * 0.2)) : 0
            return tone + (noise > 0 ? Float.random(in: -noise...noise, using: &generator) : 0)
        }
    }

    @Test func aFewWordsInALongHoldAreNotDrivenIntoClipping() {
        // 20 s held, under one second spoken at a normal level, quiet room noise.
        var generator = Noise()
        var samples = (0..<320_000).map { _ in Float.random(in: -0.003...0.003, using: &generator) }
        for index in 160_000..<174_400 { samples[index] += 0.05 * 1.414 * Float(sin(Double(index) * 0.2)) }
        let gain = LevelNormalizer.gain(for: samples)
        #expect(gain >= 1 && gain <= 4.5)
        LevelNormalizer.normalize(&samples)
        #expect(samples.filter { abs($0) >= 1 }.isEmpty)
    }

    @Test func pausesStayBelowTheSplitterThresholdWhenTheRoomIsNoisy() {
        // Speech 0.05 over room noise 0.012: lifting it would hide every pause.
        var samples = speech(seconds: 9, level: 0.05, noise: 0.0208)
        let before = LevelNormalizer.frameLevels(samples).sorted()[9]
        #expect(before < LevelNormalizer.voiceThreshold)
        LevelNormalizer.normalize(&samples)
        let levels = LevelNormalizer.frameLevels(samples).sorted()
        #expect(levels[levels.count / 10] < LevelNormalizer.voiceThreshold)
    }

    @Test func isolatedNoisesAreNotMistakenForSpeech() {
        // Clicks and a short cough inside 20 s of quiet: nothing sustained.
        var samples = [Float](repeating: 0, count: 320_000)
        for start in stride(from: 16_000, to: 300_000, by: 24_000) {
            for index in start..<(start + 1_600) { samples[index] = 0.3 * Float(sin(Double(index) * 0.3)) }
        }
        #expect(!LevelNormalizer.containsSpeech(samples))
    }

    @Test func quietSpeechIsLiftedAboveTheSplitterThreshold() {
        var samples = speech(seconds: 6, level: 0.008, noise: 0.001)
        let gain = LevelNormalizer.gain(for: samples)
        #expect(gain > 5 && gain <= 50)
        LevelNormalizer.normalize(&samples)
        let levels = LevelNormalizer.frameLevels(samples)
        #expect(levels.filter { $0 > LevelNormalizer.voiceThreshold }.count > levels.count / 2)
        #expect(samples.allSatisfy { $0 >= -1 && $0 <= 1 })
    }

    @Test func loudOrEmptyAudioIsLeftUntouched() {
        let loud = speech(seconds: 3, level: 0.3)
        var copy = loud
        LevelNormalizer.normalize(&copy)
        #expect(copy == loud)
        #expect(LevelNormalizer.gain(for: []) == 1)
        #expect(LevelNormalizer.gain(for: Array(repeating: 0, count: 48_000)) == 1)
    }

    @Test func aSingleClickDoesNotPreventNormalisation() {
        var samples = speech(seconds: 10, level: 0.008)
        for index in 16_000..<16_400 { samples[index] = 0.9 }
        #expect(LevelNormalizer.gain(for: samples) > 5)
    }

    @Test func gainIsBoundedSoSilenceIsNotTurnedIntoSpeech() {
        #expect(LevelNormalizer.gain(for: speech(seconds: 3, level: 0.000_1)) == 50)
    }

    @Test func speechIsDistinguishedFromSteadyNoiseAndSilence() {
        #expect(LevelNormalizer.containsSpeech(speech(seconds: 6, level: 0.1, noise: 0.005)))
        var generator = Noise()
        let noise = (0..<96_000).map { _ in Float.random(in: -0.2...0.2, using: &generator) }
        #expect(!LevelNormalizer.containsSpeech(noise))
        #expect(!LevelNormalizer.containsSpeech(Array(repeating: 0, count: 96_000)))
        #expect(!LevelNormalizer.containsSpeech(speech(seconds: 1, level: 0.1).prefix(8_000).map { $0 }))
    }

    /// Opt-in: runs the real engine on a recording.
    /// TYPINGRT_TEST_MODEL, TYPINGRT_TEST_TOKENIZER, TYPINGRT_TEST_AUDIO (paths),
    /// TYPINGRT_TEST_EXPECT (substrings separated by "|"), optional TYPINGRT_TEST_TERMS (comma separated).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPINGRT_TEST_AUDIO"] != nil))
    func longQuietRecordingIsTranscribedToTheEnd() async throws {
        let env = ProcessInfo.processInfo.environment
        let model = try #require(env["TYPINGRT_TEST_MODEL"]), tokenizer = try #require(env["TYPINGRT_TEST_TOKENIZER"])
        let expected = try #require(env["TYPINGRT_TEST_EXPECT"]).split(separator: "|").map(String.init)
        let terms = (env["TYPINGRT_TEST_TERMS"] ?? "").split(separator: ",").map(String.init)
        let engine = WhisperEngine()
        for audio in try #require(env["TYPINGRT_TEST_AUDIO"]).split(separator: "|").map(String.init) {
            let reply = await engine.perform(WorkerRequest(
                sessionID: UUID(), audioPath: audio, modelPath: model, tokenizerPath: tokenizer,
                canonicalTerms: terms), kind: .transcribe)
            #expect(reply.error == nil, "\(audio)")
            let text = reply.text ?? ""
            let missing = expected.filter { !text.localizedCaseInsensitiveContains($0) }
            #expect(missing.isEmpty, "\(URL(fileURLWithPath: audio).lastPathComponent): fehlt \(missing), Wörter \(text.split(separator: " ").count)")
        }
    }
}
