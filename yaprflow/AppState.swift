import Combine
import SwiftUI

enum CleanupMode: String, CaseIterable {
    case off
    case light
    case polish

    var displayName: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .polish: return "Polish"
        }
    }
}

enum TranscriptionStatus: Equatable {
    case idle
    case preparing(String)
    case listening
    case finishing
    case correcting(String)
    case summarizing  // New: on-demand summary in progress
    case copied
    /// Delivered via clipboard-free direct insertion.
    case inserted
    /// Recorded for comparison without inserting or changing the clipboard.
    case captured
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    private static let streamingModeKey = "yaprflow.streamingMode"
    private static let cleanupModeKey = "yaprflow.cleanupMode"
    // Kept as a rollback-compatible mirror. Older builds only know this Bool.
    private static let grammarModeKey = "yaprflow.grammarMode"
    private static let autoPasteModeKey = "yaprflow.autoPasteMode"
    private static let screenContextModeKey = "yaprflow.screenContextMode"
    private static let preserveClipboardModeKey = "yaprflow.preserveClipboardMode"
    private static let duckWhileRecordingKey = "yaprflow.duckWhileRecording"
    private static let comparisonLogModeKey = "yaprflow.comparisonLogMode"
    private static let bothKeyboardSidesKey = "yaprflow.bothKeyboardSides"
    private static let soundEffectsEnabledKey = "yaprflow.soundEffectsEnabled"
    private static let startSoundNameKey = "yaprflow.startSoundName"
    private static let stopSoundNameKey = "yaprflow.stopSoundName"
    private static let lastTranscriptKey = "yaprflow.lastTranscript"

    @Published var status: TranscriptionStatus = .idle
    @Published var liveTranscript: String = ""
    @Published var hotkey: HotkeyConfig = HotkeyConfig.load() ?? .defaultHotkey

    /// When `true` (default), show live partials during dictation at the cost
    /// of slightly lower accuracy. When `false`, record silently and transcribe
    /// the full clip in one pass when the hotkey is released — more accurate
    /// for longer sentences, but no text appears until you stop.
    @Published var streamingMode: Bool {
        didSet {
            UserDefaults.standard.set(streamingMode, forKey: Self.streamingModeKey)
        }
    }

    /// Off preserves the ASR transcript, Light applies only synchronous,
    /// deterministic cleanup, and Polish runs the on-device MLX LLM.
    @Published var cleanupMode: CleanupMode {
        didSet {
            UserDefaults.standard.set(cleanupMode.rawValue, forKey: Self.cleanupModeKey)
            UserDefaults.standard.set(cleanupMode == .polish, forKey: Self.grammarModeKey)
        }
    }

    /// When `true`, the final transcript is inserted directly into the focused
    /// text field without touching the clipboard. Gated at the insertion site
    /// on Accessibility permission, secure-input state, and a focus-PID match
    /// captured at recording start.
    @Published var autoPasteMode: Bool {
        didSet {
            UserDefaults.standard.set(autoPasteMode, forKey: Self.autoPasteModeKey)
        }
    }

    /// When `true`, capture a small window of text around the cursor at
    /// recording start and feed it to the on-device grammar polish so the
    /// LLM can prefer spellings already on the screen ("fleet view" →
    /// "FleetView"). Uses the same Accessibility permission as auto-paste.
    /// Defaults to off — reading text out of other apps is a meaningfully
    /// different privacy posture than the existing features and shouldn't
    /// turn itself on. Browsers, mail, messages, and password managers are
    /// hard-denied at capture time regardless of this toggle.
    @Published var screenContextMode: Bool {
        didSet {
            UserDefaults.standard.set(screenContextMode, forKey: Self.screenContextModeKey)
        }
    }

    /// Legacy compatibility mirror for builds that exposed a separate
    /// Preserve Clipboard switch. Current builds always preserve it whenever
    /// automatic insertion is enabled.
    @Published var preserveClipboardMode: Bool {
        didSet {
            UserDefaults.standard.set(preserveClipboardMode, forKey: Self.preserveClipboardModeKey)
        }
    }

    /// When `true`, mute system audio output for the duration of a recording
    /// session (Wispr-style ducking) and restore it afterwards. Toggling it
    /// mid-recording applies immediately (wired in the menu item).
    @Published var duckWhileRecording: Bool {
        didSet {
            UserDefaults.standard.set(duckWhileRecording, forKey: Self.duckWhileRecordingKey)
        }
    }

    /// When `true`, run as a silent comparison shadow: each finished dictation
    /// is appended immediately to comparison-log.jsonl and Yaprflow does not
    /// insert or touch the clipboard. Wispr Flow's side is paired later from
    /// its local History database, independent of the destination app.
    @Published var comparisonLogMode: Bool {
        didSet {
            UserDefaults.standard.set(comparisonLogMode, forKey: Self.comparisonLogModeKey)
        }
    }

    /// For modifier-only shortcuts (e.g. ⌘⇧): when `false` (default), only the
    /// physical side of the keyboard the shortcut was first triggered on fires
    /// it — so left ⌘⇧ combos don't collide with dictation. When `true`, either
    /// side triggers. No effect on key-based shortcuts.
    @Published var bothKeyboardSides: Bool {
        didSet {
            UserDefaults.standard.set(bothKeyboardSides, forKey: Self.bothKeyboardSidesKey)
        }
    }

    /// When `true`, play a short system sound on recording start and stop.
    /// Defaults to on — chimes are a small but useful signal that the mic is
    /// actually live, especially on flaky hotkeys. The specific sounds are
    /// picked via `startSoundName` / `stopSoundName`.
    @Published var soundEffectsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(soundEffectsEnabled, forKey: Self.soundEffectsEnabledKey)
        }
    }

    /// Name of the macOS system sound played at recording start. Resolved by
    /// `NSSound(named:)`, so values must match a basename in
    /// `/System/Library/Sounds/` (without the .aiff extension).
    @Published var startSoundName: String {
        didSet {
            UserDefaults.standard.set(startSoundName, forKey: Self.startSoundNameKey)
        }
    }

    /// Name of the macOS system sound played at recording stop. See
    /// `startSoundName` for resolution semantics.
    @Published var stopSoundName: String {
        didSet {
            UserDefaults.standard.set(stopSoundName, forKey: Self.stopSoundNameKey)
        }
    }

    /// Live input audio level, normalized to 0…1. Driven from
    /// `TranscriptionController.feed()` at each PCM buffer (~50 Hz at the
    /// engine's default tap size). Consumed by the overlay's bouncing-bar
    /// visualizer; safe to leave at 0 outside of an active session.
    @Published var inputLevel: Float = 0

    /// Most recent finalized transcript. Persisted so it survives restarts and
    /// can be re-copied from the menu bar after the clipboard has been replaced.
    @Published var lastTranscript: String {
        didSet {
            UserDefaults.standard.set(lastTranscript, forKey: Self.lastTranscriptKey)
        }
    }

    /// The raw transcript before grammar correction. Empty when grammar mode
    /// is off or hasn't run yet.
    @Published var lastOriginalTranscript: String = ""

    private init() {
        if let stored = UserDefaults.standard.object(forKey: Self.streamingModeKey) as? Bool {
            self.streamingMode = stored
        } else {
            self.streamingMode = false
        }
        if let raw = UserDefaults.standard.string(forKey: Self.cleanupModeKey),
           let stored = CleanupMode(rawValue: raw) {
            self.cleanupMode = stored
        } else if let legacyGrammar = UserDefaults.standard.object(forKey: Self.grammarModeKey) as? Bool {
            // Exact behavioral migration: existing Grammar On stays Polish;
            // existing Grammar Off stays Off. Fresh installs default to Light.
            self.cleanupMode = legacyGrammar ? .polish : .off
        } else {
            self.cleanupMode = .light
        }
        if let stored = UserDefaults.standard.object(forKey: Self.autoPasteModeKey) as? Bool {
            self.autoPasteMode = stored
        } else {
            self.autoPasteMode = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.screenContextModeKey) as? Bool {
            self.screenContextMode = stored
        } else {
            self.screenContextMode = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.preserveClipboardModeKey) as? Bool {
            self.preserveClipboardMode = stored
        } else {
            self.preserveClipboardMode = true
        }
        if let stored = UserDefaults.standard.object(forKey: Self.duckWhileRecordingKey) as? Bool {
            self.duckWhileRecording = stored
        } else {
            self.duckWhileRecording = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.comparisonLogModeKey) as? Bool {
            self.comparisonLogMode = stored
        } else {
            self.comparisonLogMode = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.bothKeyboardSidesKey) as? Bool {
            self.bothKeyboardSides = stored
        } else {
            self.bothKeyboardSides = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.soundEffectsEnabledKey) as? Bool {
            self.soundEffectsEnabled = stored
        } else {
            self.soundEffectsEnabled = true
        }
        self.startSoundName = UserDefaults.standard.string(forKey: Self.startSoundNameKey)
            ?? SoundEffect.defaultStartName
        self.stopSoundName = UserDefaults.standard.string(forKey: Self.stopSoundNameKey)
            ?? SoundEffect.defaultStopName
        self.lastTranscript = UserDefaults.standard.string(forKey: Self.lastTranscriptKey) ?? ""
    }
}

extension Notification.Name {
    static let yaprflowHotkeyChanged = Notification.Name("yaprflow.hotkey.changed")
}
