import AppKit
import SwiftUI

/// The floating pill that appears while yaprflow is recording / processing.
///
/// Lives at the **bottom-center** of the screen (previously top-attached to
/// the display notch — hence the filename). The pill shows three animated
/// audio-level bars on the left and the live transcript / status text on the
/// right, on a dark `hudWindow` blur. Bouncing-bar visualization matches the
/// Wispr Flow shape: a clear visual signal that the mic is actually live and
/// the user is being heard.
struct NotchOverlayView: View {
    @ObservedObject var state: AppState

    private static let transcriptFont = Font.system(size: 12.5, weight: .medium)
    private static let maxCharsPerLine = 56

    /// Width of the indicator slot — matches the waveform's natural width so
    /// the spinner / checkmark that replace it during finishing/copied states
    /// occupy the exact same footprint. This is what keeps the pill from
    /// "popping around" between states: the waveform zeroes out, the spinner
    /// appears in the same hole, the geometry never jumps.
    private static let indicatorSlotWidth: CGFloat = 48

    private var isListening: Bool {
        if case .listening = state.status { return true }
        return false
    }

    private var isIdle: Bool {
        if case .idle = state.status { return true }
        return false
    }

    /// True for transient status strings (model loading/progress, grammar,
    /// errors) as opposed to live transcript text.
    private var isStatusMessage: Bool {
        switch state.status {
        case .preparing, .correcting, .summarizing, .error: return true
        default: return false
        }
    }

    var body: some View {
        pill
            // Window is a fixed-size transparent canvas. Filling the
            // container and centering the pill puts it in the middle of
            // the canvas regardless of how big the inner content is.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pill: some View {
        HStack(alignment: .center, spacing: 8) {
            // Cancel — discard the dictation. Mirrors the Esc hotkey.
            if isListening {
                controlButton(symbol: "xmark", help: "Cancel (esc)") {
                    TranscriptionController.shared.cancel()
                }
                .transition(.scale.combined(with: .opacity))
            }

            leadingIndicator
                .frame(width: Self.indicatorSlotWidth, height: 22)

            if !displayText.isEmpty {
                if isStatusMessage {
                    // Status text (model loading, grammar progress) renders
                    // small and single-line so the chip stays discreet — an
                    // indicator, not a popup.
                    Text(displayText)
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 200)
                } else {
                    Text(displayText)
                        .font(Self.transcriptFont)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                        .fixedSize(horizontal: true, vertical: true)
                }
            }

            // Finish — stop recording and transcribe. Same as releasing /
            // tapping the hotkey. Prominent (filled) like Wispr's: the
            // affirmative action reads brighter than cancel.
            if isListening {
                controlButton(symbol: "checkmark", help: "Done", prominent: true) {
                    TranscriptionController.shared.setActive(false)
                }
                .transition(.scale.combined(with: .opacity))
            }
        }
        // While listening the button circles nest into the capsule's rounded
        // ends (Wispr-style caps); other states need a normal text inset.
        .padding(.horizontal, isListening ? 4 : 13)
        .padding(.vertical, 4)
        .background(
            Capsule(style: .continuous)
                .fill(Color.black.opacity(0.92))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        )
        .fixedSize(horizontal: true, vertical: true)
        // Retraction: as the session resolves to idle (right before the
        // window's alpha fade), the pill shrinks and pulls downward —
        // reads as a smooth retract instead of a hard vanish.
        .scaleEffect(isIdle ? 0.82 : 1)
        .offset(y: isIdle ? 14 : 0)
        // Animate ALL state-driven layout changes (buttons entering/leaving,
        // indicator swaps, text growth) so nothing pops.
        .animation(.spring(response: 0.30, dampingFraction: 0.85), value: state.status)
        .animation(.easeOut(duration: 0.12), value: displayText)
        .animation(.easeIn(duration: 0.15), value: isIdle)
    }

    private func controlButton(
        symbol: String,
        help: String,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.white.opacity(0.9))
                .frame(width: 23, height: 23)
                .background(
                    Circle().fill(prominent ? Color.white.opacity(0.95) : Color.white.opacity(0.12))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private var leadingIndicator: some View {
        switch state.status {
        case .listening:
            WaveformView(level: state.inputLevel)
        case .preparing, .finishing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .correcting, .summarizing:
            ProgressView()
                .controlSize(.small)
                .tint(.white)
        case .copied, .inserted, .captured:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.system(size: 16, weight: .semibold))
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
                .font(.system(size: 16, weight: .semibold))
        case .idle:
            // Idle state shouldn't normally render — the window is hidden
            // outside of an active session — but show static bars as a
            // fallback rather than collapsing the layout to zero width.
            LevelBarsView(level: 0, active: false)
        }
    }

    private var displayText: String {
        switch state.status {
        case .idle:                       return ""
        case .preparing(let message):     return message
        case .listening:
            // No placeholder while waiting for speech — the live waveform IS
            // the "listening" signal, and the bare pill reads cleaner.
            return state.liveTranscript.isEmpty ? "" : Self.wrappedTail(of: state.liveTranscript)
        case .finishing:
            // Keep showing the transcript while the tail transcribes — the
            // spinner in the indicator slot already says "processing", and
            // swapping the text for a label would resize the pill.
            return state.liveTranscript.isEmpty ? "" : Self.wrappedTail(of: state.liveTranscript)
        case .correcting(let message):    return message
        case .summarizing:                return "Summarizing…"
        case .copied, .inserted, .captured:
            // No completion ceremony — the pill retracts immediately, so
            // showing the full text (or a label) here is dead weight.
            return ""
        case .error(let message):         return message
        }
    }

    private static func wrappedTail(of text: String) -> String {
        wrapLines(text, maxCharsPerLine: maxCharsPerLine)
            .suffix(2)
            .joined(separator: "\n")
    }

    private static func wrapLines(_ text: String, maxCharsPerLine: Int) -> [String] {
        let words = text.split(separator: " ", omittingEmptySubsequences: true)
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate: String = current.isEmpty ? String(word) : current + " " + word
            if candidate.count <= maxCharsPerLine {
                current = candidate
            } else {
                if !current.isEmpty { lines.append(current) }
                current = word.count > maxCharsPerLine ? String(word.prefix(maxCharsPerLine)) : String(word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}

/// Wispr-style scrolling waveform: a rolling history of the live input level
/// rendered as vertically-centered capsules, newest sample on the right,
/// scrolling left as new audio arrives. Because each bar keeps its value as
/// it drifts left (instead of every bar re-animating to the newest level),
/// the motion reads as a waveform of what you actually said rather than a
/// choppy synchronized pump.
private struct WaveformView: View {
    let level: Float

    // 10 bars ≈ 47 pt — sits in the pill like a badge, not a strip.
    private static let barCount = 10
    private static let barWidth: CGFloat = 2.5
    private static let barSpacing: CGFloat = 2.5
    private static let baseHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 15

    /// Rolling normalized-amplitude history, oldest first.
    @State private var history: [Float] = Array(repeating: 0, count: barCount)

    var body: some View {
        HStack(alignment: .center, spacing: Self.barSpacing) {
            ForEach(0..<Self.barCount, id: \.self) { idx in
                Capsule(style: .continuous)
                    .fill(Color.white.opacity(opacity(at: idx)))
                    .frame(width: Self.barWidth, height: height(at: idx))
                    // Soft halo lifts the bars off the near-black pill —
                    // reads as glow, not blur, at this radius.
                    .shadow(color: .white.opacity(0.35), radius: 2.5)
            }
        }
        .frame(height: Self.maxHeight)
        .onChange(of: level) { _, newLevel in
            // Soft gain + gamma: speech RMS sits ~0.05–0.25 on a typical mic;
            // the curve lets normal speech reach the upper range without
            // shouting, while keeping silence visibly flat.
            let amplified = min(1.0, newLevel * 3.5)
            let shaped = pow(amplified, 0.6)
            // Fast attack, smooth release: a bar may jump up instantly but
            // never collapses faster than ~28%/sample, so word endings leave
            // graceful decaying tails instead of flickering to the floor.
            let previous = history.last ?? 0
            let smoothed = max(shaped, previous * 0.72)
            history.removeFirst()
            history.append(smoothed)
        }
        .animation(.linear(duration: 0.05), value: history)
    }

    private func height(at index: Int) -> CGFloat {
        Self.baseHeight + CGFloat(history[index]) * (Self.maxHeight - Self.baseHeight)
    }

    /// Older samples dissolve toward the left edge; the ease curve keeps the
    /// newest few bars near full brightness so the "now" end feels alive.
    private func opacity(at index: Int) -> Double {
        let fraction = Double(index) / Double(Self.barCount - 1)
        return 0.22 + 0.72 * pow(fraction, 1.5)
    }
}

/// Static bars for the idle fallback state (the overlay is normally hidden
/// when idle; this just keeps the layout from collapsing).
private struct LevelBarsView: View {
    let level: Float
    let active: Bool

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Color.white.opacity(0.92))
                    .frame(width: 3, height: 4)
            }
        }
    }
}

/// Wraps `NSVisualEffectView` so SwiftUI can use a real AppKit blur (the
/// `.regularMaterial` / `.ultraThinMaterial` SwiftUI materials don't include
/// the darker `hudWindow` look that fits a floating overlay against arbitrary
/// app backgrounds).
private struct VisualEffectBlur: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = false
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
