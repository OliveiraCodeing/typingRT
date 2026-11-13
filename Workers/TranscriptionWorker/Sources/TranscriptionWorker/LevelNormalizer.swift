/// Brings quiet recordings to a level the recogniser handles reliably.
///
/// WhisperKit splits audio longer than one window at pauses, using a fixed
/// energy threshold. A quiet microphone stays below it, so the splits fall
/// blindly into the middle of words and a chunk can decode to nothing. The
/// level is therefore lifted before splitting.
enum LevelNormalizer {
    /// 100 ms at the recogniser's 16 kHz sample rate.
    static let frameLength = 1_600
    /// The energy threshold WhisperKit's splitter treats as voice.
    static let voiceThreshold: Float = 0.02

    static func frameLevels(_ samples: [Float]) -> [Float] {
        var levels: [Float] = []
        levels.reserveCapacity(samples.count / frameLength)
        var start = 0
        while start + frameLength <= samples.count {
            var sum: Float = 0
            for index in start..<(start + frameLength) { sum += samples[index] * samples[index] }
            let level = (sum / Float(frameLength)).squareRoot()
            levels.append(level.isFinite ? level : 0)
            start += frameLength
        }
        return levels
    }

    /// Gain that lifts the speech level to `target`. Never attenuates.
    ///
    /// - The 95th percentile of the frame levels stands for speech, so a single
    ///   key click cannot defeat it.
    /// - The loudest sustained frames (98th percentile) cap the gain: a long
    ///   hold with only a few spoken words must not be driven into clipping.
    /// - The background (10th percentile) caps it too: pauses have to stay
    ///   below the splitter threshold or they are no longer found.
    static func gain(for samples: [Float], target: Float = 0.1, maximumGain: Float = 50) -> Float {
        let levels = frameLevels(samples).sorted()
        guard !levels.isEmpty else { return 1 }
        func percentile(_ fraction: Float) -> Float { levels[min(levels.count - 1, Int(Float(levels.count) * fraction))] }
        let speech = percentile(0.95)
        guard speech > 0.000_01, speech < target else { return 1 }
        var factor = min(target / speech, maximumGain)
        let loud = percentile(0.98)
        if loud > 0 { factor = min(factor, 0.2 / loud) }
        let background = percentile(0.10)
        if background > 0 { factor = min(factor, voiceThreshold * 0.6 / background) }
        return max(1, factor)
    }

    static func normalize(_ samples: inout [Float]) {
        let factor = gain(for: samples)
        guard factor != 1 else { return }
        for index in samples.indices { samples[index] = max(-1, min(1, samples[index] * factor)) }
    }

    /// Whether a chunk holds at least 1.5 s of sustained sound that stands
    /// clearly above its own background. Steady noise and isolated clicks,
    /// coughs or key strokes do not count, so a recording without speech still
    /// ends as "nothing recognised" rather than an error.
    static func containsSpeech(_ samples: [Float]) -> Bool {
        let levels = frameLevels(samples)
        guard levels.count >= 15 else { return false }
        let background = levels.sorted()[levels.count / 10]
        var sustained = 0, run = 0
        for level in levels {
            if level > voiceThreshold && level > background * 2.5 {
                run += 1
            } else {
                if run >= 3 { sustained += run }
                run = 0
            }
        }
        if run >= 3 { sustained += run }
        return sustained >= 15
    }

    /// WhisperKit's splitter never emits the final stretch when it is shorter
    /// than this. Appending that much silence keeps all recorded audio covered.
    static let trailingSilence = 16_000
}
