import AppKit
import Combine

/// Menu row for clipboard-free automatic insertion. Three visible states:
///
///   - "Off"               — disabled (default)
///   - "Ready"             — enabled AND Accessibility permission granted
///   - "Needs Permission"  — enabled but AX is missing/revoked; click re-prompts
///                           or opens System Settings → Privacy & Security
///
/// Why three states instead of two: TCC for Accessibility is tied to the app's
/// code signature. A two-state toggle would lie — saying "On" while the
/// synthesized ⌘V is being silently dropped by the OS. Base `MenuRowView`
/// re-reads `AXIsProcessTrusted()` on every menu open, so the label stays
/// honest without a separate observer.
@MainActor
final class AutoPasteMenuItemView: MenuRowView {
    private var cancellable: AnyCancellable?

    init() {
        super.init(symbolName: "text.cursor", title: "Automatic Insertion")
        cancellable = AppState.shared.$autoPasteMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.reload() }
    }

    required init?(coder: NSCoder) { fatalError() }

    private var needsPermission: Bool {
        AppState.shared.autoPasteMode && !AutoPaste.hasAccessibility
    }

    override func refresh() {
        if !AppState.shared.autoPasteMode {
            stateField.stringValue = "Off"
        } else if AutoPaste.hasAccessibility {
            stateField.stringValue = "Ready"
        } else {
            stateField.stringValue = "Needs Permission"
        }
    }

    override func applyStateColor() {
        stateField.textColor = needsPermission ? .systemOrange : .secondaryLabelColor
    }

    override func rowClicked() {
        let enabled = AppState.shared.autoPasteMode
        let trusted = AutoPaste.hasAccessibility

        if enabled && !trusted {
            // "Needs Permission" → try the system prompt; if it returns false
            // synchronously (previously denied), open the pane to flip manually.
            if !AutoPaste.promptForAccessibility() {
                AutoPaste.openAccessibilitySettings()
            }
        } else if !enabled {
            AppState.shared.autoPasteMode = true
            if !trusted {
                _ = AutoPaste.promptForAccessibility()
            }
        } else {
            AppState.shared.autoPasteMode = false
        }

        reload()
        enclosingMenuItem?.menu?.cancelTracking()
    }
}
