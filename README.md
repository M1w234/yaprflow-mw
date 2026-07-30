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
- ⌨️ **F-key hotkeys** — F13–F19, arrow keys, Page/Home/End are all bindable. No more "must include a modifier" guard.
- 🎵 **Start / stop chimes** — soft system sounds confirm the mic is open and closed. Togglable.
- 🪟 **Wispr-style overlay** — floating pill at the bottom-center of the screen with three audio-level bars that bounce as you speak.
- 🔒 **100% local** — audio never leaves your Mac. No accounts, no telemetry.
- ✍️ **Three cleanup levels** — Off preserves the transcript, Light performs
  instant mechanical cleanup without rephrasing, and optional Polish uses an
  on-device MLX model for stronger punctuation and grammar edits.
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
