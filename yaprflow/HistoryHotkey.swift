import AppKit
import Carbon.HIToolbox
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "HistoryHotkey")

/// Global Carbon hotkey that toggles the clipboard history window.
///
/// **Why a second hotkey class** instead of folding this into `GlobalHotkey`:
/// the dictation hotkey is user-configurable and re-registers on every
/// change; the history hotkey is fixed (⌃⌥V) and registers once at launch.
/// Mixing them in one class would mean threading two `EventHotKeyRef`s and
/// two callback slots through a singleton designed for one — clearer to
/// keep them parallel and uninteresting.
///
/// **Why ⌃⌥V**: not bound by macOS system shortcuts; not used by any
/// common app I checked (Chrome, Safari, VS Code, Slack, Notion, Mail);
/// mnemonic for "paste history"; comfortable two-finger reach.
@MainActor
final class HistoryHotkey {
    static let shared = HistoryHotkey()

    nonisolated(unsafe) static var onPressed: (@Sendable () -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?

    private init() {}

    func register() {
        unregisterHotKey()
        installEventHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: 0x59_50_72_48 /* 'YPrH' */, id: 2)
        var ref: EventHotKeyRef?
        let modifiers = UInt32(controlKey | optionKey)
        let status = RegisterEventHotKey(
            UInt32(kVK_ANSI_V),
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr {
            hotKeyRef = ref
        } else {
            log.error("RegisterEventHotKey for history failed: \(status, privacy: .public)")
        }
    }

    func unregister() {
        unregisterHotKey()
        if let ref = eventHandlerRef {
            RemoveEventHandler(ref)
            eventHandlerRef = nil
        }
    }

    private func unregisterHotKey() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                // Only one hotkey ID is registered through this handler
                // (signature 'YPrH', id 2), so any fired event is ours.
                _ = event
                let handler = HistoryHotkey.onPressed
                DispatchQueue.main.async { handler?() }
                return noErr
            },
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
    }
}
