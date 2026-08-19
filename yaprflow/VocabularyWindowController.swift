import AppKit
import SwiftUI

@MainActor
final class VocabularyWindowController: NSWindowController, NSWindowDelegate {
    static let shared = VocabularyWindowController()

    private var hostingController: NSHostingController<VocabularyView>?

    private convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 590),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Vocabulary & Corrections"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 560, height: 460)
        window.isReleasedWhenClosed = false

        self.init(window: window)
        window.delegate = self

        let root = VocabularyView(onClose: { [weak self] in self?.close() })
        let hosting = NSHostingController(rootView: root)
        hosting.view.frame = window.contentLayoutRect
        window.contentView = hosting.view
        self.hostingController = hosting
    }

    func show() {
        guard let window else { return }
        VocabularyStore.shared.reloadIfChanged()
        if !window.isVisible { window.center() }
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }
}

struct VocabularyView: View {
    @ObservedObject private var store = VocabularyStore.shared
    @ObservedObject private var state = AppState.shared

    @State private var searchText = ""
    @State private var editingID: UUID?
    @State private var preferredDraft = ""
    @State private var misheardDraft = ""
    @State private var enabledDraft = true
    @State private var formError: String?
    @State private var pendingDeletion: VocabularyEntry?

    let onClose: () -> Void

    private var filteredEntries: [VocabularyEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return store.entries }
        return store.entries.filter { entry in
            entry.term.lowercased().contains(query)
                || entry.misheard.contains(where: { $0.lowercased().contains(query) })
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            learningToggle
            Divider().opacity(0.35)
            if editingID == nil {
                addBar
                Divider().opacity(0.25)
            }
            content
            Divider().opacity(0.4)
            footer
        }
        .background(.ultraThinMaterial)
        .alert(
            "Delete \(pendingDeletion?.term ?? "this correction")?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            presenting: pendingDeletion
        ) { entry in
            Button("Delete", role: .destructive) {
                store.delete(entry)
                pendingDeletion = nil
                if editingID == entry.id { cancelEditing() }
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { entry in
            Text("Future dictations will no longer change its heard phrases to \(entry.term).")
        }
        .onExitCommand {
            if editingID != nil { cancelEditing() } else { onClose() }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Vocabulary & Corrections")
                    .font(.system(size: 17, weight: .semibold))
                Text("Teach names, terms, and recurring mis-hearings.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var learningToggle: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("Learn from corrections")
                    .font(.system(size: 13, weight: .medium))
                Text("After insertion, briefly watch that text and small boundary checks. Compatibility fields may require transiently reading the current composer value; it is not retained. A distinctive correction prompts you before saving.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 16)
            Toggle("", isOn: $state.learnFromCorrections)
                .labelsHidden()
                .toggleStyle(.switch)
                .help("Requires Automatic Insertion and Accessibility permission")
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    private var addBar: some View {
        HStack {
            Text("\(store.entries.count) entr\(store.entries.count == 1 ? "y" : "ies")")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                beginAdding()
            } label: {
                Label("Add Correction", systemImage: "plus")
                    .font(.system(size: 12, weight: .medium))
            }
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if store.entries.isEmpty && editingID == nil {
            emptyState(
                title: "No corrections yet",
                message: "Add a preferred name and what Yaprflow usually hears instead.",
                actionTitle: "Add Correction",
                action: beginAdding
            )
        } else if filteredEntries.isEmpty && editingID == nil {
            emptyState(
                title: "No matches",
                message: "Try a different name or heard phrase.",
                actionTitle: "Clear Search",
                action: { searchText = "" }
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if editingID == VocabularyEditor.newEntryID {
                        editor
                        Divider().padding(.leading, 18).opacity(0.45)
                    }
                    ForEach(filteredEntries) { entry in
                        VocabularyRow(
                            entry: entry,
                            onToggle: { store.setEnabled($0, for: entry.id) },
                            onEdit: { beginEditing(entry) },
                            onDelete: { pendingDeletion = entry }
                        )
                        if editingID == entry.id { editor }
                        Divider().padding(.leading, 18).opacity(0.35)
                    }
                }
            }
        }
    }

    private func emptyState(
        title: String,
        message: String,
        actionTitle: String,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(.tertiary)
            Text(title).font(.system(size: 15, weight: .medium))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button(actionTitle, action: action)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var editor: some View {
        VocabularyEditor(
            preferred: $preferredDraft,
            misheard: $misheardDraft,
            isEnabled: $enabledDraft,
            errorMessage: formError,
            onSave: saveEditing,
            onCancel: cancelEditing
        )
    }

    private var footer: some View {
        HStack {
            Text("History → right-click a transcript → Correct & Learn")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
            Spacer()
            Button("Done", action: onClose)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    private func beginAdding() {
        editingID = VocabularyEditor.newEntryID
        preferredDraft = ""
        misheardDraft = ""
        enabledDraft = true
        formError = nil
    }

    private func beginEditing(_ entry: VocabularyEntry) {
        editingID = entry.id
        preferredDraft = entry.term
        misheardDraft = entry.misheard.joined(separator: ", ")
        enabledDraft = entry.isEnabled
        formError = nil
    }

    private func cancelEditing() {
        editingID = nil
        preferredDraft = ""
        misheardDraft = ""
        formError = nil
    }

    private func saveEditing() {
        let phrases = misheardDraft.split(separator: ",").map(String.init)
        guard !phrases.isEmpty else {
            formError = "Enter at least one phrase Yaprflow heard."
            return
        }
        do {
            if editingID == VocabularyEditor.newEntryID {
                _ = try store.learn(
                    misheard: phrases,
                    replacement: preferredDraft,
                    source: .manual
                )
            } else if let id = editingID {
                try store.update(
                    id: id,
                    term: preferredDraft,
                    misheard: phrases,
                    isEnabled: enabledDraft
                )
            }
            cancelEditing()
        } catch {
            formError = error.localizedDescription
        }
    }
}

private struct VocabularyRow: View {
    let entry: VocabularyEntry
    let onToggle: (Bool) -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Toggle("", isOn: Binding(
                get: { entry.isEnabled },
                set: { newValue in onToggle(newValue) }
            ))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .help(entry.isEnabled ? "Disable correction" : "Enable correction")
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    Text(entry.term)
                        .font(.system(size: 13, weight: .medium))
                    Text(entry.source.displayName)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(entry.source == .automatic ? Color.accentColor : .secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.primary.opacity(0.06), in: Capsule())
                }
                Text(entry.misheard.isEmpty
                     ? "Preferred term (word boosting will use this when available)"
                     : "Heard as: " + entry.misheard.joined(separator: ", "))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .opacity(entry.isEnabled ? 1 : 0.55)
            Spacer()
            HStack(spacing: 10) {
                Button(action: onEdit) {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.plain)
                .help("Edit")
                Button(action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Delete")
            }
            .opacity(isHovered ? 1 : 0.35)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
        .background(isHovered ? Color.primary.opacity(0.04) : .clear)
        .onHover { isHovered = $0 }
        .onTapGesture(count: 2, perform: onEdit)
        .contextMenu {
            Button("Edit", action: onEdit)
            Button(entry.isEnabled ? "Disable" : "Enable") { onToggle(!entry.isEnabled) }
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }
}

private struct VocabularyEditor: View {
    static let newEntryID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    @Binding var preferred: String
    @Binding var misheard: String
    @Binding var isEnabled: Bool
    let errorMessage: String?
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var focusedField: Field?

    private enum Field { case preferred, misheard }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Preferred")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
                TextField("McKenzie", text: $preferred)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .preferred)
                    .onSubmit(onSave)
            }
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Yapr heard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 74, alignment: .leading)
                TextField("Mackenzie (comma-separate variants)", text: $misheard)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .misheard)
                    .onSubmit(onSave)
            }
            HStack {
                Toggle("Enabled", isOn: $isEnabled)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11.5))
                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        preferred.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            || misheard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .background(Color.accentColor.opacity(0.07))
        .onAppear {
            DispatchQueue.main.async { focusedField = .preferred }
        }
    }
}
