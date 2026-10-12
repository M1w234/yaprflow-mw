import AppKit
import ApplicationServices
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "TextInsertion")

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
        if axInsert(text, pid: pid) {
            log.info("Inserted \(text.count, privacy: .public) chars via AX")
            return true
        }
        if typeUnicode(text) {
            log.info("Inserted \(text.count, privacy: .public) chars via synthetic typing")
            return true
        }
        log.info("Direct insertion failed — caller should fall back to clipboard")
        return false
    }

    private static func axInsert(_ text: String, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)

        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app, kAXFocusedUIElementAttribute as CFString, &focusedRef
        ) == .success,
              let ref = focusedRef,
              CFGetTypeID(ref) == AXUIElementGetTypeID() else {
            return false
        }
        let element = ref as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.3)

        var settable = DarwinBoolean(false)
        guard AXUIElementIsAttributeSettable(
            element, kAXSelectedTextAttribute as CFString, &settable
        ) == .success, settable.boolValue else {
            return false
        }

        return AXUIElementSetAttributeValue(
            element, kAXSelectedTextAttribute as CFString, text as CFString
        ) == .success
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
