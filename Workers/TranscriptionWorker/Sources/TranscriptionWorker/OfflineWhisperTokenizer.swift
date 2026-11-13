import Foundation
import WhisperKit

/// Local-only adapter around ArgmaxCore's public tokenizer. WhisperKit's own
/// wrapper initializer is internal in 1.1.1, and its factory may silently fall
/// back to the Hub. Neither factory is called from this adapter.
struct OfflineWhisperTokenizer: WhisperTokenizer, Sendable {
    private let tokenizer: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>
    let expectedVocabularySize: Int

    static func load(from folder: URL) async throws -> Self {
        for filename in ["tokenizer.json", "tokenizer_config.json"] {
            guard FileManager.default.isReadableFile(atPath: folder.appendingPathComponent(filename).path) else {
                throw WorkerFailure.tokenizerUnavailable
            }
        }
        let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: folder, strict: true)
        return try Self(tokenizer: tokenizer)
    }

    private init(tokenizer: TokenizerWrapper) throws {
        func required(_ name: String) throws -> Int {
            guard let token = tokenizer.convertTokenToId(name) else {
                throw WorkerFailure.tokenizerUnavailable
            }
            return token
        }

        let english = try required("<|en|>")
        let translate = try required("<|translate|>")
        let firstTimestamp = try required("<|0.00|>")
        let lastTimestamp = try required("<|30.00|>")
        guard english < translate, translate - english <= 128,
              lastTimestamp - firstTimestamp == 1_500 else {
            throw WorkerFailure.incompatibleTokenizer
        }
        let languageTokens = Set(english..<translate)
        let german = try required("<|de|>")
        guard languageTokens.contains(german) else { throw WorkerFailure.incompatibleTokenizer }
        let whitespace = tokenizer.encode(text: " ", addSpecialTokens: false)
        guard whitespace.count == 1, let whitespaceToken = whitespace.first else {
            throw WorkerFailure.tokenizerUnavailable
        }

        self.tokenizer = tokenizer
        self.allLanguageTokens = languageTokens
        self.expectedVocabularySize = lastTimestamp + 1
        self.specialTokens = try SpecialTokens(
            endToken: required("<|endoftext|>"),
            englishToken: english,
            noSpeechToken: required("<|nospeech|>"),
            noTimestampsToken: required("<|notimestamps|>"),
            specialTokenBegin: required("<|endoftext|>"),
            startOfPreviousToken: required("<|startofprev|>"),
            startOfTranscriptToken: required("<|startoftranscript|>"),
            timeTokenBegin: firstTimestamp,
            transcribeToken: required("<|transcribe|>"),
            translateToken: translate,
            whitespaceToken: whitespaceToken
        )
    }

    func encode(text: String) -> [Int] { tokenizer.encode(text: text) }
    func encodeContext(text: String) -> [Int] { tokenizer.encode(text: text, addSpecialTokens: false) }
    func decode(tokens: [Int]) -> String { tokenizer.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { tokenizer.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { tokenizer.convertIdToToken(id) }

    /// Token-conserving word grouping for the supported German/English scripts.
    /// Word timestamps stay disabled; this fulfills the tokenizer protocol
    /// without attempting language-specific alignment or discarding byte pieces.
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        var words: [String] = []
        var wordTokens: [[Int]] = []
        var pending: [Int] = []

        for token in tokenIds {
            pending.append(token)
            let piece = decode(tokens: pending)
            if piece.contains("\u{fffd}"), token < specialTokens.specialTokenBegin { continue }

            let startsWord = words.isEmpty || token >= specialTokens.specialTokenBegin
                || piece.first?.isWhitespace == true
                || wordTokens.last?.last.map { $0 >= specialTokens.specialTokenBegin } == true
            if startsWord {
                words.append(piece)
                wordTokens.append(pending)
            } else {
                words[words.count - 1] += piece
                wordTokens[wordTokens.count - 1].append(contentsOf: pending)
            }
            pending.removeAll(keepingCapacity: true)
        }

        if !pending.isEmpty {
            let piece = decode(tokens: pending)
            if words.isEmpty {
                words.append(piece)
                wordTokens.append(pending)
            } else {
                words[words.count - 1] += piece
                wordTokens[wordTokens.count - 1].append(contentsOf: pending)
            }
        }
        return (words, wordTokens)
    }
}
