# Agent App Release Evidence

- Date: 2026-07-28T02:34:37Z
- App: Terminal
- Result: pass
- Environment: local PTY plus authenticated mobile Chromium and WebKit fixtures
- Glasstunnel commit: c457c2b2d271186716d7301bad14cb4a3132defd
- Artifact: artifacts/terminal-public-baseline.txt
- Privacy review: pass

## Passed

A shell command streamed output, a long-running process was interrupted, the session
recovered to a ready prompt, and the next command was accepted. Session create,
select, rename, and close controls passed in the scoped mobile path. Stale
host-owned screen attachment clients were reaped on stop and teardown without
ending persistent sessions.

## Limitations

Full-screen coding-agent TUI fidelity is adapter-specific and is not part of the
Supported Terminal claim.
