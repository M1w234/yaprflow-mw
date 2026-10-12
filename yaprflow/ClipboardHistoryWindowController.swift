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

    /// Strong reference required: the panel only retains the hosting
    /// controller's VIEW, and AppKit views don't retain their controllers.
    /// Without this the SwiftUI host can deallocate while the view is still
    /// on screen — the panel renders once and then stops updating.
    private var hostingController: NSHostingController<ClipboardHistoryView>?

    /// True while the destructive-clear NSAlert sheet is up. The panel closes
    /// on `windowDidResignKey` (click-away dismissal), but presenting a sheet
    /// also makes the panel resign key — without this guard the sheet would
    /// dismiss itself the instant it appears.
    private var isPresentingConfirmation = false

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
        panel.isMovableByWindowBackground = false
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
            },
            onRequestClear: { [weak self] in
                self?.confirmClear()
            }
        )
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = panel.contentLayoutRect
        panel.contentView = hosting.view
        self.hostingController = hosting

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

    /// Picked a row. Copy is an explicit clipboard action. Paste into Previous
    /// App instead uses the same clipboard-free insertion path as dictation.
    ///
    /// Why the short delay before insertion: `app.activate()` returns
    /// immediately but window-server focus changes asynchronously. Inserting
    /// too soon hits us (or nothing) instead of the target app.
    private func activate(_ entry: ClipboardHistoryEntry, copyOnly: Bool) {
        if copyOnly {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(entry.text, forType: .string)
            close()
            return
        }

        close()

        guard AutoPaste.hasAccessibility, !AutoPaste.isSecureInputEnabled else { return }
        guard let target = previousApp else { return }

        target.activate(options: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(60)) {
            if !TextInsertion.insert(entry.text, intoPID: target.processIdentifier) {
                AppState.shared.status = .error("Couldn't insert — item remains in History")
            }
        }
    }

    /// Present the destructive-clear confirmation as a sheet on the panel.
    /// Offers "delete everything" and, when the user has pinned entries, a
    /// "keep pinned" middle option — because pinning explicitly signals
    /// "don't lose this," so a blanket clear shouldn't silently wipe them.
    private func confirmClear() {
        guard let window else { return }
        let store = ClipboardHistoryStore.shared
        let total = store.entries.count
        guard total > 0 else { return }
        let pinned = store.entries.filter { $0.isPinned }.count

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear dictation history?"
        alert.informativeText = pinned > 0
            ? "This permanently deletes saved transcripts and can't be undone. You have \(pinned) pinned."
            : "This permanently deletes all \(total) saved transcript\(total == 1 ? "" : "s") and can't be undone."

        let deleteAll = alert.addButton(withTitle: "Delete All \(total)")
        deleteAll.hasDestructiveAction = true
        if pinned > 0 {
            let keepPinned = alert.addButton(withTitle: "Delete \(total - pinned), Keep Pinned")
            keepPinned.hasDestructiveAction = true
        }
        let cancel = alert.addButton(withTitle: "Cancel")
        // Make Cancel the default (Return) and strip the destructive button's
        // key equivalent, so a stray Return can never wipe history.
        alert.buttons.first?.keyEquivalent = ""
        cancel.keyEquivalent = "\r"

        isPresentingConfirmation = true
        alert.beginSheetModal(for: window) { [weak self] response in
            defer { self?.isPresentingConfirmation = false }
            switch response {
            case .alertFirstButtonReturn:
                store.clearAll()
            case .alertSecondButtonReturn where pinned > 0:
                store.clearUnpinned()
            default:
                break  // Cancel
            }
        }
    }

    // MARK: - NSWindowDelegate

    func windowDidResignKey(_ notification: Notification) {
        // Dismiss when the user clicks away — Paste-app convention. Suppressed
        // while the clear-confirmation sheet is up (presenting it resigns key).
        guard !isPresentingConfirmation else { return }
        close()
    }
}
