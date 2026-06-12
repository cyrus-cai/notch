<div align="center">

<img src="docs/icon.png" width="96" alt="Notch" />

# Notch

**Most thoughts seem too small to open an app for. They aren't.**

A glass panel in your MacBook's notch. Type a thought — it answers
questions, files notes, sets reminders, then gets out of your way.

<!-- Demo video: open this file in GitHub's web editor and drag the .mp4 in
     here — GitHub hosts and embeds it automatically. -->

**[See it move →](https://cyrus-cai.github.io/notch/)**

</div>

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/cyrus-cai/notch/master/install.sh | bash
```

macOS 14+ · no account · no telemetry · bring your own API key

## Developers

Open `NotchGlass.xcodeproj` (Xcode 16+), or run `./scripts/reinstall.sh` for
the build → reinstall → relaunch loop. The model seam is `AIService.swift`;
the on-device Ask/Note router is `IntentEngine.swift`.
