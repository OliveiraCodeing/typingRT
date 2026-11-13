import Foundation
import WhisperKit

/// WhisperKit 1.1.1 uses a 224-token decoder loop even when the model's KV
/// cache is larger. Its prompt cap is context/2-1; we deliberately use only
/// context/8 (28 tokens), including separators, to preserve most output space.
/// This is a conditioning hint, never a complete vocabulary or a guarantee.
enum DictionaryPrompt {
    // Lookahead is deliberately bounded: ASR context is only a hint. Full-list
    // deterministic replacements remain the host dictionary's responsibility.
    static let maximumCandidates = 256
    static func budget(decoderContextLength: Int) -> Int {
        let context = max(0, min(Constants.maxTokenContext, decoderContextLength))
        return max(0, min(context / 2 - 1, context / 8))
    }

    static func tokens(
        for canonicalTerms: [String], decoderContextLength: Int,
        specialTokenBegin: Int, encode: (String) -> [Int]
    ) -> [Int] {
        let limit = budget(decoderContextLength: decoderContextLength)
        guard limit > 0 else { return [] }
        // Canonical spellings only: no aliases, templates, or instruction text.
        // Bound each encoding operation even if an invalid peer bypasses the UI.
        let terms = Set(canonicalTerms.filter { term in
            !term.isEmpty && term.utf8.count <= 256
                && !term.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
        }).sorted()
        var selectedText = ""
        var selectedTokens: [Int] = []
        for term in terms.prefix(maximumCandidates) {
            let candidate = selectedText.isEmpty ? term : selectedText + ", " + term
            let tokens = encode(candidate)
            guard !tokens.isEmpty, tokens.count <= limit,
                  tokens.allSatisfy({ $0 >= 0 && $0 < specialTokenBegin }) else { continue }
            selectedText = candidate
            selectedTokens = tokens
            if tokens.count == limit { break }
        }
        return selectedTokens
    }

    /// Decoder.finalize appends EOT even after hitting the loop limit; EOT alone
    /// is therefore no completion proof. The decoder removes startofprev+prompt
    /// from its returned tokens. SegmentSeeker partitions each window (same
    /// seek), and includes the whole trailing text when no closing timestamp
    /// exists. A full partition at this size can be truncated: fail closed.
    static func mayHaveTruncatedWindow(
        tokenCountsByWindow: [Int], promptTokenCount: Int
    ) -> Bool {
        guard promptTokenCount > 0 else { return false }
        let limit = Constants.maxTokenContext - 1 - promptTokenCount
        return tokenCountsByWindow.contains { $0 >= limit }
    }
}
