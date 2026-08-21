import Foundation

enum NumberFormattingMode: String, CaseIterable {
    case natural
    case smart
    case preferDigits

    var displayName: String {
        switch self {
        case .natural: return "Natural"
        case .smart: return "Smart"
        case .preferDigits: return "Prefer Digits"
        }
    }
}

/// Deterministic English spoken-number formatting. This deliberately rejects
/// ambiguous sequences rather than guessing: "four eight two seven" remains
/// words unless it follows a numeric label or the explicit "digits" cue.
enum SpokenNumberFormatter {
    private struct ParsedNumber {
        let rendered: String
        let integerValue: Int
        let containsPoint: Bool
    }

    private enum CardinalKind {
        case start
        case smallUnit
        case teen
        case tens
        case hundred
        case largeScale
    }

    private static let units: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4,
        "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13,
        "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50,
        "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
    ]

    private static let largeScales: [String: Int] = [
        "thousand": 1_000,
        "million": 1_000_000,
        "billion": 1_000_000_000,
    ]

    private static let digitValues: [String: String] = [
        "zero": "0", "oh": "0", "o": "0", "one": "1", "two": "2",
        "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9",
    ]

    private static let cardinalTokenPattern = [
        "zero", "one", "two", "three", "four", "five", "six", "seven",
        "eight", "nine", "ten", "eleven", "twelve", "thirteen",
        "fourteen", "fifteen", "sixteen", "seventeen", "eighteen",
        "nineteen", "twenty", "thirty", "forty", "fifty", "sixty",
        "seventy", "eighty", "ninety", "hundred", "thousand", "million",
        "billion", "point",
    ].joined(separator: "|")

    private static let digitTokenPattern = [
        "zero", "oh", "o", "one", "two", "three", "four", "five", "six",
        "seven", "eight", "nine", "dash", "hyphen", "point", "dot", "space",
    ].joined(separator: "|")

    private static let cardinalPhrasePattern =
        "(?:\(cardinalTokenPattern))" +
        "(?:(?:[\\s-]+)(?:and[\\s-]+)?(?:\(cardinalTokenPattern)))*"

    private static let explicitAndLabeledSequence = try! NSRegularExpression(
        pattern: "(?i)\\b(" + [
            "confirmation number", "confirmation code", "verification code",
            "tracking number", "account number", "serial number", "order number",
            "phone number", "telephone number", "zip code", "access code",
            "pin number", "digits?", "number", "unit", "room", "apartment",
        ].joined(separator: "|") + ")([\\s]+(?:is[\\s]+)?)((?:" +
        digitTokenPattern + ")(?:(?:[\\s,;:-]+)(?:" + digitTokenPattern + "))*)\\b" +
        "(?![\\s-]+(?:" + cardinalTokenPattern + "))"
    )

    private static let digitWord = try! NSRegularExpression(
        pattern: "(?i)\\b(" + digitTokenPattern + ")\\b"
    )

    private static let currencyOrPercent = try! NSRegularExpression(
        pattern: "(?i)\\b(" + cardinalPhrasePattern + ")\\s+(dollars?|percent)\\b"
    )

    private static let quantity = try! NSRegularExpression(
        pattern: "(?i)\\b(" + cardinalPhrasePattern + ")\\s+(" + [
            "acres?", "miles?", "feet", "foot", "inches", "inch", "yards?",
            "meters?", "metres?", "pounds?", "ounces?", "kilograms?", "grams?",
            "degrees?", "minutes?", "hours?", "days?", "weeks?", "months?",
            "years?", "bedrooms?", "bathrooms?",
        ].joined(separator: "|") + ")\\b"
    )

    private static let generalCardinal = try! NSRegularExpression(
        pattern: "(?i)\\b(" + cardinalPhrasePattern + ")\\b"
    )

    static func apply(_ input: String, mode: NumberFormattingMode) -> String {
        var result = replaceDigitSequences(in: input, explicitOnly: mode == .natural)
        guard mode != .natural else { return result }

        result = replaceLabeledCardinals(in: result, regex: currencyOrPercent) {
            parsed, label in
            label.lowercased().hasPrefix("dollar")
                ? "$\(parsed.rendered)"
                : "\(parsed.rendered)%"
        }
        result = replaceLabeledCardinals(in: result, regex: quantity) {
            parsed, label in
            "\(parsed.rendered) \(label)"
        }
        result = replaceGeneralCardinals(in: result, mode: mode)
        return result
    }

    private static func replaceDigitSequences(
        in input: String,
        explicitOnly: Bool
    ) -> String {
        var result = input
        let matches = explicitAndLabeledSequence.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )

        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let cueRange = Range(match.range(at: 1), in: result),
                  let bridgeRange = Range(match.range(at: 2), in: result),
                  let sequenceRange = Range(match.range(at: 3), in: result) else { continue }

            let cue = String(result[cueRange])
            let isExplicit = cue.lowercased().hasPrefix("digit")
            if explicitOnly && !isExplicit { continue }

            guard let digits = renderDigitSequence(String(result[sequenceRange])) else {
                continue
            }

            if isExplicit {
                result.replaceSubrange(fullRange, with: digits)
            } else {
                let bridge = String(result[bridgeRange])
                let normalizedBridge = bridge.lowercased().contains("is") ? " is " : " "
                result.replaceSubrange(fullRange, with: cue + normalizedBridge + digits)
            }
        }
        return result
    }

    private static func renderDigitSequence(_ phrase: String) -> String? {
        let matches = digitWord.matches(
            in: phrase,
            range: NSRange(phrase.startIndex..., in: phrase)
        )
        var output = ""
        var digitCount = 0

        for match in matches {
            guard let range = Range(match.range(at: 1), in: phrase) else { continue }
            let token = phrase[range].lowercased()
            if let digit = digitValues[token] {
                output += digit
                digitCount += 1
            } else {
                switch token {
                case "dash", "hyphen": output += "-"
                case "point", "dot": output += "."
                case "space": output += " "
                default: break
                }
            }
        }

        return digitCount > 0 ? output : nil
    }

    private static func replaceLabeledCardinals(
        in input: String,
        regex: NSRegularExpression,
        replacement: (ParsedNumber, String) -> String
    ) -> String {
        var result = input
        let matches = regex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let phraseRange = Range(match.range(at: 1), in: result),
                  let labelRange = Range(match.range(at: 2), in: result),
                  let parsed = parseCardinal(String(result[phraseRange])) else { continue }
            let label = String(result[labelRange])
            result.replaceSubrange(fullRange, with: replacement(parsed, label))
        }
        return result
    }

    private static func replaceGeneralCardinals(
        in input: String,
        mode: NumberFormattingMode
    ) -> String {
        var result = input
        let matches = generalCardinal.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )
        for match in matches.reversed() {
            guard let fullRange = Range(match.range, in: result),
                  let phraseRange = Range(match.range(at: 1), in: result),
                  let parsed = parseCardinal(String(result[phraseRange])) else { continue }

            let shouldConvert = mode == .preferDigits
                || parsed.integerValue >= 10
                || parsed.containsPoint
            if shouldConvert {
                result.replaceSubrange(fullRange, with: parsed.rendered)
            }
        }
        return result
    }

    private static func parseCardinal(_ phrase: String) -> ParsedNumber? {
        let tokens = phrase.lowercased().split(whereSeparator: {
            $0.isWhitespace || $0 == "-"
        }).map(String.init)
        guard !tokens.isEmpty else { return nil }

        var total = 0
        var current = 0
        var previous: CardinalKind = .start
        var lastLargeScale = Int.max
        var sawNumber = false
        var decimalDigits: String?

        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "and" {
                guard sawNumber, index + 1 < tokens.count else { return nil }
                index += 1
                continue
            }

            if token == "point" {
                guard sawNumber, decimalDigits == nil, index + 1 < tokens.count else {
                    return nil
                }
                var digits = ""
                for decimalToken in tokens[(index + 1)...] {
                    guard let value = units[decimalToken], value < 10 else { return nil }
                    digits += String(value)
                }
                guard !digits.isEmpty else { return nil }
                decimalDigits = digits
                break
            }

            if let value = units[token] {
                if value < 10 {
                    guard previous == .start || previous == .tens
                        || previous == .hundred || previous == .largeScale else { return nil }
                    current += value
                    previous = .smallUnit
                } else {
                    guard previous == .start || previous == .hundred
                        || previous == .largeScale else { return nil }
                    current += value
                    previous = .teen
                }
                sawNumber = true
                index += 1
                continue
            }

            if let value = tens[token] {
                guard previous == .start || previous == .hundred
                    || previous == .largeScale else { return nil }
                current += value
                previous = .tens
                sawNumber = true
                index += 1
                continue
            }

            if token == "hundred" {
                guard previous == .smallUnit, current > 0, current < 10 else { return nil }
                current *= 100
                previous = .hundred
                sawNumber = true
                index += 1
                continue
            }

            if let scale = largeScales[token] {
                guard current > 0, scale < lastLargeScale else { return nil }
                let product = current.multipliedReportingOverflow(by: scale)
                guard !product.overflow else { return nil }
                let sum = total.addingReportingOverflow(product.partialValue)
                guard !sum.overflow else { return nil }
                total = sum.partialValue
                current = 0
                lastLargeScale = scale
                previous = .largeScale
                sawNumber = true
                index += 1
                continue
            }

            return nil
        }

        guard sawNumber else { return nil }
        let sum = total.addingReportingOverflow(current)
        guard !sum.overflow else { return nil }
        let integerValue = sum.partialValue
        let rendered = decimalDigits.map { "\(integerValue).\($0)" } ?? String(integerValue)
        return ParsedNumber(
            rendered: rendered,
            integerValue: integerValue,
            containsPoint: decimalDigits != nil
        )
    }
}
