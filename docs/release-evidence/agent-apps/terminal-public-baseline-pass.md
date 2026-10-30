# Agent App Release Evidence

- Date: 2026-10-30T11:58:27Z
- App: Terminal
- Result: pass
- Environment: local PTY and shared-screen-session regression coverage
- Glasstunnel commit: a1d3537f
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
Re-recorded at 8f7305fc after the 0.1.10 changes (Readable screen quality at
1080p-class size, per-host hook sockets, the Claude 1.46 accessibility opt-in,
the reconnect backoff, the lane switch-step fix) with the installed Glasstunnel
app left running.
Re-recorded at 8550bec4 for the 0.1.10 release after the September security
stages and their follow-ups (pull requests #32-#36: truthful relay disclosure,
acknowledged revocation, Mac-owned read-only control, 24-hour cache replicas,
in-place relay renewal, clock-safe cache deadlines), again with the installed
Glasstunnel app left running.
Re-recorded at 2033fef2 for the 0.1.11 release after the account and Mac app
changes (pull requests #38-#47: accounts on Convex, Mac rename and removal,
account-wide access, Open on Phone, in-app updates, the menu bar icon and
background mode); `pnpm qa:terminal` passed; the Terminal path itself is
unchanged.
Re-recorded at f094160b for the 0.1.12 release (the designed DMG installer
window, pull request #50); `pnpm qa:terminal` passed again.
Re-recorded at a1d3537f for the 0.1.13 release after the Mac hardening (pull
request #55: relay commands only from known browsers, the Mac-owned app switch,
isolated hook Python, release builds ignoring overrides); `pnpm qa:terminal`
and the default, retention, revocation and device-management lab journeys passed.

## Limitations

Full-screen coding-agent TUI fidelity is adapter-specific and is not part of the
Supported Terminal claim.
