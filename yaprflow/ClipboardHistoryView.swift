import AppKit
import SwiftUI

/// The SwiftUI body of the clipboard history window. Lives inside an
/// `NSHostingController` hosted by `ClipboardHistoryWindowController`.
///
/// **Keyboard model:**
///   - `⏎` (Return) on the selected row → copy to pasteboard + dismiss
///   - `↑` / `↓` → navigate rows
///   - `⌘P` → toggle pin
///   - `⌫` (Delete) → remove row
///   - `Esc` → dismiss (handled by the window controller via `cancelOperation`)
///
/// **Mouse model:** click a row to copy + dismiss; hover reveals pin/delete
/// glyphs at the trailing edge. Right-click brings up the same actions plus
/// "Reveal in JSON…" (skipped in v1 — not enough demand yet).
struct ClipboardHistoryView: View {
    @ObservedObject private var store = ClipboardHistoryStore.shared
    @State private var searchText: String = ""
    @State private var selection: ClipboardHistoryEntry.ID?
    @FocusState private var searchFocused: Bool

    /// Provided by the window controller so a row tap can dismiss us.
    let onCopy: (ClipboardHistoryEntry) -> Void
    let onClose: () -> Void

    private var filteredEntries: [ClipboardHistoryEntry] {
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.entries }
        return store.entries.filter { $0.text.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.6)
            content
        }
        .background(.ultraThinMaterial)
        .onAppear {
            searchFocused = true
            if selection == nil {
                selection = filteredEntries.first?.id
            }
        }
        .onChange(of: searchText) {
            // Keep selection valid when the filter changes.
            if !filteredEntries.contains(where: { $0.id == selection }) {
                selection = filteredEntries.first?.id
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
                .onSubmit { activateSelection() }
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
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(filteredEntries) { entry in
                            HistoryRow(
                                entry: entry,
                                isSelected: selection == entry.id,
                                onCopy: { onCopy(entry) },
                                onTogglePin: { store.togglePin(entry) },
                                onDelete: { store.delete(entry) }
                            )
                            .id(entry.id)
                            .onTapGesture { onCopy(entry) }
                            .onHover { hovering in
                                if hovering { selection = entry.id }
                            }
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

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: searchText.isEmpty ? "tray" : "magnifyingglass")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.tertiary)
            Text(searchText.isEmpty ? "No history yet" : "No matches")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.secondary)
            Text(searchText.isEmpty
                 ? "Dictated transcripts will appear here automatically."
                 : "Try a different search.")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    // MARK: - Keyboard helpers

    private func moveSelection(by offset: Int) {
        let items = filteredEntries
        guard !items.isEmpty else { return }
        let currentIdx = items.firstIndex(where: { $0.id == selection }) ?? -1
        let nextIdx = max(0, min(items.count - 1, currentIdx + offset))
        selection = items[nextIdx].id
    }

    private func activateSelection() {
        guard let id = selection,
              let entry = filteredEntries.first(where: { $0.id == id })
        else { return }
        onCopy(entry)
    }
}

private struct HistoryRow: View {
    let entry: ClipboardHistoryEntry
    let isSelected: Bool
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovered = false

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
                Text(entry.relativeTimestamp)
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing actions appear on hover. Keep the gutter even when
            // unhovered so widths don't jitter.
            HStack(spacing: 6) {
                if isHovered {
                    Button { onDelete() } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Delete")
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
            Button("Copy") { onCopy() }
            Button(entry.isPinned ? "Unpin" : "Pin") { onTogglePin() }
            Divider()
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
