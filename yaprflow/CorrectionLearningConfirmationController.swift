import AppKit
import Combine
import SwiftUI

@MainActor
private final class CorrectionLearningConfirmationModel: ObservableObject {
    @Published var candidate = CorrectionCandidate(misheard: "", replacement: "")
    @Published var isEditing = false
    @Published var misheardDraft = ""
    @Published var replacementDraft = ""
    @Published var errorMessage: String?

    var onDismiss: (() -> Void)?
    var onEdit: (() -> Void)?
    var onConfirm: (() -> Void)?

    func reset(candidate: CorrectionCandidate) {
        self.candidate = candidate
        misheardDraft = candidate.misheard
        replacementDraft = candidate.replacement
        isEditing = false
        errorMessage = nil
    }
}

/// A non-activating confirmation card shown after Yaprflow detects that the
/// user corrected a distinctive name or term in the exact range it inserted.
/// The correction is never saved until Learn is clicked. Choosing Edit makes
/// the panel key only then, so the initial suggestion does not steal focus
/// from the app where the correction was made.
@MainActor
final class CorrectionLearningConfirmationController: NSWindowController {
    static let shared = CorrectionLearningConfirmationController()

    private static let compactSize = NSSize(width: 430, height: 132)
    private static let editingSize = NSSize(width: 430, height: 218)
    private static let bottomMargin: CGFloat = 18

    private var model = CorrectionLearningConfirmationModel()
    private var confirmHandler: ((CorrectionCandidate) -> String?)?

    private convenience init() {
        let model = CorrectionLearningConfirmationModel()
        let view = CorrectionLearningConfirmationView(model: model)
        let host = CorrectionConfirmationHostingView(rootView: view)
        let window = CorrectionLearningPanel(
            contentRect: NSRect(origin: .zero, size: Self.compactSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.level = .statusBar
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isMovableByWindowBackground = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.animationBehavior = .utilityWindow

        self.init(window: window)
        self.model = model

        model.onDismiss = { [weak self] in self?.dismiss() }
        model.onEdit = { [weak self] in self?.enterEditingMode() }
        model.onConfirm = { [weak self] in self?.confirm() }
    }

    required init?(coder: NSCoder) { fatalError() }

    override init(window: NSWindow?) {
        super.init(window: window)
    }

    func show(
        candidate: CorrectionCandidate,
        onConfirm: @escaping (CorrectionCandidate) -> String?
    ) {
        confirmHandler = onConfirm
        model.reset(candidate: candidate)
        resize(to: Self.compactSize)
        recenter()
        window?.orderFrontRegardless()
    }

    func dismiss() {
        confirmHandler = nil
        model.errorMessage = nil
        window?.orderOut(nil)
    }

    private func enterEditingMode() {
        model.isEditing = true
        model.errorMessage = nil
        resize(to: Self.editingSize)
        recenter()
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func confirm() {
        let candidate = CorrectionCandidate(
            misheard: model.misheardDraft.trimmingCharacters(in: .whitespacesAndNewlines),
            replacement: model.replacementDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        guard let confirmHandler else { return }
        if let error = confirmHandler(candidate) {
            model.errorMessage = error
            if !model.isEditing { enterEditingMode() }
        } else {
            dismiss()
        }
    }

    private func resize(to size: NSSize) {
        guard let window else { return }
        var frame = window.frame
        frame.origin.y += frame.height - size.height
        frame.size = size
        window.setFrame(frame, display: true)
    }

    private func recenter() {
        guard let window, let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let frame = window.frame
        let x = screen.frame.midX - frame.width / 2
        let y = screen.visibleFrame.minY + Self.bottomMargin
        window.setFrameOrigin(NSPoint(x: x, y: y))
    }
}

private struct CorrectionLearningConfirmationView: View {
    @ObservedObject var model: CorrectionLearningConfirmationModel
    @FocusState private var focusedField: Field?

    private enum Field { case replacement, misheard }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                    .background(Color.accentColor.opacity(0.14), in: Circle())
                VStack(alignment: .leading, spacing: 3) {
                    Text("Learn this correction?")
                        .font(.system(size: 13.5, weight: .semibold))
                    if !model.isEditing {
                        Text("\u{201C}\(model.candidate.misheard)\u{201D}  \u{2192}  \u{201C}\(model.candidate.replacement)\u{201D}")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
            }

            if model.isEditing {
                editFields
            }

            HStack(spacing: 8) {
                if let errorMessage = model.errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("Not Now") { model.onDismiss?() }
                    .keyboardShortcut(.cancelAction)
                if !model.isEditing {
                    Button("Edit\u{2026}") { model.onEdit?() }
                }
                Button(model.isEditing ? "Save & Learn" : "Learn") {
                    model.onConfirm?()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(
                    model.misheardDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || model.replacementDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .fill(.ultraThickMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .padding(6)
        .onChange(of: model.isEditing) { _, editing in
            if editing {
                DispatchQueue.main.async { focusedField = .replacement }
            }
        }
    }

    private var editFields: some View {
        Grid(alignment: .leading, horizontalSpacing: 9, verticalSpacing: 7) {
            GridRow {
                Text("Use")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("Preferred spelling", text: $model.replacementDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .replacement)
            }
            GridRow {
                Text("Instead of")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextField("What Yaprflow heard", text: $model.misheardDraft)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .misheard)
            }
        }
    }
}

private final class CorrectionLearningPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

private final class CorrectionConfirmationHostingView:
    NSHostingView<CorrectionLearningConfirmationView>
{
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    required init(rootView: CorrectionLearningConfirmationView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}
