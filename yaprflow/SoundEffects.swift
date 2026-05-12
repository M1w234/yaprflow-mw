import AppKit
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "SoundEffects")

/// Tiny wrapper around system sounds for the start/stop chimes. macOS ships
/// these in `/System/Library/Sounds/`; `NSSound(named:)` finds them by basename
/// with no bundle weight on our side. The specific names come from
/// `AppState.startSoundName` / `stopSoundName`, configurable via the menu.
/// Gated on `AppState.soundEffectsEnabled` so users who find chimes annoying
/// can silence them without losing the rest of the visual feedback.
@MainActor
enum SoundEffect {
    case start
    case stop

    /// Defaults chosen for the feel they convey: a single short croak (Frog)
    /// to signal recording started, and a satisfying pop (Bottle) when it
    /// stops. Used by AppState on first launch and by "Reset to Defaults" in
    /// the menu.
    nonisolated static let defaultStartName = "Frog"
    nonisolated static let defaultStopName = "Bottle"

    /// Stable list of macOS system sounds, used as a fallback if the sandbox
    /// or a filesystem hiccup blocks directory enumeration. These names have
    /// shipped with macOS for many releases; safe to hardcode.
    nonisolated private static let canonicalSounds: [String] = [
        "Basso", "Blow", "Bottle", "Frog", "Funk",
        "Glass", "Hero", "Morse", "Ping", "Pop",
        "Purr", "Sosumi", "Submarine", "Tink",
    ]

    /// Names of all selectable sounds. Tries `/System/Library/Sounds/` first so
    /// any sounds Apple adds in future macOS versions surface automatically,
    /// then falls back to the canonical list. User-installed sounds in
    /// `~/Library/Sounds/` aren't enumerated — the app sandbox forbids that
    /// directory without explicit user-selected file access.
    nonisolated static func availableSounds() -> [String] {
        let systemDir = URL(fileURLWithPath: "/System/Library/Sounds")
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: systemDir, includingPropertiesForKeys: nil
        ) {
            let names = entries
                .filter { $0.pathExtension.lowercased() == "aiff" }
                .map { $0.deletingPathExtension().lastPathComponent }
                .sorted()
            if !names.isEmpty { return names }
        }
        return canonicalSounds
    }

    private var systemSoundName: String {
        switch self {
        case .start: return AppState.shared.startSoundName
        case .stop:  return AppState.shared.stopSoundName
        }
    }

    /// Fire-and-forget. Multiple back-to-back plays (e.g. user taps the hotkey
    /// twice fast in tap-to-toggle) overlap cleanly — `NSSound.play()` returns
    /// immediately and the audio path is independent of our recording pipeline.
    func play() {
        guard AppState.shared.soundEffectsEnabled else { return }
        Self.playByName(systemSoundName)
    }

    /// Play a sound by name regardless of the global enabled toggle. Used by
    /// the sound picker so users can audition options even when chimes are
    /// turned off overall.
    static func preview(_ name: String) {
        playByName(name)
    }

    private static func playByName(_ name: String) {
        guard let sound = NSSound(named: NSSound.Name(name)) else {
            log.error("System sound \(name, privacy: .public) not found")
            return
        }
        sound.play()
    }
}
