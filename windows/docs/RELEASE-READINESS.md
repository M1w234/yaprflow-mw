# Windows parity and release readiness

Updated October 1, 2026. Preview 0.2.2 is an integrated Deskling candidate; physical acceptance remains outstanding.

## Implemented in 0.2.1

- Refined native sidebar, setting switches, help hierarchy and compact recording panel.
- Soft, Wood and Glass original sound pairs plus Classic, independent cue preview and existing WAV overrides. New cues have rounded attacks/tails and lower level; sound-off, volume and custom imports are preserved.

## Implemented in 0.2.0

- Direct streaming: completed phrases at quiet boundaries, with a revisable live draft. Insertion is held while modifier keys are down; tap-to-toggle is recommended. No rewriting of already inserted text. Cancel cannot remove text already sent.
- Flat settings navigation: Dictation, Shortcuts, Sound, Privacy, Models, History, Vocabulary. Native Segoe UI controls, keyboard labels, scrolling, high-contrast colors where available.
- Stable microphone endpoint IDs with periodic device refresh; reconnecting the selected input does not silently switch it. Input loss cancels the session. Legacy numeric selections migrate only if uniquely identifiable.
- Soft original cues, independent volume, preview, and local mono/stereo WAV imports up to three seconds, limited to a safe peak in the imported file.
- Optional side-specific Ctrl+Shift hold, double-tap lock, next-tap finish. Extra modifiers/ordinary shortcuts reject the gesture. The registered primary and external shortcuts remain available. Escape/on-screen cancel and ten-minute cap remain.
- Optional built-in offline AI Polish using Qwen3 0.6B Q8_0 and LLamaSharp CPU. Extra 610 MiB checksum-verified download, no other app. Each completed phrase is polished before insertion; this adds latency. Original transcript remains in History; cancellation and failed/oversized/number-changing output preserve original text. This is grammar cleanup, not summarization.
- Opt-in learned correction suggestions: only the exact non-password field just used, at most 20 seconds while focused, bounded document size, small stable word edits. No field contents saved; suggestions are memory-only until reviewed in Vocabulary.

## Evidence

- Current 0.2.1 at `8f9121d` passed [Windows CI](https://github.com/M1w234/yaprflow-mw/actions/runs/36838662515): 55 behavior tests, all seven native sections, all sound presets/assets, compact layout and overlay focus checks, real Parakeet and Qwen inference, installer/uninstaller. Screenshots reviewed. Installer exit 0 on the AMD PC; version 0.2.1.0, preferences/history/speech marker hashes preserved, optional Polish model present. Dictation and Sound windows visually confirmed through RustDesk, and remote navigation to Sound worked. New Soft preset defaults without changing 35% volume, sound enabled state, tap-to-toggle or other existing preferences. Michael confirmed the new interface looks better and the sound cues sound better. Streaming, cancellation and microphone reconnect on this candidate remain pending physical acceptance.

- Prior 0.1.1 passed CI, installer upgrade preserving settings/history/model, and Michael's physical microphone dictation/browser insertion/quit-relaunch tests.
- Previous 0.2.0 at fe6f416 passed [Windows CI](https://github.com/M1w234/yaprflow-mw/actions/runs/36819840085): all 54 behavior tests, native UI/shortcut checks, real speech and Polish inference, installer/uninstaller. Rendered screenshots were reviewed. Installed version 0.2.0.0 is running on the AMD PC; installer preserved settings/history and the existing speech model. Streaming is configured with tap-to-toggle. Optional Polish model is downloaded and verified; Polish remains off. The new app window has not yet been visually confirmed on that desktop because automated RustDesk input did not reliably act on Windows.
- Microphone reconnect, streaming while speaking, modifier lock, custom sound listening, correction observation and AI Polish latency need a physical PC acceptance pass after upgrade.
- Remote SSH/RustDesk reconnection after reboot passed previously; pre-login access remains unobserved. Remote access is test infrastructure, never a customer requirement.

## Signing and Deskling integration

October 1, 2026: 0.2.2 adds a loopback-only Deskling client for Start, Stop, Cancel and toggle recording. Only coarse state is published. Commands are acknowledged once; reconnect rotates the client token so stale work is discarded. A lost relay cancels a recording started through the screen. The existing target-field, cancellation and recording-duration protections remain in use.

Submit remains unavailable (`canSubmit=false`) because Windows does not implement the Mac one-shot insertion receipt. No synthesized Enter is sent. Streaming is optional and is not a bundle release gate per Michael's instruction.

The signed 0.2.2 app, own assemblies, installer and generated uninstaller passed Windows trust and timestamp verification with publisher Michael Wong. All 64 behavior tests and the installed interactive UI smoke passed. The upgrade preserved existing data. The preceding 0.2.1 signing-source CI also completed successfully.

`windows/scripts/bundle-deskling.py` creates a separate integrated Windows gift candidate from an existing Deskling Windows recipient package and the signed installer. It adds Windows installer signature/hash validation and connection checking without changing firmware or the original Deskling package. Physical screen acceptance is separate from software relay testing.

## Before public release

1. Complete WINDOWS-ACCEPTANCE.md on this candidate, especially wrong-field prevention, cancel, unplug/replug, long speech and offline relaunch.
2. Test a typical Intel laptop as well as the AMD desktop. Measure CPU latency and memory for streaming plus Polish. x64 only; no ARM support claim.
3. Verify installer upgrade preserving settings/history/vocabulary/custom cues/models and sign-in launch.
4. Private beta, publisher signing, downloaded-installer verification and honest feature notes. Automatic updates and summarization remain out of scope.
5. Review/merge the PR and publish separately approved signed artifacts/checksums with distinct Mac/Windows downloads.
