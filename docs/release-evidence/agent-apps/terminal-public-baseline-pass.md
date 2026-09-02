# Agent App Release Evidence

- Date: 2026-09-02T16:32:57Z
- App: Terminal
- Result: pass
- Environment: local PTY and shared-screen-session regression coverage
- Glasstunnel commit: cbe61e1f
- Artifact: artifacts/terminal-public-baseline.txt
- Privacy review: pass

## Passed

A shell command streamed output, a long-running process was interrupted, the
session recovered to a ready prompt, and the next command was accepted. Default
and named Terminal sessions published correctly; create, select, rename, and
close behavior stayed stable, including the no-op select-current path and the
guard against duplicate generated session names. Shared screen-session launch
and cleanup behavior passed without leaving host-owned attachment clients stale.
Re-recorded after the signaling and relay Workers began guarding sends to
sockets that close, or are replaced by a quick reconnect, while their
authentication is still in flight.

## Limitations

Full-screen coding-agent TUI fidelity is adapter-specific and is not part of the
Supported Terminal claim.
