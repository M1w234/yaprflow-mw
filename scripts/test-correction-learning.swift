import Foundation

@main
@MainActor
struct CorrectionLearningTests {
    static func main() throws {
        try testInferenceSafety()
        testValueBackedObservation()
        try testMigrationPersistenceAndAtomicAliases()
        try testPersistenceFailureRollsBack()
        print("Correction learning tests passed")
    }

    private static func testValueBackedObservation() {
        let endObservation = TextValueObservation(
            original: "Draft: ",
            selectionLocation: nil,
            selectionLength: nil
        )!
        precondition(
            endObservation.insertedSegment(
                in: "Draft: I confirmed with Ciena today.",
                expectedUTF16Length: "I confirmed with Sienna today.".utf16.count
            ) == "I confirmed with Ciena today."
        )
        precondition(
            endObservation.insertedSegment(
                in: "Changed: I confirmed with Ciena today.",
                expectedUTF16Length: "I confirmed with Sienna today.".utf16.count
            ) == nil,
            "An edit outside the inserted range must invalidate its prefix anchor."
        )

        let original = "Before OLD after"
        let selected = (original as NSString).range(of: "OLD")
        let replacementObservation = TextValueObservation(
            original: original,
            selectionLocation: selected.location,
            selectionLength: selected.length
        )!
        precondition(
            replacementObservation.insertedSegment(
                in: "Before Ciena after",
                expectedUTF16Length: "Sienna".utf16.count
            ) == "Ciena"
        )

        let emojiObservation = TextValueObservation(
            original: "👍🏽 ",
            selectionLocation: nil,
            selectionLength: nil
        )!
        precondition(
            emojiObservation.insertedSegment(
                in: "👍🏽 Ciena",
                expectedUTF16Length: "Sienna".utf16.count
            ) == "Ciena",
            "Offsets must use Accessibility's UTF-16 coordinate system."
        )
    }

    private static func testInferenceSafety() throws {
        try expectCandidate(
            original: "Call Mackenzie today",
            corrected: "Call McKenzie today",
            expected: .init(misheard: "Mackenzie", replacement: "McKenzie"),
            automatic: true
        )
        try expectCandidate(
            original: "Use a pie for it",
            corrected: "Use API for it",
            expected: .init(misheard: "a pie", replacement: "API"),
            automatic: true
        )
        try expectCandidate(
            original: "open github now",
            corrected: "open GitHub now",
            expected: .init(misheard: "github", replacement: "GitHub"),
            automatic: true
        )
        try expectCandidate(
            original: "ask lee tomorrow",
            corrected: "ask Lee tomorrow",
            expected: .init(misheard: "lee", replacement: "Lee"),
            automatic: true
        )

        let ordinaryEdit = try CorrectionInference.infer(
            original: "we walk today",
            corrected: "we walked today"
        )
        precondition(!ordinaryEdit.isSafeForAutomaticLearning)

        let typedName = try CorrectionInference.inferFromTypedCorrection(
            original: "I confirmed with Sienna about the appointment",
            typedCorrection: "Ciena"
        )
        precondition(
            typedName == .init(misheard: "Sienna", replacement: "Ciena")
        )
        let typedNameInFullSentence = try CorrectionInference.inferFromTypedCorrection(
            original: "I confirmed the appointment with Sienna, so we're good to go.",
            typedCorrection: "Ciena"
        )
        precondition(
            typedNameInFullSentence == .init(misheard: "Sienna", replacement: "Ciena")
        )
        let typedShorterVariant = try CorrectionInference.inferFromTypedCorrection(
            original: "I confirmed the appointment with Siena, so we're good to go.",
            typedCorrection: "Ciena"
        )
        precondition(
            typedShorterVariant == .init(misheard: "Siena", replacement: "Ciena")
        )
        let typedAcronym = try CorrectionInference.inferFromTypedCorrection(
            original: "Use a pie for it",
            typedCorrection: "API"
        )
        precondition(
            typedAcronym == .init(misheard: "a pie", replacement: "API")
        )
        do {
            _ = try CorrectionInference.inferFromTypedCorrection(
                original: "Call Sienna or Xienna tomorrow",
                typedCorrection: "Ciena"
            )
            preconditionFailure("Expected an ambiguous typed correction to be rejected")
        } catch CorrectionInferenceError.noLikelyMatch {
            // Expected.
        } catch {
            preconditionFailure("Unexpected typed-correction error: \(error)")
        }

        try expectError(
            original: "send it today",
            corrected: "send it",
            expected: .additionOrDeletion
        )
        try expectError(
            original: "one two three four five six seven",
            corrected: "one alpha beta gamma delta epsilon seven",
            expected: .tooBroad
        )
    }

    private static func testMigrationPersistenceAndAtomicAliases() throws {
        let fixture = try TemporaryVocabularyFixture()
        defer { fixture.remove() }

        let legacyJSON = #"{"entries":[{"term":"McKenzie","misheard":["Mackenzie"]}]}"#
        try Data(legacyJSON.utf8).write(to: fixture.fileURL, options: .atomic)

        let store = VocabularyStore(fileURL: fixture.fileURL)
        precondition(store.entries.count == 1)
        precondition(store.entries[0].source == .manual)
        precondition(store.entries[0].isEnabled)
        precondition(store.applyReplacements(to: "Call Mackenzie") == "Call McKenzie")
        let migratedID = store.entries[0].id

        _ = try store.learn(
            misheard: ["a pie", "A-P-I", "a pie"],
            replacement: "API",
            source: .manual
        )
        let api = try require(store.entries.first { $0.term == "API" })
        precondition(api.misheard == ["a pie", "A-P-I"])
        precondition(store.applyReplacements(to: "Use a pie") == "Use API")

        let beforeConflict = try Data(contentsOf: fixture.fileURL)
        do {
            _ = try store.learn(
                misheard: ["safe variant", "Mackenzie"],
                replacement: "Other Name",
                source: .manual
            )
            preconditionFailure("Expected an alias conflict")
        } catch VocabularyError.conflictingRule {
            // Expected: no alias from this batch may persist.
        }
        precondition(!store.entries.contains { $0.term == "Other Name" })
        let afterConflict = try Data(contentsOf: fixture.fileURL)
        precondition(afterConflict == beforeConflict)

        let reloaded = VocabularyStore(fileURL: fixture.fileURL)
        precondition(reloaded.entries.count == 2)
        precondition(reloaded.entries.contains { $0.id == migratedID })
        precondition(reloaded.entries.contains { $0.id == api.id })
        precondition(reloaded.applyReplacements(to: "Use A-P-I") == "Use API")

        reloaded.setEnabled(false, for: api.id)
        precondition(reloaded.applyReplacements(to: "Use a pie") == "Use a pie")
        let afterDisable = VocabularyStore(fileURL: fixture.fileURL)
        precondition(afterDisable.entries.first { $0.id == api.id }?.isEnabled == false)
    }

    private static func testPersistenceFailureRollsBack() throws {
        let fixture = try TemporaryVocabularyFixture()
        defer { fixture.remove() }
        let directoryAtFilePath = fixture.directory.appendingPathComponent("not-a-file")
        try FileManager.default.createDirectory(
            at: directoryAtFilePath,
            withIntermediateDirectories: false
        )
        let store = VocabularyStore(fileURL: directoryAtFilePath)
        let originalEntries = store.entries
        do {
            _ = try store.learn(
                misheard: "Mackenzie",
                replacement: "McKenzie",
                source: .manual
            )
            preconditionFailure("Expected persistence to fail")
        } catch VocabularyError.persistenceFailed {
            // Expected.
        }
        precondition(store.entries == originalEntries)
    }

    private static func expectCandidate(
        original: String,
        corrected: String,
        expected: CorrectionCandidate,
        automatic: Bool
    ) throws {
        let actual = try CorrectionInference.infer(original: original, corrected: corrected)
        precondition(actual == expected, "Expected \(expected), got \(actual)")
        precondition(actual.isSafeForAutomaticLearning == automatic)
    }

    private static func expectError(
        original: String,
        corrected: String,
        expected: CorrectionInferenceError
    ) throws {
        do {
            _ = try CorrectionInference.infer(original: original, corrected: corrected)
            preconditionFailure("Expected \(expected)")
        } catch let error as CorrectionInferenceError {
            precondition(error == expected, "Expected \(expected), got \(error)")
        }
    }

    private static func require<T>(_ value: T?) throws -> T {
        guard let value else {
            throw TestFailure.missingExpectedValue
        }
        return value
    }
}

private struct TemporaryVocabularyFixture {
    let directory: URL
    let fileURL: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("yaprflow-correction-tests-\(UUID().uuidString)")
        fileURL = directory.appendingPathComponent("vocabulary.json")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}

private enum TestFailure: Error {
    case missingExpectedValue
}
