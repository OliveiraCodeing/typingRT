import Foundation
import Testing
import WhisperKit
@testable import TranscriptionWorker

struct DictionaryPromptTests {
    @Test func budgetFollowsPinnedDecoderAndActualCache() {
        #expect(Constants.maxTokenContext == 224)
        #expect(DictionaryPrompt.budget(decoderContextLength: 448) == 28)
        #expect(DictionaryPrompt.budget(decoderContextLength: 224) == 28)
        #expect(DictionaryPrompt.budget(decoderContextLength: 128) == 16)
        #expect(DictionaryPrompt.budget(decoderContextLength: 0) == 0)
    }

    @Test func selectionIsDeterministicAndIncludesSeparatorsInBudget() {
        let terms = (0..<1_000).map { String(format: "Term%04d", $0) }
        func encode(_ value: String) -> [Int] { Array(value.utf8).map(Int.init) }
        let first = DictionaryPrompt.tokens(for: terms, decoderContextLength: 448,
            specialTokenBegin: 500, encode: encode)
        let second = DictionaryPrompt.tokens(for: terms.reversed(), decoderContextLength: 448,
            specialTokenBegin: 500, encode: encode)
        #expect(first == second)
        #expect(first == encode("Term0000, Term0001, Term0002"))
        #expect(first.count <= 28)
    }

    @Test func oversizedAndSpecialTermsAreSkippedWithoutSplittingThem() {
        func encode(_ value: String) -> [Int] {
            value.contains("<|") ? [500] : Array(value.utf8).map(Int.init)
        }
        let result = DictionaryPrompt.tokens(
            for: [String(repeating: "A", count: 29), "<|endoftext|>", "C++", "line\nbreak"],
            decoderContextLength: 224, specialTokenBegin: 500, encode: encode)
        #expect(result == encode("C++"))
    }

    @Test func emptyContextDoesNotCreateBareStartOfPreviousPrompt() {
        #expect(DictionaryPrompt.tokens(for: [], decoderContextLength: 224,
            specialTokenBegin: 500, encode: { _ in [] }).isEmpty)
        #expect(DictionaryPrompt.tokens(for: ["A"], decoderContextLength: 0,
            specialTokenBegin: 500, encode: { _ in [1] }).isEmpty)
    }

    @Test func veryLargeDictionaryBoundsEncodingWorkAndStopsWhenFull() {
        var calls = 0
        let terms = (0..<10_000).map { "Term\($0)" }
        let skipped = DictionaryPrompt.tokens(for: terms, decoderContextLength: 224,
            specialTokenBegin: 500, encode: { _ in calls += 1; return Array(repeating: 1, count: 29) })
        #expect(skipped.isEmpty)
        #expect(calls == 256)
        calls = 0
        let full = DictionaryPrompt.tokens(for: terms, decoderContextLength: 224,
            specialTokenBegin: 500, encode: { _ in calls += 1; return Array(repeating: 1, count: 28) })
        #expect(full.count == 28)
        #expect(calls == 1)
    }

    @Test func cappedTrailingTextIsRejectedPerWindowRatherThanAcrossDictation() {
        #expect(!DictionaryPrompt.mayHaveTruncatedWindow(tokenCountsByWindow: [100, 100, 100], promptTokenCount: 28))
        #expect(!DictionaryPrompt.mayHaveTruncatedWindow(tokenCountsByWindow: [194], promptTokenCount: 28))
        #expect(DictionaryPrompt.mayHaveTruncatedWindow(tokenCountsByWindow: [195], promptTokenCount: 28))
        #expect(!DictionaryPrompt.mayHaveTruncatedWindow(tokenCountsByWindow: [224], promptTokenCount: 0))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPINGRT_TEST_TOKENIZER"] != nil))
    func localTokenizerUsesRealTokenBudgetAndRejectsSpecialTokens() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TYPINGRT_TEST_TOKENIZER"])
        let tokenizer = try await OfflineWhisperTokenizer.load(from: URL(fileURLWithPath: path))
        let terms = ["Supabase", "Next.js", "C++", "<|endoftext|>"] + (0..<1_000).map { "Fachbegriff\($0)" }
        let tokens = DictionaryPrompt.tokens(for: terms, decoderContextLength: 448,
            specialTokenBegin: tokenizer.specialTokens.specialTokenBegin, encode: tokenizer.encodeContext)
        #expect(!tokens.isEmpty)
        #expect(tokens.count <= 28)
        #expect(tokens.allSatisfy { $0 < tokenizer.specialTokens.specialTokenBegin })
        let text = tokenizer.decode(tokens: tokens)
        #expect(!text.contains("<|"))
        #expect(text.split(separator: ",").allSatisfy { terms.contains($0.trimmingCharacters(in: .whitespaces)) })
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["TYPINGRT_TEST_TOKENIZER"] != nil))
    func upstreamFinalizeAndSegmentSeekerExposeCappedTrailingText() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["TYPINGRT_TEST_TOKENIZER"])
        let tokenizer = try await OfflineWhisperTokenizer.load(from: URL(fileURLWithPath: path))
        let special = tokenizer.specialTokens
        let promptCount = 28
        let textToken = try #require(tokenizer.encodeContext(text: " text").first)
        var tokens = [special.startOfPreviousToken] + Array(repeating: textToken, count: promptCount)
            + [special.startOfTranscriptToken, special.englishToken, special.transcribeToken, special.timeTokenBegin]
        tokens += Array(repeating: textToken, count: Constants.maxTokenContext - 1 - tokens.count)
        let sampler = GreedyTokenSampler(temperature: 0, eotToken: special.endToken, decodingOptions: DecodingOptions())
        let finalized = sampler.finalize(tokens: tokens, logProbs: Array(repeating: -0.1, count: tokens.count))
        // Reproduce TextDecoder's removal of the conditioning prefix.
        let start = try #require(finalized.tokens.firstIndex(of: special.startOfTranscriptToken))
        var decoded = DecodingResult.emptyResults
        decoded.tokens = Array(finalized.tokens[start...])
        decoded.tokenLogProbs = decoded.tokens.map { [$0: -0.1] }
        let (_, segments) = SegmentSeeker().findSeekPointAndSegments(
            decodingResult: decoded, options: DecodingOptions(), allSegmentsCount: 0,
            currentSeek: 0, segmentSize: 480_000, sampleRate: 16_000,
            timeToken: special.timeTokenBegin, specialToken: special.specialTokenBegin,
            tokenizer: tokenizer)
        let count = try #require(segments).reduce(0) { $0 + $1.tokens.count }
        #expect(decoded.tokens.last == special.endToken) // EOT is not proof.
        #expect(count == 195)
        #expect(DictionaryPrompt.mayHaveTruncatedWindow(tokenCountsByWindow: [count], promptTokenCount: promptCount))
    }
}
