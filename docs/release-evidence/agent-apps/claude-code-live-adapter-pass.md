# Agent App Release Evidence

- Date: 2026-09-02T09:20:42Z
- App: Claude Code
- Result: pass
- Environment: Mac host adapter driving the signed-in Claude Code CLI 2.1.226 in a real PTY
- Glasstunnel commit: 2c4d343e
- Artifact: artifacts/claude-code-live-adapter.txt
- Privacy review: pass

## Passed

The adapter launched the real `claude` CLI in a PTY pinned to a fresh session id,
with its hooks loaded from a temporary settings file so the user's own settings
stayed untouched. A prompt sent through the adapter was submitted by the TUI, the
Stop hook arrived over the shared socket and set "Response ready", and the
transcript parsed to the prompt followed by the assistant reply containing the
expected marker, with the pinned session selected as the target. The flag-surface
lane (`pnpm qa:claude-code`) passed for the same build.

## Limitations

This is an adapter-level run on the Mac. The phone-driven path through the mobile
browser — prompt, permission prompt, interrupt, and relaunch from a paired
phone — is not yet recorded, so the Claude Code card stays short of Supported.
