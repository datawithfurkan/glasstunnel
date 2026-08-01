# Agent App Release Evidence

- Date: 2026-08-01T14:11:53Z
- App: Terminal
- Result: pass
- Environment: local PTY plus authenticated mobile Chromium fixture
- Glasstunnel commit: 8eb429ceeca762a499955f2df3dbab51e950bb1f
- Artifact: artifacts/terminal-public-baseline.txt
- Privacy review: pass

## Passed

A shell command streamed output, a long-running process was interrupted, the session
recovered to a ready prompt, and the next command was accepted. Session create,
select, rename, and close controls passed in the authenticated mobile path. Stale
host-owned screen attachment clients were reaped on stop and teardown without
ending persistent sessions.

## Limitations

Full-screen coding-agent TUI fidelity is adapter-specific and is not part of the
Supported Terminal claim.
