import CoreML
import Foundation
import TypingRTCore
import WhisperKit

actor WhisperEngine {
    private struct ModelKey: Equatable {
        let model: URL
        let tokenizer: URL
    }

    private var pipe: WhisperKit?
    private var loadedKey: ModelKey?
    private var promptTerms: [String]?
    private var cachedPromptTokens: [Int] = []

    func perform(_ request: WorkerRequest, kind: WorkerOperation) async -> WorkerReply {
        var loadSeconds = 0.0
        var inferenceSeconds = 0.0
        do {
            try Task.checkCancellation()
            let loadStart = ContinuousClock.now
            let pipe = try await loadIfNeeded(request)
            loadSeconds = Self.elapsed(since: loadStart)
            try Task.checkCancellation()

            guard let tokenizer = pipe.tokenizer as? OfflineWhisperTokenizer,
                  let decoderContextLength = pipe.textDecoder.kvCacheMaxSequenceLength else {
                throw WorkerFailure.incompatibleTokenizer
            }
            let promptTokens: [Int]
            if promptTerms == request.canonicalTerms {
                promptTokens = cachedPromptTokens
            } else {
                promptTokens = DictionaryPrompt.tokens(
                    for: request.canonicalTerms, decoderContextLength: decoderContextLength,
                    specialTokenBegin: tokenizer.specialTokens.specialTokenBegin,
                    encode: tokenizer.encodeContext
                )
                promptTerms = request.canonicalTerms
                cachedPromptTokens = promptTokens
            }

            if kind == .prepare {
                return WorkerReply(sessionID: request.sessionID, text: nil, error: nil,
                                   loadSeconds: loadSeconds, inferenceSeconds: 0)
            }

            guard !request.audioPath.isEmpty,
                  FileManager.default.isReadableFile(atPath: request.audioPath) else {
                throw WorkerFailure.audioUnavailable
            }

            if try !AudioSignalInspection.hasSignal(at: URL(fileURLWithPath: request.audioPath)) {
                return WorkerReply(sessionID: request.sessionID, text: "", error: nil,
                                   loadSeconds: loadSeconds, inferenceSeconds: 0)
            }

            let inferenceStart = ContinuousClock.now
            let results = try await pipe.transcribe(
                audioPath: request.audioPath,
                audioInputOptions: AudioInputOptions(
                    channelMode: .sumChannels(nil),
                    audioLoadingMode: .incremental(chunkDurationSeconds: 120, maxBufferedChunks: 2)
                ),
                decodeOptions: DecodingOptions(
                    verbose: false,
                    task: .transcribe,
                    language: nil,
                    detectLanguage: true,
                    skipSpecialTokens: true,
                    wordTimestamps: false,
                    promptTokens: promptTokens.isEmpty ? nil : promptTokens,
                    concurrentWorkerCount: 1,
                    chunkingStrategy: .vad
                ),
                callback: { _ in !Task.isCancelled }
            )
            inferenceSeconds = Self.elapsed(since: inferenceStart)
            // A false progress callback can produce partial results rather than
            // throwing. Never return those as a completed cancelled dictation.
            try Task.checkCancellation()
            for result in results {
                let windows = Dictionary(grouping: result.segments, by: \.seek)
                let counts = windows.values.map { $0.reduce(0) { $0 + $1.tokens.count } }
                guard !DictionaryPrompt.mayHaveTruncatedWindow(
                    tokenCountsByWindow: counts, promptTokenCount: promptTokens.count
                ) else { throw WorkerFailure.incompleteTranscription }
            }
            let text = results.map(\.text).map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }.joined(separator: " ")
            return WorkerReply(sessionID: request.sessionID, text: text, error: nil,
                               loadSeconds: loadSeconds, inferenceSeconds: inferenceSeconds)
        } catch is CancellationError {
            return WorkerReply(sessionID: request.sessionID, text: nil, error: "Das Diktat wurde verworfen.",
                               loadSeconds: loadSeconds, inferenceSeconds: inferenceSeconds)
        } catch let failure as WorkerFailure {
            return WorkerReply(sessionID: request.sessionID, text: nil, error: failure.message,
                               loadSeconds: loadSeconds, inferenceSeconds: inferenceSeconds,
                               errorCode: failure == .incompleteTranscription ? .incompleteTranscription : nil)
        } catch {
            // Third-party errors may contain paths, tokens or decoded text.
            // Return a fixed product message and never log the underlying error.
            return WorkerReply(sessionID: request.sessionID, text: nil,
                               error: "Die lokale Spracherkennung ist fehlgeschlagen. Bitte prüfe Modell und Tokenizer.",
                               loadSeconds: loadSeconds, inferenceSeconds: inferenceSeconds)
        }
    }

    private func loadIfNeeded(_ request: WorkerRequest) async throws -> WhisperKit {
        guard !request.modelPath.isEmpty, !request.tokenizerPath.isEmpty else {
            throw WorkerFailure.modelUnavailable
        }
        let key = ModelKey(
            model: URL(fileURLWithPath: request.modelPath).standardizedFileURL.resolvingSymlinksInPath(),
            tokenizer: URL(fileURLWithPath: request.tokenizerPath).standardizedFileURL.resolvingSymlinksInPath()
        )
        if loadedKey == key, let pipe { return pipe }
        promptTerms = nil
        cachedPromptTokens = []

        for name in ["MelSpectrogram", "AudioEncoder", "TextDecoder"] {
            guard FileManager.default.fileExists(atPath: key.model.appendingPathComponent(name + ".mlmodelc").path) else {
                throw WorkerFailure.modelUnavailable
            }
        }

        // This public local factory has no Hub fallback. The standard WhisperKit
        // tokenizer loader does, even with config.download == false.
        let tokenizer = try await OfflineWhisperTokenizer.load(from: key.tokenizer)
        try Task.checkCancellation()

        if let pipe {
            await pipe.unloadModels()
            self.pipe = nil
            loadedKey = nil
        }

        let configuration = WhisperKitConfig(
            modelFolder: key.model.path,
            tokenizerFolder: key.tokenizer,
            computeOptions: ModelComputeOptions(
                melCompute: .cpuAndGPU,
                audioEncoderCompute: .cpuAndNeuralEngine,
                textDecoderCompute: .cpuAndNeuralEngine
            ),
            verbose: false,
            logLevel: .none,
            prewarm: true,
            load: false,
            download: false
        )
        let candidate = try await WhisperKit(configuration)
        try Task.checkCancellation()
        candidate.tokenizer = tokenizer
        try await candidate.loadModels()
        try Task.checkCancellation()

        guard let vocabularySize = candidate.textDecoder.logitsSize,
              vocabularySize == tokenizer.expectedVocabularySize else {
            throw WorkerFailure.incompatibleTokenizer
        }
        // Injecting a tokenizer bypasses WhisperKit.loadTokenizerIfNeeded(),
        // including its multilingual-flag setup. Restore this model metadata
        // explicitly after validating the decoder's vocabulary size.
        candidate.textDecoder.isModelMultilingual = vocabularySize != 51_864
        guard candidate.textDecoder.isModelMultilingual else {
            throw WorkerFailure.incompatibleTokenizer
        }
        pipe = candidate
        loadedKey = key
        return candidate
    }

    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        let duration = start.duration(to: .now).components
        return Double(duration.seconds) + Double(duration.attoseconds) / 1e18
    }
}

enum WorkerFailure: Error, Equatable {
    case modelUnavailable
    case tokenizerUnavailable
    case incompatibleTokenizer
    case audioUnavailable
    case incompleteTranscription

    var message: String {
        switch self {
        case .modelUnavailable:
            "Das lokale Whisper-Modell ist unvollständig oder nicht verfügbar."
        case .tokenizerUnavailable:
            "Der lokale Tokenizer fehlt oder ist ungültig. Bitte richte das Modell erneut ein."
        case .incompatibleTokenizer:
            "Modell und lokaler Tokenizer passen nicht zusammen. Bitte richte das Modell erneut ein."
        case .audioUnavailable:
            "Die temporäre Aufnahme ist nicht verfügbar."
        case .incompleteTranscription:
            "Die Erkennung hat ihre Textgrenze erreicht. Es wurde kein möglicherweise unvollständiges Diktat eingefügt. Bitte in kürzeren Abschnitten erneut diktieren."
        }
    }
}
