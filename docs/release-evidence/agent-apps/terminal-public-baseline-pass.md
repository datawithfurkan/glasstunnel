# Agent App Release Evidence

- Date: 2026-09-02T15:29:24Z
- App: Terminal
- Result: pass
- Environment: local PTY and shared-screen-session regression coverage
- Glasstunnel commit: 277044fb
- Artifact: artifacts/terminal-public-baseline.txt
- Privacy review: pass

## Passed

A shell command streamed output, a long-running process was interrupted, the
session recovered to a ready prompt, and the next command was accepted. Default
and named Terminal sessions published correctly; create, select, rename, and
close behavior stayed stable, including the no-op select-current path and the
guard against duplicate generated session names. Shared screen-session launch
and cleanup behavior passed without leaving host-owned attachment clients stale.
Re-recorded after the PTY layer began carrying split UTF-8 sequences across reads
and draining a process's final output before reporting its exit.

## Limitations

Full-screen coding-agent TUI fidelity is adapter-specific and is not part of the
Supported Terminal claim.
