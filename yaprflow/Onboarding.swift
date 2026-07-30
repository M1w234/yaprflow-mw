import AppKit
import AVFoundation
import Combine
import SwiftUI

private enum OnboardingStep {
    case welcome
    case automaticInsertion
    case permissions
    case ready
}

struct OnboardingView: View {
    let onComplete: () -> Void

    @State private var step: OnboardingStep = .welcome
    @State private var automaticInsertionSelected: Bool = true
    @State private var micStatus: AVAuthorizationStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityTrusted: Bool = AutoPaste.hasAccessibility

    private let permissionPoller = Timer.publish(every: 0.75, on: .main, in: .common)
        .autoconnect()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Group {
                switch step {
                case .welcome:              welcomeScreen
                case .automaticInsertion:   automaticInsertionScreen
                case .permissions:          permissionsScreen
                case .ready:                readyScreen
                }
            }
            .transition(.opacity)
        }
        .frame(width: 520, height: 520)
        .onReceive(permissionPoller) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            accessibilityTrusted = AutoPaste.hasAccessibility
        }
    }

    private var welcomeScreen: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                .resizable()
                .interpolation(.high)
                .frame(width: 128, height: 128)
            Text("Yaprflow")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(.white)
                .padding(.top, 24)
            Text("Private, offline dictation for macOS")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.top, 8)
            Spacer()
            Button {
                // The recommended path is intentionally opinionated: process
                // the full recording for accuracy, then apply fast mechanical
                // cleanup. Alternative modes remain available under Advanced.
                AppState.shared.streamingMode = false
                AppState.shared.cleanupMode = .light
                withAnimation(.easeInOut(duration: 0.25)) { step = .automaticInsertion }
            } label: {
                Text("Get started").frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingButtonStyle())
            .frame(width: 260)
            .padding(.bottom, 48)
        }
    }

    private var automaticInsertionScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 48)
            Text("Type where you're working")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
            Text("No pasting and no clipboard replacement.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .padding(.top, 8)
            Spacer(minLength: 28)

            VStack(spacing: 12) {
                featureToggleCard(
                    title: "Automatic Insertion",
                    body: "Yaprflow types the finished transcript into the field you were using while leaving your clipboard untouched. macOS calls this Accessibility access.",
                    isOn: $automaticInsertionSelected
                )
                infoCard(
                    title: "Your words stay recoverable",
                    body: "Every finished dictation is saved in History. If a field cannot accept insertion, Yaprflow keeps the transcript there instead of replacing your clipboard."
                )
            }
            .padding(.horizontal, 28)

            Spacer()
            Button {
                AppState.shared.autoPasteMode = automaticInsertionSelected
                // Preserve Clipboard is now the only automatic-delivery
                // behavior. Keep the legacy preference pinned on for rollback
                // compatibility with older builds.
                AppState.shared.preserveClipboardMode = true
                if automaticInsertionSelected {
                    _ = AutoPaste.promptForAccessibility()
                }
                withAnimation(.easeInOut(duration: 0.25)) { step = .permissions }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingButtonStyle())
            .frame(width: 260)
            .padding(.bottom, 40)
        }
    }

    private func featureToggleCard(
        title: String,
        body: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button(action: { isOn.wrappedValue.toggle() }) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                    Text(body)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .multilineTextAlignment(.leading)
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(isOn.wrappedValue ? 0.35 : 0.08), lineWidth: 1)
                        .frame(width: 20, height: 20)
                    if isOn.wrappedValue {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.white.opacity(isOn.wrappedValue ? 0.10 : 0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(isOn.wrappedValue ? 0.35 : 0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func infoCard(title: String, body: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                Text(body)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.white.opacity(0.55))
                    .multilineTextAlignment(.leading)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Image(systemName: "text.bullet.list")
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Color.white.opacity(0.25))
                .frame(width: 20, height: 20)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var permissionsScreen: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 40)
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 56))
                .foregroundStyle(.white)
                .frame(width: 112, height: 112)
                .background(
                    RoundedRectangle(cornerRadius: 28)
                        .fill(Color.white.opacity(0.08))
                )
            Text("Finish setup")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 20)
            Text("Yaprflow rechecks permissions automatically.")
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.55))
                .multilineTextAlignment(.center)
                .padding(.top, 8)

            VStack(spacing: 10) {
                permissionRow(
                    icon: "mic.fill",
                    title: "Microphone",
                    detail: "Audio stays on this Mac",
                    isReady: micStatus == .authorized
                )
                if automaticInsertionSelected {
                    permissionRow(
                        icon: "text.cursor",
                        title: "Automatic Insertion",
                        detail: "Leaves the clipboard untouched",
                        isReady: accessibilityTrusted
                    )
                }
            }
            .padding(.horizontal, 48)
            .padding(.top, 24)

            Spacer(minLength: 20)
            VStack(spacing: 12) {
                Button {
                    handlePrimaryAction()
                } label: {
                    Text(primaryButtonTitle).frame(maxWidth: .infinity)
                }
                .buttonStyle(OnboardingButtonStyle())
                .frame(width: 260)

                if micStatus == .authorized,
                   automaticInsertionSelected,
                   !accessibilityTrusted {
                    Button("Finish without Automatic Insertion") {
                        AppState.shared.autoPasteMode = false
                        onComplete()
                    }
                        .buttonStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .padding(.bottom, 40)
        }
    }

    private var readyScreen: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 72))
                .foregroundStyle(.white)
            Text("Ready to dictate")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.top, 24)
            Text("Hold Option + Shift while you speak,\nthen release to insert your words.")
                .font(.system(size: 14))
                .foregroundStyle(Color.white.opacity(0.62))
                .multilineTextAlignment(.center)
                .lineSpacing(4)
                .padding(.top, 10)

            HStack(spacing: 8) {
                shortcutKey("⌥")
                shortcutKey("⇧")
            }
            .padding(.top, 28)

            Text("A chime and the recording pill confirm when the microphone is live.")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.42))
                .multilineTextAlignment(.center)
                .frame(width: 330)
                .padding(.top, 18)

            Spacer()
            Button {
                onComplete()
            } label: {
                Text("Start using Yaprflow").frame(maxWidth: .infinity)
            }
            .buttonStyle(OnboardingButtonStyle())
            .frame(width: 260)
            .padding(.bottom, 48)
        }
    }

    private func shortcutKey(_ label: String) -> some View {
        Text(label)
            .font(.system(size: 22, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 56, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
            )
    }

    private func permissionRow(
        icon: String,
        title: String,
        detail: String,
        isReady: Bool
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Color.white.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.45))
            }
            Spacer()
            Label(isReady ? "Ready" : "Needed",
                  systemImage: isReady ? "checkmark.circle.fill" : "exclamationmark.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isReady ? Color.green : Color.orange)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var primaryButtonTitle: String {
        if micStatus == .authorized {
            if automaticInsertionSelected, !accessibilityTrusted {
                return "Enable Automatic Insertion"
            }
            return "You're all set"
        }
        switch micStatus {
        case .authorized:          return "You're all set"
        case .denied, .restricted: return "Open System Settings"
        case .notDetermined:       return "Grant microphone access"
        @unknown default:          return "Continue"
        }
    }

    private func handlePrimaryAction() {
        if micStatus == .authorized {
            if automaticInsertionSelected, !accessibilityTrusted {
                if !AutoPaste.promptForAccessibility() {
                    AutoPaste.openAccessibilitySettings()
                }
                accessibilityTrusted = AutoPaste.hasAccessibility
                return
            }
            withAnimation(.easeInOut(duration: 0.25)) { step = .ready }
            return
        }

        switch micStatus {
        case .authorized:
            break
        case .denied, .restricted:
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                NSWorkspace.shared.open(url)
            }
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async {
                    self.micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                }
            }
        @unknown default:
            onComplete()
        }
    }
}

private struct OnboardingButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.black)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(configuration.isPressed ? 0.85 : 1.0))
            )
    }
}

@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindowController()

    private static let defaultsKey = "yaprflow.didCompleteOnboarding"
    private var window: NSWindow?
    private var didFinishCurrentFlow = false

    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let rootView = OnboardingView { [weak self] in
            self?.complete()
        }

        let hosting = NSHostingController(rootView: rootView)
        let newWindow = NSWindow(contentViewController: hosting)
        // Must match OnboardingView's fixed frame (520×520) — a narrower
        // window clips the mode-selection cards at both edges.
        newWindow.setContentSize(NSSize(width: 520, height: 520))
        newWindow.styleMask = [.titled, .closable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.title = ""
        newWindow.isMovableByWindowBackground = true
        newWindow.backgroundColor = .black
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()

        window = newWindow

        // Temporarily show the app in the Dock so the onboarding window is
        // focusable; we flip back to .accessory on completion.
        NSApp.setActivationPolicy(.regular)
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func complete() {
        didFinishCurrentFlow = true
        window?.close() // windowWillClose will finish the cleanup.
    }

    // MARK: - NSWindowDelegate

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            if self.didFinishCurrentFlow {
                UserDefaults.standard.set(true, forKey: Self.defaultsKey)
            }
            self.didFinishCurrentFlow = false
            self.window = nil
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
