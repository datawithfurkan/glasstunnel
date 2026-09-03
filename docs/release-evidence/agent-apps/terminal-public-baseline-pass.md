# Agent App Release Evidence

- Date: 2026-09-03T18:45:00Z
- App: Terminal
- Result: pass
- Environment: local PTY and shared-screen-session regression coverage
- Glasstunnel commit: f660996b
- Artifact: artifacts/terminal-public-baseline.txt
- Privacy review: pass

## Passed

A shell command streamed output, a long-running process was interrupted, the
session recovered to a ready prompt, and the next command was accepted. Default
and named Terminal sessions published correctly; create, select, rename, and
close behavior stayed stable, including the no-op select-current path and the
guard against duplicate generated session names. Shared screen-session launch
and cleanup behavior passed without leaving host-owned attachment clients stale.
Re-recorded at 1ff17e4f after the screen-sharing stability fixes changed the
host transport and the phone app (pull request #23); the Terminal path itself
is unchanged.
Re-recorded at 7ffe2d45 after the Cursor cards (pull request #22) changed the lab
lanes and the phone app; `pnpm qa:terminal` passed again at that commit.
Re-recorded at f660996b after the Codex desktop parity merge (pull request #21)
changed the host, the accessibility injector, and the lab lanes.

## Limitations

Full-screen coding-agent TUI fidelity is adapter-specific and is not part of the
Supported Terminal claim.
