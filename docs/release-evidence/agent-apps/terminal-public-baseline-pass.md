# Agent App Release Evidence

- Date: 2026-07-27T23:05:14Z
- App: Terminal
- Result: pass
- Environment: local PTY plus authenticated mobile Chromium and WebKit fixtures
- Glasstunnel commit: f0542cb0bec9295a442ff463846e5594f7b3fabb
- Artifact: artifacts/terminal-public-baseline.txt
- Privacy review: pass

## Passed

A shell command streamed output, a long-running process was interrupted, the session
recovered to a ready prompt, and the next command was accepted. Session create,
select, rename, and close controls passed in the scoped mobile path. Stale
host-owned screen attachment clients were reaped without ending persistent sessions.

## Limitations

Full-screen coding-agent TUI fidelity is adapter-specific and is not part of the
Supported Terminal claim.
