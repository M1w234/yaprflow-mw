import AppKit
import CoreGraphics

/// Permission helpers for listening to global keyboard events. This is a
/// separate macOS privacy grant from Accessibility, which is used for text
/// insertion. Modifier-only shortcuts require both.
@MainActor
enum InputMonitoring {
    static var hasPermission: Bool {
        CGPreflightListenEventAccess()
    }

    /// Requests Input Monitoring. macOS only shows its prompt once for a code
    /// identity; stale or previously denied entries must be repaired manually
    /// in System Settings.
    @discardableResult
    static func requestPermission() -> Bool {
        CGRequestListenEventAccess()
    }

    static func openSettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
        )!
        NSWorkspace.shared.open(url)
    }
}
