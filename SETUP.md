# yaprflow — Setup

**yaprflow** is a privacy-first, on-device dictation app for macOS. Hold a
hotkey, talk, and your words are transcribed and inserted into the field you
were using — entirely locally, with nothing sent to the cloud.

**Compatibility:** Apple-silicon Mac (M1 or newer) running macOS 14 Sonoma or
later. This build does not run on Intel Macs.

---

## Easiest install

Download the `.dmg` from the
[latest release](https://github.com/M1w234/yaprflow-mw/releases/latest), open
it, and drag **yaprflow** to **Applications**. Then continue at Step 2 below for
the one-time macOS permissions.

## Install it with Claude Code (or Codex)

Open Claude Code (or Codex) anywhere, and say:

> Read SETUP.md from https://github.com/M1w234/yaprflow-mw and set up yaprflow on my Mac — do the command-line steps for me and walk me through the permission clicks. Adapt to whatever macOS shows.

The agent then follows the steps below. (You can also just do them yourself.)

---

## Steps

**Agent: run the shell steps for the user; guide them through the clicks they must do themselves. This is a real, self-contained app — the ~450 MB speech model is bundled, so there's no separate model download and it runs offline.**

### 0. Download the notarized app
No building required — grab the ready-to-run disk image from the latest release:
```bash
cd ~/Downloads
curl -L -o yaprflow.dmg \
  https://github.com/M1w234/yaprflow-mw/releases/latest/download/yaprflow.dmg
open yaprflow.dmg
```

### 1. Install
Drag **yaprflow** from the opened disk image into **Applications**, then launch
it from Applications.

### 2. If macOS says it "can't be opened" / "cannot check for malicious software"
This release is signed and notarized by Apple, so that message is not expected.
Delete the download and get a fresh copy from the GitHub release. Do not bypass
Gatekeeper for a file from another source.

### 3. Follow the first-run guide
Yaprflow opens a short setup guide automatically. Keep the recommended defaults:

- **Single-shot transcription** for the best accuracy
- **Light cleanup** for instant cleanup without rephrasing
- **Automatic Insertion** so dictation appears in the focused field without
  replacing the clipboard

The final screen shows the default shortcut and confirms setup is complete. You
can reopen this guide later from the waveform menu → **Setup Guide…**.

### 4. Grant Microphone access
- The setup guide asks for Microphone access → click **Allow**.
- Or manually: **System Settings → Privacy & Security → Microphone → turn on yaprflow.**

### 5. Grant Accessibility access (required for the hotkey + Automatic Insertion)
```bash
open "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
```
- If **yaprflow** is listed, turn it **on**. If not, click **➕**, choose **Applications → yaprflow**, turn it on.
- The hotkey comes alive within a few seconds — no restart needed.

### 6. Use it
- **Hold ⌥⇧ (Option+Shift) and talk**, then release → your words appear.
- Or **double-tap ⌥⇧** to lock recording on; tap again to stop.

### 7. Optional — use the Globe 🌐 key instead (MacBook laptops only)

**Agent: ask first — "Are you on a MacBook laptop, and would you rather use the 🌐 (Globe/Fn) key at the bottom-left as your dictation key instead of ⌥⇧?" If no, or they're on a desktop / external keyboard with no Globe key, SKIP this step — you're done.**

If yes, free the Globe key from its default job first (on most Macs it opens the Emoji picker, which would conflict with the shortcut):

1. Open Keyboard settings and set **"Press 🌐 key to" → "Do Nothing"** (applies immediately):
   ```bash
   open "x-apple.systempreferences:com.apple.Keyboard-Settings.extension"
   ```
   While there, if macOS **Dictation** is on and bound to the Globe key, turn it off (Keyboard → Dictation) so it doesn't collide.
2. Point yaprflow at it: open the yaprflow menu (search "yaprflow" in Spotlight → Enter — the menu pops up at your cursor), click **Shortcut**, then **press 🌐 twice** to set it.
3. Test: hold 🌐 and talk — no emoji picker should appear.

---

## Common issues (agent: adapt to whichever applies)

- **Can't find the menu-bar icon** (common on notched laptops — it overflows and hides): you don't need it to dictate, but to open the menu, **search "yaprflow" in Spotlight → Enter** and it pops up at your cursor. Or ⌘-drag menu-bar icons to make room.
- **Hotkey does nothing:** almost always Accessibility (Step 4) isn't granted. Grant it, wait ~5s.
- **App will not open on an Intel Mac:** this build requires Apple silicon (M1 or newer).
- **No text / nothing transcribed:** check Microphone (Step 3). The very first recording after install can take ~30s while the model warms up (one-time).
- **Is my voice going to the cloud?** No — transcription runs entirely on your Mac; the model is bundled in the app.
- **Change settings later:** open the menu (icon or the Spotlight trick) —
  shortcut, trigger mode, Cleanup (Off/Light/Polish), Automatic Insertion,
  sounds, History (⌃⌥V), and personal vocabulary are all there.
