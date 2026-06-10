<div align="center">

<img src="docs/icon.png" width="128" alt="Notch icon" />

# Notch — Liquid Glass

**The fastest way to talk to AI on your Mac has been hiding at the top of your screen.**

[Install](#install) · [First 60 seconds](#your-first-60-seconds) · [Why Notch](#why-notch) · [For developers](#for-developers)

</div>

---

Point your cursor at the notch. It melts open into a panel of dark Liquid
Glass. Type a question, get a streaming answer. Type a thought, and it files
itself into Apple Notes. Move your mouse away — it's gone.

No window to manage. No Dock icon. No menu bar clutter. No hotkey to memorize.
The dead space around your camera becomes the lightest-weight AI surface on
macOS.

## Why Notch

**It's already where you look.** Your eyes pass the notch hundreds of times a
day. Notch turns that reflex into an interface: hover, ask, leave. The cost of
asking a question drops to almost nothing — which changes how often you ask.

**One box, two jobs.** The same input fields both questions and thoughts. Type
*"why is the sky blue"* and the button reads **Ask**; type *"buy milk
tomorrow"* and it flips to **Note** and saves straight into Apple's native
Notes app. The routing happens live as you type, on-device, with zero latency —
and you can flip it manually any time. Capture and curiosity, one muscle
memory.

**Bring your own model.** Nine providers wired in out of the box — OpenAI,
Anthropic, Google Gemini, DeepSeek, Qwen, Kimi, GLM, MiniMax, and MiMo. Paste
one API key and go. Switch providers or models any time from settings rendered
right inside the glass.

**Nothing in between.** Notch is a native Swift app that talks directly to
your chosen provider. No account, no middleman server, no analytics, no
telemetry. Your key and your questions stay between your Mac and your vendor.

**It disappears.** When you're not using it, Notch is literally invisible — it
*is* the notch. Even on Macs without one (or on an external display), it draws
a clean software notch at the top-center and works exactly the same.

## Install

One line. Downloads the latest release and installs it into `/Applications`:

```bash
curl -fsSL https://raw.githubusercontent.com/cyrus-cai/notch/master/install.sh | bash
```

Requires macOS 14 or later. Works on every Mac — notch or no notch.

> **Prefer to install by hand?** Grab the `.zip` from the
> [latest release](https://github.com/cyrus-cai/notch/releases/latest), unzip,
> drag **NotchGlass.app** to Applications, then clear the quarantine flag
> (the app isn't notarized):
> `xattr -dr com.apple.quarantine /Applications/NotchGlass.app`
> — the one-line installer does this for you.

## Your first 60 seconds

1. **Hover the notch.** It springs open into a glass panel that says
   *Ask anything*.
2. **Press ⌘, anywhere** (or click the gear) to open settings — inside the
   panel itself. Pick a provider, paste its API key, hit **Test** to verify
   connectivity. The model list refreshes live from the provider.
3. **Ask something.** Answers stream in as they're generated; ask follow-ups
   inline, copy with one click, and revisit past questions under **Recent**
   (kept across launches).
4. **Jot something.** Type a to-do or a fleeting thought — the button flips to
   **Note** and the line lands in Apple Notes. macOS will ask once for
   permission to control Notes.

Good to know:

- The panel auto-retracts when your mouse leaves (only when idle). `Esc` or a
  click outside also closes it.
- Notch runs as a background agent — no Dock icon, no menu bar item. To quit:
  `pkill -f NotchGlass`.
- Without an API key, Notch runs against a built-in offline stub, so you can
  feel the interaction before signing up for anything.
- API keys are stored locally on your Mac and sent only to the provider you
  chose. They're client-side keys — fine for personal use; put them behind a
  backend before distributing to others.

---

## For developers

### Build & run

```bash
xcodebuild -project NotchGlass.xcodeproj -scheme NotchGlass -configuration Release \
  -derivedDataPath build build
open build/Build/Products/Release/NotchGlass.app
```

Or open `NotchGlass.xcodeproj` in Xcode and run. Requires macOS 14+ / Xcode 16+.

For the local dev loop, `./scripts/reinstall.sh` builds Debug from your working
tree, replaces `/Applications/NotchGlass.app`, and relaunches it.

> **Debug flags:** launch with `NOTCH_OPEN=1` to open the panel at startup,
> `NOTCH_DEMO=1` to seed a sample answer.

### AI backend

The seam is the `AIService` protocol — a single streaming method
(`AsyncThrowingStream<String, Error>`). Without an API key it falls back to a
stub; with one, `OpenAICompatAIService` is a thin `URLSession` client for any
**OpenAI-compatible** `/v1/chat/completions` vendor (Anthropic's native
`/v1/messages` is handled too). Adding another vendor is one `case` in
`Provider` — base URL, default model, display name — no new client code.

### Intent classification

The Ask/Note routing is a pure, local, rules-based function
(`IntentClassifier`), not a model call — it runs on every keystroke so the
button label is always correct *before* you press Enter, and it works on every
Mac with no Apple Intelligence requirement. The classifier returns intent +
confidence + reason, so a model-based fallback for ambiguous cases can slot in
later without touching the UI.

### Notes integration

`NotesService` writes to Apple Notes via AppleScript, with user text passed as
an Apple Event parameter (never interpolated into script source — injection
safe), executed off the main thread so the first-run TCC permission prompt
can't deadlock the app.

### Project layout

```
NotchGlass/Sources/
  NotchGlassApp.swift      App entry (agent app, LSUIElement)
  AppDelegate.swift        Pins the panel to the notched screen; global ⌘, hot key
  NotchPanel.swift         Borderless, transparent, all-Spaces NSPanel
  ContentView.swift        Canvas + spring-animated island + Esc handling
  GlassBackground.swift    NotchShape + black→obsidian-glass material
  NotchBody.swift          idle / loading / answer states + Recent list
  Components.swift         PromptField, SendButton, ThinkingDots, markdown
  NotchModel.swift         State machine, history, AI calls, ask/note routing
  IntentClassifier.swift   Local, zero-latency ask-vs-note classifier
  NotesService.swift       Injection-safe AppleScript bridge to Apple Notes
  AIService.swift          AI seam, streaming, providers, offline stub
  APIKeyStore.swift        Per-provider key + model persistence
  InlineSettingsView.swift Settings rendered inside the glass panel
  HotKey.swift             Carbon RegisterEventHotKey wrapper (no a11y perms)
  DesignSystem.swift       Color scale, type, dimensions

design_bundle/             Original design handoff (HTML prototype + chat)
scripts/reinstall.sh       Local dev loop: build Debug → reinstall → relaunch
install.sh                 End-user installer (latest GitHub release)
```
