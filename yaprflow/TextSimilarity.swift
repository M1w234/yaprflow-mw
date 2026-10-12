import Foundation

enum TextSimilarity {
    private static let commonWords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "but", "by", "do", "for",
        "from", "had", "has", "have", "he", "her", "him", "his", "i", "if",
        "in", "is", "it", "me", "my", "of", "on", "or", "our", "she", "so",
        "that", "the", "their", "them", "then", "there", "they", "this", "to",
        "was", "we", "were", "what", "when", "where", "which", "who", "will",
        "with", "would", "you", "your",
    ]

    static func tokenSimilarity(_ a: String, _ b: String) -> Double {
        let aTokens = tokens(in: a)
        let bTokens = tokens(in: b)
        if aTokens.isEmpty && bTokens.isEmpty { return 1 }
        if aTokens.isEmpty || bTokens.isEmpty { return 0 }

        var previous = Array(0...bTokens.count)
        var current = [Int](repeating: 0, count: bTokens.count + 1)
        for i in 1...aTokens.count {
            current[0] = i
            for j in 1...bTokens.count {
                let cost = aTokens[i - 1] == bTokens[j - 1] ? 0 : 1
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + cost
                )
            }
            swap(&previous, &current)
        }
        let distance = previous[bTokens.count]
        return 1 - Double(distance) / Double(max(aTokens.count, bTokens.count))
    }

    /// Fraction of the reference's meaningful vocabulary also present in the
    /// candidate. This still recognizes a full Wispr transcript when yaprflow
    /// captured only a short beginning, while rejecting random clipboard text.
    static func meaningfulTokenCoverage(candidate: String, reference: String) -> Double {
        let referenceTokens = meaningfulTokens(in: reference)
        guard !referenceTokens.isEmpty else {
            return tokenSimilarity(candidate, reference)
        }
        let candidateTokens = Set(meaningfulTokens(in: candidate))
        let matched = referenceTokens.filter(candidateTokens.contains).count
        return Double(matched) / Double(referenceTokens.count)
    }

    static func isPlausiblyRelatedTranscript(_ candidate: String, to reference: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != reference else { return false }

        let candidateTokens = tokens(in: trimmed)
        let referenceTokens = tokens(in: reference)
        guard candidateTokens.count >= 2, referenceTokens.count >= 2 else { return false }

        // Bare URLs, filesystem paths, hashes, and credentials were the main
        // sources of false "Wispr" captures in the old study log.
        if !trimmed.contains(where: \.isWhitespace) {
            if trimmed.contains("://")
                || trimmed.hasPrefix("/")
                || trimmed.count > 80
            {
                return false
            }
        }

        // A tiny clipboard snippet cannot be the alternate transcript of a
        // much longer recording. Longer candidates remain allowed because
        // they are exactly what we need to observe when our ASR cut off early.
        if candidateTokens.count < max(2, referenceTokens.count / 5) {
            return false
        }

        let similarity = tokenSimilarity(trimmed, reference)
        let coverage = meaningfulTokenCoverage(candidate: trimmed, reference: reference)
        return similarity >= 0.28 || coverage >= 0.55
    }

    private static func tokens(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func meaningfulTokens(in text: String) -> [String] {
        tokens(in: text).filter { $0.count >= 3 && !commonWords.contains($0) }
    }
}
