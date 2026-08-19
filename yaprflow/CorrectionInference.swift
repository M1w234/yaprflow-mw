import Foundation

/// A single, localized replacement inferred from an original transcript and
/// the text the user corrected it to. Learning is intentionally limited to a
/// short substitution: additions, deletions, and broad rewrites are not safe
/// enough to turn into a global rule.
struct CorrectionCandidate: Equatable, Sendable {
    let misheard: String
    let replacement: String

    /// Automatic learning is stricter than an explicit History edit. It only
    /// accepts compact substitutions and filters common everyday words unless
    /// the replacement has a distinctive spelling.
    var isSafeForAutomaticLearning: Bool {
        let wrongWords = CorrectionInference.words(in: misheard)
        let rightWords = CorrectionInference.words(in: replacement)
        guard (1...2).contains(wrongWords.count),
              (1...2).contains(rightWords.count),
              misheard.count <= 60,
              replacement.count <= 60 else {
            return false
        }

        if rightWords.count > 1 {
            // A multi-word replacement is only automatic when it looks like a
            // proper name ("New Construction Hawaii"), not an ordinary prose
            // rewrite ("going to" -> "went to").
            return rightWords.allSatisfy { word in
                !Self.commonWords.contains(word.lowercased())
                    && Self.looksLikeProperName(word)
            }
        }
        guard let word = rightWords.first else { return false }
        return !Self.commonWords.contains(word.lowercased())
            && Self.looksLikeProperName(word)
    }

    private static func looksLikeProperName(_ word: String) -> Bool {
        let letters = word.filter(\.isLetter)
        guard !letters.isEmpty else { return false }
        let isAcronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
        let hasInternalCapital = word.dropFirst().contains(where: \Character.isUppercase)
        let isTitleCased = word.first?.isUppercase == true && word.count >= 2
        return isAcronym
            || hasInternalCapital
            || isTitleCased
            || word.contains(where: \Character.isNumber)
            || word.contains("-")
    }

    private static let commonWords: Set<String> = [
        "a", "about", "after", "again", "all", "also", "am", "an", "and",
        "any", "are", "as", "at", "be", "because", "been", "before", "but",
        "by", "can", "could", "did", "do", "does", "for", "from", "get",
        "go", "had", "has", "have", "he", "her", "here", "him", "his",
        "how", "i", "if", "in", "into", "is", "it", "its", "just", "like",
        "me", "more", "my", "no", "not", "now", "of", "on", "one", "or",
        "our", "out", "please", "so", "some", "that", "the", "their", "them",
        "then", "there", "they", "this", "to", "up", "us", "was", "we",
        "were", "what", "when", "where", "which", "who", "will", "with",
        "would", "you", "your",
    ]
}

enum CorrectionInferenceError: LocalizedError, Equatable {
    case unchanged
    case additionOrDeletion
    case tooBroad
    case noLikelyMatch

    var errorDescription: String? {
        switch self {
        case .unchanged:
            return "Change one word or short phrase first."
        case .additionOrDeletion:
            return "Yaprflow can learn replacements, but not added or deleted wording."
        case .tooBroad:
            return "Make one name or short phrase correction at a time."
        case .noLikelyMatch:
            return "Yaprflow couldn't identify a likely corrected name or term."
        }
    }
}

enum CorrectionInference {
    /// Infer one token-level substitution. Comparing whole word tokens instead
    /// of raw characters avoids learning fragments such as "ack" -> "cK" from
    /// a correction like "Mackenzie" -> "McKenzie".
    static func infer(original: String, corrected: String) throws -> CorrectionCandidate {
        let originalWords = words(in: original)
        let correctedWords = words(in: corrected)
        guard originalWords != correctedWords else { throw CorrectionInferenceError.unchanged }

        var prefix = 0
        while prefix < originalWords.count,
              prefix < correctedWords.count,
              originalWords[prefix] == correctedWords[prefix] {
            prefix += 1
        }

        var suffix = 0
        while suffix < originalWords.count - prefix,
              suffix < correctedWords.count - prefix,
              originalWords[originalWords.count - 1 - suffix]
                == correctedWords[correctedWords.count - 1 - suffix] {
            suffix += 1
        }

        let wrongEnd = originalWords.count - suffix
        let rightEnd = correctedWords.count - suffix
        let wrong = Array(originalWords[prefix..<wrongEnd])
        let right = Array(correctedWords[prefix..<rightEnd])

        guard !wrong.isEmpty, !right.isEmpty else {
            throw CorrectionInferenceError.additionOrDeletion
        }
        guard wrong.count <= 4, right.count <= 4 else {
            throw CorrectionInferenceError.tooBroad
        }

        let candidate = CorrectionCandidate(
            misheard: wrong.joined(separator: " "),
            replacement: right.joined(separator: " ")
        )
        guard candidate.misheard.count <= 120,
              candidate.replacement.count <= 120 else {
            throw CorrectionInferenceError.tooBroad
        }
        return candidate
    }

    /// Infer a likely replacement when a target app exposes no readable text.
    /// The short-lived typing observer supplies only the characters entered
    /// after an edit gesture. Match a distinctive one- or two-word replacement
    /// against similarly sized spans in the original transcript, rejecting
    /// weak or ambiguous matches. Persistence still requires user confirmation.
    static func inferFromTypedCorrection(
        original: String,
        typedCorrection: String
    ) throws -> CorrectionCandidate {
        let originalWords = words(in: original)
        let typedWords = words(in: typedCorrection)
        guard !originalWords.isEmpty, !typedWords.isEmpty else {
            throw CorrectionInferenceError.noLikelyMatch
        }

        var scored: [(candidate: CorrectionCandidate, score: Double)] = []
        for replacementLength in 1...min(2, typedWords.count) {
            for replacementStart in 0...(typedWords.count - replacementLength) {
                let replacement = typedWords[
                    replacementStart..<(replacementStart + replacementLength)
                ].joined(separator: " ")
                for heardLength in 1...min(2, originalWords.count) {
                    for heardStart in 0...(originalWords.count - heardLength) {
                        let heard = originalWords[
                            heardStart..<(heardStart + heardLength)
                        ].joined(separator: " ")
                        let candidate = CorrectionCandidate(
                            misheard: heard,
                            replacement: replacement
                        )
                        guard heard.caseInsensitiveCompare(replacement) != .orderedSame,
                              candidate.isSafeForAutomaticLearning else { continue }
                        let score = similarity(heard, replacement)
                        guard score >= 0.50 else { continue }
                        scored.append((candidate, score))
                    }
                }
            }
        }

        scored.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.candidate.misheard.count < rhs.candidate.misheard.count
        }
        guard let best = scored.first else {
            throw CorrectionInferenceError.noLikelyMatch
        }
        if let runnerUp = scored.dropFirst().first,
           runnerUp.candidate != best.candidate,
           best.score - runnerUp.score < 0.08 {
            throw CorrectionInferenceError.noLikelyMatch
        }
        return best.candidate
    }

    private static func similarity(_ lhs: String, _ rhs: String) -> Double {
        let left = Array(lhs.lowercased())
        let right = Array(rhs.lowercased())
        let maximumLength = max(left.count, right.count)
        guard maximumLength > 0 else { return 1 }

        var previous = Array(0...right.count)
        for (leftIndex, leftCharacter) in left.enumerated() {
            var current = Array(repeating: 0, count: right.count + 1)
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in right.enumerated() {
                let substitution = previous[rightIndex]
                    + (leftCharacter == rightCharacter ? 0 : 1)
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    substitution
                )
            }
            previous = current
        }
        return 1 - Double(previous[right.count]) / Double(maximumLength)
    }

    fileprivate static func words(in text: String) -> [String] {
        let range = NSRange(text.startIndex..., in: text)
        return wordRegex.matches(in: text, range: range).compactMap { match in
            guard let swiftRange = Range(match.range, in: text) else { return nil }
            return String(text[swiftRange])
        }
    }

    private static let wordRegex = try! NSRegularExpression(
        pattern: #"[\p{L}\p{N}]+(?:['’.-][\p{L}\p{N}]+)*"#
    )
}
