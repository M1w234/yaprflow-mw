@preconcurrency import AVFoundation
import AppKit
import CoreML
import FluidAudio
import Foundation
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "Transcription")

enum TranscriptionError: LocalizedError {
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .microphoneDenied: return "Microphone access denied"
        }
    }
}

@MainActor
final class TranscriptionController {
    static let shared = TranscriptionController()

    private let state = AppState.shared
    private let capture: AudioCapture
    private let audioConverter = AudioConverter()

    // Models are loaded once and kept for the process lifetime
    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private var loadingTask: Task<(AsrManager, VadManager), Error>?

    // Per-session state
    private var sessionSamples: [Float] = []
    private var vadPending: [Float] = []
    private var vadState: VadStreamState?
    private var currentSpeechStart: Int?
    private var confirmedText = ""
    private var volatileText = ""
    private var lastSpeculativeSampleCount = 0
    private var transcribeChain: Task<Void, Never>?

    private var isActive = false
    private var isStarting = false
    /// In-flight stop() work. start() awaits this before resetting session
    /// state — without it, pressing the hotkey again while stop() is still
    /// awaiting the transcribe chain lets start() wipe `confirmedText` mid-
    /// stop and the previous dictation is silently lost.
    private var stopTask: Task<Void, Never>?
    /// Reentrancy guard for feed()'s VAD drain loop. feed() suspends at
    /// `processStreamingChunk`, and the MainActor is free to interleave
    /// another feed() at that point — two drains running against the same
    /// `vadState` process chunks out of order and corrupt speech detection.
    /// Samples still accumulate in `vadPending` while the guard is held, so
    /// a skipped drain is lossless; the next feed() picks them up.
    private var isDrainingVAD = false
    /// What the caller most recently asked for. Diverges from isActive while
    /// start() is awaiting mic/model load — if the user releases push-to-talk
    /// during that window, start() will see desiredActive == false and bail.
    private var desiredActive = false
    private var sessionIsStreaming = true
    private var autoHideTask: Task<Void, Never>?
    /// Safety ceiling on a single recording session. Mostly protects lock
    /// mode (double-tap) — an accidental lock would otherwise leave the mic
    /// hot and session buffers growing (~230 MB/hour) until noticed. Hitting
    /// the ceiling stops-and-transcribes; nothing is discarded.
    private let maxSessionDuration: TimeInterval = 10 * 60
    private var maxDurationTask: Task<Void, Never>?
    /// Keep the microphone live briefly after the stop gesture so a soft or
    /// trailing final word reaches the app before the tap is removed.
    private let captureTailGrace: Duration = .milliseconds(350)
    /// Once the tap is removed, give already-enqueued MainActor feed tasks a
    /// bounded chance to append their copied buffers before isActive flips.
    private let captureDrainGrace: Duration = .milliseconds(40)

    /// Monotonic per-recording session ID. Bumped in start() before any await.
    /// Async work (notably the grammar correction Task that outlives stop())
    /// captures this value at launch time and bails if it no longer matches —
    /// otherwise a slow grammar pass from session 1 can overwrite session 2's
    /// clipboard, or worse, auto-paste session 1's transcript into session 2's
    /// target window.
    private var currentSessionID = UUID()

    /// PID of the frontmost app at the moment the user fired the hotkey for
    /// THIS session, with yaprflow itself filtered out. The auto-paste site
    /// re-reads `NSWorkspace.shared.frontmostApplication?.processIdentifier`
    /// and compares against this value, aborting on mismatch. nil → auto-paste
    /// suppressed for this session (yaprflow was frontmost, or capture failed).
    private var sessionFrontmostPID: pid_t?

    /// Off-main capture of text-near-cursor for the grammar polish. Fires in
    /// start(), result is consumed in stop()'s grammar Task. The store never
    /// blocks the polish path; missing context just means the grammar call
    /// runs without a hint and the user gets normal correction.
    private let screenContextStore = ScreenContextStore()

    // Segmentation tuned to STOP over-chopping continuous speech, which was the
    // main cause of dropped words. Every segment boundary is a place transducer
    // ASR (Parakeet) deletes words (worst-case deletions happen at chunk edges),
    // and the silence gap between one segment's end and the next's start is
    // discarded outright. The old 0.3s silence threshold split a normal sentence
    // at every little inter-word pause.
    //   - minSilenceDuration 0.8s: only a deliberate pause between separate
    //     thoughts ends a segment; natural mid-sentence pauses stay in one piece.
    //     Costs nothing on the final text (push-to-talk flushes the tail on
    //     release) and the speculative partials still update the live preview.
    //   - speechPadding 0.25s: pads each segment's edges so word onsets/offsets
    //     aren't clipped, and overlaps the silence gap so no audio is lost.
    //   - minSpeechDuration 0.1s: don't drop very short isolated words ("a", "I").
    private let segmentationConfig = VadSegmentationConfig(
        minSpeechDuration: 0.1,
        minSilenceDuration: 0.8,
        maxSpeechDuration: 60.0,
        speechPadding: 0.25
    )

    // Speculative partials: re-transcribe in-progress speech every 2.0s.
    // Less frequent = fewer re-transcriptions for long recordings.
    private let speculativeIntervalSamples = Int(2.0 * 16000)
    private let speculativeMinSpeechSamples = Int(1.0 * 16000)
    /// Cap on how much audio each speculative pass re-transcribes. Without
    /// it, a continuous monologue re-transcribes the ENTIRE in-progress
    /// segment (up to 60s) every 2s, and the serialized transcribe chain
    /// falls further behind the longer you talk. The overlay only shows the
    /// last two lines anyway; the confirmed pass still covers the full
    /// segment on speechEnd.
    private let speculativeMaxWindowSamples = Int(15.0 * 16000)

    private init() {
        let bufferHandler: @Sendable (AVAudioPCMBuffer) -> Void = { buffer in
            Task { @MainActor in
                await TranscriptionController.shared.feed(buffer)
            }
        }
        self.capture = AudioCapture(bufferHandler: bufferHandler)
        // Default input device changed / sample rate changed mid-recording:
        // the engine has already stopped feeding us. End the session
        // gracefully (transcribing what we have) instead of leaving a dead
        // mic behind a "Listening…" overlay.
        self.capture.onConfigurationChange = {
            Task { @MainActor in
                let controller = TranscriptionController.shared
                guard controller.isActive else { return }
                log.info("Audio engine configuration changed mid-session — finishing dictation")
                controller.setActive(false)
            }
        }
    }

    var isRecording: Bool { isActive }

    func toggle() {
        setActive(!desiredActive)
    }

    /// Discard the current session entirely: stop the mic, throw away the
    /// audio and any partial transcript, touch neither clipboard nor target
    /// app. Bound to Esc while recording.
    func cancel() {
        guard isActive else { return }
        let cancelledSessionID = currentSessionID
        desiredActive = false
        isActive = false
        maxDurationTask?.cancel()
        CancelHotkey.shared.unregister()
        capture.stop()
        AudioDucking.shared.restore()
        ModifierOnlyHotkey.shared.notifyRecordingEndedExternally()
        SoundEffect.stop.play()

        // Invalidate in-flight async work: chained transcribes check this
        // session ID before touching confirmedText, and any grammar Task
        // from a previous session already guards on it.
        ComparisonLogger.shared.cancelSession(sessionID: cancelledSessionID)
        currentSessionID = UUID()
        sessionSamples.removeAll()
        vadPending.removeAll()
        currentSpeechStart = nil
        confirmedText = ""
        volatileText = ""
        state.inputLevel = 0
        state.liveTranscript = ""
        state.status = .idle
        scheduleAutoHide(after: 0.4)
        log.info("Dictation cancelled — session discarded")
    }

    /// Reads the frontmost-app PID with yaprflow itself filtered out — when we
    /// are foreground (status item click, onboarding window, focused menu) we
    /// must NOT auto-paste, because the target "field" would be our own UI.
    /// Returns nil when frontmost is unavailable or is us; callers treat nil
    /// as "do not auto-paste this session."
    private static func captureFrontmostExcludingSelf() -> pid_t? {
        let mine = ProcessInfo.processInfo.processIdentifier
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else {
            return nil
        }
        return pid == mine ? nil : pid
    }

    /// Final delivery of a transcript to the user. Automatic insertion never
    /// touches the clipboard: if the target or Accessibility permission is
    /// unavailable, the transcript remains recoverable in History and the
    /// overlay reports the failure. With automatic insertion disabled, the
    /// transcript is copied for manual paste. `updateStatus: false` keeps a
    /// caller-set status (e.g. the grammar-failure error) visible.
    private func deliverTranscript(
        _ text: String,
        sessionID: UUID,
        targetPID: pid_t?,
        autoPasteEnabled: Bool,
        shadowComparisonEnabled: Bool,
        updateStatus: Bool = true
    ) {
        ComparisonLogger.shared.recordDelivered(sessionID: sessionID, text: text)
        if shadowComparisonEnabled {
            if updateStatus { state.status = .captured }
            log.info("Shadow comparison captured transcript without delivery")
            return
        }
        if autoPasteEnabled {
            if insertDirectly(text, targetPID: targetPID) {
                if updateStatus { state.status = .inserted }
                return
            }
            log.info("Automatic insertion unavailable — transcript retained in History")
            if updateStatus {
                state.status = .error("Couldn't insert — saved to History")
            }
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        let writeOK = pb.setString(text, forType: .string)
        if updateStatus { state.status = .copied }
        if !writeOK {
            log.error("Failed to copy transcript to clipboard")
        }
    }

    /// Same guard set as auto-paste, then TextInsertion (AX selected-text
    /// write → synthetic Unicode typing). False when any guard or both
    /// mechanisms fail.
    private func insertDirectly(_ text: String, targetPID: pid_t?) -> Bool {
        guard let target = targetPID else {
            log.info("Insertion skipped: no captured target")
            return false
        }
        guard AutoPaste.hasAccessibility else {
            log.info("Insertion skipped: Accessibility permission not granted")
            return false
        }
        guard !AutoPaste.isSecureInputEnabled else {
            log.info("Insertion skipped: secure event input is enabled")
            return false
        }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target else {
            log.info("Insertion skipped: focus changed since recording started")
            return false
        }
        guard let result = TextInsertion.insertWithResult(
            text,
            intoPID: target,
            captureCorrectionReceipt: state.learnFromCorrections
        ) else {
            return false
        }
        if state.learnFromCorrections {
            if let receipt = result.receipt {
                CorrectionLearningMonitor.shared.begin(receipt)
            } else {
                CorrectionLearningMonitor.shared.beginTypingFallback(
                    originalText: text,
                    targetPID: target
                )
            }
        }
        return true
    }

    /// Drive recording from desired state. Safe to call rapidly from push-to-talk:
    /// if the user presses-and-releases during start()'s async warmup, start()
    /// observes desiredActive == false post-await and bails out cleanly.
    func setActive(_ active: Bool) {
        desiredActive = active
        Task { @MainActor in
            if active {
                // Serialize behind any in-flight stop(): it is still reading
                // session state (confirmedText, sessionSamples) across its
                // awaits, and start() resets all of it.
                if let pending = stopTask {
                    await pending.value
                }
                // Re-check: the user may have released again while we waited.
                guard desiredActive else { return }
                if !isActive, !isStarting { await start() }
            } else {
                // If start() is still in-flight, it will see desiredActive=false
                // post-await and bail. Otherwise stop normally.
                if isActive, stopTask == nil {
                    let task = Task { @MainActor in
                        await self.stop()
                    }
                    stopTask = task
                    await task.value
                    // Only one stop can be in flight (guarded above), so this
                    // is necessarily our own task being cleared.
                    stopTask = nil
                }
            }
        }
    }

    /// Eagerly load ASR + VAD models so the first hotkey press doesn't block
    /// on the ~30s Encoder compile. Safe to call multiple times — subsequent
    /// calls are no-ops once the models are loaded.
    func preload() {
        Task { @MainActor in
            do {
                _ = try await ensureLoaded()
                // Don't leave the overlay/menu showing a stale "preparing…"
                // status once preload finishes if the user hasn't started yet.
                if !isActive, !isStarting {
                    state.status = .idle
                }
            } catch {
                log.error("Preload failed: \(error.localizedDescription)")
            }
        }
    }

    private func start() async {
        guard !isActive, !isStarting else { return }
        // A new dictation ends the previous insertion's correction window.
        CorrectionLearningMonitor.shared.cancel()
        isStarting = true
        defer { isStarting = false }

        autoHideTask?.cancel()
        confirmedText = ""
        volatileText = ""
        lastSpeculativeSampleCount = 0
        state.liveTranscript = ""
        // Snapshot the mode for this session so toggling the menu mid-recording
        // doesn't corrupt the pipeline.
        sessionIsStreaming = state.streamingMode

        // Pick up any hand edits to vocabulary.json (cheap mtime check).
        VocabularyStore.shared.reloadIfChanged()

        // Per-session capture for auto-paste. Done BEFORE any await: by the
        // time ensureLoaded() returns (up to 30s on cold launch) frontmost may
        // have drifted, but we want "the app the user was in when they fired
        // the hotkey," not "wherever they happen to be after the model loads."
        currentSessionID = UUID()
        sessionFrontmostPID = Self.captureFrontmostExcludingSelf()
        ComparisonLogger.shared.prepareSession(sessionID: currentSessionID)

        // Fire screen-context capture in parallel. Off-main, fire-and-forget;
        // the polish path reads whatever has landed by then. If the user
        // disabled the feature, clear any stale capture from a prior session
        // so it can't be picked up if they re-enable mid-session.
        if state.cleanupMode == .polish,
           state.screenContextMode,
           let targetPID = sessionFrontmostPID {
            let appName = NSWorkspace.shared.frontmostApplication?.localizedName
            screenContextStore.startCapture(
                sessionID: currentSessionID,
                targetPID: targetPID,
                appName: appName
            )
        } else {
            screenContextStore.clear()
        }

        NotchOverlayWindowController.shared.show()

        do {
            try await ensureMicPermission()
            let (_, vad) = try await ensureLoaded()

            // Push-to-talk race guard: if the user released the hotkey while
            // we were awaiting mic permission / model load, abandon the start
            // instead of stranding capture running with no way to stop it.
            guard desiredActive else {
                state.status = .idle
                scheduleAutoHide(after: 0.1)
                return
            }

            sessionSamples.removeAll(keepingCapacity: true)
            vadPending.removeAll(keepingCapacity: true)
            vadState = await vad.makeStreamState()
            currentSpeechStart = nil

            state.status = .listening
            try capture.start()
            isActive = true
            ComparisonLogger.shared.recordingDidStart(sessionID: currentSessionID)
            SoundEffect.start.play()

            // Session-scoped affordances — all torn down in stop()/cancel().
            if state.duckWhileRecording {
                if state.soundEffectsEnabled {
                    // Let the start chime land before muting output — ducking
                    // immediately silences the very cue that says "mic is
                    // live" (the sound plays on the device we're about to
                    // mute). ~0.5s covers the short system chimes.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(500))
                        guard self.isActive, self.state.duckWhileRecording else { return }
                        AudioDucking.shared.duck()
                    }
                } else {
                    AudioDucking.shared.duck()
                }
            }
            CancelHotkey.onPressed = {
                Task { @MainActor in
                    TranscriptionController.shared.cancel()
                }
            }
            CancelHotkey.shared.register()
            maxDurationTask?.cancel()
            let durationSessionID = currentSessionID
            maxDurationTask = Task { @MainActor in
                do {
                    try await Task.sleep(for: .seconds(maxSessionDuration))
                } catch {
                    return
                }
                // Session-identity guard so a stale timer can't stop a newer
                // recording, on top of the cancel() in start()/stop()/cancel().
                guard self.isActive, self.currentSessionID == durationSessionID else { return }
                log.info("Max session duration reached — auto-stopping")
                self.setActive(false)
            }
        } catch {
            log.error("Start failed: \(error.localizedDescription)")
            state.status = .error(error.localizedDescription)
            scheduleAutoHide(after: 2.5)
        }
    }

    private func stop() async {
        guard isActive else { return }
        maxDurationTask?.cancel()
        ComparisonLogger.shared.recordingDidStop(sessionID: currentSessionID)

        // Show immediate feedback while keeping capture live for a short
        // post-roll. This recovers softly trailed endings without running any
        // additional model or slowing the transcription itself.
        state.status = .finishing
        try? await Task.sleep(for: captureTailGrace)

        // Esc can cancel and clear the session while the post-roll suspends.
        // Do not resurrect or deliver a cancelled dictation when we resume.
        guard isActive else { return }

        capture.stop()

        // AudioCapture copies each render-thread buffer before handing it to a
        // MainActor task. After removing the tap, allow that finite queue to
        // drain while feed() still sees isActive == true.
        try? await Task.sleep(for: captureDrainGrace)
        guard isActive else { return }

        isActive = false
        CancelHotkey.shared.unregister()
        AudioDucking.shared.restore()
        // No-op for chord-initiated stops (the recognizer already reset
        // itself before firing onStop); resyncs it after max-duration or
        // device-change stops so the next tap isn't consumed as a stale
        // lock-mode "stop".
        ModifierOnlyHotkey.shared.notifyRecordingEndedExternally()
        SoundEffect.stop.play()
        state.inputLevel = 0

        if sessionIsStreaming {
            // Streaming: flush any pending speech segment so we don't lose the
            // tail of what the user was saying.
            if let start = currentSpeechStart, start < sessionSamples.count {
                let tail = Array(sessionSamples[start..<sessionSamples.count])
                currentSpeechStart = nil
                enqueueTranscribe(samples: tail)
            }
            await transcribeChain?.value
        } else {
            // Single-shot: transcribe the whole clip in one pass. The overlay
            // has been showing "Listening…" / "Processing…" the whole time; the
            // final text will land below.
            if !sessionSamples.isEmpty {
                await performTranscribe(samples: sessionSamples, sessionID: currentSessionID)
            }
        }

        // Vocabulary pass: swap known ASR mis-hearings for the user's
        // preferred spellings ("yapper flow" → "yaprflow") before delivery
        // AND before the grammar polish sees the text.
        let finalText = VocabularyStore.shared.applyReplacements(
            to: confirmedText.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        state.liveTranscript = finalText

        if !finalText.isEmpty {
            state.lastOriginalTranscript = finalText
            // Comparison study (no-op unless the menu toggle is on): log our
            // raw transcript. Wispr's side is paired later from its richer
            // local History table, independent of the destination app.
            ComparisonLogger.shared.beginCapture(
                sessionID: currentSessionID,
                raw: finalText
            )

            // Snapshot session-scoped values for any async work below — never
            // read `self.currentSessionID` / `self.sessionFrontmostPID` from
            // inside the grammar Task closure, since a new dictation could
            // mutate them before the Task resumes.
            let sessionID = currentSessionID
            let targetPID = sessionFrontmostPID
            let autoPasteEnabled = state.autoPasteMode
            let shadowComparisonEnabled = state.comparisonLogMode
            let screenContextEnabled = state.screenContextMode
            let numberFormattingMode = state.numberFormattingMode
            let formattedOriginal = SpokenNumberFormatter.apply(
                finalText,
                mode: numberFormattingMode
            )

            switch state.cleanupMode {
            case .polish:
                // Manual-copy mode: put the original on the clipboard first so
                // the user has SOMETHING while correction runs; the final
                // delivery below overwrites it. Skipped for automatic insertion,
                // whose whole point is not touching the clipboard. The
                // original write is never auto-pasted — auto-paste/insertion
                // only fires on the final value (corrected on success, or
                // original on failure below).
                if !autoPasteEnabled && !shadowComparisonEnabled {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(formattedOriginal, forType: .string)
                }

                state.status = .correcting("Improving grammar…")
                autoHideTask?.cancel()
                autoHideTask = nil

                Task { @MainActor in
                    do {
                        // Decide whether to use screen context for this
                        // polish. Re-check focus PID HERE (not at start) —
                        // the user may have ⌘Tab'd away during recording, in
                        // which case the captured snapshot is irrelevant.
                        var contextForPolish: ScreenContext? = nil
                        let frontmostNow = NSWorkspace.shared.frontmostApplication?.processIdentifier
                        let pidMatches = (frontmostNow == targetPID)
                        if screenContextEnabled, let _ = targetPID, pidMatches {
                            contextForPolish = self.screenContextStore.contextIfReady(for: sessionID)
                        }
                        log.info("Polish context decision: enabled=\(screenContextEnabled, privacy: .public) pidMatch=\(pidMatches, privacy: .public) gotContext=\(contextForPolish != nil, privacy: .public)")

                        let corrected = try await GrammarController.shared.correct(
                            text: finalText,
                            context: contextForPolish
                        ) { msg in
                            self.state.status = .correcting(msg)
                        }
                        // Stale-session guard: a new dictation may have
                        // started (and even finished) while we were awaiting
                        // the grammar model. Pasting / writing the clipboard
                        // now would clobber the newer session's transcript
                        // — and, for auto-paste, would deliver this
                        // session's text to whatever app the user has moved
                        // on to. Drop the result entirely.
                        guard sessionID == self.currentSessionID else {
                            log.info("Dropping stale grammar correction (newer session in flight)")
                            return
                        }
                        let formatted = SpokenNumberFormatter.apply(
                            corrected,
                            mode: numberFormattingMode
                        )
                        self.state.liveTranscript = formatted
                        self.state.lastTranscript = formatted
                        self.deliverTranscript(
                            formatted,
                            sessionID: sessionID,
                            targetPID: targetPID,
                            autoPasteEnabled: autoPasteEnabled,
                            shadowComparisonEnabled: shadowComparisonEnabled
                        )
                        // Deliver → retract. No completion ceremony; the pill
                        // pulls away as soon as the text has landed.
                        self.scheduleAutoHide(after: 0.3)
                    } catch {
                        log.error("Grammar correction failed: \(error.localizedDescription)")
                        guard sessionID == self.currentSessionID else { return }
                        // Surface the failure briefly so the user notices
                        // grammar didn't run — most often this is a fresh
                        // install where the model download failed (network,
                        // 404 release tag, etc.) and silent fallback would
                        // let it go undetected forever.
                        self.state.lastTranscript = formattedOriginal
                        self.state.status = .error("Grammar unavailable — used original")
                        self.scheduleAutoHide(after: 3.0)

                        // Deliver the original anyway — the user invoked
                        // dictation expecting text to appear, and silently
                        // dropping it on grammar failure is worse than
                        // delivering uncorrected text. updateStatus false so
                        // the error above stays visible.
                        self.deliverTranscript(
                            formattedOriginal,
                            sessionID: sessionID,
                            targetPID: targetPID,
                            autoPasteEnabled: autoPasteEnabled,
                            shadowComparisonEnabled: shadowComparisonEnabled,
                            updateStatus: false
                        )
                    }
                }
            case .light:
                // Light mode is synchronous and deterministic: no model load,
                // no paraphrasing, and no async correction latency.
                let cleaned = LightCleanup.apply(finalText)
                let formatted = SpokenNumberFormatter.apply(
                    cleaned,
                    mode: numberFormattingMode
                )
                state.liveTranscript = formatted
                state.lastTranscript = formatted
                deliverTranscript(
                    formatted,
                    sessionID: sessionID,
                    targetPID: targetPID,
                    autoPasteEnabled: autoPasteEnabled,
                    shadowComparisonEnabled: shadowComparisonEnabled
                )
                scheduleAutoHide(after: 0.3)

            case .off:
                state.lastTranscript = formattedOriginal
                deliverTranscript(
                    formattedOriginal,
                    sessionID: sessionID,
                    targetPID: targetPID,
                    autoPasteEnabled: autoPasteEnabled,
                    shadowComparisonEnabled: shadowComparisonEnabled
                )
                scheduleAutoHide(after: 0.3)
            }
        } else {
            state.status = .idle
            scheduleAutoHide(after: 1.2)
        }
    }

    private func feed(_ buffer: AVAudioPCMBuffer) async {
        guard isActive else { return }

        // Publish a normalized input-level reading for the overlay's bouncing
        // bars. Cheap (single pass over the buffer's floats) and fires at the
        // engine's tap rate, which is roughly 20–50 Hz — plenty smooth for UI.
        state.inputLevel = Self.rmsLevel(of: buffer)

        let samples: [Float]
        do {
            samples = try audioConverter.resampleBuffer(buffer)
        } catch {
            log.error("Resample failed: \(error.localizedDescription)")
            return
        }

        sessionSamples.append(contentsOf: samples)

        // Single-shot mode: just accumulate, transcribe everything in stop().
        guard sessionIsStreaming else { return }

        guard let vad = vadManager else { return }
        vadPending.append(contentsOf: samples)

        // Only one drain loop at a time — see `isDrainingVAD`. Our samples are
        // already in vadPending; the in-flight drain will process them.
        guard !isDrainingVAD, var currentVadState = vadState else { return }
        isDrainingVAD = true
        defer { isDrainingVAD = false }

        while vadPending.count >= VadManager.chunkSize {
            let chunk = Array(vadPending.prefix(VadManager.chunkSize))
            vadPending.removeFirst(VadManager.chunkSize)

            let result: VadStreamResult
            do {
                result = try await vad.processStreamingChunk(
                    chunk,
                    state: currentVadState,
                    config: segmentationConfig
                )
            } catch {
                log.error("VAD failed: \(error.localizedDescription)")
                return
            }
            // stop() may have run during the await — it already flushed the
            // in-progress segment as the session tail, so acting on this
            // (stale) VAD result would double-transcribe it.
            guard isActive else { return }
            currentVadState = result.state
            vadState = currentVadState

            guard let event = result.event else { continue }
            switch event.kind {
            case .speechStart:
                currentSpeechStart = event.sampleIndex
                lastSpeculativeSampleCount = event.sampleIndex
            case .speechEnd:
                guard let start = currentSpeechStart else { continue }
                let clampedStart = max(0, min(start, sessionSamples.count))
                let clampedEnd = max(clampedStart, min(event.sampleIndex, sessionSamples.count))
                currentSpeechStart = nil
                guard clampedEnd > clampedStart else { continue }
                let segment = Array(sessionSamples[clampedStart..<clampedEnd])
                enqueueTranscribe(samples: segment)
            }
        }

        maybeRunSpeculative()
    }

    /// While the user is still speaking, re-transcribe the in-progress speech
    /// segment every ~1.2s and show it as volatile text. The confirmed segment
    /// replaces this on speechEnd.
    private func maybeRunSpeculative() {
        guard let start = currentSpeechStart else { return }
        let total = sessionSamples.count
        guard total - lastSpeculativeSampleCount >= speculativeIntervalSamples else { return }
        guard total - start >= speculativeMinSpeechSamples else { return }

        lastSpeculativeSampleCount = total
        // Cap the preview window — see `speculativeMaxWindowSamples`. The
        // guard identity stays `start` (the segment's true beginning) so
        // performSpeculative's relevance check still works.
        let windowStart = max(start, total - speculativeMaxWindowSamples)
        let segment = Array(sessionSamples[windowStart..<total])
        enqueueSpeculative(samples: segment, segmentStart: start)
    }

    /// Transcribe segments in the order they arrive by chaining Tasks.
    private func enqueueTranscribe(samples: [Float]) {
        let previous = transcribeChain
        let sessionID = currentSessionID
        transcribeChain = Task { [weak self] in
            await previous?.value
            await self?.performTranscribe(samples: samples, sessionID: sessionID)
        }
    }

    private func performTranscribe(samples: [Float], sessionID: UUID) async {
        guard let asr = asrManager else { return }
        do {
            let result = try await asr.transcribe(samples, source: .microphone)
            let cleaned = Self.cleanTranscript(result.text)
            await MainActor.run {
                // cancel() bumps the session ID; a chained transcribe from a
                // discarded session must not resurrect its text.
                guard sessionID == self.currentSessionID else { return }
                if !cleaned.isEmpty {
                    if self.confirmedText.isEmpty {
                        self.confirmedText = cleaned
                    } else {
                        self.confirmedText += " " + cleaned
                    }
                }
                // This segment is confirmed — drop any volatile text that was
                // showing a preview of it.
                self.volatileText = ""
                self.state.liveTranscript = self.displayText()
            }
        } catch {
            log.error("Transcribe failed: \(error.localizedDescription)")
        }
    }

    private func enqueueSpeculative(samples: [Float], segmentStart: Int) {
        let previous = transcribeChain
        let sessionID = currentSessionID
        transcribeChain = Task { [weak self] in
            await previous?.value
            await self?.performSpeculative(samples: samples, segmentStart: segmentStart, sessionID: sessionID)
        }
    }

    private func performSpeculative(samples: [Float], segmentStart: Int, sessionID: UUID) async {
        // Skip if the user already paused (speechEnd fired) — the confirmed
        // transcribe is about to run and supersede this anyway. Session-ID
        // check because sample offsets reset each recording, so segmentStart
        // alone can collide across sessions and leak a stale preview into a
        // new one.
        guard sessionID == currentSessionID, currentSpeechStart == segmentStart, isActive else { return }
        guard let asr = asrManager else { return }
        do {
            let result = try await asr.transcribe(samples, source: .microphone)
            let cleaned = Self.cleanTranscript(result.text)
            await MainActor.run {
                // Re-check relevance: the segment may have ended or a new one
                // started by the time the transcribe returned.
                guard sessionID == self.currentSessionID,
                      self.isActive, self.currentSpeechStart == segmentStart else { return }
                self.volatileText = cleaned
                self.state.liveTranscript = self.displayText()
            }
        } catch {
            log.error("Speculative transcribe failed: \(error.localizedDescription)")
        }
    }

    /// RMS amplitude of the first channel of `buffer`. Returns roughly 0 for
    /// silence; typical speech reads 0.02–0.3 on a typical built-in mic. Used
    /// purely for the overlay's level visualizer; not in the ASR path. Handles
    /// both float and int16 input formats — the engine tap on Apple Silicon is
    /// almost always float, but Intel Macs and external interfaces can deliver
    /// int16 and we shouldn't go silent in the UI.
    private static func rmsLevel(of buffer: AVAudioPCMBuffer) -> Float {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return 0 }

        if let channelData = buffer.floatChannelData {
            let samples = channelData[0]
            var sumSquares: Float = 0
            for i in 0..<frameCount {
                let s = samples[i]
                sumSquares += s * s
            }
            return sqrtf(sumSquares / Float(frameCount))
        }
        if let channelData = buffer.int16ChannelData {
            let samples = channelData[0]
            var sumSquares: Float = 0
            for i in 0..<frameCount {
                let s = Float(samples[i]) / Float(Int16.max)
                sumSquares += s * s
            }
            return sqrtf(sumSquares / Float(frameCount))
        }
        return 0
    }

    /// Regex matching filler words ("uh", "um", "hmm", "mhm" and obvious
    /// repetitions like "uhhh") as standalone words — not substrings — so we
    /// don't eat real tokens like "umbrella". The er/ah/mm families were
    /// removed: `e+r+` matched the real word "err", `a+h+` matched the
    /// interjection "ah" people dictate on purpose, and `mm+` matched the
    /// unit ("5 mm bolt"). uh/um cover the overwhelming majority of what the
    /// ASR actually emits. Optional trailing comma or period gets swallowed
    /// with the filler.
    private static let fillerWordRegex: NSRegularExpression = {
        let pattern = #"(?i)\b(?:u+h+m*|u+m+h*|hmm+|mhm+)\b[,\.]?\s*"#
        return try! NSRegularExpression(pattern: pattern)
    }()

    private static func cleanTranscript(_ raw: String) -> String {
        let range = NSRange(raw.startIndex..., in: raw)
        var text = fillerWordRegex.stringByReplacingMatches(
            in: raw,
            options: [],
            range: range,
            withTemplate: ""
        )
        // Tidy up double spaces and stranded leading punctuation the model may
        // leave behind (e.g. "um, hello" → ", hello" → "hello").
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = text.first, ",.;:!?".contains(first) {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    private func displayText() -> String {
        switch (confirmedText.isEmpty, volatileText.isEmpty) {
        case (true, true):   return ""
        case (false, true):  return confirmedText
        case (true, false):  return volatileText
        case (false, false): return confirmedText + " " + volatileText
        }
    }

    private func ensureMicPermission() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return
        case .notDetermined:
            if await AVCaptureDevice.requestAccess(for: .audio) { return }
            throw TranscriptionError.microphoneDenied
        case .denied, .restricted:
            throw TranscriptionError.microphoneDenied
        @unknown default:
            throw TranscriptionError.microphoneDenied
        }
    }

    private func ensureLoaded() async throws -> (AsrManager, VadManager) {
        if let asr = asrManager, let vad = vadManager { return (asr, vad) }
        if let existing = loadingTask {
            return try await existing.value
        }

        state.status = .preparing("Loading transcription model…")

        let task = Task<(AsrManager, VadManager), Error> { @MainActor in
            let mlConfig = MLModelConfiguration()
            mlConfig.computeUnits = .cpuAndNeuralEngine

            let modelDir = try await self.ensureModelsLocally()

            state.status = .preparing("Preparing speech model for your Mac…")
            log.info("Loading ASR model from \(modelDir.path, privacy: .public)")

            let asrModels: AsrModels
            do {
                asrModels = try await AsrModels.load(
                    from: modelDir,
                    configuration: mlConfig,
                    version: .v2
                )
            } catch {
                // A freshly-downloaded model that fails to load is almost
                // always bytes on disk that CoreML can't parse — wipe and
                // retry once before giving up.
                log.error("Initial model load failed (\(error.localizedDescription)); clearing cache and retrying.")
                try? FileManager.default.removeItem(at: Self.cachedModelDir())
                let freshModelDir = try await self.ensureModelsLocally()
                asrModels = try await AsrModels.load(
                    from: freshModelDir,
                    configuration: mlConfig,
                    version: .v2
                )
            }

            let asr = AsrManager(config: .default)
            try await asr.loadModels(asrModels)

            state.status = .preparing("Loading voice detector…")
            let vadConfig = VadConfig(computeUnits: .cpuAndNeuralEngine)
            let vad: VadManager
            if let vadBase = Self.bundledVADBaseURL() {
                log.info("Loading bundled VAD from \(vadBase.path, privacy: .public)")
                vad = try await VadManager(config: vadConfig, modelDirectory: vadBase)
            } else {
                log.info("Bundled VAD missing, downloading Silero VAD from HuggingFace")
                vad = try await VadManager(config: vadConfig)
            }

            // Warm up first-inference compile paths. Without this, the user's
            // first real transcribe on a fresh install pays a 5–10s CoreML
            // warmup cost and feels broken. One silent chunk each is enough.
            state.status = .preparing("Warming up…")
            log.info("Warming up ASR + VAD with silent chunks")
            await Self.warmUp(asr: asr, vad: vad)

            return (asr, vad)
        }
        loadingTask = task

        do {
            let (asr, vad) = try await task.value
            self.asrManager = asr
            self.vadManager = vad
            return (asr, vad)
        } catch {
            loadingTask = nil
            throw error
        }
    }

    private static let modelSubpath = "Models/parakeet-tdt-0.6b-v2"
    private static let requiredModelFiles = [
        "Preprocessor.mlmodelc",
        "Encoder.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    /// Small model pieces that ship inside the app bundle. The big
    /// `Encoder.mlmodelc` (~445MB) is downloaded on first launch so the DMG
    /// stays small.
    private static let bundledSmallModelFiles = [
        "Preprocessor.mlmodelc",
        "Decoder.mlmodelc",
        "JointDecision.mlmodelc",
        "parakeet_vocab.json",
    ]

    private static let encoderDownloadURL = URL(string:
        "https://github.com/tmoreton/yaprflow/releases/download/models-v2/parakeet-v2-encoder.tar.gz"
    )!

    /// Full bundle (dev builds with the encoder still in the repo). If every
    /// file is in the bundle, we use it directly.
    private static func fullBundledModelDir() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent(modelSubpath, isDirectory: true)
        return allModelFilesPresent(in: dir) ? dir : nil
    }

    /// Production bundle (encoder stripped). Returns the bundle dir if the
    /// small files are present — they'll be copied into the writable cache.
    private static func partialBundledModelDir() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let dir = resources.appendingPathComponent(modelSubpath, isDirectory: true)
        let fm = FileManager.default
        for file in bundledSmallModelFiles where !fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
            return nil
        }
        return dir
    }

    /// Writable cache location that `AsrModels.load` reads from. In a
    /// sandboxed app this resolves under the app's container.
    private static func cachedModelDir() -> URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        return appSupport
            .appendingPathComponent("FluidAudio", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
            .appendingPathComponent("parakeet-tdt-0.6b-v2", isDirectory: true)
    }

    private static func allModelFilesPresent(in dir: URL) -> Bool {
        let fm = FileManager.default
        for file in requiredModelFiles where !fm.fileExists(atPath: dir.appendingPathComponent(file).path) {
            return false
        }
        return true
    }

    private func ensureModelsLocally() async throws -> URL {
        // Dev builds with the encoder still in the repo.
        if let bundle = Self.fullBundledModelDir() {
            return bundle
        }

        // Cache already populated from a previous launch and looks healthy.
        let cacheDir = Self.cachedModelDir()
        if Self.cacheLooksHealthy(cacheDir) {
            return cacheDir
        }

        // Anything less than a healthy cache — partial download, partial
        // extraction, corrupt bytes — wipe and start over. Re-downloading 400MB
        // is slower than shipping with a broken model.
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            log.info("Cache at \(cacheDir.path, privacy: .public) is incomplete; clearing before re-populating.")
            try? FileManager.default.removeItem(at: cacheDir)
        }

        try await populateModelCache(cacheDir)

        guard Self.cacheLooksHealthy(cacheDir) else {
            // Populate succeeded but the files still don't look right — fail
            // loudly rather than load a broken model.
            try? FileManager.default.removeItem(at: cacheDir)
            throw NSError(domain: "yaprflow.model", code: 2, userInfo: [
                NSLocalizedDescriptionKey:
                    "Model files look incomplete after download. Please try again — if it keeps failing, your network may be blocking GitHub releases."
            ])
        }
        return cacheDir
    }

    /// A "healthy" cache has all required files AND the encoder's weight file
    /// is at least 100 MB (uncompressed encoder weights are ~400 MB). This
    /// catches partial extractions where the directory exists but its contents
    /// are truncated.
    private static func cacheLooksHealthy(_ dir: URL) -> Bool {
        guard allModelFilesPresent(in: dir) else { return false }
        let weightFile = dir
            .appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
            .appendingPathComponent("weights", isDirectory: true)
            .appendingPathComponent("weight.bin")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: weightFile.path),
              let size = attrs[.size] as? Int64,
              size > 100_000_000
        else {
            return false
        }
        return true
    }

    private func populateModelCache(_ cacheDir: URL) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)

        guard let partial = Self.partialBundledModelDir() else {
            throw NSError(domain: "yaprflow.model", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    "Bundled model files missing — please reinstall Yaprflow."
            ])
        }

        // Copy small pieces from bundle → cache (only ones not already present).
        for name in Self.bundledSmallModelFiles {
            let src = partial.appendingPathComponent(name)
            let dst = cacheDir.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { continue }
            if src.hasDirectoryPath {
                try fm.copyItem(at: src, to: dst)
            } else {
                try fm.copyItem(at: src, to: dst)
            }
        }

        // Download + extract Encoder if not already there.
        if !fm.fileExists(atPath: cacheDir.appendingPathComponent("Encoder.mlmodelc").path) {
            try await downloadAndExtractEncoder(into: cacheDir)
        }
    }

    /// Run a silent chunk through both models so CoreML's per-device
    /// compile + first-inference warmup happens during preload, not on the
    /// user's first real dictation. Any error here is swallowed — the worst
    /// case is the original slow-first-call behaviour.
    private static func warmUp(asr: AsrManager, vad: VadManager) async {
        do {
            let oneSecondOfSilence = [Float](repeating: 0.0, count: 16_000)
            _ = try await asr.transcribe(oneSecondOfSilence, source: .microphone)
        } catch {
            log.info("ASR warmup skipped: \(error.localizedDescription, privacy: .public)")
        }

        do {
            let chunk = [Float](repeating: 0.0, count: VadManager.chunkSize)
            let state = await vad.makeStreamState()
            _ = try await vad.processStreamingChunk(chunk, state: state)
        } catch {
            log.info("VAD warmup skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func downloadAndExtractEncoder(into cacheDir: URL) async throws {
        state.status = .preparing("Downloading speech model... 0%")
        log.info("Downloading encoder from \(Self.encoderDownloadURL.absoluteString, privacy: .public)")

        let delegate = EncoderDownloadDelegate()
        let session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        let (tempURL, response) = try await session.download(from: Self.encoderDownloadURL)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            try? FileManager.default.removeItem(at: tempURL)
            throw NSError(domain: "yaprflow.download", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Download failed (HTTP \(http.statusCode))"
            ])
        }

        state.status = .preparing("Extracting speech model...")

        // Extract into a staging sibling directory first; only move into the
        // real cache if tar succeeds AND the expected files are there. This
        // way a crashed/killed extract can never leave a half-written
        // Encoder.mlmodelc that fools cacheLooksHealthy on the next launch.
        let fm = FileManager.default
        let stagingDir = cacheDir
            .deletingLastPathComponent()
            .appendingPathComponent(".encoder-staging-\(UUID().uuidString)", isDirectory: true)
        try? fm.removeItem(at: stagingDir)
        try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: stagingDir) }

        log.info("Extracting encoder into staging \(stagingDir.path, privacy: .public)")

        let tar = Process()
        tar.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        tar.arguments = ["-xzf", tempURL.path, "-C", stagingDir.path]
        let errPipe = Pipe()
        tar.standardError = errPipe

        try tar.run()
        tar.waitUntilExit()

        try? fm.removeItem(at: tempURL)

        guard tar.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let errStr = String(data: errData, encoding: .utf8) ?? "unknown"
            throw NSError(domain: "yaprflow.extract", code: Int(tar.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "Extract failed (exit \(tar.terminationStatus)): \(errStr)"
            ])
        }

        // Verify the encoder extracted correctly before promoting.
        let extractedEncoder = stagingDir.appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
        let extractedWeight = extractedEncoder
            .appendingPathComponent("weights", isDirectory: true)
            .appendingPathComponent("weight.bin")
        guard fm.fileExists(atPath: extractedEncoder.path),
              let attrs = try? fm.attributesOfItem(atPath: extractedWeight.path),
              let size = attrs[.size] as? Int64,
              size > 100_000_000
        else {
            throw NSError(domain: "yaprflow.extract", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "Extracted encoder looks incomplete — weight file missing or truncated. Try again."
            ])
        }

        // Atomic-ish promote. Same filesystem, rename is atomic.
        let finalEncoder = cacheDir.appendingPathComponent("Encoder.mlmodelc", isDirectory: true)
        try? fm.removeItem(at: finalEncoder)
        try fm.moveItem(at: extractedEncoder, to: finalEncoder)
    }

    private static let vadModelFile = "silero-vad-unified-256ms-v6.0.0.mlmodelc"

    /// Returns the base directory that `VadManager(modelDirectory:)` expects —
    /// it internally appends `Models/silero-vad/<file>`. We bundle the model at
    /// `<Resources>/Models/silero-vad/...`, so `Resources` is the right base.
    private static func bundledVADBaseURL() -> URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let modelPath = resources
            .appendingPathComponent("Models/silero-vad", isDirectory: true)
            .appendingPathComponent(vadModelFile, isDirectory: true)
        guard FileManager.default.fileExists(atPath: modelPath.path) else { return nil }
        return resources
    }

    private func scheduleAutoHide(after seconds: Double) {
        autoHideTask?.cancel()
        autoHideTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(seconds))
            } catch {
                return
            }
            state.status = .idle
            state.liveTranscript = ""
            NotchOverlayWindowController.shared.hide()
        }
    }
}

/// URLSession delegate that pushes download progress into AppState.status so
/// the overlay shows "Downloading speech model... 42%" during first launch.
private final class EncoderDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let pct = Int((fraction * 100).rounded())
        Task { @MainActor in
            AppState.shared.status = .preparing("Downloading speech model... \(pct)%")
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        // Intentionally empty — URLSession's async `download(from:)` moves the
        // file to a temp location and returns its URL from the awaited call.
    }
}
