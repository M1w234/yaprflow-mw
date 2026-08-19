<div align="center">
  <img src="yaprflow/Assets.xcassets/AppIcon.appiconset/icon_256.png" width="128" alt="Yaprflow">
  <h1>Yaprflow MW</h1>
  <p><strong>Private, offline dictation for macOS — Wispr Flow style.</strong></p>
  <p>Hold your hotkey. Speak. Release. The text appears in the focused field.</p>
</div>

---

A personal fork of [tmoreton/yaprflow](https://github.com/tmoreton/yaprflow) with the features I wanted for daily dictation. Same local-first speech pipeline (Parakeet TDT 0.6B on the Neural Engine), same Apache-2.0 license, same menubar app — plus a handful of additions:

- ⌨️ **Automatic insertion** — writes the transcript directly into the focused
  text field without replacing your clipboard. Focus-race guarded (it will not
  type into a different window if you switch apps mid-recording) and disabled
  for secure-input fields.
- ⏯️ **Hold-to-talk OR tap-to-toggle** — pick whichever feel fits the hotkey. Hold-to-talk supports modifier chords; tap-to-toggle is one press to start, one to stop.
- 🖱️ **Independent external-button shortcut** — keep your keyboard shortcut and
  add a second key-based trigger for Logitech Options+ or other mouse-remapping
  software, with its own tap-to-toggle or hold-to-talk mode.
- ⌨️ **F-key hotkeys** — F13–F19, arrow keys, Page/Home/End are all bindable. No more "must include a modifier" guard.
- 🎵 **Personalized start / stop chimes** — adjust Yaprflow's volume, choose bundled or macOS sounds, or import a local WAV, AIFF, M4A, MP3, or CAF file.
- 🪟 **Wispr-style overlay** — floating pill at the bottom-center of the screen with three audio-level bars that bounce as you speak.
- 🔒 **100% local** — audio never leaves your Mac. No accounts, no telemetry.
- ✍️ **Three cleanup levels** — Off preserves the transcript, Light performs
  instant mechanical cleanup without rephrasing, and optional Polish uses an
  on-device MLX model for stronger punctuation and grammar edits.
- 📖 **Personal corrections** — teach names and recurring mis-hearings from a
  searchable Vocabulary window or directly from History. Optional same-field
  learning notices a distinctive name you correct after automatic insertion,
  then asks you to confirm, edit, or dismiss the suggestion. It runs locally
  and ignores broad rewrites and secure fields.
- 📝 **Summarize** — condense any transcript on demand (inherited from upstream).

## Install

The easiest path is the notarized disk image on the
[latest GitHub Release](https://github.com/M1w234/yaprflow-mw/releases/latest).
Download the `.dmg`, open it, and drag **yaprflow** to Applications. The speech
model is already bundled, and the app is signed and notarized by Apple.
[SETUP.md](SETUP.md) has the complete permission walkthrough.

**Requires an Apple-silicon Mac (M1 or newer) running macOS 14 Sonoma or later.**

### Build from source

Install the Hugging Face CLI first, then:

```bash
git clone https://github.com/M1w234/yaprflow-mw.git
cd yaprflow-mw
./scripts/fetch-models.sh
./scripts/dev-build.sh
```

`dev-build.sh` does the full loop: builds Release, applies the stable local
signing identity when available, replaces `/Applications/yaprflow.app`, strips
Gatekeeper quarantine, and relaunches. ~3 min cold, ~30 s incremental.

## Enabling Automatic Insertion

Automatic Insertion needs macOS Accessibility permission so Yaprflow can type
into the field you were using:

1. Click the waveform icon in your menubar → **Automatic Insertion**
2. Grant in **System Settings → Privacy & Security → Accessibility** when prompted
3. The menu row should now read **Ready** instead of **Needs Permission**

If you ever rebuild from source, you may need to re-grant — ad-hoc signed apps get a fresh code-directory hash each build, which can invalidate the TCC entry. Quickest reset:

```bash
tccutil reset Accessibility com.teamwong.yaprflow
```

Then click **Automatic Insertion** in the menu again to re-prompt.

## Teaching Names and Corrections

Open the waveform menu → **Vocabulary…**, then add both the spelling you want
and what Yaprflow heard. For an existing transcript, open **History…**,
right-click it, and choose **Correct & Learn…**. The correction is saved locally
and applied to future final transcripts.

**Learn from corrections** is optional and requires Automatic Insertion. When
enabled, Yaprflow briefly watches the range it just inserted, plus small
in-memory boundary checks. Compatibility fields that expose only their current
composer value may require that value to be read transiently; it is immediately
reduced to the inserted segment and boundary anchors and is not retained. If
you correct one distinctive name or term in that
same field, Yaprflow asks you to confirm or edit the localized replacement
before saving it. If a web field exposes neither ranged text nor its current
value, a listen-only event tap runs for at most 25 seconds and retains only a
short typing burst after an edit gesture in the original target app. It cannot
block or alter typing, and the burst is never persisted. Yaprflow never learns
from secure fields or turns broad sentence rewrites into global rules. During
that brief window, events outside the original app are discarded before their
characters are read. Avoid entering sensitive information in a non-secure field
of that same app until the correction prompt appears or the window ends.

## Using a Programmable Mouse Button

1. Click the waveform icon → **External Button**.
2. Leave the external shortcut at its default, `⌃⌥⌘Space`, or record a new
   key-based shortcut twice.
3. Choose **Tap to Toggle** or **Hold to Talk**, then turn **Enabled** on.
4. In Logitech Options+ (or your mouse software), assign the same keystroke to
   the mouse button.
5. If another dictation app should keep using your main keyboard shortcut, set
   **Keyboard Shortcut** to **Paused** in the External Button submenu.

This second trigger is independent. Enabling, disabling, or changing it does
not replace the saved main Yaprflow keyboard shortcut. Pausing that shortcut
only stops listening for it; its keys and trigger mode remain saved. Turning
the external button off—or failing to register it—automatically restores the
keyboard shortcut so Yaprflow is never left without a trigger. Tap to Toggle
is the most compatible option; Hold to Talk requires the remapping software to
preserve both key-down and key-up events.

## What's deliberately different from upstream

- **Distinct bundle ID** (`com.teamwong.yaprflow`) so this fork has its own
  signing identity, settings container, and macOS permission records.
- **Notarized releases** — downloadable `.dmg` files are Developer ID signed,
  submitted to Apple's notary service, stapled, and Gatekeeper-checked before
  publishing.
- **Overlay position moved** from top-of-screen (notch-attached) to bottom-center, where Wispr Flow puts theirs.

## Credits

- All the heavy lifting (ASR pipeline, MLX integration, menubar architecture, grammar correction) is [Tim Moreton's](https://github.com/tmoreton). This fork only adds UX polish on top.
- Speech model: [FluidInference's Parakeet TDT 0.6B v2 (CoreML)](https://huggingface.co/FluidInference/parakeet-tdt-0.6b-v2-coreml), CC-BY-4.0.

## License

Apache 2.0, same as upstream.
