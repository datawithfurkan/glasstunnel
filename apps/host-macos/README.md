# glasstunnel host-macos

The Mac app. Runs while you are at home, exposes supported local agent apps as remote apps, and streams them to your phone over WebRTC.

## Development

### Open in Xcode (recommended)

```bash
open apps/host-macos/Package.swift
```

Xcode will open the Swift package as a project. `cmd-R` to build + run. You will need to grant Screen Recording and Accessibility permissions on first run.

### Build from the command line

```bash
cd apps/host-macos
swift build
swift test
```

CLI build produces a bare executable. For a distributable `.app` bundle see `docs/mac-distribution.md`.

## Module graph

```
GlassTunnelApp  -> GTAdapters -> GTCapture
                               -> GTInput
                               -> GTSecurity
                               -> GTProtocol
                -> GTTransport -> GTProtocol
                               -> GTSecurity
                               -> WebRTC (SPM binary)
```

Each module has a clear purpose:

- **GTProtocol** - protocol types, JSON codec, remote-app, grid-compatibility, and adapter enums.
- **GTSecurity** - device keys (Keychain), signing, secret redaction, auto-lock state.
- **GTTransport** - signaling client (WebSocket), relay client, and WebRTC peer.
- **GTCapture** - `ScreenCaptureKit` wrappers, window enumeration, frame streaming.
- **GTInput** - `CGEvent` keyboard synthesis + Accessibility-driven input targeting.
- **GTAdapters** - `AgentAdapter` protocol and Cursor / Claude Code / Codex / OpenCode / Mirror adapters.
- **GlassTunnelApp** - SwiftUI entry point, menu bar, permissions onboarding, Workspace / Access / Settings UI.

## Required permissions

Glasstunnel needs two macOS privacy permissions on first run:

1. **Screen Recording** — so `ScreenCaptureKit` can capture a specific window without grabbing the whole desktop.
2. **Accessibility** — so the Cursor adapter can find and focus the chat input field, and so keyboard input can be targeted at the right process.
The app's onboarding screen walks you through granting each permission and links you straight to the correct System Settings pane.
