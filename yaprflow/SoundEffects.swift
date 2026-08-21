import AppKit
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "SoundEffects")

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

    struct Option: Hashable {
        let identifier: String
        let displayName: String
    }

    enum ImportError: LocalizedError {
        case fileTooLarge
        case soundTooLong
        case unreadableAudio
        case invalidSelection

        var errorDescription: String? {
            switch self {
            case .fileTooLarge:
                return "Choose an audio file smaller than 25 MB."
            case .soundTooLong:
                return "Choose a sound effect that is 30 seconds or shorter."
            case .unreadableAudio:
                return "Yaprflow couldn't read that audio file. Try WAV, AIFF, M4A, MP3, or CAF."
            case .invalidSelection:
                return "That imported sound is no longer available."
            }
        }
    }

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

    private nonisolated static let bundledExtensions: Set<String> = [
        "aac", "aif", "aiff", "caf", "m4a", "mp3", "wav",
    ]
    private nonisolated static let importedPrefix = "imported:"
    private nonisolated static let maximumImportedBytes: UInt64 = 25 * 1_024 * 1_024
    private nonisolated static let maximumImportedDuration: TimeInterval = 30

    /// Directories that may hold app-bundled chimes. Xcode's synchronized
    /// folder groups can copy `yaprflow/Sounds/*` either flat into Resources
    /// or as a `Sounds/` folder reference depending on project settings —
    /// scan both so a project-format change can't silently orphan the sounds.
    private nonisolated static func bundledSoundDirs() -> [URL] {
        guard let resources = Bundle.main.resourceURL else { return [] }
        return [resources.appendingPathComponent("Sounds", isDirectory: true), resources]
    }

    /// Names of custom chimes shipped inside the app bundle (synthesized
    /// Yapr set + imported ones). Shown as their own section in the picker.
    nonisolated static func bundledSounds() -> [String] {
        var names: Set<String> = []
        for dir in bundledSoundDirs() {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil
            ) else { continue }
            for url in entries where bundledExtensions.contains(url.pathExtension.lowercased()) {
                names.insert(url.deletingPathExtension().lastPathComponent)
            }
        }
        return names.sorted()
    }

    /// User-selected sounds are copied into the app container. That makes
    /// playback reliable across launches without retaining a security-scoped
    /// bookmark to the person's original file.
    nonisolated static func importedSounds() -> [Option] {
        guard let directory = try? importedSoundDirectory(create: false),
              let entries = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              )
        else {
            return []
        }

        return entries
            .filter {
                bundledExtensions.contains($0.pathExtension.lowercased())
                    && !$0.hasDirectoryPath
            }
            .map {
                Option(
                    identifier: importedPrefix + $0.lastPathComponent,
                    displayName: $0.deletingPathExtension().lastPathComponent
                )
            }
            .sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
    }

    nonisolated static func importSound(from source: URL) throws -> Option {
        guard bundledExtensions.contains(source.pathExtension.lowercased()) else {
            throw ImportError.unreadableAudio
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        if let size = attributes[.size] as? NSNumber,
           size.uint64Value > maximumImportedBytes {
            throw ImportError.fileTooLarge
        }

        guard let sound = NSSound(contentsOf: source, byReference: false) else {
            throw ImportError.unreadableAudio
        }
        if sound.duration.isFinite && sound.duration > maximumImportedDuration {
            throw ImportError.soundTooLong
        }

        let directory = try importedSoundDirectory(create: true)
        let destination = uniqueDestination(for: source, in: directory)
        try FileManager.default.copyItem(at: source, to: destination)

        guard NSSound(contentsOf: destination, byReference: true) != nil else {
            try? FileManager.default.removeItem(at: destination)
            throw ImportError.unreadableAudio
        }

        return Option(
            identifier: importedPrefix + destination.lastPathComponent,
            displayName: destination.deletingPathExtension().lastPathComponent
        )
    }

    nonisolated static func removeImportedSound(identifier: String) throws {
        guard let url = importedSoundURL(for: identifier),
              FileManager.default.fileExists(atPath: url.path)
        else {
            throw ImportError.invalidSelection
        }
        try FileManager.default.removeItem(at: url)
    }

    nonisolated static func displayName(for identifier: String) -> String {
        guard identifier.hasPrefix(importedPrefix) else { return identifier }
        let filename = String(identifier.dropFirst(importedPrefix.count))
        return URL(fileURLWithPath: filename)
            .deletingPathExtension()
            .lastPathComponent
    }

    nonisolated static func resolvedSelection(_ stored: String?, fallback: String) -> String {
        guard let stored, !stored.isEmpty else { return fallback }
        if stored.hasPrefix(importedPrefix) {
            return importedSoundURL(for: stored) != nil ? stored : fallback
        }
        return stored
    }

    private nonisolated static func bundledSoundURL(named name: String) -> URL? {
        let fm = FileManager.default
        for dir in bundledSoundDirs() {
            for ext in bundledExtensions {
                let url = dir.appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: url.path) { return url }
            }
        }
        return nil
    }

    private nonisolated static func importedSoundDirectory(create: Bool) throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport
            .appendingPathComponent("yaprflow", isDirectory: true)
            .appendingPathComponent("Sounds", isDirectory: true)
        if create {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }
        return directory
    }

    private nonisolated static func importedSoundURL(for identifier: String) -> URL? {
        guard identifier.hasPrefix(importedPrefix) else { return nil }
        let filename = String(identifier.dropFirst(importedPrefix.count))
        guard !filename.isEmpty,
              URL(fileURLWithPath: filename).lastPathComponent == filename,
              let directory = try? importedSoundDirectory(create: false)
        else {
            return nil
        }
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        guard url.deletingLastPathComponent().standardizedFileURL
            == directory.standardizedFileURL
        else {
            return nil
        }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private nonisolated static func uniqueDestination(for source: URL, in directory: URL) -> URL {
        let originalBase = source.deletingPathExtension().lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let base = originalBase.isEmpty ? "Custom Sound" : originalBase
        let ext = source.pathExtension.lowercased()
        let existingDisplayNames = Set(
            importedSounds().map { $0.displayName.lowercased() }
        )

        var suffix = 1
        while true {
            let name = suffix == 1 ? base : "\(base) \(suffix)"
            let candidate = directory
                .appendingPathComponent(name, isDirectory: false)
                .appendingPathExtension(ext)
            if !existingDisplayNames.contains(name.lowercased()),
               !FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            suffix += 1
        }
    }

    /// Strong reference to the currently-playing file-based sound. Unlike
    /// `NSSound(named:)` (system-cached), a `contentsOf:` sound stops if its
    /// last reference dies before playback finishes.
    private static var activeSound: NSSound?

    /// Picker auditions have their own lifecycle: starting another preview
    /// replaces the previous one, and closing the picker stops it. This avoids
    /// a stack of overlapping chimes when the pointer moves down the menu.
    private static var previewSound: NSSound?

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
        previewSound?.stop()
        previewSound = nil

        guard let sound = resolvedSound(named: name, isolatedSystemSound: true) else {
            log.error("Sound \(name, privacy: .public) not found (bundle or system)")
            return
        }
        sound.volume = currentVolume
        previewSound = sound
        sound.play()
    }

    static func stopPreview() {
        previewSound?.stop()
        previewSound = nil
    }

    private static func playByName(_ name: String) {
        guard let sound = resolvedSound(named: name, isolatedSystemSound: false) else {
            log.error("Sound \(name, privacy: .public) not found (bundle or system)")
            return
        }
        activeSound = sound
        sound.volume = currentVolume
        sound.play()
    }

    private static var currentVolume: Float {
        min(max(AppState.shared.soundEffectsVolume, 0), 1)
    }

    private static func resolvedSound(
        named name: String,
        isolatedSystemSound: Bool
    ) -> NSSound? {
        if let url = importedSoundURL(for: name),
           let sound = NSSound(contentsOf: url, byReference: true) {
            return sound
        }

        // Bundled custom chimes win over same-named system sounds.
        if let url = bundledSoundURL(named: name),
           let sound = NSSound(contentsOf: url, byReference: true) {
            return sound
        }

        // NSSound(named:) may return the same cached instance repeatedly.
        // Picker previews need an independent player so stopping an audition
        // cannot cut off a real start/stop confirmation sound.
        if isolatedSystemSound {
            let url = URL(fileURLWithPath: "/System/Library/Sounds")
                .appendingPathComponent(name)
                .appendingPathExtension("aiff")
            if let sound = NSSound(contentsOf: url, byReference: true) {
                return sound
            }
        }

        return NSSound(named: NSSound.Name(name))
    }
}
