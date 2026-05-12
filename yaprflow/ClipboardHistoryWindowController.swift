import AppKit
import SwiftUI

/// Hosts `ClipboardHistoryView` in a borderless floating panel.
///
/// **Window behaviour:**
///   - Floating level so it sits above whatever app has focus.
///   - Centered on the screen the user is currently on.
///   - Closes on Esc, on resignKey, or on selecting/copying a row.
///   - `.nonactivatingPanel` so opening the window doesn't change the
///     frontmost-app PID — important because the user is typically about
///     to paste the chosen entry into the app they came from.
@MainActor
final class ClipboardHistoryWindowController: NSWindowController, NSWindowDelegate {
    static let shared = ClipboardHistoryWindowController()

    private convenience init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 520),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "yaprflow History"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.hasShadow = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        // Borderless aesthetic — let the SwiftUI background paint the chrome.
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.standardWindowButton(.closeButton)?.isHidden = true

        self.init(window: panel)
        panel.delegate = self

        let root = ClipboardHistoryView(
            onCopy: { [weak self] entry in
                self?.copyAndClose(entry)
            },
            onClose: { [weak self] in
                self?.close()
            }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = panel.contentLayoutRect
        panel.contentView = hosting.view

        // Rounded corners on the contentView so the ultraThinMaterial
        // background reads as a single rounded card.
        hosting.view.wantsLayer = true
        hosting.view.layer?.cornerRadius = 12
        hosting.view.layer?.masksToBounds = true
    }

    func toggle() {
        if let win = window, win.isVisible {
            close()
        } else {
            show()
        }
    }

    func show() {
        guard let win = window else { return }
        if !win.isVisible {
            centerOnActiveScreen()
        }
        // `orderFrontRegardless` brings the panel forward without changing
        // the active app, so the user's prior focus survives — the chosen
        // entry can be pasted into the app they were just in.
        win.orderFrontRegardless()
        win.makeKey()
    }

    override func close() {
        window?.orderOut(nil)
    }

    private func centerOnActiveScreen() {
        guard let win = window else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else {
            win.center()
            return
        }
        let size = win.frame.size
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2 + 80 // slightly above center, feels right
        )
        win.setFrameOrigin(origin)
    }

    /// Copy the entry's text, restore focus to the app that was active before
    /// the history window appeared, and dismiss. Auto-paste into that app is
    /// out of scope for v1 — TCC permission is reused but the focus-PID
    /// snapshot is owned by `TranscriptionController`, not us. The user
    /// presses ⌘V manually after the window closes.
    private func copyAndClose(_ entry: ClipboardHistoryEntry) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        close()
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Dismiss when the user clicks away — Paste-app convention.
        close()
    }
}
