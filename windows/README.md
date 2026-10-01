# yaprflow for Windows

A Windows companion to the native Mac app. **Preview 0.2.1 — Windows 11 on Intel/AMD x64.**
Uses local Parakeet TDT 0.6B v2 through sherpa-onnx. No account, Python installation, NVIDIA GPU, or separate .NET installation is required for the packaged app.

## Get started

1. Run the Windows preview setup executable, or unzip the portable build into a permanent folder and open `yaprflow.exe`. Keep its DLLs alongside it.
2. In Settings, download the speech model (460 MB; allow 2 GB free during installation). The download and model files are checked against pinned SHA-256 hashes.
3. Wait for **Ready**. Focus a normal text field in another app.
4. Hold **Ctrl + Alt + Space**, speak, then release. Choose **Tap to toggle** in Settings if preferred.
5. If insertion is withheld, open **History**, select the transcript, and click **Copy transcript**.

Closing the settings window leaves yaprflow in the system tray. Use the tray's **Quit** command to stop it. Windows may hide the tray icon behind the overflow arrow.

Unsigned preview builds may receive Windows reputation warnings. A signed, hardware-tested public release is a separate release step; do not advertise this preview as production-ready.

## Included

- Local CPU speech recognition with the same Parakeet v2 model family as the Mac app.
- Configurable key-based hold/toggle shortcuts; optional independent mouse-mapped shortcut.
- Microphone selection, soft start/stop cues with independent volume and previews, nonactivating recording pill with level meter.
- Escape, pill and tray cancel; ten-minute recording limit; no late text insertion after cancellation.
- Original-field checks, password-field rejection, Unicode insertion that never changes the clipboard.
- Local history (up to 200 entries), search, explicit copy/delete, and opt-out for future history.
- Personal vocabulary, literal phrase replacements and conservative light cleanup.
- Checksummed model setup with cancel/retry; tray behavior and optional launch at sign-in.
- Self-contained portable package and per-user installer/uninstaller.

## Intentional preview limits

- Preview 0.2.0 adds streaming at speech pauses, side-specific modifier gestures/double-tap lock, optional local AI Polish, and reviewed correction suggestions. Screen context, summarization, and automatic application of learned corrections are not included.
- With streaming off, recognition completes after release. Long audio uses bounded chunks, preferring quiet boundaries; this needs testing on continuous speech and noisy microphones.
- Some applications expose no safely identifiable editable field. Insertion is withheld there. Administrator/elevated applications may also reject synthetic input. Recover the transcript manually; yaprflow does not elevate itself, press Enter, or automatically resend.
- Input dispatch is best-effort: a successful Windows `SendInput` call confirms dispatch, not that the receiving app accepted the text. Check the field before retrying.
- The UI currently offers a microphone list from startup. Restart yaprflow after adding or removing devices if the list is stale.
- Windows ARM64, Windows 10, and older PCs are not validated. Minimum practical RAM/CPU guidance awaits hardware testing; no latency guarantee is made.
- No automatic updates yet. A newer installer upgrades the same per-user location.

## Privacy and local files

Audio is held in memory and discarded after the session; it is never written to disk or uploaded. Setup contacts GitHub and its download hosts for public model files. Recognition makes no network requests. No telemetry is implemented.

Settings, vocabulary, model files, and plain-text history are in `%LOCALAPPDATA%\YaprFlow`. Turning History off stops saving future transcripts and keeps the latest result in memory; clear existing saved history explicitly. Uninstall preserves this directory. To remove all local data, quit the app and delete the directory yourself.

## Build and test

Install the .NET 10 SDK. From PowerShell at the repository root:

```powershell
./windows/scripts/build.ps1
# Also create an installer (requires Inno Setup 6):
./windows/scripts/build.ps1 -Installer
# Optional Windows code-signing certificate already in your certificate store:
./windows/scripts/build.ps1 -Installer -CertificateThumbprint YOUR_THUMBPRINT
```

Artifacts appear under `windows/artifacts/`. The script runs behavior tests, publishes a self-contained x64 app, checks native DLLs, and creates a portable zip. CI also exercises native window rendering, model installation and real inference, and installer/uninstaller execution. CI never publishes a GitHub release.

Cross-platform logic tests can run on macOS:

```sh
dotnet test windows/tests/YaprFlow.Tests
dotnet build windows/src/YaprFlow.Windows -p:EnableWindowsTargeting=true
```

Real inference check using a mono 16 kHz PCM16 WAV:

```sh
dotnet run --project windows/tools/YaprFlow.Smoke -- /path/to/model /path/to/sample.wav --install
```

`--archive /path/to/model.tar.bz2` supports the same checksummed installer using a previously downloaded official archive. `yaprflow.exe --smoke-ui <output-directory>` renders each native tab and writes a smoke receipt, using a fresh temporary user-data folder with no personal history. This is a build verification tool, not a full keyboard/accessibility test.

## Organization

- `src/YaprFlow.Core`: portable session state machine, persistence, settings and text processing.
- `src/YaprFlow.Speech`: pinned model distribution, verified installation, sherpa-onnx inference.
- `src/YaprFlow.Windows`: native WPF UI, Win32 hotkeys, microphone capture, UI Automation and insertion.
- `tests/YaprFlow.Tests`: cancellation/race tests, text behavior, persistence, model integrity and segmentation.
- `docs/WINDOWS-ACCEPTANCE.md`: the physical-PC check before wider distribution.

Mac remains in the existing Swift project. Vocabulary concepts and cleanup behavior match the Mac version; Windows settings use their own schema and are not directly interchangeable with the Mac preferences file. There is no cross-device synchronization.

## Preview 0.2.0

Choose tap-to-toggle in **Shortcuts** for direct streaming. Completed phrases are inserted when you pause; held Ctrl/Alt keys queue text until released. A live draft can change until committed. Cancel stops new insertions; words already sent remain in the destination. If focus changes, remaining text stays in History.

**Models** offers an optional 610 MiB AI Polish download. Enable it in Dictation after downloading. Grammar cleanup runs entirely inside yaprflow on the CPU and can slow streaming. History includes Copy original. Speech recognition works without the Polish model.

**Vocabulary** can suggest corrections you make immediately after dictation. This is off by default and only observes the same non-password field for up to 20 seconds; approve a suggestion before it becomes a rule. Suggestions are not saved automatically.

**Sound** supports quiet original cues, independent volume, and custom WAV imports. **Dictation** refreshes microphones automatically and remembers the selected device across reconnects. **Shortcuts** adds optional left/right Ctrl+Shift hold and double-tap lock.

This preview needs hardware acceptance before public release. See docs/RELEASE-READINESS.md for evidence and remaining gates.

## Preview 0.2.1

A quieter sound palette and a refined native settings interface. In **Sound**, choose **Soft**, **Wood**, **Glass**, or the original **Classic**, then use **Preview start** and **Preview stop**. Soft is the new default; volume, disabled sounds and imported WAVs are preserved. Imports override the selected style until **Use selected style** is chosen for that cue.

Settings now use a persistent sidebar, grouped switch rows and clearer help. The recording panel fits the draft instead of reserving empty space. Native keyboard navigation, high-contrast settings, and nonactivating recording controls remain in place.
