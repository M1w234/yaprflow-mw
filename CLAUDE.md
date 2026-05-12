# yaprflow-mw — Local Dictation App (Patched Fork)

Local-first macOS menubar dictation app. Cloned from [tmoreton/yaprflow](https://github.com/tmoreton/yaprflow) (Apache-2.0) and patched with additional push-to-talk modes. Local STT via Parakeet TDT 0.6B v2 on the Neural Engine. Swift / AppKit / Carbon hotkey API.

If you're a developer looking at this for the first time, start with [README.md](README.md) → "Install (build from source)". This file is context for Claude Code (and future you) — gotchas, architecture, and the rebuild loop.

## Quick Status

| Thing | Where |
|-------|-------|
| Source | this repo |
| Built app | `build/Build/Products/Release/yaprflow.app` |
| Installed app | `/Applications/yaprflow.app` |
| Bundle ID | `com.tmoreton.yaprflow` (unchanged from upstream) |
| Saved hotkey config | `~/Library/Containers/com.tmoreton.yaprflow/Data/Library/Preferences/com.tmoreton.yaprflow.plist` |
| Speech model | `Models/parakeet-tdt-0.6b-v2/` (~450 MB, gitignored) |
| Signing | Ad-hoc (no Developer ID). Gatekeeper quarantine stripped on install. |

## Rebuild Loop (after editing source)

One command:

```bash
./scripts/dev-build.sh
```

Quits the running yaprflow, builds Release with ad-hoc signing, replaces `/Applications/yaprflow.app`, strips quarantine, relaunches. First build ~3 min; incremental builds ~30 sec.

Manual equivalent:
```bash
xcodebuild -project yaprflow.xcodeproj -scheme yaprflow -configuration Release \
  -derivedDataPath build CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO
osascript -e 'tell application "yaprflow" to quit'
rm -rf /Applications/yaprflow.app
cp -R build/Build/Products/Release/yaprflow.app /Applications/
xattr -dr com.apple.quarantine /Applications/yaprflow.app
open /Applications/yaprflow.app
```

## Architecture (the parts that matter)

- **Sandboxed** (`yaprflow/yaprflow.entitlements`): app-sandbox + audio-input + network.client. Affects what hotkey APIs are usable.
- **Two hotkey backends** that swap based on binding shape:
  - `GlobalHotkey.swift` — Carbon `RegisterEventHotKey`. Sandbox-safe. Used for normal chord bindings (e.g. ⌘T, ⌃⌥Space, F13). Supports pressed + released events.
  - `ModifierOnlyHotkey.swift` — listen-only `CGEventTap` on `flagsChanged` + `keyDown`. Used when the binding is modifier-only (e.g. ⌘⇧ alone, no third key). Requires Accessibility permission. Implements **both** hold-to-talk and double-tap-to-lock concurrently; disambiguates by tracking whether a non-modifier keyDown or extra modifier interrupted the chord. ⌘⇧+3, ⌘⇧+letter, etc. pass through untouched.
  - `AppDelegate.registerHotkey()` picks exactly one backend per binding via `HotkeyConfig.isModifierOnly`. The inactive backend is always unregistered.
- **Synchronized file groups**: `yaprflow.xcodeproj` uses Xcode 16's `PBXFileSystemSynchronizedRootGroup` — new `.swift` files dropped into `yaprflow/` are auto-picked-up by the project. No `.pbxproj` editing needed.
- **Speech pipeline**: `TranscriptionController` → `AudioCapture` → VAD (`FluidAudio`) → Parakeet ASR (CoreML `.mlmodelc` bundles in `Models/`). Final text → clipboard.
- **Grammar mode (optional)**: `GrammarController` runs a small MLX LLM on the transcript before pasting.
- **Menu**: `AppDelegate.installStatusItem()` builds the menu from custom NSView-based items (`HotkeyMenuItemView`, `HotkeyModeMenuItemView`, `StreamingModeMenuItemView`, etc.). All toggle-style items follow the same NSView pattern.

## Patches Applied (vs. upstream tmoreton/yaprflow)

| File | Change |
|------|--------|
| `HotkeyConfig.swift` | Added `HotkeyMode` enum (`tapToToggle` \| `holdToTalk`), back-compat `decodeIfPresent` for the `mode` field. Added F13–F19, arrow, Page/Home/End labels in `displayString`. Added `modifierOnlyKeyCode` sentinel + `isModifierOnly` / `isValid` for modifier-only bindings. |
| `GlobalHotkey.swift` | Installed `kEventHotKeyReleased` handler alongside the existing pressed handler. `onFire` → `onPressed` + `onReleased`. |
| `ModifierOnlyHotkey.swift` (new) | `CGEventTap`-based backend for modifier-only bindings. Dual-gesture state machine: hold-to-talk + double-tap-to-lock both always active. Handles `tapDisabledByTimeout` / `tapDisabledByUserInput` re-enable. |
| `TranscriptionController.swift` | Added `desiredActive` flag + `setActive(_:)` method. Race-safe push-to-talk: `start()` re-checks `desiredActive` after each `await` and bails if user already released. |
| `AppDelegate.swift` | `registerHotkey()` switches backends based on `config.isModifierOnly`. `wireHotkeyCallbacks(for:)` dispatches based on `config.mode` for chord bindings. Re-wires on `yaprflowHotkeyChanged`. |
| `HotkeyMenuItemView.swift` | Removed "must have a modifier" guard so picker accepts F-keys, Space, etc. Recorder polls `NSEvent.modifierFlags` on a `.common`-mode `Timer` to capture modifier-only bindings during NSMenu tracking (NSMenu swallows `flagsChanged` before local monitors see it). |
| `HotkeyModeMenuItemView.swift` (new) | Toggle row in menu: "Tap to Toggle" ↔ "Hold to Talk". Greys out to "Hold + Double-tap" when the binding is modifier-only (both gestures always on). |

## Constraints / Gotchas

- **No Developer ID cert** — must build with `CODE_SIGN_IDENTITY=-`. App runs locally but can't be distributed via notarization. Don't try `scripts/release.sh`.
- **Metal Toolchain** — Xcode 16+ ships without it by default. If a fresh Xcode install fails the first build with `cannot execute tool 'metal'`, run `xcodebuild -downloadComponent MetalToolchain` (~700 MB one-time).
- **Models** — `Models/parakeet-tdt-0.6b-v2/` must exist before the build (the Copy Models phase fails otherwise). The upstream `scripts/fetch-models.sh` is brittle: (1) the `models-v2` GitHub release tarball may 404, and (2) the script calls `hf`, which may resolve to the higgsfield CLI on systems that have it installed instead of HuggingFace. Use `huggingface-cli` directly:
  ```bash
  HF_HUB_DISABLE_XET=1 huggingface-cli download FluidInference/parakeet-tdt-0.6b-v2-coreml \
    --include "Preprocessor.mlmodelc/*" "Encoder.mlmodelc/*" "Decoder.mlmodelc/*" \
              "JointDecision.mlmodelc/*" "parakeet_vocab.json" \
    --local-dir Models/parakeet-tdt-0.6b-v2
  ```
- **AX TCC after rebuild** — ad-hoc signed builds get a fresh code-directory hash each build, which silently invalidates the existing Accessibility grant *even though the System Settings switch still shows "on."* Symptoms: auto-paste stops working, modifier-only hotkey stops firing. Fix:
  ```bash
  tccutil reset Accessibility com.tmoreton.yaprflow
  ```
  Then re-grant when prompted (or via System Settings → Privacy & Security → Accessibility).
- **First recording delay** — ~30s on a cold launch while the Parakeet Encoder compiles. `TranscriptionController.preload()` runs at launch to warm this in the background.
- **Mic permission** — granted in System Settings → Privacy → Microphone (yaprflow). Carries across builds since the bundle ID is stable.
- **Stale Xcode Debug builds** — if you launch yaprflow from Xcode at any point, a Debug copy lives in DerivedData and may stay running after you switch back to dev-build. Symptom: the menu bar icon looks right but the hotkey behaves like an older build. Fix: `ps -ax | grep yaprflow.app/Contents/MacOS`, kill anything outside `/Applications/`, relaunch from `/Applications/yaprflow.app`.

## Common Tasks

- **"Add a new hotkey mode / trigger"** — for non-modifier-only bindings: touch `HotkeyMode` enum + `GlobalHotkey` callbacks + `AppDelegate.wireHotkeyCallbacks` + add a UI affordance. For modifier-only bindings: extend `ModifierOnlyHotkey`'s state machine.
- **"Improve the menu UI"** — copy the `StreamingModeMenuItemView` / `HotkeyModeMenuItemView` pattern. Custom NSView, layout in `setupLayout()`, refresh on Combine subscription, mutate `AppState` on `mouseDown`.
- **"Bump the speech model"** — update the `Models/` Copy Models phase reference in `.pbxproj` and the download command above.
- **"Make this push upstream"** — `git remote add upstream https://github.com/tmoreton/yaprflow`, push branch, open a PR. Re-test under their Developer ID signing path before submitting.

## Don't Bother

- Adding `NSAccessibilityUsageDescription` to `Info.plist` — that's a microphone-style usage string and isn't the right key for AX prompts.
- Trying to keep the app sandboxed AND adopt `NSEvent` global monitors for `flagsChanged` without TCC permission — doesn't work. Use the `CGEventTap` route via `ModifierOnlyHotkey.swift`.
- Looking for a build-cache shortcut — `xcodebuild` already caches SPM packages, MLX, etc. in `build/SourcePackages/`. Don't `git clean -fdx` that dir unless you want a fresh ~3 min build.
