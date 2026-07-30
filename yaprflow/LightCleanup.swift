import Foundation

/// Fast, deterministic transcript cleanup. This deliberately cannot rephrase,
/// summarize, substitute words, or complete an unfinished thought.
enum LightCleanup {
    private static let horizontalWhitespace = try! NSRegularExpression(
        pattern: #"[ \t]{2,}"#
    )
    private static let whitespaceBeforePunctuation = try! NSRegularExpression(
        pattern: #"[ \t]+([,.;:!?])"#
    )
    private static let repeatedCommaSemicolonColon = try! NSRegularExpression(
        pattern: #"([,;:])\1+"#
    )
    private static let excessiveBlankLines = try! NSRegularExpression(
        pattern: #"\n[ \t]*\n(?:[ \t]*\n)+"#
    )

    // Closed list only: these adjacent whitespace-separated repeats are
    // overwhelmingly ASR/stutter artifacts. Prepositions and particles are
    // deliberately excluded because phrases such as "log in in the morning"
    // and "turn it on on weekends" are legitimate.
    private static let duplicateFunctionWord = try! NSRegularExpression(
        pattern: #"(?i)\b(the|a|an|of|and|i)\b([ \t]+)\1\b"#
    )

    static func apply(_ input: String) -> String {
        var text = input

        text = replacing(horizontalWhitespace, in: text, with: " ")
        text = replacing(whitespaceBeforePunctuation, in: text, with: "$1")
        text = replacing(repeatedCommaSemicolonColon, in: text, with: "$1")
        text = replacing(excessiveBlankLines, in: text, with: "\n\n")

        // Run until stable so "the the the" becomes "the" without broadening
        // the rule to punctuation-separated or non-allowlisted repetitions.
        while true {
            let next = replacing(duplicateFunctionWord, in: text, with: "$1")
            if next == text { break }
            text = next
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replacing(
        _ regex: NSRegularExpression,
        in text: String,
        with template: String
    ) -> String {
        regex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: template
        )
    }
}
