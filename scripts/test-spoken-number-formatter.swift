import Foundation

@main
enum SpokenNumberFormatterTests {
    static func main() throws {
        try check(.natural, "I have twenty five questions.", "I have twenty five questions.")
        try check(.natural, "digits eight zero eight", "808")

        try check(.smart, "I have two questions.", "I have two questions.")
        try check(.smart, "I have twenty five questions.", "I have 25 questions.")
        try check(.smart, "There are ten offers.", "There are 10 offers.")
        try check(.smart, "It sold for two hundred fifty dollars.", "It sold for $250.")
        try check(.smart, "The rate is six point five percent.", "The rate is 6.5%.")
        try check(.smart, "The lot is five acres.", "The lot is 5 acres.")
        try check(.smart, "Call phone number eight zero eight five five five one two one two.", "Call phone number 8085551212.")
        try check(.smart, "The confirmation code is four two zero one.", "The confirmation code is 4201.")
        try check(.smart, "Meet me at room two zero five.", "Meet me at room 205.")
        try check(.smart, "The number is one hundred five.", "The number is 105.")
        try check(.smart, "Meet me at room three hundred four.", "Meet me at room 304.")
        try check(.smart, "digits eight zero eight, five five five, one two one two.", "8085551212.")
        try check(.smart, "digits one two dash four five.", "12-45.")
        try check(.smart, "one hundred and five people", "105 people")
        try check(.smart, "two thousand twenty six", "2026")
        try check(.smart, "one point five miles", "1.5 miles")

        // Ambiguous or invalid sequences stay untouched unless the speaker
        // explicitly says "digits" or supplies a numeric label.
        try check(.smart, "The numbers are four eight two seven.", "The numbers are four eight two seven.")
        try check(.smart, "twenty twenty six", "twenty twenty six")
        try check(.smart, "She is one of the finalists.", "She is one of the finalists.")
        try check(.smart, "I have one or two questions.", "I have one or two questions.")
        try check(.smart, "It happened a hundred times.", "It happened a hundred times.")
        try check(.natural, "digits one hundred", "digits one hundred")

        try check(.preferDigits, "I have two questions.", "I have 2 questions.")
        try check(.preferDigits, "I have one or two questions.", "I have 1 or 2 questions.")

        print("Spoken number formatter tests passed")
    }

    private static func check(
        _ mode: NumberFormattingMode,
        _ input: String,
        _ expected: String
    ) throws {
        let actual = SpokenNumberFormatter.apply(input, mode: mode)
        guard actual == expected else {
            throw Failure(
                message: "[\(mode.rawValue)] \(input.debugDescription) expected \(expected.debugDescription), got \(actual.debugDescription)"
            )
        }
    }
}

private struct Failure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}
