import AppKit
import SwiftUI

/// The SwiftUI body of the clipboard history window. Lives inside an
/// `NSHostingController` hosted by `ClipboardHistoryWindowController`.
///
/// **Two activation modes:**
///   - **Click** (or **Enter** on the selected row): copy + auto-paste into
///     the app that was frontmost when the window opened.
///   - **⌥-click** (or **⌥ Enter**): copy only — no auto-paste. Use when you
///     want the text on the clipboard but plan to paste it elsewhere or
///     manipulate it first.
///
/// **Keyboard:** `↑` `↓` navigate rows; `Esc` dismisses; right-click brings up
/// pin / delete actions per row. Hover reveals a copy icon at the trailing
/// edge for copy-only activation.
///
/// Modifier detection is via `NSEvent.modifierFlags` at the moment the gesture
/// fires — SwiftUI doesn't expose modifier state on `.onTapGesture` directly,
/// and reading the class property is reliable on AppKit-backed platforms.
struct ClipboardHistoryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var searchText: String = ""
    @State private var selection: ClipboardHistoryEntry.ID?
    @State private var timeFilter: TimeFilter = .all
    @State private var pinnedOnly: Bool = false
    @State private var collapsedSections: Set<String> = []
    @State private var learningEntryID: ClipboardHistoryEntry.ID?
    @State private var correctedDraft: String = ""
    @State private var learningError: String?
    @State private var learningConfirmation: String?
    @FocusState private var searchFocused: Bool

    enum TimeFilter: String, CaseIterable, Identifiable {
        case all = "All"
        case today = "Today"
        case week = "Week"
        case month = "Month"
        var id: String { rawValue }
    }

    private var isFiltering: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || timeFilter != .all
            || pinnedOnly
    }

    /// Provided by the window controller. `copyOnly` is true when the user
    /// held ⌥ during the activation; the controller then skips the auto-paste
    /// step and just leaves the text on the clipboard.
    let onActivate: (ClipboardHistoryEntry, Bool) -> Void
    let onClose: () -> Void
    /// Ask the window controller to present the destructive-clear confirmation
    /// sheet. Handled there (not here) so the confirmation is a native NSAlert
    /// attached to the panel window — and so the panel's click-away auto-close
    /// can be suppressed while the sheet is up.
    let onRequestClear: () -> Void

    private static func optionDown() -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private var filteredEntries: [ClipboardHistoryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        return store.entries.filter { entry in
            if pinnedOnly && !entry.isPinned { return false }
            if !q.isEmpty && !entry.text.lowercased().contains(q) { return false }
            switch timeFilter {
            case .all:
                return true
            case .today:
                return cal.isDateInToday(entry.timestamp)
            case .week, .month:
                let limit = (timeFilter == .week) ? 7 : 30
                let days = cal.dateComponents(
                    [.day], from: cal.startOfDay(for: entry.timestamp), to: startOfToday
                ).day ?? Int.max
                return days <= limit
            }
        }
    }

    /// Date-bucketed grouping of the filtered entries. Pinned float into their
    /// own section at the top; everything else is bucketed by recency
    /// (Today / Yesterday / Previous 7 / Previous 30) and then by month.
    private var sections: [HistorySection] {
        HistorySection.group(filteredEntries)
    }

    /// Flattened order of the rows actually on screen — collapsed sections
    /// contribute nothing, so keyboard nav skips their hidden rows.
    private var orderedEntries: [ClipboardHistoryEntry] {
        sections
            .filter { !collapsedSections.contains($0.id) }
            .flatMap { $0.entries }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            filterBar
            Divider().opacity(0.3)
            content
            if !store.entries.isEmpty {
                Divider().opacity(0.4)
                footer
            }
        }
        .background(.ultraThinMaterial)
        .onAppear {
            searchFocused = true
            if selection == nil {
                selection = orderedEntries.first?.id
            }
        }
        .onChange(of: searchText) {
            // Keep selection valid when the filter changes.
            if !orderedEntries.contains(where: { $0.id == selection }) {
                selection = orderedEntries.first?.id
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .font(.system(size: 13, weight: .medium))
            TextField("Search history", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($searchFocused)
                .onSubmit { activateSelection(copyOnly: Self.optionDown()) }
                .onKeyPress(.downArrow) {
                    moveSelection(by: +1)
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    moveSelection(by: -1)
                    return .handled
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            Text("\(store.entries.count)")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if filteredEntries.isEmpty {
            emptyState
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                        ForEach(sections) { section in
                            Section {
                                if !collapsedSections.contains(section.id) {
                                    ForEach(section.entries) { entry in
                                        HistoryRow(
                                            entry: entry,
                                            isSelected: selection == entry.id,
                                            onActivate: { copyOnly in onActivate(entry, copyOnly) },
                                            onTogglePin: { store.togglePin(entry) },
                                            onDelete: {
                                                if learningEntryID == entry.id { cancelLearning() }
                                                store.delete(entry)
                                            },
                                            onLearn: { beginLearning(entry) }
                                        )
                                        .id(entry.id)
                                        if learningEntryID == entry.id {
                                            HistoryCorrectionEditor(
                                                original: entry.text,
                                                corrected: $correctedDraft,
                                                errorMessage: learningError,
                                                confirmation: learningConfirmation,
                                                onSave: { saveLearning(from: entry) },
                                                onCancel: cancelLearning
                                            )
                                        }
                                    }
                                }
                            } header: {
                                sectionHeader(section)
                            }
                        }
                    }
                }
                .onAppear {
                    // LazyVStack realizes rows on demand, so SwiftUI's initial
                    // scroll position is unpredictable — it sometimes lands at
                    // the bottom of the realized content. Force the most-recent
                    // entry to the top of the viewport on each open.
                    if let firstId = orderedEntries.first?.id {
                        DispatchQueue.main.async {
                            proxy.scrollTo(firstId, anchor: .top)
                        }
                    }
                }
                .onChange(of: selection) { _, newValue in
                    if let id = newValue {
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
    }

    private func sectionHeader(_ section: HistorySection) -> some View {
        let collapsed = collapsedSections.contains(section.id)
        return Button {
            toggleCollapse(section.id)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                if section.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.orange)
                }
                Text(section.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("\(section.entries.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(.ultraThinMaterial)
        }
        .buttonStyle(.plain)
    }

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(TimeFilter.allCases) { filter in
                FilterChip(
                    title: filter.rawValue,
                    isOn: timeFilter == filter
                ) {
                    timeFilter = filter
                    revalidateSelection()
                }
            }
            Divider().frame(height: 14).opacity(0.5)
            FilterChip(
                title: "Pinned",
                systemImage: "pin.fill",
                isOn: pinnedOnly
            ) {
                pinnedOnly.toggle()
                revalidateSelection()
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            HintChip(key: "⏎", label: "Paste")
            HintChip(key: "⌥⏎", label: "Copy only")
            HintChip(key: "esc", label: "Close")
            Spacer()
            Button(action: onRequestClear) {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                    Text("Clear")
                }
                .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Delete dictation history")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.03))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: isFiltering ? "line.3.horizontal.decrease.circle" : "tray")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(isFiltering ? "No matches" : "No history yet")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            Text(isFiltering
                 ? "No transcripts match the current search and filters."
                 : "Dictated transcripts will appear here automatically.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Keyboard helpers

    private func toggleCollapse(_ id: String) {
        if collapsedSections.contains(id) {
            collapsedSections.remove(id)
        } else {
            collapsedSections.insert(id)
        }
        revalidateSelection()
    }

    /// Keep the selection pointing at a visible row after a filter/collapse
    /// change; fall back to the first visible row.
    private func revalidateSelection() {
        if !orderedEntries.contains(where: { $0.id == selection }) {
            selection = orderedEntries.first?.id
        }
    }

    private func moveSelection(by offset: Int) {
        let items = orderedEntries
        guard !items.isEmpty else { return }
        let currentIdx = items.firstIndex(where: { $0.id == selection }) ?? -1
        let nextIdx = max(0, min(items.count - 1, currentIdx + offset))
        selection = items[nextIdx].id
    }

    private func activateSelection(copyOnly: Bool) {
        guard learningEntryID == nil else { return }
        guard let id = selection,
              let entry = orderedEntries.first(where: { $0.id == id })
        else { return }
        onActivate(entry, copyOnly)
    }

    private func beginLearning(_ entry: ClipboardHistoryEntry) {
        selection = entry.id
        learningEntryID = entry.id
        correctedDraft = entry.text
        learningError = nil
        learningConfirmation = nil
    }

    private func cancelLearning() {
        learningEntryID = nil
        correctedDraft = ""
        learningError = nil
        learningConfirmation = nil
    }

    private func saveLearning(from entry: ClipboardHistoryEntry) {
        do {
            let candidate = try CorrectionInference.infer(
                original: entry.text,
                corrected: correctedDraft
            )
            _ = try VocabularyStore.shared.learn(
                misheard: candidate.misheard,
                replacement: candidate.replacement,
                source: .history
            )
            learningError = nil
            learningConfirmation = "Learned \(candidate.misheard) -> \(candidate.replacement)"
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1.4))
                guard learningEntryID == entry.id else { return }
                cancelLearning()
            }
        } catch {
            learningConfirmation = nil
            learningError = error.localizedDescription
        }
    }
}

/// A titled group of history entries — Pinned, or a recency/month bucket.
struct HistorySection: Identifiable {
    let id: String
    let title: String
    let isPinned: Bool
    let entries: [ClipboardHistoryEntry]

    private static let monthFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    /// Bucket entries: a "Pinned" section first (any pinned entries, newest
    /// first), then unpinned grouped by recency and finally by month. Empty
    /// buckets are omitted so the panel never shows a header with no rows.
    static func group(_ entries: [ClipboardHistoryEntry]) -> [HistorySection] {
        let cal = Calendar.current
        let startOfToday = cal.startOfDay(for: Date())
        var result: [HistorySection] = []

        let pinned = entries.filter { $0.isPinned }.sorted { $0.timestamp > $1.timestamp }
        if !pinned.isEmpty {
            result.append(.init(id: "pinned", title: "Pinned", isPinned: true, entries: pinned))
        }

        let unpinned = entries.filter { !$0.isPinned }.sorted { $0.timestamp > $1.timestamp }

        var today: [ClipboardHistoryEntry] = []
        var yesterday: [ClipboardHistoryEntry] = []
        var prev7: [ClipboardHistoryEntry] = []
        var prev30: [ClipboardHistoryEntry] = []
        var months: [(key: String, entries: [ClipboardHistoryEntry])] = []

        for e in unpinned {
            if cal.isDateInToday(e.timestamp) {
                today.append(e)
            } else if cal.isDateInYesterday(e.timestamp) {
                yesterday.append(e)
            } else {
                let days = cal.dateComponents(
                    [.day], from: cal.startOfDay(for: e.timestamp), to: startOfToday
                ).day ?? Int.max
                if days <= 7 {
                    prev7.append(e)
                } else if days <= 30 {
                    prev30.append(e)
                } else {
                    let key = monthFormatter.string(from: e.timestamp)
                    if let idx = months.firstIndex(where: { $0.key == key }) {
                        months[idx].entries.append(e)
                    } else {
                        months.append((key, [e]))
                    }
                }
            }
        }

        func add(_ id: String, _ title: String, _ bucket: [ClipboardHistoryEntry]) {
            guard !bucket.isEmpty else { return }
            result.append(.init(id: id, title: title, isPinned: false, entries: bucket))
        }
        add("today", "Today", today)
        add("yesterday", "Yesterday", yesterday)
        add("prev7", "Previous 7 Days", prev7)
        add("prev30", "Previous 30 Days", prev30)
        for m in months {
            result.append(.init(id: m.key, title: m.key, isPinned: false, entries: m.entries))
        }
        return result
    }
}

/// Small pill toggle used in the history filter bar.
private struct FilterChip: View {
    let title: String
    var systemImage: String? = nil
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 8))
                }
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .foregroundStyle(isOn ? Color.white : Color.secondary)
            .background(
                Capsule().fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            )
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryRow: View {
    let entry: ClipboardHistoryEntry
    let isSelected: Bool
    /// `copyOnly == false` -> paste into previous app; `true` -> just copy.
    let onActivate: (Bool) -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void
    let onLearn: () -> Void

    @State private var isHovered = false

    private static func optionDown() -> Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            // Pin gutter — always reserved so rows don't shift when pinning.
            Image(systemName: entry.isPinned ? "pin.fill" : "pin")
                .font(.system(size: 11))
                .foregroundStyle(entry.isPinned ? .orange : (isHovered ? .secondary : .clear))
                .frame(width: 14)
                .onTapGesture { onTogglePin() }

            VStack(alignment: .leading, spacing: 4) {
                Text(entry.preview)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(entry.relativeTimestamp)  ·  \(entry.wordCount) word\(entry.wordCount == 1 ? "" : "s")")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { onActivate(Self.optionDown()) }

            // Trailing actions appear on hover. Keep the gutter even when
            // unhovered so widths don't jitter.
            HStack(spacing: 6) {
                if isHovered {
                    Button { onActivate(true) } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy")
                }
            }
            .frame(width: 20)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(rowBackground)
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 14).opacity(0.5)
        }
        .contextMenu {
            Button("Paste into Previous App") { onActivate(false) }
            Button("Copy") { onActivate(true) }
            Button("Correct & Learn…", action: onLearn)
            Divider()
            Button(entry.isPinned ? "Unpin" : "Pin") { onTogglePin() }
            Button("Delete", role: .destructive) { onDelete() }
        }
    }

    private var rowBackground: some View {
        Group {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(0.18))
                    .padding(.horizontal, 6)
            } else if isHovered {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                    .padding(.horizontal, 6)
            } else {
                Color.clear
            }
        }
    }
}

private struct HistoryCorrectionEditor: View {
    let original: String
    @Binding var corrected: String
    let errorMessage: String?
    let confirmation: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Correct one name or short phrase", systemImage: "character.cursor.ibeam")
                    .font(.system(size: 11.5, weight: .semibold))
                Spacer()
                Text("Original stays in History")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
            }
            TextEditor(text: $corrected)
                .font(.system(size: 12.5))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 64, maxHeight: 96)
                .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 6))
                .focused($editorFocused)
            HStack {
                if let confirmation {
                    Label(confirmation, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.green)
                } else if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                } else {
                    Text("Only the changed phrase becomes a reusable rule.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Learn", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(corrected == original || corrected.isEmpty)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
        .background(Color.accentColor.opacity(0.07))
        .onAppear { editorFocused = true }
    }
}

/// Footer key-hint chip — small inline glyph + label pair used to surface
/// the click/keyboard model so users don't have to read docs to find ⌥Enter.
private struct HintChip: View {
    let key: String
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 3))
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}
