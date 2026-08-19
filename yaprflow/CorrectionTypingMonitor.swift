import AppKit
import Carbon.HIToolbox
import CoreGraphics
import OSLog

private let log = Logger(subsystem: "com.teamwong.yaprflow", category: "CorrectionTyping")

/// Last-resort correction observation for web/contenteditable controls that
/// expose neither ranged text nor AXValue. The listen-only tap is installed
/// for at most 25 seconds, filters immediately to the original target app, and
/// retains at most a short post-edit typing burst. It never blocks or changes
/// an event and never persists the burst; a suggestion still requires explicit
/// confirmation before VocabularyStore is touched.
@MainActor
final class CorrectionTypingMonitor {
    static let shared = CorrectionTypingMonitor()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var deadlineTask: Task<Void, Never>?
    private var evaluationTask: Task<Void, Never>?
    private var deferredActionTask: Task<Void, Never>?
    private var targetPID: pid_t?
    private var originalText = ""
    private var typedBurst = ""
    private var sawEditGesture = false
    private var isFinishing = false
    private var onCandidate: ((CorrectionCandidate) -> Void)?

    private let observationDuration: Duration = .seconds(25)
    private let quietInterval: Duration = .milliseconds(900)
    private let maximumBurstLength = 80

    private init() {}

    @discardableResult
    func begin(
        originalText: String,
        targetPID: pid_t,
        onCandidate: @escaping (CorrectionCandidate) -> Void
    ) -> Bool {
        cancel()
        self.originalText = originalText
        self.targetPID = targetPID
        self.onCandidate = onCandidate

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.tapDisabledByTimeout.rawValue) |
            (1 << CGEventType.tapDisabledByUserInput.rawValue)
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<CorrectionTypingMonitor>
                    .fromOpaque(refcon).takeUnretainedValue()
                monitor.handleFromTap(type: type, event: event)
                return Unmanaged.passUnretained(event)
            },
            userInfo: userInfo
        ) else {
            log.info("Typing fallback unavailable: listen-only event tap could not be created")
            cancel()
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        runLoopSource = source
        deadlineTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: self?.observationDuration ?? .seconds(25))
            guard !Task.isCancelled else { return }
            self?.cancel()
        }
        log.info("Typing fallback active for target app")
        return true
    }

    func cancel() {
        deadlineTask?.cancel()
        deadlineTask = nil
        evaluationTask?.cancel()
        evaluationTask = nil
        deferredActionTask?.cancel()
        deferredActionTask = nil
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            self.runLoopSource = nil
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            self.tap = nil
        }
        targetPID = nil
        originalText = ""
        typedBurst = ""
        sawEditGesture = false
        isFinishing = false
        onCandidate = nil
    }

    nonisolated private func handleFromTap(type: CGEventType, event: CGEvent) {
        let typeRaw = type.rawValue
        let eventPID = event.getIntegerValueField(.eventTargetUnixProcessID)
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flagsRaw = event.flags.rawValue
        if typeRaw == CGEventType.tapDisabledByTimeout.rawValue
            || typeRaw == CGEventType.tapDisabledByUserInput.rawValue {
            MainActor.assumeIsolated {
                if let tap = self.tap { CGEvent.tapEnable(tap: tap, enable: true) }
            }
            return
        }

        // Check the immutable event metadata and current target context before
        // materializing any key characters. Events for other apps are never
        // converted into text, even transiently.
        let acceptsEvent = MainActor.assumeIsolated {
            self.acceptsEvent(eventPID: eventPID)
        }
        guard acceptsEvent else { return }
        let characters = type == .keyDown ? NSEvent(cgEvent: event)?.characters : nil
        MainActor.assumeIsolated {
            self.process(
                typeRaw: typeRaw,
                eventPID: eventPID,
                keyCode: keyCode,
                flagsRaw: flagsRaw,
                characters: characters
            )
        }
    }

    private func acceptsEvent(eventPID: Int64) -> Bool {
        guard !isFinishing,
              let targetPID,
              AppState.shared.learnFromCorrections,
              !AutoPaste.isSecureInputEnabled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            scheduleCancel()
            return false
        }
        let typedEventPID = pid_t(eventPID)
        return typedEventPID == 0 || typedEventPID == targetPID
    }

    private func process(
        typeRaw: UInt32,
        eventPID: Int64,
        keyCode: Int64,
        flagsRaw: UInt64,
        characters: String?
    ) {
        guard !isFinishing,
              let targetPID,
              AppState.shared.learnFromCorrections,
              !AutoPaste.isSecureInputEnabled,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else {
            scheduleCancel()
            return
        }

        if typeRaw == CGEventType.leftMouseDown.rawValue {
            if presentCandidateIfAvailable() { return }
            sawEditGesture = true
            typedBurst = ""
            evaluationTask?.cancel()
            return
        }
        guard typeRaw == CGEventType.keyDown.rawValue else { return }

        let typedEventPID = pid_t(eventPID)
        guard typedEventPID == 0 || typedEventPID == targetPID else { return }
        let typedKeyCode = CGKeyCode(keyCode)

        switch Int(typedKeyCode) {
        case kVK_Escape:
            scheduleCancel()
            return
        case kVK_Return, kVK_ANSI_KeypadEnter, kVK_Tab:
            if presentCandidateIfAvailable() { return }
            scheduleCancel()
            return
        case kVK_Delete:
            if sawEditGesture, !typedBurst.isEmpty {
                typedBurst.removeLast()
                if typedBurst.isEmpty {
                    evaluationTask?.cancel()
                } else {
                    scheduleEvaluation()
                }
                return
            }
            sawEditGesture = true
            typedBurst = ""
            evaluationTask?.cancel()
            return
        case kVK_ForwardDelete,
             kVK_LeftArrow, kVK_RightArrow, kVK_UpArrow, kVK_DownArrow,
             kVK_Home, kVK_End, kVK_PageUp, kVK_PageDown:
            sawEditGesture = true
            typedBurst = ""
            evaluationTask?.cancel()
            return
        default:
            break
        }

        let flags = CGEventFlags(rawValue: flagsRaw)
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            if presentCandidateIfAvailable() { return }
            // A cut/paste or selection shortcut is an edit signal, but the
            // clipboard and command payload are deliberately not inspected.
            sawEditGesture = true
            typedBurst = ""
            evaluationTask?.cancel()
            return
        }
        guard sawEditGesture,
              let characters,
              !characters.isEmpty,
              characters.unicodeScalars.allSatisfy({
                !CharacterSet.controlCharacters.contains($0)
              }) else {
            return
        }

        typedBurst.append(contentsOf: characters)
        if typedBurst.count > maximumBurstLength {
            typedBurst = String(typedBurst.suffix(maximumBurstLength))
        }
        scheduleEvaluation()
    }

    private func scheduleEvaluation() {
        evaluationTask?.cancel()
        evaluationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: self?.quietInterval ?? .milliseconds(900))
            } catch {
                return
            }
            guard let self,
                  !Task.isCancelled else { return }
            if !presentCandidateIfAvailable() {
                log.info("Typing fallback ignored an ambiguous edit")
            }
        }
    }

    /// Finish immediately when the buffered edit is already a safe match.
    /// This lets a click, Return, Tab, or shortcut after the correction act as
    /// a boundary instead of discarding a valid name before the quiet timer.
    private func presentCandidateIfAvailable() -> Bool {
        guard !typedBurst.isEmpty, let onCandidate else { return false }
        do {
            let candidate = try CorrectionInference.inferFromTypedCorrection(
                original: originalText,
                typedCorrection: typedBurst
            )
            log.info("Typing fallback found a likely correction")
            isFinishing = true
            evaluationTask?.cancel()
            evaluationTask = nil
            deferredActionTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled else { return }
                self.cancel()
                onCandidate(candidate)
            }
            return true
        } catch {
            return false
        }
    }

    /// Event-tap callbacks return before their run-loop source is invalidated.
    /// This avoids tearing down the CFMachPort or presenting UI reentrantly
    /// from inside the callback that is currently using it.
    private func scheduleCancel() {
        guard !isFinishing else { return }
        isFinishing = true
        evaluationTask?.cancel()
        evaluationTask = nil
        deferredActionTask = Task { @MainActor [weak self] in
            guard let self, !Task.isCancelled else { return }
            self.cancel()
        }
    }
}
