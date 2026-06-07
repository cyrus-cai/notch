# Notch — Liquid Glass

A native macOS app that turns the Mac's notch into a Liquid-Glass AI input. The
black notch **itself grows downward**, melting through one continuous vertical
gradient into dark, translucent "obsidian" glass — no separate floating popover.
Hover the notch to grow the glass, type a question, get an answer, and it
retracts when you leave.

This is the SwiftUI implementation of the `Mac Notch.html` design prototype
(see `design_bundle/`). It recreates the design's final, agreed-upon look — the
one the user landed on after iterating in the design tool.

## What it does

- **Resting**: a clean black notch with a camera dot, pinned to the top-center of
  the screen that has the menu bar (the notched display, with a fallback).
- **Hover** → the notch springs open into a glass panel (`Ask anything`).
- **Enter / send** → calls the AI, shows a calm three-dot "thinking" wave, then an
  answer (with `**bold**` markdown). Ask a follow-up inline.
- **Recent** → a collapsed entry under the input reveals recent questions
  (persisted across launches); click one to revisit the answer.
- **Auto-retract** on mouse-leave — but only when nothing has been asked and
  nothing is on screen. It stays open while loading, while an answer is showing,
  or while you're mid-question. `Esc` or a click outside closes it.

### Design decisions carried over from the prototype

These were explicit calls the user made while iterating — preserved here:

- The notch is **one continuous black→glass body**, not a popover. The top is
  **pure black** (one body with the hardware notch / bezel) and melts over a
  short band into the glass; **no bright "light band" or glowing lip** (the user
  rejected those for breaking the black blend).
- The glass uses the **native** Liquid Glass material — SwiftUI's
  `.glassEffect(.regular, in: NotchShape)` on macOS 26+ (genuine
  refraction/adaptivity, not a hand-rolled blur), with an `NSVisualEffectView`
  fallback on older systems. The black→glass darkening is **not** baked into the
  glass tint; it's a separate full-height obsidian gradient that eases from
  opaque black at the notch to a faint tint at the bottom, so the transition is
  smooth across the whole panel rather than a hard band. See
  `GlassBackground.swift`.
- **No light/cursor effects.**
- **Minimal**: no sparkle icon, no example prompts, no emoji hints. Send button
  appears only when there's text.
- **English copy**, unified SF font, and a single 4-level label color scale
  (`text-1…4`) — no ad-hoc rgba values (`DesignSystem.swift`).
- Springy expand, snappier (non-springy) collapse.

## Build & run

```bash
xcodebuild -project NotchGlass.xcodeproj -scheme NotchGlass -configuration Release \
  -derivedDataPath build build
open build/Build/Products/Release/NotchGlass.app
```

Or open `NotchGlass.xcodeproj` in Xcode and run. Requires macOS 14+ / Xcode 16+.

It runs as an agent app (`LSUIElement`) — no Dock icon, no menu bar item. It's a
floating panel that lives in the notch and follows you across Spaces and
full-screen apps. To quit, use Activity Monitor or `pkill -f NotchGlass`.

### Debug aid

Launch with `NOTCH_OPEN=1` to open the panel at startup, and add `NOTCH_DEMO=1`
to seed a sample answer — handy for inspecting the expanded glass without a live
hover. No effect in normal use.

## The AI backend

The seam is `AIService` (`AIService.swift`). Without an API key the app falls back
to `StubAIService`, which returns a placeholder after a short delay so the loading
state is exercised exactly as it will be live.

With a key, live answers come from `OpenAICompatAIService` — a single thin
`URLSession` client for any **OpenAI-compatible** `/v1/chat/completions` vendor.
Two are wired up out of the box (the `Provider` enum):

- **MiMo (Xiaomi)** — `mimo-v2.5-pro` · key at platform.xiaomimimo.com
- **DeepSeek** — `deepseek-chat` · key at platform.deepseek.com

Pick the provider and paste its key in Settings (⌘,). Each provider keeps its own
key in the Keychain, and the choice persists. For local dev you can also force a
key via the `MIMO_API_KEY` / `DEEPSEEK_API_KEY` environment variables (these
override whatever is stored).

Adding another OpenAI-compatible vendor is a one-line `case` in `Provider`
(endpoint + default model + signup host) — no new networking code. The persona
lives in `notchSystemPrompt`.

> ⚠️ These are client-side keys (see `APIKeyStore`). Fine for personal use; before
> distributing, move the key behind a small backend so it never ships in the app.

## Project layout

```
NotchGlass/Sources/
  NotchGlassApp.swift   App entry (agent app, no standard window)
  AppDelegate.swift     Creates & pins the notch panel; tracks screen changes
  NotchPanel.swift      Borderless, transparent, all-Spaces floating NSPanel
  ContentView.swift     Transparent canvas + the spring-animated island + Esc
  GlassBackground.swift  NotchShape + the black→obsidian-glass material + grain
  NotchBody.swift       idle / load / result content + Recent history list
  Components.swift      PromptField, SendButton, ThinkingDots, inline markdown
  NotchModel.swift      State machine, history persistence, AI calls
  DesignSystem.swift    Color scale, font, dimensions, environment metrics
  AIService.swift       AI seam + offline stub
NotchGlass/Resources/Info.plist   LSUIElement agent-app config

design_bundle/          The original Claude Design handoff (HTML prototype + chat)
```
