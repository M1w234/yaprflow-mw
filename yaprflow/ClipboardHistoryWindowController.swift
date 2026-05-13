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

    /// Frontmost app at the moment `show()` was called. Snapshotted so that
    /// when the user picks a row we can reactivate this app and synthesize
    /// ⌘V into it — emulating the Paste / Wispr workflow where the chosen
    /// snippet lands in the field the user was just typing in.
    private var previousApp: NSRunningApplication?

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
            onActivate: { [weak self] entry, copyOnly in
                self?.activate(entry, copyOnly: copyOnly)
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
        // Snapshot frontmost app BEFORE ordering our panel forward, so we
        // can reactivate it and synthesize ⌘V into it on row activation.
        // Skip our own app — if yaprflow is already frontmost, there's no
        // sensible "previous" app to paste into.
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousApp = front
        }
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

    /// Picked a row. Always writes to the pasteboard and closes the window.
    /// If `copyOnly` is false AND Accessibility is granted AND we're not in
    /// Secure Event Input mode (password fields, sudo prompts, lock screen),
    /// also reactivate the previously-frontmost app and synthesize ⌘V so
    /// the snippet lands in the field the user was typing in.
    ///
    /// Why the short delay before paste: `app.activate()` returns immediately
    /// but window-server focus changes asynchronously. Posting ⌘V too soon
    /// hits us (or nothing) instead of the target app. ~60 ms is enough on
    /// every machine I tested without being noticeable to the user.
    private func activate(_ entry: ClipboardHistoryEntry, copyOnly: Bool) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(entry.text, forType: .string)
        close()

        guard !copyOnly else { return }
        guard AutoPaste.hasAccessibility, !AutoPaste.isSecureInputEnabled else { return }
        guard let target = previousApp else { return }

        target.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            AutoPaste.sendCmdV()
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Dismiss when the user clicks away — Paste-app convention.
        close()
    }
}
