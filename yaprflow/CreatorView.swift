import AppKit
import SwiftUI

/// Shared by first-run setup and the permanent About window.
struct CreatorCard: View {
    private struct Profile: Identifiable {
        let title: String
        let detail: String
        let symbol: String
        let url: URL
        var id: String { title }
    }

    // Public destinations linked from michaelwong.ai.
    private let profiles: [Profile] = [
        Profile(
            title: "Instagram", detail: "@mikedubsdigital", symbol: "camera",
            url: URL(string: "https://www.instagram.com/mikedubsdigital/")!
        ),
        Profile(
            title: "YouTube", detail: "@mikedubshi", symbol: "play.rectangle",
            url: URL(string: "https://www.youtube.com/@mikedubshi")!
        )
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Created by Michael Wong")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Text("Free to use. If you enjoy it, come say hello.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.65))
            }
            ForEach(profiles) { profile in
                Link(destination: profile.url) {
                    HStack(spacing: 12) {
                        Image(systemName: profile.symbol)
                            .font(.system(size: 17))
                            .frame(width: 24)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.title)
                                .font(.system(size: 13, weight: .semibold))
                            Text(profile.detail)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.white.opacity(0.65))
                        }
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 11, weight: .medium))
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(.white)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
                    .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(profile.title), \(profile.detail)")
                .accessibilityHint("Opens in your browser")
                .help(profile.url.absoluteString)
            }
        }
        .padding(18)
        .background(Color.white.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }
}

struct CreatorAboutView: View {
    let onClose: () -> Void

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Yaprflow")
                        .font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white)
                    Text("Version \(version) · Private, offline dictation")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.65))
                }
                Spacer()
            }
            CreatorCard()
                .padding(.top, 24)
            Text("Based on the open-source Yaprflow by Tim Moreton Jr.")
                .font(.system(size: 11))
                .foregroundStyle(Color.white.opacity(0.65))
                .padding(.top, 14)
            Link("Original project · Apache 2.0", destination: URL(string: "https://github.com/tmoreton/yaprflow")!)
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(.white)
                .padding(.top, 5)
            Spacer(minLength: 20)
            Button(action: onClose) {
                Text("Done").frame(maxWidth: .infinity)
            }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(OnboardingButtonStyle())
                .frame(width: 260)
        }
        .padding(32)
        .frame(width: 520, height: 560)
        .background(.black)
        .onExitCommand(perform: onClose)
    }
}

@MainActor
final class CreatorWindowController: NSObject, NSWindowDelegate {
    static let shared = CreatorWindowController()
    private var window: NSWindow?

    func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hosting = NSHostingController(rootView: CreatorAboutView { [weak self] in
            self?.window?.close()
        })
        let newWindow = NSWindow(contentViewController: hosting)
        newWindow.setContentSize(NSSize(width: 520, height: 560))
        newWindow.styleMask = [.titled, .closable, .fullSizeContentView]
        newWindow.titlebarAppearsTransparent = true
        newWindow.titleVisibility = .hidden
        newWindow.title = "About Yaprflow & Creator"
        newWindow.backgroundColor = .black
        newWindow.isMovableByWindowBackground = true
        newWindow.isReleasedWhenClosed = false
        newWindow.delegate = self
        newWindow.center()
        window = newWindow
        newWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in self.window = nil }
    }
}
