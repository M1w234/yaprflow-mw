import Combine
import Foundation
import OSLog

private let log = Logger(subsystem: "com.tmoreton.yaprflow", category: "ClipboardHistory")

/// One row in the clipboard history. `text` is the final transcript that
/// landed on the clipboard (grammar-corrected if grammar mode was on; raw
/// otherwise). Pinned entries survive the FIFO cap and sort to the top.
struct ClipboardHistoryEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let text: String
    let timestamp: Date
    var isPinned: Bool

    init(text: String, timestamp: Date = Date(), isPinned: Bool = false) {
        self.id = UUID()
        self.text = text
        self.timestamp = timestamp
        self.isPinned = isPinned
    }

    /// First non-empty line, trimmed and capped — used by the row label.
    var preview: String {
        let lines = text.split(whereSeparator: \.isNewline)
        let firstLine = lines.first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        let basis = firstLine.isEmpty ? text : firstLine
        if basis.count <= 120 { return basis }
        return String(basis.prefix(120)) + "…"
    }

    /// "Just now", "5m ago", "Yesterday at 3:14 PM", "May 12 at 10:31 AM".
    /// Tuned to be readable at a glance without crowding the row.
    var relativeTimestamp: String {
        let now = Date()
        let interval = now.timeIntervalSince(timestamp)
        if interval < 60 { return "Just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }

        let cal = Calendar.current
        if cal.isDateInToday(timestamp) {
            return "\(Int(interval / 3600))h ago"
        }
        let timeFmt = DateFormatter()
        timeFmt.timeStyle = .short
        if cal.isDateInYesterday(timestamp) {
            return "Yesterday at \(timeFmt.string(from: timestamp))"
        }
        let dateFmt = DateFormatter()
        dateFmt.dateFormat = "MMM d"
        return "\(dateFmt.string(from: timestamp)) at \(timeFmt.string(from: timestamp))"
    }
}

/// Persistent store of finalized dictation transcripts. Auto-captures every
/// non-empty value pushed to `AppState.lastTranscript` via Combine, so
/// `TranscriptionController` and the grammar-correction Task don't need to
/// know about history. Stored as JSON in the app's Application Support
/// container; pinned entries survive the FIFO cap (`maxEntries`).
@MainActor
final class ClipboardHistoryStore: ObservableObject {
    static let shared = ClipboardHistoryStore()

    @Published private(set) var entries: [ClipboardHistoryEntry] = []

    /// Soft cap. Pinned entries are kept beyond this; unpinned overflow is
    /// evicted oldest-first. 500 is enough for ~weeks of heavy dictation
    /// while keeping the JSON small (~MB at the high end).
    private let maxEntries = 500

    private let storeURL: URL
    private var lastCapturedText: String = ""
    private var transcriptObserver: AnyCancellable?
    private var saveDebounce: DispatchWorkItem?

    private init() {
        let fm = FileManager.default
        // Sandboxed apps get their own Application Support container
        // (`~/Library/Containers/<bundle-id>/Data/Library/Application Support/`),
        // so this path is unique per-user, per-install. No fallback needed —
        // if the URL lookup fails we have bigger problems.
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("yaprflow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.storeURL = dir.appendingPathComponent("history.json")

        load()

        // Capture every finalized transcript. AppState publishes
        // `lastTranscript` on the main actor; the corresponding Combine
        // publisher fires for all three finalization paths in
        // TranscriptionController (regular mode, grammar success, grammar
        // failure fallback). Filtering out empty + consecutive-duplicate
        // values keeps the history clean if a session aborts.
        transcriptObserver = AppState.shared.$lastTranscript
            .receive(on: RunLoop.main)
            .sink { [weak self] text in
                self?.captureIfNew(text)
            }
    }

    private func captureIfNew(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != lastCapturedText else { return }
        lastCapturedText = trimmed
        append(text: trimmed)
    }

    private func append(text: String) {
        let entry = ClipboardHistoryEntry(text: text)
        entries.insert(entry, at: 0)
        evictIfNeeded()
        scheduleSave()
    }

    func togglePin(_ entry: ClipboardHistoryEntry) {
        guard let idx = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        entries[idx].isPinned.toggle()
        sortInPlace()
        scheduleSave()
    }

    func delete(_ entry: ClipboardHistoryEntry) {
        entries.removeAll { $0.id == entry.id }
        scheduleSave()
    }

    /// Clear unpinned entries only. Pinned items survive — users typically
    /// pin to keep something around long-term and would not want a "clear"
    /// action to wipe their saved snippets.
    func clearUnpinned() {
        entries.removeAll { !$0.isPinned }
        scheduleSave()
    }

    /// Pinned entries sort first, then unpinned by timestamp descending.
    /// Called after pin/unpin so the row order updates immediately.
    private func sortInPlace() {
        entries.sort { lhs, rhs in
            if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private func evictIfNeeded() {
        guard entries.count > maxEntries else { return }
        let pinned = entries.filter { $0.isPinned }
        let unpinned = entries.filter { !$0.isPinned }
        let slack = max(0, maxEntries - pinned.count)
        entries = pinned + Array(unpinned.prefix(slack))
        sortInPlace()
    }

    // MARK: - Persistence

    /// Coalesce rapid writes (e.g. burst of dictation sessions) into one
    /// disk write so we're not hitting the file system every transcript.
    private func scheduleSave() {
        saveDebounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.saveNow()
        }
        saveDebounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(300), execute: work)
    }

    private func saveNow() {
        do {
            let data = try JSONEncoder().encode(entries)
            try data.write(to: storeURL, options: [.atomic])
        } catch {
            log.error("Failed to save history: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL) else { return }
        guard let decoded = try? JSONDecoder().decode([ClipboardHistoryEntry].self, from: data) else {
            log.error("History file exists but failed to decode — starting fresh")
            return
        }
        entries = decoded
        sortInPlace()
        lastCapturedText = entries.first(where: { !$0.isPinned })?.text ?? ""
    }
}
