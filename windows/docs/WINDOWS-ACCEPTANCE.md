# Windows hardware acceptance

Record tester, date, Windows build, CPU, RAM, microphone and artifact SHA-256. CI proves buildability and selected Windows runtime paths; it cannot validate a real microphone, keyboard, Bluetooth driver, sleep/resume, or third-party app behavior.

Before offering beyond a preview test group:

- Install as a standard user on Windows 11 x64 without a developer SDK. Setup, tray, uninstall and reinstall work. Check publisher signature on the public artifact.
- First model download completes; cancel and restart; disconnect internet mid-download and retry. Confirm no partial model becomes Ready. Restart offline and dictate.
- Test built-in microphone, USB headset and Bluetooth mic. Select another input. Unplug during recording. Deny microphone access then re-enable and retry.
- In Notepad, Word, Chrome/Edge forms, Outlook, Teams, VS Code and a terminal, verify accurate text, Unicode, replacement of selection and original clipboard contents.
- Start in one field, move to another field in the SAME window, finish: no text should be inserted. Repeat switching apps/windows and closing the target. Transcript must remain recoverable in History.
- Password fields: never insert or read field contents. Elevated app: do not elevate yaprflow; gracefully withhold/retain transcript if input is blocked.
- Hold, release before microphone startup completes, rapidly repeat, cancel during recognition, toggle twice, and alternate primary/external shortcuts. No late delivery, stuck recording or overlapping native decode.
- Register a conflicting shortcut in another app. Apply it in yaprflow: retain the previously working trigger. Test second shortcut and disable it.
- Escape, on-screen Cancel, tray Cancel and Finish all work; ten-minute stop works. Test sleep/resume and screen lock during recording.
- History search/copy/delete/clear work. Turning history off stops future disk writes of transcripts; quitting removes in-memory-only result. Existing saved history can still be explicitly cleared.
- Vocabulary does not replace inside longer names and does not cascade replacements. Test apostrophes, Hawaiian names, punctuation and case.
- Launch with Windows app mode set to both Light and Dark; Settings labels, buttons, tabs and dropdowns remain readable.
- Keyboard navigation and Narrator labels work. Check 100%, 150%, 200% display scaling, high contrast, multiple monitors, small laptop window and tray overflow.
- Time cold startup and final-text latency for 5-, 30-, and 120-second dictations on at least an ordinary Intel and AMD laptop; include quiet and noisy audio. Compare transcript quality with the Mac app on the same recordings.

Known limitations must be listed with the preview. Do not mark a row passed based only on a successful compile or unit test.

## Recorded 0.2.1 acceptance

- September 30, 2026: Michael accepted the revised interface and sound cues on the existing AMD Windows 11 test PC.
- This confirms visual and listening acceptance only. Streaming, cancellation, microphone reconnect, offline relaunch and the other hardware checks remain pending unless separately recorded.

## Preview 0.2.0 additions

- Streaming with tap-to-toggle: phrases arrive at pauses, with no duplication at final stop. Change focus mid-stream and verify later phrases are withheld. Cancel after one insertion and verify nothing further arrives. Hold modifier keys and confirm text queues until release.
- Unplug/replug the selected microphone and verify the same endpoint stays selected; unplug while recording and confirm cancellation and a useful notice. Check the Windows default input separately.
- Test left and right Ctrl+Shift gestures, wrong-side combinations, ordinary Ctrl+Shift shortcuts, extra modifiers, double-tap lock, next-tap finish, Escape and the regular shortcut still available.
- Import a short mono/stereo WAV, preview both cues, reset, change volume and mute cues. Confirm only yaprflow volume changes. Invalid/long files should fail with a clear message.
- Download/cancel/retry AI Polish, then restart offline. Enable Polish and check latency, names/numbers and Copy original; interrupt during polishing and confirm no late insertion. Basic speech works without this optional model.
- With correction learning off, no observation occurs. Enable it, edit one name in the just-used field, wait for a suggestion, then accept/dismiss. Move focus, edit surrounding text, use a password field or perform a broad rewrite; no suggestion should be learned. Only approved vocabulary persists.
