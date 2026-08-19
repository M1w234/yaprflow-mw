import AppKit
import ApplicationServices
import Foundation
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "CorrectionLearning")

/// Short-lived, opt-in observation of the exact text range Yaprflow inserted.
/// It never installs a keyboard tap. Small prefix/suffix anchors are retained
/// in memory for at most this observation window to prove that edits stayed
/// inside the inserted range. A validated short replacement is presented for
/// confirmation and is persisted only after the user chooses Learn.
@MainActor
final class CorrectionLearningMonitor {
    static let shared = CorrectionLearningMonitor()

    private var task: Task<Void, Never>?
    private let observationDuration: Duration = .seconds(25)
    private let pollInterval: Duration = .milliseconds(350)
    private let quietInterval: TimeInterval = 1.6

    private init() {}

    func begin(_ receipt: TextInsertionReceipt) {
        cancel()
        guard AppState.shared.learnFromCorrections else { return }

        task = Task { @MainActor [weak self] in
            guard let self else { return }
            let deadline = ContinuousClock.now.advanced(by: observationDuration)
            var lastValue = receipt.insertedText
            var lastChangedAt = Date()

            while !Task.isCancelled, ContinuousClock.now < deadline {
                do {
                    try await Task.sleep(for: pollInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard AppState.shared.learnFromCorrections else {
                    log.info("Correction observation ended: learning disabled")
                    return
                }
                guard !AutoPaste.isSecureInputEnabled else {
                    log.info("Correction observation ended: secure input enabled")
                    return
                }
                guard NSWorkspace.shared.frontmostApplication?.processIdentifier == receipt.pid else {
                    log.info("Correction observation ended: target app changed")
                    return
                }
                guard focusedElementMatches(receipt) else {
                    log.info("Correction observation ended: focused field changed")
                    return
                }
                guard let current = readInsertedSegment(receipt) else {
                    log.info("Correction observation ended: inserted range unreadable")
                    return
                }

                if current != lastValue {
                    lastValue = current
                    lastChangedAt = Date()
                    continue
                }
                guard current != receipt.insertedText,
                      Date().timeIntervalSince(lastChangedAt) >= quietInterval else {
                    continue
                }

                do {
                    let candidate = try CorrectionInference.infer(
                        original: receipt.insertedText,
                        corrected: current
                    )
                    guard candidate.isSafeForAutomaticLearning else {
                        log.info("Ignored ambiguous automatic correction")
                        return
                    }
                    presentSuggestion(candidate)
                } catch {
                    log.info("Automatic correction not suggested: \(error.localizedDescription, privacy: .public)")
                }
                return
            }
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        CorrectionLearningConfirmationController.shared.dismiss()
    }

    private func focusedElementMatches(_ receipt: TextInsertionReceipt) -> Bool {
        let app = AXUIElementCreateApplication(receipt.pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &ref
        ) == .success,
              let ref,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else { return false }
        return CFEqual(ref, receipt.element)
    }

    private func readInsertedSegment(_ receipt: TextInsertionReceipt) -> String? {
        let element = receipt.element
        AXUIElementSetMessagingTimeout(element, 0.1)
        if let observation = receipt.valueObservation {
            let maximumObservedValueLength = 20_000
            guard let value = readValue(element),
                  value.utf16.count <= maximumObservedValueLength else { return nil }
            return observation.insertedSegment(
                in: value,
                expectedUTF16Length: receipt.insertedText.utf16.count
            )
        }
        guard let totalCount = readInt(element, kAXNumberOfCharactersAttribute) else {
            return nil
        }

        let originalTailCount = receipt.originalTotalCount
            - receipt.insertionStart
            - receipt.replacedLength
        let candidateLength = totalCount - receipt.insertionStart - originalTailCount
        let maximumLength = receipt.insertedText.utf16.count + 160
        guard candidateLength >= 0, candidateLength <= maximumLength else { return nil }

        if !receipt.prefixAnchor.isEmpty {
            let prefixLength = receipt.prefixAnchor.utf16.count
            let prefixStart = receipt.insertionStart - prefixLength
            guard prefixStart >= 0,
                  readString(element, location: prefixStart, length: prefixLength)
                    == receipt.prefixAnchor else { return nil }
        }

        if !receipt.suffixAnchor.isEmpty {
            let suffixLength = receipt.suffixAnchor.utf16.count
            let suffixStart = receipt.insertionStart + candidateLength
            guard readString(element, location: suffixStart, length: suffixLength)
                    == receipt.suffixAnchor else { return nil }
        }

        return readString(
            element,
            location: receipt.insertionStart,
            length: candidateLength
        )
    }

    private func readInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &ref
        ) == .success else { return nil }
        return (ref as? NSNumber)?.intValue
    }

    private func readString(
        _ element: AXUIElement,
        location: Int,
        length: Int
    ) -> String? {
        guard length > 0 else { return "" }
        var range = CFRange(location: location, length: length)
        guard let value = AXValueCreate(.cfRange, &range) else { return nil }
        var ref: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            value,
            &ref
        ) == .success else { return nil }
        if let string = ref as? String { return string }
        if let string = ref as? NSAttributedString { return string.string }
        return nil
    }

    private func readValue(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &ref
        ) == .success else { return nil }
        if let string = ref as? String { return string }
        if let string = ref as? NSAttributedString { return string.string }
        return nil
    }

    private func presentSuggestion(_ candidate: CorrectionCandidate) {
        CorrectionLearningConfirmationController.shared.show(candidate: candidate) {
            [weak self] approved in
            guard let self else { return nil }
            do {
                _ = try VocabularyStore.shared.learn(
                    misheard: approved.misheard,
                    replacement: approved.replacement,
                    source: .automatic
                )
                showLearnedFeedback(approved)
                return nil
            } catch {
                log.info("Confirmed correction not learned: \(error.localizedDescription, privacy: .public)")
                return error.localizedDescription
            }
        }
    }

    private func showLearnedFeedback(_ candidate: CorrectionCandidate) {
        let state = AppState.shared
        state.status = .learned("Learned \(candidate.misheard) -> \(candidate.replacement)")
        NotchOverlayWindowController.shared.show()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.2))
            guard case .learned = state.status else { return }
            state.status = .idle
            NotchOverlayWindowController.shared.hide()
        }
    }
}
