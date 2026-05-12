import AppKit
import Carbon.HIToolbox
import CoreGraphics
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "ModifierOnlyHotkey")

/// Detects modifier-only hotkey gestures (e.g. ⌘⇧ alone, no third key) via a
/// listen-only `CGEventTap`. Carbon's `RegisterEventHotKey` requires a non-
/// modifier keyCode, so modifier-only combos go through this path instead.
///
/// **Two gestures are recognized simultaneously, both always on:**
///   1. *Hold-to-talk*: press and hold the chord past `holdEngageMilliseconds`
///      → starts recording; release the chord → stops.
///   2. *Double-tap-to-lock*: tap the chord twice within `doubleTapWindowMilliseconds`
///      → starts recording in "locked" mode (recording continues even after
///      chord is released); a subsequent clean single tap of the chord → stops.
///
/// **Disambiguation:** the chord is only "tapped" if released cleanly without
/// any non-modifier keyDown or extra modifier added in between. This lets the
/// user keep pressing ⌘⇧+3, ⌘⇧+letter, etc. without falsely starting dictation.
///
/// **In lock mode, regular chord usage doesn't stop recording** — only a clean
/// chord tap stops it. So you can keep typing ⌘⇧+arrow, ⌘⇧+letter while dictating
/// and recording continues until you explicitly tap the chord alone.
@MainActor
final class ModifierOnlyHotkey {
    static let shared = ModifierOnlyHotkey()

    /// Called when recording should start (either hold engaged or double-tap completed).
    /// Idempotent: only called when transitioning from not-recording → recording.
    nonisolated(unsafe) static var onStart: (@Sendable () -> Void)?

    /// Called when recording should stop (hold released, or stop-tap in lock mode).
    /// Idempotent: only called when transitioning from recording → not-recording.
    nonisolated(unsafe) static var onStop: (@Sendable () -> Void)?

    /// Minimum chord hold time before hold-to-talk engages. Tuned for ⌘⇧ —
    /// long enough that typing ⌘⇧+letter chords quickly doesn't accidentally
    /// engage hold mode, short enough that a deliberate hold feels responsive.
    private static let holdEngageMilliseconds: Int = 200

    /// Maximum gap between two chord taps to count as a double-tap.
    private static let doubleTapWindowMilliseconds: Int = 400

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    /// Carbon-style modifier mask (cmdKey | shiftKey | ...). Modifier-only.
    private var desiredMask: UInt32 = 0

    /// Tracks what we observed on the previous event, so we can detect the
    /// "chord just became exact" / "exact → subset" / "exact → with-extras"
    /// transitions cleanly.
    private var lastActiveMask: UInt32 = 0

    /// Gesture recognizer state.
    private enum Gesture {
        case idle       // chord not held / nothing pending
        case armed      // exact chord held, awaiting hold-or-tap decision
        case poisoned   // chord held but used for something else (extra mod or keyDown)
    }
    private var gesture: Gesture = .idle

    /// Recording state. Driven entirely by this class; the `on{Start,Stop}`
    /// callbacks are fired on transitions.
    private enum RecordingMode {
        case none       // not recording
        case hold       // recording active, will stop when chord released
        case lock       // recording active, persists until clean stop-tap
    }
    private var recordingMode: RecordingMode = .none

    /// `true` between the release of the first tap and the double-tap window
    /// expiring. A second tap during this window engages lock-mode recording.
    private var pendingFirstTap: Bool = false

    private var holdEngageWork: DispatchWorkItem?
    private var doubleTapWindowWork: DispatchWorkItem?

    private init() {}

    func register(modifiers: UInt32) {
        unregister()
        guard modifiers != 0 else {
            log.error("refusing to register modifier-only hotkey with empty mask")
            return
        }
        self.desiredMask = modifiers
        resetState()
        installTapIfNeeded()
    }

    func unregister() {
        cancelHoldEngage()
        cancelDoubleTapWindow()
        if recordingMode != .none {
            invoke(Self.onStop)
        }
        resetState()
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            runLoopSource = nil
        }
        if let tap = tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
    }

    private func resetState() {
        gesture = .idle
        recordingMode = .none
        pendingFirstTap = false
        lastActiveMask = 0
    }

    private func installTapIfNeeded() {
        guard tap == nil else { return }

        let mask: CGEventMask =
            (1 << CGEventType.flagsChanged.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)

        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<ModifierOnlyHotkey>.fromOpaque(refcon).takeUnretainedValue()
                me.handleFromTap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            log.error("CGEvent.tapCreate returned nil (Accessibility not granted?)")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.tap = port
        self.runLoopSource = source
    }

    /// Tap callback entry. The run loop source was added to
    /// `CFRunLoopGetMain()`, so this is invoked on the main thread — we use
    /// `MainActor.assumeIsolated` to bridge from the `@convention(c)`
    /// callback's nonisolated context.
    nonisolated private func handleFromTap(type: CGEventType, event: CGEvent) {
        let flagsRaw = event.flags.rawValue

        MainActor.assumeIsolated {
            // Re-enable on timeout / user-input disable. macOS will not do
            // this for us; missing it means the hotkey silently dies forever.
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let port = self.tap {
                    CGEvent.tapEnable(tap: port, enable: true)
                }
                return
            }
            self.process(flagsRaw: flagsRaw, isKeyDown: type == .keyDown, type: type)
        }
    }

    private func process(flagsRaw: UInt64, isKeyDown: Bool, type: CGEventType) {
        let activeMask = carbonModifiers(fromCGFlags: flagsRaw)
        let prevActive = lastActiveMask

        // keyDown while armed → user is pressing a real chord. Stop hold-mode
        // recording (the chord is being repurposed), but leave lock-mode
        // recording running (lock means recording persists through chord use).
        if isKeyDown {
            if gesture == .armed {
                cancelHoldEngage()
                if recordingMode == .hold {
                    stopRecording()
                }
                gesture = .poisoned
            }
            return
        }

        // Only flagsChanged drives modifier-set transitions below.
        guard type == .flagsChanged else { return }

        lastActiveMask = activeMask

        let wasExact = (prevActive == desiredMask)
        let isExact  = (activeMask == desiredMask)
        let hasExtraNow = (activeMask & ~desiredMask) != 0

        // Event A: chord just became exact.
        if !wasExact && isExact {
            gesture = .armed
            if recordingMode == .none {
                scheduleHoldEngage()
            }
            return
        }

        // Event B: chord was exact, now isn't.
        if wasExact && !isExact {
            cancelHoldEngage()

            if hasExtraNow {
                // User added a modifier outside the desired set on top of
                // the chord (e.g. ⌘⇧ → ⌘⇧⌃). Treat as poisoning — different
                // chord. Stop hold-mode recording; lock-mode persists.
                if gesture == .armed && recordingMode == .hold {
                    stopRecording()
                }
                gesture = .poisoned
                return
            }

            // active is a proper subset of desired → user released a desired
            // modifier without extras / keyDown → this completes a "tap" or
            // ends a "hold".
            if gesture == .armed {
                handleCleanTapRelease()
            }
            gesture = (activeMask == 0) ? .idle : .poisoned
            return
        }

        // Event C: chord wasn't exact, isn't exact now either, but active
        // changed. If we're in armed state and an extra mod was added, poison.
        // Also: if all desired modifiers released while poisoned, return to idle.
        if gesture == .poisoned && activeMask == 0 {
            gesture = .idle
        } else if gesture == .armed && hasExtraNow {
            cancelHoldEngage()
            if recordingMode == .hold {
                stopRecording()
            }
            gesture = .poisoned
        }
    }

    /// Called when the user releases a desired modifier from the exact-chord
    /// state cleanly (no extra mods, no keyDown observed). This is the only
    /// path where taps actually do something.
    private func handleCleanTapRelease() {
        switch recordingMode {
        case .hold:
            // Hold-to-talk recording ends on chord release.
            stopRecording()
            // Pending tap is irrelevant after a hold session.
            pendingFirstTap = false
            cancelDoubleTapWindow()

        case .lock:
            // Tap-to-stop while in locked recording.
            stopRecording()
            pendingFirstTap = false
            cancelDoubleTapWindow()

        case .none:
            // No recording active — this is just a tap; decide single vs double.
            if pendingFirstTap {
                // Second tap inside window → double-tap → start lock recording.
                pendingFirstTap = false
                cancelDoubleTapWindow()
                startRecording(mode: .lock)
            } else {
                // First tap — wait for a possible second tap.
                pendingFirstTap = true
                scheduleDoubleTapWindow()
            }
        }
    }

    // MARK: - Recording lifecycle

    private func startRecording(mode: RecordingMode) {
        guard recordingMode == .none, mode != .none else { return }
        recordingMode = mode
        invoke(Self.onStart)
    }

    private func stopRecording() {
        guard recordingMode != .none else { return }
        recordingMode = .none
        invoke(Self.onStop)
    }

    // MARK: - Timers

    private func scheduleHoldEngage() {
        cancelHoldEngage()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                // Only engage hold if we're still armed and not already recording.
                guard self.gesture == .armed, self.recordingMode == .none else { return }
                self.startRecording(mode: .hold)
            }
        }
        holdEngageWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.holdEngageMilliseconds),
            execute: work
        )
    }

    private func cancelHoldEngage() {
        holdEngageWork?.cancel()
        holdEngageWork = nil
    }

    private func scheduleDoubleTapWindow() {
        cancelDoubleTapWindow()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            MainActor.assumeIsolated {
                self.pendingFirstTap = false
            }
        }
        doubleTapWindowWork = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Self.doubleTapWindowMilliseconds),
            execute: work
        )
    }

    private func cancelDoubleTapWindow() {
        doubleTapWindowWork?.cancel()
        doubleTapWindowWork = nil
    }

    private func invoke(_ handler: (@Sendable () -> Void)?) {
        handler?()
    }

    /// Translate CGEventFlags (`NSEvent.ModifierFlags`-compatible mask) into
    /// the Carbon `cmdKey | shiftKey | ...` mask used by `HotkeyConfig`.
    /// CapsLock and the secondary-Fn bit are intentionally excluded.
    private func carbonModifiers(fromCGFlags raw: UInt64) -> UInt32 {
        var mods: UInt32 = 0
        if raw & UInt64(CGEventFlags.maskCommand.rawValue)   != 0 { mods |= UInt32(cmdKey) }
        if raw & UInt64(CGEventFlags.maskShift.rawValue)     != 0 { mods |= UInt32(shiftKey) }
        if raw & UInt64(CGEventFlags.maskAlternate.rawValue) != 0 { mods |= UInt32(optionKey) }
        if raw & UInt64(CGEventFlags.maskControl.rawValue)   != 0 { mods |= UInt32(controlKey) }
        return mods
    }
}
