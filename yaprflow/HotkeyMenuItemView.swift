import AppKit
import Carbon.HIToolbox

@MainActor
final class HotkeyMenuItemView: NSView {
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let shortcutField = NSTextField(labelWithString: "")
    private var isRecording = false {
        didSet {
            if isRecording { installFlagsMonitor() } else { removeFlagsMonitor() }
        }
    }

    /// Highest modifier mask seen during the current recording session. Used
    /// to commit a modifier-only binding when the user releases all modifiers
    /// without pressing a non-modifier key.
    private var recordedFlags: NSEvent.ModifierFlags = []
    private var sawNonModifierKey: Bool = false
    private var pollTimer: Timer?
    private var lastPolledFlags: NSEvent.ModifierFlags = []

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 22))
        autoresizingMask = [.width]
        setupLayout()
        refresh()

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(onHotkeyChanged),
            name: .yaprflowHotkeyChanged,
            object: nil
        )
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        NotificationCenter.default.removeObserver(self)
        // Monitor lifecycle is tied to `isRecording.didSet`; it's never live
        // when the view is being torn down (the menu always closes first).
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 22)
    }

    private func setupLayout() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.menuFont(ofSize: 0)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)

        shortcutField.translatesAutoresizingMaskIntoConstraints = false
        shortcutField.font = NSFont.menuFont(ofSize: 0)
        shortcutField.textColor = .secondaryLabelColor
        shortcutField.alignment = .right
        addSubview(shortcutField)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor),

            shortcutField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            shortcutField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            shortcutField.leadingAnchor.constraint(greaterThanOrEqualTo: titleField.trailingAnchor, constant: 16),
        ])
    }

    @objc private func onHotkeyChanged() {
        refresh()
    }

    private func refresh() {
        if isRecording {
            titleField.stringValue = "Press a shortcut…"
            titleField.textColor = .systemBlue
            shortcutField.stringValue = "esc"
        } else {
            titleField.stringValue = "Shortcut"
            titleField.textColor = .labelColor
            shortcutField.stringValue = AppState.shared.hotkey.displayString
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !isRecording {
            recordedFlags = []
            sawNonModifierKey = false
        }
        isRecording.toggle()
        refresh()
        window?.makeFirstResponder(self)
    }

    /// NSMenu's event tracking loop swallows `.flagsChanged` events before
    /// they reach `NSEvent.addLocalMonitorForEvents`, so we can't observe
    /// modifier transitions reactively while the menu is open. Instead we
    /// poll `NSEvent.modifierFlags` (a synchronous class method that returns
    /// the current global modifier state — no event delivery needed) on a
    /// Timer registered in `.common` run-loop modes, which includes
    /// `.eventTracking` where NSMenu runs.
    private func installFlagsMonitor() {
        guard pollTimer == nil else { return }
        lastPolledFlags = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        let timer = Timer(timeInterval: 0.020, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollModifierFlags()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func removeFlagsMonitor() {
        pollTimer?.invalidate()
        pollTimer = nil
    }

    private func pollModifierFlags() {
        guard isRecording else { return }
        let current = NSEvent.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)
        guard current != lastPolledFlags else { return }
        lastPolledFlags = current

        // Track the strongest modifier set seen.
        recordedFlags.formUnion(current)

        // All modifiers released. Commit modifier-only binding if the user
        // never pressed a non-modifier key during this recording.
        if current.isEmpty && !recordedFlags.isEmpty && !sawNonModifierKey {
            let carbonMods = carbonModifiers(from: recordedFlags)
            guard carbonMods != 0 else { return }
            let newConfig = HotkeyConfig(
                keyCode: HotkeyConfig.modifierOnlyKeyCode,
                modifiers: carbonMods,
                mode: AppState.shared.hotkey.mode
            )
            AppState.shared.hotkey = newConfig
            newConfig.save()
            NotificationCenter.default.post(name: .yaprflowHotkeyChanged, object: nil)

            isRecording = false
            recordedFlags = []
            refresh()
            enclosingMenuItem?.menu?.cancelTracking()
        }
    }

    private func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option)  { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift)   { mods |= UInt32(shiftKey) }
        return mods
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return false }
        return handle(event: event)
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording, handle(event: event) else {
            super.keyDown(with: event)
            return
        }
    }

    @discardableResult
    private func handle(event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if event.keyCode == UInt16(kVK_Escape) && flags.subtracting(.capsLock).isEmpty {
            isRecording = false
            recordedFlags = []
            refresh()
            enclosingMenuItem?.menu?.cancelTracking()
            return true
        }

        // Mark that the user pressed a non-modifier key — disqualifies the
        // modifier-only commit path inside `handleFlagsChanged`.
        sawNonModifierKey = true

        let newConfig = HotkeyConfig(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonModifiers(from: flags),
            mode: AppState.shared.hotkey.mode
        )
        AppState.shared.hotkey = newConfig
        newConfig.save()
        NotificationCenter.default.post(name: .yaprflowHotkeyChanged, object: nil)

        isRecording = false
        recordedFlags = []
        refresh()
        enclosingMenuItem?.menu?.cancelTracking()
        return true
    }
}
