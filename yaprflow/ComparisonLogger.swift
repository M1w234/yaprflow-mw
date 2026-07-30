import Foundation
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "ComparisonLog")

/// Local half of the side-by-side dictation study.
///
/// Yaprflow deliberately does not reach into Wispr Flow while dictation is
/// happening. Wispr already persists a richer, app-independent record in its
/// local `History` table (raw text, formatted text, recording duration, target
/// app, and end-to-end latency). A later analysis pass pairs the two local
/// histories by recording end time and transcript similarity.
///
/// This keeps normal use simple and reliable:
///   - Wispr Flow remains the only user-facing inserter.
///   - Yaprflow records/transcribes/cleans silently.
///   - Neither app's clipboard behavior matters.
///   - Chrome, Codex, native apps, and custom editors all use the same path.
///   - Raw + deterministic Light output flush immediately.
///   - A no-context Polish candidate runs later from an idle, serial queue.
///
/// Transcript and Polish-result records share a session ID and are appended to
/// `Application Support/yaprflow/comparison-log.jsonl`. Keeping them as
/// separate append-only records makes the raw evidence durable even when the
/// app quits before a background Polish job finishes.
@MainActor
final class ComparisonLogger {
    static let shared = ComparisonLogger()
    private static let schemaVersion = 2
    private static let shadowPolishIdleDelay: Duration = .seconds(3)

    private struct PreparedSession {
        let sessionID: UUID
        var recordingStartedAt: Date?
        var recordingStoppedAt: Date?
    }

    private struct PendingEntry {
        let sessionID: UUID
        let asrReadyAt: Date
        let recordingStartedAt: Date?
        let recordingStoppedAt: Date?
        let raw: String
        let cleanupMode: String
        let streamingMode: Bool
        let appVersion: String?
        var selectedOutput: String?
        var yaprReadyAt: Date?
    }

    private struct TranscriptLogLine: Encodable {
        let schemaVersion: Int
        let recordType: String
        let ts: Date
        let sessionID: UUID
        let peerSource: String
        let raw: String
        let light: String
        let cleanupMode: String
        let streamingMode: Bool
        let appVersion: String?
        /// Backward-compatible alias for the output selected by the app's
        /// current cleanup mode.
        let polished: String?
        let selectedOutput: String?
        let recordingStartedAt: Date?
        let recordingStoppedAt: Date?
        let yaprASRReadyMs: Int?
        let yaprReadyMs: Int?
        let shadowPolishExpected: Bool
        let grammarModelID: String
        let grammarPromptVersion: String
    }

    private struct PolishJob {
        let sessionID: UUID
        let raw: String
        let queuedAt: Date
        let recordingStoppedAt: Date?
    }

    private struct PolishResultLogLine: Encodable {
        let schemaVersion: Int
        let recordType: String
        let ts: Date
        let sessionID: UUID
        let polish: String?
        let polishStatus: String
        let polishError: String?
        let polishContext: String
        let grammarModelID: String
        let grammarPromptVersion: String
        let polishQueuedAt: Date
        let polishStartedAt: Date?
        let polishReadyAt: Date
        let polishQueueWaitMs: Int?
        let polishInferenceMs: Int?
        let polishReadyFromRecordingStopMs: Int?
    }

    private let fileURL: URL
    private var preparedSession: PreparedSession?
    /// Delivery can finish after a newer recording starts. Keep base entries
    /// session-keyed until their selected output is known.
    private var pending: [UUID: PendingEntry] = [:]
    private var polishQueue: [PolishJob] = []
    private var polishWorkerTask: Task<Void, Never>?
    private var recordingInProgress = false
    private var isTerminating = false

    private init() {
        let fm = FileManager.default
        let appSupport = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = appSupport.appendingPathComponent("yaprflow", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        self.fileURL = dir.appendingPathComponent("comparison-log.jsonl")
    }

    /// Start a new comparison session. A new hotkey press is an unambiguous
    /// recording boundary; any older async Polish entry remains session-keyed
    /// until its own result arrives.
    func prepareSession(sessionID: UUID) {
        guard AppState.shared.comparisonLogMode else {
            preparedSession = nil
            return
        }
        // Pause shadow inference as soon as the hotkey is pressed, before ASR
        // warmup or microphone activation. A cancelled job is re-queued.
        recordingInProgress = true
        polishWorkerTask?.cancel()
        preparedSession = PreparedSession(
            sessionID: sessionID,
            recordingStartedAt: nil,
            recordingStoppedAt: nil
        )
    }

    /// Stamp the moment the microphone actually becomes live, after any cold
    /// model warmup or permission wait.
    func recordingDidStart(sessionID: UUID) {
        recordingInProgress = true
        polishWorkerTask?.cancel()
        guard var prepared = preparedSession, prepared.sessionID == sessionID else { return }
        prepared.recordingStartedAt = Date()
        preparedSession = prepared
    }

    /// Stamp hotkey release immediately, before local transcription begins.
    func recordingDidStop(sessionID: UUID) {
        if var prepared = preparedSession, prepared.sessionID == sessionID {
            prepared.recordingStoppedAt = Date()
            preparedSession = prepared
        }
        recordingInProgress = false
        startPolishWorkerIfPossible()
    }

    /// Resume deferred comparison work after an explicitly cancelled
    /// recording without emitting a transcript record for that session.
    func cancelSession(sessionID: UUID) {
        if preparedSession?.sessionID == sessionID {
            preparedSession = nil
        }
        pending.removeValue(forKey: sessionID)
        recordingInProgress = false
        startPolishWorkerIfPossible()
    }

    /// Record Yaprflow's raw ASR result. The final cleaned result follows
    /// synchronously for Off/Light or asynchronously for Polish.
    func beginCapture(sessionID: UUID, raw: String) {
        guard AppState.shared.comparisonLogMode, !raw.isEmpty else { return }

        let prepared = preparedSession?.sessionID == sessionID ? preparedSession : nil
        preparedSession = nil
        pending[sessionID] = PendingEntry(
            sessionID: sessionID,
            asrReadyAt: Date(),
            recordingStartedAt: prepared?.recordingStartedAt,
            recordingStoppedAt: prepared?.recordingStoppedAt,
            raw: raw,
            cleanupMode: AppState.shared.cleanupMode.rawValue,
            streamingMode: AppState.shared.streamingMode,
            appVersion: Bundle.main.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            selectedOutput: nil,
            yaprReadyAt: nil
        )
    }

    /// Persist raw/Light/current-mode output immediately, then enqueue a
    /// separate no-context Polish candidate for the same session.
    func recordDelivered(sessionID: UUID, text: String) {
        guard var entry = pending.removeValue(forKey: sessionID) else { return }
        entry.selectedOutput = text
        entry.yaprReadyAt = Date()
        writeTranscript(entry)
        enqueueShadowPolish(for: entry)
    }

    func flush() {
        isTerminating = true
        polishWorkerTask?.cancel()
        let entries = pending.values.sorted { $0.asrReadyAt < $1.asrReadyAt }
        pending.removeAll()
        for entry in entries {
            writeTranscript(entry)
        }
    }

    private func writeTranscript(_ entry: PendingEntry) {
        let line = TranscriptLogLine(
            schemaVersion: Self.schemaVersion,
            recordType: "transcript",
            ts: entry.asrReadyAt,
            sessionID: entry.sessionID,
            peerSource: "wisprFlowLocalHistory",
            raw: entry.raw,
            light: LightCleanup.apply(entry.raw),
            cleanupMode: entry.cleanupMode,
            streamingMode: entry.streamingMode,
            appVersion: entry.appVersion,
            polished: entry.selectedOutput,
            selectedOutput: entry.selectedOutput,
            recordingStartedAt: entry.recordingStartedAt,
            recordingStoppedAt: entry.recordingStoppedAt,
            yaprASRReadyMs: Self.milliseconds(
                from: entry.recordingStoppedAt,
                to: entry.asrReadyAt
            ),
            yaprReadyMs: Self.milliseconds(
                from: entry.recordingStoppedAt,
                to: entry.yaprReadyAt
            ),
            shadowPolishExpected: true,
            grammarModelID: GrammarController.correctionModelID,
            grammarPromptVersion: GrammarController.correctionPromptVersion
        )
        append(line)
    }

    private func enqueueShadowPolish(for entry: PendingEntry) {
        polishQueue.append(PolishJob(
            sessionID: entry.sessionID,
            raw: entry.raw,
            queuedAt: Date(),
            recordingStoppedAt: entry.recordingStoppedAt
        ))
        startPolishWorkerIfPossible()
    }

    /// Run at most one grammar evaluation at a time, after a short idle grace
    /// period. Starting a new recording cancels and re-queues the active job.
    private func startPolishWorkerIfPossible() {
        guard !isTerminating,
              AppState.shared.comparisonLogMode,
              !recordingInProgress,
              polishWorkerTask == nil,
              !polishQueue.isEmpty else { return }

        let job = polishQueue.removeFirst()
        polishWorkerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var startedAt: Date?
            do {
                try await Task.sleep(for: Self.shadowPolishIdleDelay)
                try Task.checkCancellation()
                guard !self.recordingInProgress else {
                    throw CancellationError()
                }

                startedAt = Date()
                let candidate = try await GrammarController.shared.correct(
                    text: job.raw,
                    progress: { _ in }
                )
                try Task.checkCancellation()
                let readyAt = Date()
                self.writePolishResult(
                    job: job,
                    candidate: candidate,
                    error: nil,
                    startedAt: startedAt,
                    readyAt: readyAt
                )
            } catch is CancellationError {
                if !self.isTerminating {
                    self.polishQueue.insert(job, at: 0)
                }
            } catch {
                let readyAt = Date()
                self.writePolishResult(
                    job: job,
                    candidate: nil,
                    error: error.localizedDescription,
                    startedAt: startedAt,
                    readyAt: readyAt
                )
            }

            self.polishWorkerTask = nil
            self.startPolishWorkerIfPossible()
        }
    }

    private func writePolishResult(
        job: PolishJob,
        candidate: String?,
        error: String?,
        startedAt: Date?,
        readyAt: Date
    ) {
        let line = PolishResultLogLine(
            schemaVersion: Self.schemaVersion,
            recordType: "polishResult",
            ts: readyAt,
            sessionID: job.sessionID,
            polish: candidate,
            polishStatus: error == nil ? "completed" : "failed",
            polishError: error,
            polishContext: "none",
            grammarModelID: GrammarController.correctionModelID,
            grammarPromptVersion: GrammarController.correctionPromptVersion,
            polishQueuedAt: job.queuedAt,
            polishStartedAt: startedAt,
            polishReadyAt: readyAt,
            polishQueueWaitMs: Self.milliseconds(from: job.queuedAt, to: startedAt),
            polishInferenceMs: Self.milliseconds(from: startedAt, to: readyAt),
            polishReadyFromRecordingStopMs: Self.milliseconds(
                from: job.recordingStoppedAt,
                to: readyAt
            )
        )
        append(line)
    }

    private func append<T: Encodable>(_ line: T) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(line) else { return }
        data.append(0x0A)

        let fm = FileManager.default
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            log.info("Appended shadow comparison record")
        } else {
            log.error("Could not append to comparison log")
        }
    }

    private static func milliseconds(from start: Date?, to end: Date?) -> Int? {
        guard let start, let end else { return nil }
        return max(0, Int((end.timeIntervalSince(start) * 1_000).rounded()))
    }
}
