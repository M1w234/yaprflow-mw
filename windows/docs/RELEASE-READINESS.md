# Windows parity and release readiness

Updated September 30, 2026. The Windows companion is a private preview, not a full Mac feature match. Public release has not been approved or published.

## Current evidence

- Windows CI passed at 3418c73: build, native UI/shortcut checks, real CPU model inference, installer/uninstaller.
- Michael confirmed physical microphone dictation, Ctrl+Alt+Space, browser insertion, and dictation after quitting/reopening on a Ryzen 9 Windows 11 PC.
- Mac verified SSH and RustDesk reconnection after a real Windows restart. SSH returned after a delay; pre-login access was not observed. Remote access is test infrastructure, not a customer requirement.
- Preview 0.1.1 replaces Windows notification sounds with original, short start/stop cues. Defaults to 35% app-local volume; adds volume control and previews. Perceived loudness still needs Michael's listening check.

## Feature comparison

| Area | Windows state | Recommendation |
| --- | --- | --- |
| Offline Parakeet dictation | Implemented and user-tested on one PC | Test a typical Intel laptop and longer/noisy speech |
| Hold/toggle keyboard shortcuts and separate mouse mapping | Implemented; primary hold user-tested | Exercise toggle, conflicts, cancellation, and mouse mapping |
| Safe insertion, history, vocabulary | Implemented; browser insertion user-tested | Complete app/field switching, clipboard, password-field, and history checks |
| Recording cues | Quiet original cues and independent volume in 0.1.1 | Listen on the PC and tune defaults if needed |
| Custom sound selection/import | Mac supports it; Windows currently has a fixed cue pair | Optional follow-up, not required for dependable dictation |
| Microphone changes | List collected when Settings is constructed; numeric device selection | Refresh devices and preserve selection reliably across reconnects before broad release |
| Startup, tray, installer | Implemented | Verify sign-in launch and actual upgrade on physical PC |
| Modifier-only gestures and double-tap lock | Not implemented | Separate Windows hotkey design/test effort; do not advertise parity |
| Streaming partial text | Not implemented | Follow-up; Windows currently finalizes on release |
| AI Polish/summarization and learned corrections | Not implemented | Separate local inference/privacy work; document clearly |
| ARM Windows and automatic updates | Not validated / not implemented | Ship x64 scope and manual updates first |

## Gates before broad public release

1. Finish microphone reconnection/selection behavior and verify the complete installer upgrade preserves settings, history, and models.
2. Complete windows/docs/WINDOWS-ACCEPTANCE.md, prioritizing no wrong-field insertion, cancellation, microphone loss, offline relaunch, and long recordings. Track evidence, not inferred passes.
3. Test one ordinary Intel laptop as well as the existing AMD desktop; measure recognition latency and memory, and establish honest minimum requirements.
4. Run a small private beta with clear preview labeling, known limitations, and a feedback route.
5. Review code/dependency licenses and model notices; arrange Windows publisher signing, verify signatures, and test downloaded installer behavior. Signing alone does not guarantee immediate Windows reputation.
6. Review/merge the companion PR, publish the approved signed artifacts with checksums and release notes, and create one download page with separate Mac and Windows choices and explicit feature differences.

Full Mac feature parity is not needed for a scoped Windows release. Reliability, clear feature claims, and a reproducible installer are needed. No signing credential, public deployment, or release publication is part of the sound change.
