import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "TextInsertion")

/// Enough information to re-read only the text range Yaprflow inserted. The
/// AX element never leaves the MainActor and is retained only for the short,
/// opt-in correction-learning window.
struct TextInsertionReceipt {
    let pid: pid_t
    let element: AXUIElement
    let insertedText: String
    let insertionStart: Int
    let replacedLength: Int
    let originalTotalCount: Int
    let prefixAnchor: String
    let suffixAnchor: String
    /// Present when the target exposes AXValue but not ranged text APIs.
    let valueObservation: TextValueObservation?
}

struct TextInsertionResult {
    let receipt: TextInsertionReceipt?
}

/// Inserts text into the focused field of another app WITHOUT touching the
/// clipboard — the "Preserve Clipboard" delivery path.
///
/// Two mechanisms, tried in order:
///   1. **AX insertion** — write `kAXSelectedTextAttribute` on the focused
///      element. Atomic and instant; replaces the current selection exactly
///      like a paste. Native AppKit text views support it; many Electron /
///      web views don't.
///   2. **Synthetic Unicode typing** — CGEvents carrying the literal text
///      (`keyboardSetUnicodeString`), chunked at 20 UTF-16 units per event
///      (the API's documented-by-folklore safe limit). Works nearly
///      everywhere text input works, at the cost of being a stream of key
///      events rather than one atomic operation.
///
/// Caller is responsible for the insertion guards: Accessibility
/// granted, secure input off, focus still on the intended target PID.
/// Returns false if neither mechanism worked. The caller keeps the transcript
/// in History and reports the failure without changing the clipboard.
@MainActor
enum TextInsertion {
    static func insert(_ text: String, intoPID pid: pid_t) -> Bool {
        insertWithResult(text, intoPID: pid, captureCorrectionReceipt: false) != nil
    }

    static func insertWithResult(
        _ text: String,
        intoPID pid: pid_t,
        captureCorrectionReceipt: Bool
    ) -> TextInsertionResult? {
        let axResult = axInsert(
            text,
            pid: pid,
            captureCorrectionReceipt: captureCorrectionReceipt
        )
        if axResult.succeeded {
            log.info("Inserted \(text.count, privacy: .public) chars via AX")
            return TextInsertionResult(receipt: axResult.receipt)
        }
        if typeUnicode(text) {
            if captureCorrectionReceipt, axResult.receipt != nil {
                log.info("Inserted \(text.count, privacy: .public) chars via synthetic typing; correction monitoring available")
            } else if captureCorrectionReceipt {
                log.info("Inserted \(text.count, privacy: .public) chars via synthetic typing; correction monitoring unavailable for this field")
            } else {
                log.info("Inserted \(text.count, privacy: .public) chars via synthetic typing")
            }
            return TextInsertionResult(receipt: axResult.receipt)
        }
        log.info("Direct insertion failed — caller should fall back to clipboard")
        return nil
    }

    private static func axInsert(
        _ text: String,
        pid: pid_t,
        captureCorrectionReceipt: Bool
    ) -> (succeeded: Bool, receipt: TextInsertionReceipt?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
              let ref = focusedRef,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return (false, nil)
        }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)

        // Capture a read-only receipt before checking whether AX can perform
        // the insertion. Electron/web fields often expose their selection and
        // ranged text but do not allow kAXSelectedText to be set. Those fields
        // fall back to synthetic Unicode typing, and the same receipt can still
        // safely observe the exact range afterward for correction suggestions.
        let receipt = captureCorrectionReceipt
            ? makeReceipt(text: text, pid: pid, element: element)
            : nil

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else {
            return (false, receipt)
        }

        let succeeded = AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success
        return (succeeded, receipt)
    }

    private static func makeReceipt(
        text: String,
        pid: pid_t,
        element: AXUIElement
    ) -> TextInsertionReceipt? {
        let selection = readRange(element, kAXSelectedTextRangeAttribute)
        if let selection,
           selection.location >= 0,
           selection.length >= 0,
           let totalCount = readInt(element, kAXNumberOfCharactersAttribute),
           totalCount >= selection.location + selection.length {
            return makeRangedReceipt(
                text: text,
                pid: pid,
                element: element,
                selection: selection,
                totalCount: totalCount
            )
        }

        // Electron/contenteditable fallback. AXValue may require the whole
        // current composer value to be returned by macOS, but it is never
        // retained: immediately reduce it to offsets and 32-character anchors.
        let maximumObservedValueLength = 20_000
        guard let originalValue = readValue(element),
              originalValue.utf16.count <= maximumObservedValueLength,
              let observation = TextValueObservation(
                original: originalValue,
                selectionLocation: selection?.location,
                selectionLength: selection?.length
              ) else { return nil }

        return TextInsertionReceipt(
            pid: pid,
            element: element,
            insertedText: text,
            insertionStart: observation.insertionStart,
            replacedLength: observation.replacedLength,
            originalTotalCount: observation.originalTotalCount,
            prefixAnchor: observation.prefixAnchor,
            suffixAnchor: observation.suffixAnchor,
            valueObservation: observation
        )
    }

    private static func makeRangedReceipt(
        text: String,
        pid: pid_t,
        element: AXUIElement,
        selection: CFRange,
        totalCount: Int
    ) -> TextInsertionReceipt? {

        let anchorLength = 32
        let prefixStart = max(0, selection.location - anchorLength)
        let prefix = readString(
            element,
            location: prefixStart,
            length: selection.location - prefixStart
        ) ?? ""
        let selectionEnd = selection.location + selection.length
        let suffix = readString(
            element,
            location: selectionEnd,
            length: min(anchorLength, totalCount - selectionEnd)
        ) ?? ""

        return TextInsertionReceipt(
            pid: pid,
            element: element,
            insertedText: text,
            insertionStart: selection.location,
            replacedLength: selection.length,
            originalTotalCount: totalCount,
            prefixAnchor: prefix,
            suffixAnchor: suffix,
            valueObservation: nil
        )
    }

    private static func readValue(_ element: AXUIElement) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, kAXValueAttribute as CFString, &ref
        ) == .success else { return nil }
        if let string = ref as? String { return string }
        if let string = ref as? NSAttributedString { return string.string }
        return nil
    }

    private static func readInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &ref
        ) == .success else { return nil }
        return (ref as? NSNumber)?.intValue
    }

    private static func readRange(_ element: AXUIElement, _ attribute: String) -> CFRange? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element, attribute as CFString, &ref
        ) == .success,
              let ref,
              CFGetTypeID(ref) == AXValueGetTypeID() else { return nil }
        let value = ref as! AXValue
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(value, .cfRange, &range) else { return nil }
        return range
    }

    private static func readString(
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

    private static func typeUnicode(_ text: String) -> Bool {
        // .privateState keeps physical modifier state (for example, a
        // just-released hold-to-talk chord) out of the synthesized events.
        guard let source = CGEventSource(stateID: .privateState) else { return false }

        let utf16 = Array(text.utf16)
        let chunkSize = 20
        var index = 0
        while index < utf16.count {
            var end = min(index + chunkSize, utf16.count)
            // Never split a UTF-16 surrogate pair across CGEvents. A lone
            // high/low surrogate is malformed and many target apps replace
            // each half with U+FFFD.
            if end < utf16.count,
               (0xD800...0xDBFF).contains(utf16[end - 1]),
               (0xDC00...0xDFFF).contains(utf16[end]) {
                end -= 1
            }
            let chunk = Array(utf16[index..<end])
            guard
                let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                return false
            }
            down.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            up.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            index = end
        }
        return true
    }
}
