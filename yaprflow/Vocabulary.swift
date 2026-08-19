import AppKit
import Combine
import Foundation
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "Vocabulary")

enum VocabularyEntrySource: String, Codable, CaseIterable {
    case starter
    case manual
    case history
    case automatic

    var displayName: String {
        switch self {
        case .starter: return "Built in"
        case .manual: return "Added"
        case .history: return "From History"
        case .automatic: return "Learned"
        }
    }
}

/// One dictionary entry: the correct spelling plus the phrases the ASR keeps
/// mis-hearing it as ("yaprflow" <- "yapper flow", "yabber flow").
struct VocabularyEntry: Codable, Identifiable, Hashable {
    var id: UUID
    var term: String
    var misheard: [String]
    var source: VocabularyEntrySource
    var isEnabled: Bool
    var createdAt: Date

    init(
        id: UUID = UUID(),
        term: String,
        misheard: [String] = [],
        source: VocabularyEntrySource = .manual,
        isEnabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.term = term
        self.misheard = misheard
        self.source = source
        self.isEnabled = isEnabled
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, term, misheard, source, isEnabled, createdAt
    }

    /// Backward-compatible with the original two-field vocabulary.json.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        term = try container.decode(String.self, forKey: .term)
        misheard = try container.decodeIfPresent([String].self, forKey: .misheard) ?? []
        source = try container.decodeIfPresent(VocabularyEntrySource.self, forKey: .source) ?? .manual
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }
}

private struct VocabularyFile: Codable {
    var entries: [VocabularyEntry]
}

/// Persistent personal vocabulary and deterministic correction rules.
/// Exact mis-hearings are replaced before Light/Polish cleanup.
@MainActor
final class VocabularyStore: ObservableObject {
    static let shared = VocabularyStore()

    @Published private(set) var entries: [VocabularyEntry] = []

    private let fileURL: URL
    private var loadedModificationDate: Date?
    private var compiled: [(NSRegularExpression, String)] = []

    private convenience init() {
        self.init(fileURL: nil)
    }

    /// An injectable file location keeps migration and persistence behavior
    /// testable without touching the user's real Application Support data.
    init(fileURL customFileURL: URL?) {
        let fm = FileManager.default
        let fileURL: URL
        if let customFileURL {
            fileURL = customFileURL
        } else {
            let appSupport = (try? fm.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
            fileURL = appSupport
                .appendingPathComponent("yaprflow", isDirectory: true)
                .appendingPathComponent("vocabulary.json")
        }
        let dir = fileURL.deletingLastPathComponent()
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = fileURL

        if !fm.fileExists(atPath: fileURL.path) {
            seedDefaultFile()
        }
        reloadIfChanged()
    }

    func applyReplacements(to text: String) -> String {
        var result = text
        for (regex, term) in compiled {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: term)
            )
        }
        for (regex, term) in Self.builtinCasing {
            let range = NSRange(result.startIndex..., in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: NSRegularExpression.escapedTemplate(for: term)
            )
        }
        return result
    }

    private static let builtinCasing: [(NSRegularExpression, String)] = {
        let map: [(String, String)] = [
            ("github", "GitHub"), ("ios", "iOS"), ("macos", "macOS"),
            ("iphone", "iPhone"), ("ipad", "iPad"), ("macbook", "MacBook"),
            ("imessage", "iMessage"), ("imessages", "iMessages"),
            ("xcode", "Xcode"), ("javascript", "JavaScript"),
            ("typescript", "TypeScript"), ("json", "JSON"), ("url", "URL"),
            ("api", "API"), ("css", "CSS"), ("html", "HTML"), ("sql", "SQL"),
            ("vs code", "VS Code"), ("mlx", "MLX"),
        ]
        return map.compactMap { phrase, term in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, term)
        }
    }()

    func reloadIfChanged() {
        let mtime = (try? FileManager.default.attributesOfItem(
            atPath: fileURL.path
        ))?[.modificationDate] as? Date
        guard mtime != loadedModificationDate else { return }

        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(VocabularyFile.self, from: data) else {
            log.error("vocabulary.json unreadable or malformed -- keeping previous entries")
            return
        }
        loadedModificationDate = mtime
        entries = file.entries
        compile()
        log.info("Vocabulary loaded: \(self.entries.count, privacy: .public) terms")
    }

    /// Advanced escape hatch; the normal menu opens the native vocabulary UI.
    func openInEditor() {
        NSWorkspace.shared.open(fileURL)
    }

    @discardableResult
    func learn(
        misheard rawMisheard: String,
        replacement rawReplacement: String,
        source: VocabularyEntrySource
    ) throws -> VocabularyEntry {
        try learn(
            misheard: [rawMisheard],
            replacement: rawReplacement,
            source: source
        )
    }

    /// Add every heard variant as one atomic correction. Either all aliases
    /// persist, or the in-memory list rolls back to its previous state.
    @discardableResult
    func learn(
        misheard rawMisheard: [String],
        replacement rawReplacement: String,
        source: VocabularyEntrySource
    ) throws -> VocabularyEntry {
        let misheard = Self.uniquePhrases(rawMisheard)
        let replacement = Self.normalizedPhrase(rawReplacement)
        guard !misheard.isEmpty, !replacement.isEmpty else {
            throw VocabularyError.emptyValue
        }
        guard misheard.allSatisfy({ $0.count <= 120 }), replacement.count <= 120 else {
            throw VocabularyError.valueTooLong
        }
        guard misheard.allSatisfy({ $0 != replacement }) else {
            throw VocabularyError.noChange
        }

        for phrase in misheard {
            if let conflict = entries.first(where: { entry in
                entry.misheard.contains(where: {
                    $0.caseInsensitiveCompare(phrase) == .orderedSame
                }) && entry.term.caseInsensitiveCompare(replacement) != .orderedSame
            }) {
                throw VocabularyError.conflictingRule(
                    misheard: phrase,
                    existingReplacement: conflict.term
                )
            }
        }

        let previousEntries = entries
        if let index = entries.firstIndex(where: {
            $0.term.caseInsensitiveCompare(replacement) == .orderedSame
        }) {
            for phrase in misheard where !entries[index].misheard.contains(where: {
                $0.caseInsensitiveCompare(phrase) == .orderedSame
            }) {
                entries[index].misheard.append(phrase)
            }
            entries[index].term = replacement
            entries[index].isEnabled = true
            if entries[index].source == .automatic && source != .automatic {
                entries[index].source = source
            }
            try persistAndCompile(previousEntries: previousEntries)
            return entries[index]
        }

        let entry = VocabularyEntry(
            term: replacement,
            misheard: misheard,
            source: source
        )
        entries.insert(entry, at: 0)
        try persistAndCompile(previousEntries: previousEntries)
        return entry
    }

    func update(
        id: UUID,
        term rawTerm: String,
        misheard rawMisheard: [String],
        isEnabled: Bool
    ) throws {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let term = Self.normalizedPhrase(rawTerm)
        let misheard = Self.uniquePhrases(rawMisheard)
        guard !term.isEmpty else { throw VocabularyError.emptyValue }
        guard term.count <= 120, misheard.allSatisfy({ $0.count <= 120 }) else {
            throw VocabularyError.valueTooLong
        }

        for phrase in misheard {
            if let conflict = entries.first(where: { entry in
                entry.id != id
                    && entry.misheard.contains(where: {
                        $0.caseInsensitiveCompare(phrase) == .orderedSame
                    })
                    && entry.term.caseInsensitiveCompare(term) != .orderedSame
            }) {
                throw VocabularyError.conflictingRule(
                    misheard: phrase,
                    existingReplacement: conflict.term
                )
            }
        }

        let previousEntries = entries
        entries[index].term = term
        entries[index].misheard = misheard
        entries[index].isEnabled = isEnabled
        try persistAndCompile(previousEntries: previousEntries)
    }

    func setEnabled(_ enabled: Bool, for id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        let previousEntries = entries
        entries[index].isEnabled = enabled
        do {
            try persistAndCompile(previousEntries: previousEntries)
        } catch {
            log.error("Failed to change vocabulary state: \(error.localizedDescription, privacy: .public)")
        }
    }

    func delete(_ entry: VocabularyEntry) {
        let previousEntries = entries
        entries.removeAll { $0.id == entry.id }
        do {
            try persistAndCompile(previousEntries: previousEntries)
        } catch {
            log.error("Failed to delete vocabulary entry: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func compile() {
        var pairs: [(String, String)] = []
        for entry in entries where entry.isEnabled {
            for phrase in entry.misheard where !phrase.isEmpty {
                pairs.append((phrase, entry.term))
            }
        }
        pairs.sort { $0.0.count > $1.0.count }
        compiled = pairs.compactMap { phrase, term in
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: phrase) + "\\b"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
                return nil
            }
            return (regex, term)
        }
    }

    private func seedDefaultFile() {
        let seed = VocabularyFile(entries: [
            VocabularyEntry(term: "yaprflow", misheard: ["yapper flow", "yabber flow", "yaper flow", "yapperflow"], source: .starter),
            VocabularyEntry(term: "Wispr Flow", misheard: ["whisper flow", "whisperflow", "wisper flow"], source: .starter),
            VocabularyEntry(term: "Claude Code", misheard: ["cloud code", "clawed code", "clod code", "claude code"], source: .starter),
            VocabularyEntry(term: "Claude desktop", misheard: ["cloud desktop"], source: .starter),
            VocabularyEntry(term: "Claude", misheard: ["claud"], source: .starter),
            VocabularyEntry(term: "Codex", misheard: ["code x", "co-decks", "codeex", "codex"], source: .starter),
            VocabularyEntry(term: "Fable 5", misheard: ["fable five", "able five"], source: .starter),
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(seed) else { return }
        try? data.write(to: fileURL, options: [.atomic])
        log.info("Seeded vocabulary.json")
    }

    private func persistAndCompile(previousEntries: [VocabularyEntry]) throws {
        let file = VocabularyFile(entries: entries)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(file)
            try data.write(to: fileURL, options: [.atomic])
            loadedModificationDate = (try? FileManager.default.attributesOfItem(
                atPath: fileURL.path
            ))?[.modificationDate] as? Date
            compile()
        } catch {
            entries = previousEntries
            compile()
            log.error("Failed to save vocabulary: \(error.localizedDescription, privacy: .public)")
            throw VocabularyError.persistenceFailed
        }
    }

    private static func normalizedPhrase(_ phrase: String) -> String {
        phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }

    private static func uniquePhrases(_ phrases: [String]) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for raw in phrases {
            let phrase = normalizedPhrase(raw)
            let key = phrase.lowercased()
            guard !phrase.isEmpty, seen.insert(key).inserted else { continue }
            result.append(phrase)
        }
        return result
    }
}

enum VocabularyError: LocalizedError {
    case emptyValue
    case valueTooLong
    case noChange
    case conflictingRule(misheard: String, existingReplacement: String)
    case persistenceFailed

    var errorDescription: String? {
        switch self {
        case .emptyValue:
            return "Enter the preferred spelling and the phrase Yaprflow heard."
        case .valueTooLong:
            return "Keep each word or phrase under 120 characters."
        case .noChange:
            return "The heard phrase and preferred spelling are already the same."
        case .conflictingRule(let misheard, let replacement):
            return "\u{201C}\(misheard)\u{201D} already changes to \u{201C}\(replacement)\u{201D}."
        case .persistenceFailed:
            return "Yaprflow couldn't save that correction. Try again."
        }
    }
}
