import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Accessibility permission helpers for clipboard-free text insertion.
@MainActor
enum AutoPaste {
    /// Re-checked on every call; TCC entries can be revoked at any time and
    /// ad-hoc signed builds (every `dev-build.sh` iteration) get a fresh code
    /// directory hash, which typically invalidates the existing AX grant.
    static var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the macOS "<App> would like to control this computer using
    /// accessibility features" prompt. The system only presents it on the
    /// FIRST call per (app, user); after a denial this returns false silently
    /// and the user has to grant manually in System Settings → Privacy &
    /// Security → Accessibility. Caller should treat the return value as the
    /// best current read of trust state, not as "the user just answered."
    @discardableResult
    static func promptForAccessibility() -> Bool {
        let promptKey = "AXTrustedCheckOptionPrompt" as CFString
        let opts = [promptKey: kCFBooleanTrue!] as CFDictionary
        return AXIsProcessTrustedWithOptions(opts)
    }

    /// Opens the Accessibility pane directly so a user who already denied can
    /// flip the switch. Used by the menu item when state is "Needs Permission".
    static func openAccessibilitySettings() {
        let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )!
        NSWorkspace.shared.open(url)
    }

    /// True when macOS secure event input is active — typically a Terminal
    /// sudo prompt, FileVault unlock, or the lock screen mid-wake. Synthetic
    /// typing is silently dropped in this state, so insertion must stop and
    /// leave the transcript recoverable in History.
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}
