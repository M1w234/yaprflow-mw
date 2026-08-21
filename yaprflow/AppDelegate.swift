import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation, NSMenuDelegate {
    private var statusItem: NSStatusItem?
    private var cleanupModeMenu: NSMenu?
    private var modifierResponseMenu: NSMenu?
    private var numberFormattingMenu: NSMenu?
    private var startSoundPickerMenu: NSMenu?
    private var stopSoundPickerMenu: NSMenu?
    private var soundsMenuItem: NSMenuItem?
    private var statusIconCancellable: AnyCancellable?
    private var cleanupModeCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installStatusItem()
        cleanupModeCancellable = AppState.shared.$cleanupMode
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshCleanupModeCheckmarks() }
        _ = NotchOverlayWindowController.shared
        registerHotkey()
        registerExternalHotkey()
        registerHistoryHotkey()

        // Eagerly instantiate the history store so its Combine subscription
        // on `AppState.$lastTranscript` is live before the first dictation.
        _ = ClipboardHistoryStore.shared

        // Warm the ASR + VAD models in the background so the first hotkey press
        // doesn't block on the ~30s Encoder compile. Release builds bundle the
        // complete ASR and VAD models; the loader retains a network fallback
        // for older or incomplete app bundles.
        TranscriptionController.shared.preload()

        // Polish mode uses the model directly. Shadow Comparison also queues
        // a no-context Polish candidate after each recording, so pre-download
        // the model without loading it into memory.
        if AppState.shared.cleanupMode == .polish
            || AppState.shared.comparisonLogMode {
            GrammarController.shared.preload()
        }

        if !OnboardingWindowController.hasCompleted {
            OnboardingWindowController.shared.show()
        }

        NotificationCenter.default.addObserver(
            forName: .yaprflowHotkeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.registerHotkey()
                // A changed primary shortcut can create or remove a conflict
                // with the independent external shortcut.
                self.registerExternalHotkey()
            }
        }
        NotificationCenter.default.addObserver(
            forName: .yaprflowExternalHotkeyChanged,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                self.registerExternalHotkey()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        GlobalHotkey.shared.unregister()
        ModifierOnlyHotkey.shared.unregister()
        ExternalHotkey.shared.unregister()
        HistoryHotkey.shared.unregister()
        CancelHotkey.shared.unregister()
        CorrectionLearningMonitor.shared.cancel()
        // Never leave the system muted behind us if we quit mid-recording.
        AudioDucking.shared.restore()
        // History saves are debounced 300 ms — flush so a dictation finished
        // right before quit isn't lost. Same for an open comparison-capture
        // window.
        ClipboardHistoryStore.shared.flushPendingSave()
        ComparisonLogger.shared.flush()
    }

    private func registerHistoryHotkey() {
        HistoryHotkey.onPressed = {
            Task { @MainActor in
                ClipboardHistoryWindowController.shared.toggle()
            }
        }
        HistoryHotkey.shared.register()
    }

    @objc private func showHistory() {
        ClipboardHistoryWindowController.shared.show()
    }

    @objc private func openVocabulary() {
        VocabularyWindowController.shared.show()
    }

    @objc private func showSetup() {
        OnboardingWindowController.shared.show()
    }

    /// Re-launching or re-opening the app (Spotlight, double-click in Finder,
    /// `open -a yaprflow`) pops the status menu at the pointer. On small
    /// displays — especially notched laptops — the menu-bar icon can overflow
    /// and become unreachable; this guarantees the menu is always accessible
    /// without a visible icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        popUpStatusMenuAtPointer()
        return true
    }

    private func popUpStatusMenuAtPointer() {
        guard let menu = statusItem?.menu else { return }
        // `in: nil` interprets the point in screen coordinates (bottom-left
        // origin), which is what NSEvent.mouseLocation returns.
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yaprflow")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let shortcutItem = NSMenuItem()
        shortcutItem.view = HotkeyMenuItemView()
        menu.addItem(shortcutItem)

        let triggerItem = NSMenuItem()
        triggerItem.view = HotkeyModeMenuItemView()
        triggerItem.toolTip = "Tap to Toggle: press once to start, again to stop. Hold to Talk: hold the shortcut while you speak, release to stop."
        menu.addItem(triggerItem)

        let bothSidesItem = NSMenuItem()
        bothSidesItem.view = ToggleMenuItemView(
            symbolName: "keyboard",
            title: "Both Keyboard Sides",
            publisher: AppState.shared.$bothKeyboardSides.eraseToAnyPublisher(),
            get: { AppState.shared.bothKeyboardSides },
            set: { newValue in
                AppState.shared.bothKeyboardSides = newValue
                // Re-register so the change takes effect immediately.
                NotificationCenter.default.post(name: .yaprflowHotkeyChanged, object: nil)
            }
        )
        bothSidesItem.toolTip = "For modifier-only shortcuts (e.g. ⌘⇧): off = only the side of the keyboard you first used it on triggers dictation, so left-side ⌘⇧ shortcuts don't collide. On = either side works. No effect on key-based shortcuts."
        menu.addItem(bothSidesItem)

        let externalButtonItem = NSMenuItem(
            title: "External Button",
            action: nil,
            keyEquivalent: ""
        )
        externalButtonItem.image = NSImage(
            systemSymbolName: "computermouse",
            accessibilityDescription: nil
        )
        externalButtonItem.submenu = buildExternalButtonSubmenu()
        externalButtonItem.toolTip = "Keep your main keyboard shortcut and add an independent shortcut for Logitech Options+ or other button-remapping software."
        menu.addItem(externalButtonItem)

        menu.addItem(NSMenuItem.separator())

        let cleanupItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        cleanupItem.image = NSImage(
            systemSymbolName: "text.badge.checkmark",
            accessibilityDescription: nil
        )
        cleanupItem.submenu = buildCleanupModeSubmenu()
        cleanupItem.toolTip = "Off preserves the transcript. Light performs instant mechanical cleanup without changing your wording. Polish uses the on-device AI model for stronger grammar edits."
        menu.addItem(cleanupItem)

        let autoPasteItem = NSMenuItem()
        autoPasteItem.view = AutoPasteMenuItemView()
        autoPasteItem.toolTip = "Insert the finished transcript directly into the focused text field without changing your clipboard. Requires Accessibility permission."
        menu.addItem(autoPasteItem)

        let duckItem = NSMenuItem()
        duckItem.view = ToggleMenuItemView(
            symbolName: "speaker.slash",
            title: "Mute While Dictating",
            publisher: AppState.shared.$duckWhileRecording.eraseToAnyPublisher(),
            get: { AppState.shared.duckWhileRecording },
            set: { newValue in
                AppState.shared.duckWhileRecording = newValue
                // Live-apply when toggled mid-recording.
                if TranscriptionController.shared.isRecording {
                    if newValue {
                        AudioDucking.shared.duck()
                    } else {
                        AudioDucking.shared.restore()
                    }
                }
            }
        )
        duckItem.toolTip = "Mute system audio output while recording so music or video doesn't bleed into the mic. Volume is restored when you stop (unless you changed it yourself mid-recording)."
        menu.addItem(duckItem)

        let soundsItem = NSMenuItem(title: "Sound Effects", action: nil, keyEquivalent: "")
        soundsItem.image = NSImage(systemSymbolName: "speaker.wave.2", accessibilityDescription: nil)
        soundsItem.submenu = buildSoundsSubmenu()
        soundsItem.toolTip = "Adjust volume, choose start/stop chimes, or import your own local sound."
        self.soundsMenuItem = soundsItem
        menu.addItem(soundsItem)

        let advancedItem = NSMenuItem(title: "Advanced", action: nil, keyEquivalent: "")
        advancedItem.image = NSImage(
            systemSymbolName: "gearshape.2",
            accessibilityDescription: nil
        )
        advancedItem.submenu = buildAdvancedSubmenu()
        advancedItem.toolTip = "Optional experimental and diagnostic controls."
        menu.addItem(advancedItem)

        let launchAtLoginItem = NSMenuItem()
        launchAtLoginItem.view = LaunchAtLoginMenuItemView()
        launchAtLoginItem.toolTip = "Open Yaprflow automatically when you log in to your Mac."
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        // Copy text: original first, then corrected if grammar mode was on.
        // Custom view so the icon lines up with Shortcut/Streaming/Grammar above.
        let copyItem = NSMenuItem()
        copyItem.view = IconActionMenuItemView(
            symbolName: "doc.on.clipboard",
            title: "Copy Transcript",
            target: self,
            action: #selector(copyTranscript),
            isEnabled: {
                !AppState.shared.lastTranscript.isEmpty
                    || !AppState.shared.lastOriginalTranscript.isEmpty
            }
        )
        menu.addItem(copyItem)

        // Summarize on demand
        let summarizeItem = NSMenuItem()
        summarizeItem.view = IconActionMenuItemView(
            symbolName: "text.alignleft",
            title: "Copy Summary",
            target: self,
            action: #selector(copySummary),
            isEnabled: { !AppState.shared.lastTranscript.isEmpty }
        )
        menu.addItem(summarizeItem)

        // Clipboard history — opens the floating panel. Also bound to ⌃⌥V
        // as a global hotkey (see `registerHistoryHotkey`).
        let historyItem = NSMenuItem()
        historyItem.view = IconActionMenuItemView(
            symbolName: "clock.arrow.circlepath",
            title: "Show History…",
            shortcut: "⌃⌥V",
            target: self,
            action: #selector(showHistory)
        )
        menu.addItem(historyItem)

        // Personal dictionary and learned correction manager.
        let vocabularyItem = NSMenuItem()
        vocabularyItem.view = IconActionMenuItemView(
            symbolName: "character.book.closed",
            title: "Vocabulary…",
            target: self,
            action: #selector(openVocabulary)
        )
        vocabularyItem.toolTip = "Add names and recurring mis-hearings, review learned corrections, or enable private same-field correction learning."
        menu.addItem(vocabularyItem)

        menu.addItem(NSMenuItem.separator())

        let setupItem = NSMenuItem()
        setupItem.view = IconActionMenuItemView(
            symbolName: "checkmark.circle",
            title: "Setup Guide…",
            target: self,
            action: #selector(showSetup)
        )
        setupItem.toolTip = "Reopen the first-run guide for permissions and the default shortcut."
        menu.addItem(setupItem)

        menu.addItem(NSMenuItem(
            title: "Quit",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        item.menu = menu
        self.statusItem = item

        // Swap the menu bar icon to a red record dot while the mic is live —
        // the overlay pill is easy to miss (especially in lock mode), and a
        // persistent "recording" indicator in the menu bar is the honest
        // signal that audio is being captured.
        statusIconCancellable = AppState.shared.$status
            .receive(on: RunLoop.main)
            .sink { [weak self] status in
                self?.updateStatusIcon(for: status)
            }
    }

    private func buildExternalButtonSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let enabledItem = NSMenuItem()
        enabledItem.view = ToggleMenuItemView(
            symbolName: "computermouse",
            title: "Enabled",
            publisher: AppState.shared.$externalHotkey
                .map(\.enabled)
                .removeDuplicates()
                .eraseToAnyPublisher(),
            get: { AppState.shared.externalHotkey.enabled },
            set: { newValue in
                var config = AppState.shared.externalHotkey
                config.enabled = newValue
                AppState.shared.externalHotkey = config
                config.save()
                NotificationCenter.default.post(
                    name: .yaprflowExternalHotkeyChanged,
                    object: nil
                )
            }
        )
        enabledItem.toolTip = "Turn on the independent shortcut used by your programmable mouse. Your main keyboard shortcut is unchanged."
        submenu.addItem(enabledItem)

        let shortcutItem = NSMenuItem()
        shortcutItem.view = ExternalHotkeyShortcutMenuItemView()
        shortcutItem.toolTip = "Assign this same keystroke to a mouse button in Logitech Options+. Press a new shortcut twice here to change it."
        submenu.addItem(shortcutItem)

        let triggerItem = NSMenuItem()
        triggerItem.view = ExternalHotkeyModeMenuItemView()
        triggerItem.toolTip = "Tap to Toggle is most reliable with remapping software. Hold to Talk requires the software to preserve key-down and key-up events."
        submenu.addItem(triggerItem)

        let keyboardItem = NSMenuItem()
        keyboardItem.view = KeyboardShortcutActivationMenuItemView()
        keyboardItem.toolTip = "Pause the saved keyboard shortcut while using the external button. Its keys and trigger behavior remain saved."
        submenu.addItem(keyboardItem)

        return submenu
    }

    private func updateStatusIcon(for status: TranscriptionStatus) {
        guard let button = statusItem?.button else { return }
        if case .listening = status {
            let image = NSImage(
                systemSymbolName: "record.circle.fill",
                accessibilityDescription: "Yaprflow — recording"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(paletteColors: [.systemRed])
            )
            image?.isTemplate = false
            button.image = image
        } else {
            let image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Yaprflow")
            image?.isTemplate = true
            button.image = image
        }
    }

    /// Copies the corrected transcript when grammar mode produced one,
    /// otherwise the raw original.
    @objc private func copyTranscript() {
        let original = AppState.shared.lastOriginalTranscript
        let corrected = AppState.shared.lastTranscript
        let text = corrected.isEmpty ? original : corrected
        guard !text.isEmpty else { return }

        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    /// Generates and copies a summary of the last transcript (on-demand)
    @objc private func copySummary() {
        let text = AppState.shared.lastTranscript
        guard !text.isEmpty else { return }

        // Show overlay and loading state
        NotchOverlayWindowController.shared.show()
        AppState.shared.status = .summarizing

        Task { @MainActor in
            do {
                let summary = try await GrammarController.shared.summarize(text: text) { msg in
                    // Fresh installs may need the model download first —
                    // show its progress instead of a frozen "Summarizing…".
                    AppState.shared.status = .correcting(msg)
                }
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(summary, forType: .string)

                // Show completion
                AppState.shared.status = .copied

                // Auto-hide after delay
                try? await Task.sleep(for: .seconds(2.0))
                if AppState.shared.status == .copied {
                    AppState.shared.status = .idle
                    NotchOverlayWindowController.shared.hide()
                }
            } catch {
                // Silent fail — hide overlay
                AppState.shared.status = .idle
                NotchOverlayWindowController.shared.hide()
            }
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(copyTranscript) {
            return !AppState.shared.lastTranscript.isEmpty || !AppState.shared.lastOriginalTranscript.isEmpty
        }
        if menuItem.action == #selector(copySummary) {
            return !AppState.shared.lastTranscript.isEmpty
        }
        if menuItem.action == #selector(resetSoundsToDefaults) {
            return AppState.shared.startSoundName != SoundEffect.defaultStartName
                || AppState.shared.stopSoundName != SoundEffect.defaultStopName
                || abs(AppState.shared.soundEffectsVolume - 1) > 0.001
        }
        return true
    }

    // MARK: - Cleanup mode submenu

    private func buildCleanupModeSubmenu() -> NSMenu {
        let submenu = NSMenu()
        for mode in CleanupMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectCleanupMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            submenu.addItem(item)
        }
        cleanupModeMenu = submenu
        refreshCleanupModeCheckmarks()
        return submenu
    }

    private func buildModifierResponseMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(
            title: "Use Safe when this chord overlaps other shortcuts"
        ))
        for speed in ModifierResponseSpeed.allCases {
            let item = NSMenuItem(
                title: speed.displayName,
                action: #selector(selectModifierResponseSpeed(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = speed.rawValue
            item.toolTip = switch speed {
            case .fast: "Starts sooner for a dedicated dictation chord."
            case .balanced: "The default balance of response and shortcut protection."
            case .safe: "Leaves time to continue into another keyboard shortcut."
            }
            menu.addItem(item)
        }
        modifierResponseMenu = menu
        refreshModifierResponseCheckmarks()
        return menu
    }

    @objc private func selectModifierResponseSpeed(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let speed = ModifierResponseSpeed(rawValue: raw) else { return }
        AppState.shared.modifierResponseSpeed = speed
        refreshModifierResponseCheckmarks()
        NotificationCenter.default.post(name: .yaprflowHotkeyChanged, object: nil)
    }

    private func refreshModifierResponseCheckmarks() {
        let current = AppState.shared.modifierResponseSpeed
        modifierResponseMenu?.items.forEach { item in
            let speed = (item.representedObject as? String)
                .flatMap(ModifierResponseSpeed.init(rawValue:))
            item.state = speed == current ? .on : .off
        }
    }

    private func buildNumberFormattingMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(NSMenuItem.sectionHeader(
            title: "Say “digits…” for an exact number sequence"
        ))
        for mode in NumberFormattingMode.allCases {
            let item = NSMenuItem(
                title: mode.displayName,
                action: #selector(selectNumberFormattingMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            item.toolTip = switch mode {
            case .natural: "Leaves number words alone unless you explicitly say “digits”."
            case .smart: "Formats clear quantities and labeled sequences while keeping small prose numbers natural."
            case .preferDigits: "Converts valid spoken-number phrases more broadly."
            }
            menu.addItem(item)
        }
        numberFormattingMenu = menu
        refreshNumberFormattingCheckmarks()
        return menu
    }

    @objc private func selectNumberFormattingMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = NumberFormattingMode(rawValue: raw) else { return }
        AppState.shared.numberFormattingMode = mode
        refreshNumberFormattingCheckmarks()
    }

    private func refreshNumberFormattingCheckmarks() {
        let current = AppState.shared.numberFormattingMode
        numberFormattingMenu?.items.forEach { item in
            let mode = (item.representedObject as? String)
                .flatMap(NumberFormattingMode.init(rawValue:))
            item.state = mode == current ? .on : .off
        }
    }

    @objc private func selectCleanupMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = CleanupMode(rawValue: raw) else { return }
        AppState.shared.cleanupMode = mode
        refreshCleanupModeCheckmarks()
        if mode == .polish {
            GrammarController.shared.preload()
        }
    }

    private func refreshCleanupModeCheckmarks() {
        let current = AppState.shared.cleanupMode
        cleanupModeMenu?.items.forEach { item in
            let mode = (item.representedObject as? String).flatMap(CleanupMode.init(rawValue:))
            item.state = mode == current ? .on : .off
        }
    }

    // MARK: - Advanced submenu

    private func buildAdvancedSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let responseItem = NSMenuItem(
            title: "Keyboard Shortcut Response",
            action: nil,
            keyEquivalent: ""
        )
        responseItem.image = NSImage(
            systemSymbolName: "speedometer",
            accessibilityDescription: nil
        )
        responseItem.submenu = buildModifierResponseMenu()
        responseItem.toolTip = "Changes how long a modifier-only shortcut must be held before dictation starts."
        submenu.addItem(responseItem)

        let numberItem = NSMenuItem(
            title: "Number Formatting",
            action: nil,
            keyEquivalent: ""
        )
        numberItem.image = NSImage(
            systemSymbolName: "number",
            accessibilityDescription: nil
        )
        numberItem.submenu = buildNumberFormattingMenu()
        numberItem.toolTip = "Controls when spoken number words become digits."
        submenu.addItem(numberItem)

        submenu.addItem(NSMenuItem.separator())

        let streamingItem = NSMenuItem()
        streamingItem.view = StreamingModeMenuItemView()
        streamingItem.toolTip = "Experimental: show partial text while speaking. Single-shot mode is the recommended, more accurate default."
        submenu.addItem(streamingItem)

        let screenContextItem = NSMenuItem()
        screenContextItem.view = ScreenContextMenuItemView()
        screenContextItem.toolTip = "Used only in Polish mode. Reads a short window of text near your cursor so the on-device model can prefer spellings already on screen. Sensitive apps are skipped."
        submenu.addItem(screenContextItem)

        let comparisonItem = NSMenuItem()
        comparisonItem.view = ToggleMenuItemView(
            symbolName: "eye.slash",
            title: "Shadow Comparison",
            publisher: AppState.shared.$comparisonLogMode.eraseToAnyPublisher(),
            get: { AppState.shared.comparisonLogMode },
            set: {
                AppState.shared.comparisonLogMode = $0
                if $0 {
                    GrammarController.shared.preload()
                }
            }
        )
        comparisonItem.toolTip = "Study tool: logs Yaprflow raw, Light, and queued Polish results silently while Wispr Flow inserts normally. Wispr's local history is paired later, so this works in every app without touching the clipboard."
        submenu.addItem(comparisonItem)

        return submenu
    }

    // MARK: - Sound Effects submenu

    /// Builds the "Sound Effects" submenu: enablement, per-app volume,
    /// start/stop pickers, local import management, and reset. It is rebuilt
    /// after an import or removal so the new inventory appears immediately.
    private func buildSoundsSubmenu() -> NSMenu {
        let submenu = NSMenu()

        let enabledItem = NSMenuItem(
            title: "Enabled",
            action: #selector(toggleSoundsEnabled(_:)),
            keyEquivalent: ""
        )
        enabledItem.target = self
        enabledItem.state = AppState.shared.soundEffectsEnabled ? .on : .off
        submenu.addItem(enabledItem)

        let volumeItem = NSMenuItem()
        volumeItem.view = SoundVolumeMenuItemView()
        volumeItem.toolTip = "Changes only Yaprflow's confirmation sounds, not system volume."
        submenu.addItem(volumeItem)

        submenu.addItem(NSMenuItem.separator())

        let startPicker = buildSoundPickerMenu(forStart: true)
        self.startSoundPickerMenu = startPicker
        let startParent = NSMenuItem(title: "Start Sound", action: nil, keyEquivalent: "")
        startParent.submenu = startPicker
        submenu.addItem(startParent)

        let stopPicker = buildSoundPickerMenu(forStart: false)
        self.stopSoundPickerMenu = stopPicker
        let stopParent = NSMenuItem(title: "Stop Sound", action: nil, keyEquivalent: "")
        stopParent.submenu = stopPicker
        submenu.addItem(stopParent)

        submenu.addItem(NSMenuItem.separator())

        let imported = SoundEffect.importedSounds()
        if !imported.isEmpty {
            let removeParent = NSMenuItem(
                title: "Remove Imported Sound",
                action: nil,
                keyEquivalent: ""
            )
            let removeMenu = NSMenu()
            for option in imported {
                let item = NSMenuItem(
                    title: option.displayName,
                    action: #selector(removeImportedSound(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = option.identifier
                removeMenu.addItem(item)
            }
            removeParent.submenu = removeMenu
            submenu.addItem(removeParent)
        }

        let resetItem = NSMenuItem(
            title: "Reset to Defaults",
            action: #selector(resetSoundsToDefaults),
            keyEquivalent: ""
        )
        resetItem.target = self
        submenu.addItem(resetItem)

        return submenu
    }

    private func buildSoundPickerMenu(forStart: Bool) -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        let current = forStart
            ? AppState.shared.startSoundName
            : AppState.shared.stopSoundName
        let selector: Selector = forStart
            ? #selector(selectStartSound(_:))
            : #selector(selectStopSound(_:))

        func addSound(_ name: String) {
            addSound(identifier: name, displayName: name)
        }

        func addSound(identifier: String, displayName: String) {
            let item = NSMenuItem(title: displayName, action: selector, keyEquivalent: "")
            item.target = self
            item.representedObject = identifier
            item.state = (identifier == current) ? .on : .off
            item.toolTip = "Highlight to preview. Click to select."
            menu.addItem(item)
        }

        let imported = SoundEffect.importedSounds()
        if !imported.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Imported"))
            imported.forEach {
                addSound(identifier: $0.identifier, displayName: $0.displayName)
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Custom chimes bundled with the app (synthesized + imported) get
        // their own section above the macOS system set.
        let bundled = SoundEffect.bundledSounds()
        if !bundled.isEmpty {
            menu.addItem(NSMenuItem.sectionHeader(title: "Yaprflow"))
            bundled.forEach(addSound)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem.sectionHeader(title: "macOS"))
        }
        SoundEffect.availableSounds().forEach(addSound)

        menu.addItem(NSMenuItem.separator())
        let importItem = NSMenuItem(
            title: "Import Custom Sound…",
            action: forStart
                ? #selector(importStartSound)
                : #selector(importStopSound),
            keyEquivalent: ""
        )
        importItem.target = self
        importItem.toolTip = "Copies a local audio file into Yaprflow. The original file is unchanged."
        menu.addItem(importItem)

        return menu
    }

    /// Audition sounds while the picker remains open. Highlighting works with
    /// both pointer movement and the keyboard's arrow-key menu navigation;
    /// only activating an item commits the new selection.
    func menu(_ menu: NSMenu, willHighlight item: NSMenuItem?) {
        guard menu === startSoundPickerMenu || menu === stopSoundPickerMenu,
              let identifier = item?.representedObject as? String else {
            return
        }
        SoundEffect.preview(identifier)
    }

    /// Imported sounds may be up to 30 seconds long. Leaving the picker should
    /// end the audition immediately instead of letting it continue in the
    /// background after the user has moved on.
    func menuDidClose(_ menu: NSMenu) {
        guard menu === startSoundPickerMenu || menu === stopSoundPickerMenu else {
            return
        }
        SoundEffect.stopPreview()
    }

    @objc private func toggleSoundsEnabled(_ sender: NSMenuItem) {
        AppState.shared.soundEffectsEnabled.toggle()
        sender.state = AppState.shared.soundEffectsEnabled ? .on : .off
    }

    @objc private func selectStartSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        AppState.shared.startSoundName = name
        refreshSoundCheckmarks(in: sender.menu, current: name)
    }

    @objc private func selectStopSound(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        AppState.shared.stopSoundName = name
        refreshSoundCheckmarks(in: sender.menu, current: name)
    }

    @objc private func resetSoundsToDefaults() {
        AppState.shared.startSoundName = SoundEffect.defaultStartName
        AppState.shared.stopSoundName = SoundEffect.defaultStopName
        AppState.shared.soundEffectsVolume = 1
        refreshSoundCheckmarks(in: startSoundPickerMenu, current: SoundEffect.defaultStartName)
        refreshSoundCheckmarks(in: stopSoundPickerMenu, current: SoundEffect.defaultStopName)
    }

    @objc private func importStartSound() {
        presentSoundImporter(forStart: true)
    }

    @objc private func importStopSound() {
        presentSoundImporter(forStart: false)
    }

    private func presentSoundImporter(forStart: Bool) {
        let panel = NSOpenPanel()
        panel.title = forStart ? "Choose a Start Sound" : "Choose a Stop Sound"
        panel.message = "Choose a local sound effect up to 30 seconds. Yaprflow keeps its own private copy."
        panel.prompt = "Import"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.audio]

        NSApp.activate(ignoringOtherApps: true)
        panel.begin { [weak self] response in
            guard response == .OK, let source = panel.url else { return }
            Task { @MainActor in
                self?.finishSoundImport(from: source, forStart: forStart)
            }
        }
    }

    private func finishSoundImport(from source: URL, forStart: Bool) {
        let didAccess = source.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                source.stopAccessingSecurityScopedResource()
            }
        }

        do {
            let option = try SoundEffect.importSound(from: source)
            if forStart {
                AppState.shared.startSoundName = option.identifier
            } else {
                AppState.shared.stopSoundName = option.identifier
            }
            rebuildSoundsSubmenu()
            SoundEffect.preview(option.identifier)
        } catch {
            showSoundAlert(
                title: "Couldn't Import Sound",
                message: error.localizedDescription
            )
        }
    }

    @objc private func removeImportedSound(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        let displayName = SoundEffect.displayName(for: identifier)

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Remove “\(displayName)” from Yaprflow?"
        alert.informativeText = "Yaprflow's private copy will be deleted. Your original audio file will not be changed."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        do {
            try SoundEffect.removeImportedSound(identifier: identifier)
            if AppState.shared.startSoundName == identifier {
                AppState.shared.startSoundName = SoundEffect.defaultStartName
            }
            if AppState.shared.stopSoundName == identifier {
                AppState.shared.stopSoundName = SoundEffect.defaultStopName
            }
            rebuildSoundsSubmenu()
        } catch {
            showSoundAlert(
                title: "Couldn't Remove Sound",
                message: error.localizedDescription
            )
        }
    }

    private func rebuildSoundsSubmenu() {
        soundsMenuItem?.submenu = buildSoundsSubmenu()
    }

    private func showSoundAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func refreshSoundCheckmarks(in menu: NSMenu?, current: String) {
        guard let menu else { return }
        for item in menu.items {
            if let name = item.representedObject as? String {
                item.state = (name == current) ? .on : .off
            }
        }
    }

    private func registerHotkey() {
        guard AppState.shared.keyboardShortcutEnabled else {
            GlobalHotkey.shared.unregister()
            ModifierOnlyHotkey.shared.unregister()
            return
        }

        let config = AppState.shared.hotkey

        // Exactly one backend active at a time.
        if config.isModifierOnly {
            GlobalHotkey.shared.unregister()
            guard config.isValid else { return }
            wireModifierOnlyCallbacks()
            ModifierOnlyHotkey.shared.register(
                modifiers: config.modifiers,
                sideMask: config.sideMask,
                sideMatching: !AppState.shared.bothKeyboardSides,
                holdEngageMilliseconds: AppState.shared.modifierResponseSpeed
                    .holdEngageMilliseconds
            )
        } else {
            ModifierOnlyHotkey.shared.unregister()
            wireHotkeyCallbacks(for: config.mode)
            GlobalHotkey.shared.register(keyCode: config.keyCode, modifiers: config.modifiers)
        }
    }

    private func registerExternalHotkey() {
        let config = AppState.shared.externalHotkey
        guard config.enabled else {
            ExternalHotkey.shared.unregister()
            restoreKeyboardShortcutIfNeeded()
            return
        }

        // Carbon cannot register the same key combination twice. Keep the
        // main shortcut authoritative if both settings ever converge.
        guard !config.conflicts(with: AppState.shared.hotkey) else {
            ExternalHotkey.shared.unregister()
            restoreKeyboardShortcutIfNeeded()
            return
        }

        switch config.mode {
        case .tapToToggle:
            ExternalHotkey.onPressed = {
                Task { @MainActor in
                    TranscriptionController.shared.toggle()
                }
            }
            ExternalHotkey.onReleased = nil
        case .holdToTalk:
            ExternalHotkey.onPressed = {
                Task { @MainActor in
                    TranscriptionController.shared.setActive(true)
                }
            }
            ExternalHotkey.onReleased = {
                Task { @MainActor in
                    TranscriptionController.shared.setActive(false)
                }
            }
        }

        let registered = ExternalHotkey.shared.register(
            keyCode: config.keyCode,
            modifiers: config.modifiers
        )
        if !registered {
            restoreKeyboardShortcutIfNeeded()
        }
    }

    /// The primary shortcut is the fail-safe: if the external path disappears
    /// while it is paused, restore it without changing its saved configuration.
    private func restoreKeyboardShortcutIfNeeded() {
        guard !AppState.shared.keyboardShortcutEnabled else { return }
        AppState.shared.keyboardShortcutEnabled = true
        registerHotkey()
        NotificationCenter.default.post(name: .yaprflowHotkeyChanged, object: nil)
    }

    /// Modifier-only bindings always support both hold-to-talk and
    /// double-tap-to-lock simultaneously. `ModifierOnlyHotkey` handles the
    /// gesture state internally and only fires onStart / onStop on actual
    /// recording-state transitions, so wiring is symmetric and idempotent.
    private func wireModifierOnlyCallbacks() {
        ModifierOnlyHotkey.onStart = {
            Task { @MainActor in
                TranscriptionController.shared.setActive(true)
            }
        }
        ModifierOnlyHotkey.onStop = {
            Task { @MainActor in
                TranscriptionController.shared.setActive(false)
            }
        }
    }

    private func wireHotkeyCallbacks(for mode: HotkeyMode) {
        switch mode {
        case .tapToToggle:
            GlobalHotkey.onPressed = {
                Task { @MainActor in
                    TranscriptionController.shared.toggle()
                }
            }
            GlobalHotkey.onReleased = nil
        case .holdToTalk:
            GlobalHotkey.onPressed = {
                Task { @MainActor in
                    TranscriptionController.shared.setActive(true)
                }
            }
            GlobalHotkey.onReleased = {
                Task { @MainActor in
                    TranscriptionController.shared.setActive(false)
                }
            }
        }
    }
}
