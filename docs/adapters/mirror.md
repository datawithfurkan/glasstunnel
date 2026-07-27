# Mirror adapter

**Source:** `apps/host-macos/Sources/Adapters/Mirror/`.

Generic fallback adapter used whenever a selected window does not have a first-class adapter.

## What it does

- Nothing "smart" — no structured chat parsing, no hook integration.
- Video: relies on `GTCapture.WindowCapture` to stream the window over WebRTC.
- Input: `GTInput.KeyboardInjector` targets the owning PID with `CGEvent` synthetic keystrokes.
- Interrupt: `CGEvent` with Control+C modifier, targeted at the owning PID.

## Status detection

The mirror adapter does not emit `AgentStatus.done` transitions — it stays in `idle` until input is sent (which flips it to `working` briefly). If you want "agent is done" push notifications, you need a tool-specific adapter.

## When to use

This adapter is automatically picked when no bundle ID match is found in `AdapterFactory.resolveKind()`. Manual mirror selection is still a planned advanced control.

## Compatibility

Anything with a window will work. There is no "compatibility matrix" because there is nothing to be compatible with.
