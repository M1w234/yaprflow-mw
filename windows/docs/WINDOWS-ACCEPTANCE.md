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
- Keyboard navigation and Narrator labels work. Check 100%, 150%, 200% display scaling, high contrast, multiple monitors, small laptop window and tray overflow.
- Time cold startup and final-text latency for 5-, 30-, and 120-second dictations on at least an ordinary Intel and AMD laptop; include quiet and noisy audio. Compare transcript quality with the Mac app on the same recordings.

Known limitations must be listed with the preview. Do not mark a row passed based only on a successful compile or unit test.
