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

/// How long a modifier-only chord must remain exact before hold-to-talk
/// begins. Faster settings feel more immediate; slower settings leave more
/// time to add a regular shortcut key without accidentally starting dictation.
enum ModifierResponseSpeed: String, CaseIterable {
    case fast
    case balanced
    case safe

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .balanced: return "Balanced"
        case .safe: return "Safe"
        }
    }

    var holdEngageMilliseconds: Int {
        switch self {
        case .fast: return 100
        case .balanced: return 200
        case .safe: return 300
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
    /// A distinctive in-place correction was added to the vocabulary.
    case learned(String)
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
    private static let learnFromCorrectionsKey = "yaprflow.learnFromCorrections"
    private static let keyboardShortcutEnabledKey = "yaprflow.keyboardShortcutEnabled"
    private static let bothKeyboardSidesKey = "yaprflow.bothKeyboardSides"
    private static let modifierResponseSpeedKey = "yaprflow.modifierResponseSpeed"
    private static let numberFormattingModeKey = "yaprflow.numberFormattingMode"
    private static let soundEffectsEnabledKey = "yaprflow.soundEffectsEnabled"
    private static let soundEffectsVolumeKey = "yaprflow.soundEffectsVolume"
    private static let startSoundNameKey = "yaprflow.startSoundName"
    private static let stopSoundNameKey = "yaprflow.stopSoundName"
    private static let lastTranscriptKey = "yaprflow.lastTranscript"

    @Published var status: TranscriptionStatus = .idle
    @Published var liveTranscript: String = ""
    @Published var hotkey: HotkeyConfig = HotkeyConfig.load() ?? .defaultHotkey
    @Published var externalHotkey: ExternalHotkeyConfig =
        ExternalHotkeyConfig.load() ?? .defaultConfig

    /// Controls whether the saved primary keyboard shortcut is currently
    /// registered. Pausing it never changes the saved keys or trigger mode.
    @Published var keyboardShortcutEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                keyboardShortcutEnabled,
                forKey: Self.keyboardShortcutEnabledKey
            )
        }
    }

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

    /// Opt-in observation of the text range Yaprflow just inserted, plus small
    /// in-memory boundary anchors that prevent edits elsewhere from learning.
    /// Compatibility fields may expose only their current AXValue; that value
    /// is read transiently and immediately reduced to the same anchors.
    /// If a web field exposes neither, a listen-only event tap briefly retains
    /// only a short typing burst after an edit gesture in the target app.
    /// When a distinctive name/term is corrected in-place, Yaprflow asks the
    /// user to confirm or edit the localized replacement before saving it to
    /// personal vocabulary. No surrounding document text or observed typing
    /// is persisted.
    @Published var learnFromCorrections: Bool {
        didSet {
            UserDefaults.standard.set(
                learnFromCorrections,
                forKey: Self.learnFromCorrectionsKey
            )
            if !learnFromCorrections {
                CorrectionLearningMonitor.shared.cancel()
            }
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

    /// Applies only to modifier-only hold-to-talk. Key-based primary shortcuts
    /// and the independent external shortcut fire through their own backends.
    @Published var modifierResponseSpeed: ModifierResponseSpeed {
        didSet {
            UserDefaults.standard.set(
                modifierResponseSpeed.rawValue,
                forKey: Self.modifierResponseSpeedKey
            )
        }
    }

    /// Controls deterministic spoken-number conversion after cleanup and
    /// before delivery. The explicit "digits" cue works in every mode.
    @Published var numberFormattingMode: NumberFormattingMode {
        didSet {
            UserDefaults.standard.set(
                numberFormattingMode.rawValue,
                forKey: Self.numberFormattingModeKey
            )
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

    /// Per-chime playback volume. This changes only Yaprflow's confirmation
    /// sounds; it never changes the Mac's system output volume.
    @Published var soundEffectsVolume: Float {
        didSet {
            UserDefaults.standard.set(
                min(max(soundEffectsVolume, 0), 1),
                forKey: Self.soundEffectsVolumeKey
            )
        }
    }

    /// Identifier of the sound played at recording start. Legacy values are
    /// macOS/bundled sound names; imported sounds use SoundEffect's private
    /// identifier prefix so equal display names cannot collide.
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
        if let stored = UserDefaults.standard.object(
            forKey: Self.keyboardShortcutEnabledKey
        ) as? Bool {
            self.keyboardShortcutEnabled = stored
        } else {
            self.keyboardShortcutEnabled = true
        }
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
        if let stored = UserDefaults.standard.object(forKey: Self.learnFromCorrectionsKey) as? Bool {
            self.learnFromCorrections = stored
        } else {
            self.learnFromCorrections = false
        }
        if let stored = UserDefaults.standard.object(forKey: Self.bothKeyboardSidesKey) as? Bool {
            self.bothKeyboardSides = stored
        } else {
            self.bothKeyboardSides = false
        }
        if let raw = UserDefaults.standard.string(forKey: Self.modifierResponseSpeedKey),
           let stored = ModifierResponseSpeed(rawValue: raw) {
            self.modifierResponseSpeed = stored
        } else {
            self.modifierResponseSpeed = .balanced
        }
        if let raw = UserDefaults.standard.string(forKey: Self.numberFormattingModeKey),
           let stored = NumberFormattingMode(rawValue: raw) {
            self.numberFormattingMode = stored
        } else {
            self.numberFormattingMode = .smart
        }
        if let stored = UserDefaults.standard.object(forKey: Self.soundEffectsEnabledKey) as? Bool {
            self.soundEffectsEnabled = stored
        } else {
            self.soundEffectsEnabled = true
        }
        if let stored = UserDefaults.standard.object(forKey: Self.soundEffectsVolumeKey) as? NSNumber {
            self.soundEffectsVolume = min(max(stored.floatValue, 0), 1)
        } else {
            self.soundEffectsVolume = 1
        }
        self.startSoundName = SoundEffect.resolvedSelection(
            UserDefaults.standard.string(forKey: Self.startSoundNameKey),
            fallback: SoundEffect.defaultStartName
        )
        self.stopSoundName = SoundEffect.resolvedSelection(
            UserDefaults.standard.string(forKey: Self.stopSoundNameKey),
            fallback: SoundEffect.defaultStopName
        )
        self.lastTranscript = UserDefaults.standard.string(forKey: Self.lastTranscriptKey) ?? ""

        // Never restore a persisted state with both user-facing trigger paths
        // disabled. The keyboard shortcut is the safe fallback.
        if !externalHotkey.enabled && !keyboardShortcutEnabled {
            keyboardShortcutEnabled = true
        }
    }
}

extension Notification.Name {
    static let yaprflowHotkeyChanged = Notification.Name("yaprflow.hotkey.changed")
    static let yaprflowExternalHotkeyChanged = Notification.Name("yaprflow.externalHotkey.changed")
}
