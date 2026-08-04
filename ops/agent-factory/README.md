# Glasstunnel Agent Factory

This directory contains the portable, reviewable definition of Glasstunnel's
agent factory. Mutable Gas City, Beads, Dolt, worktree, lease, notification, and
artifact state belongs outside the repository. The default private state root
is `~/.local/share/glasstunnel-factory`; override it with `GT_FACTORY_HOME`
only when the replacement is also outside the checkout and contains no
whitespace. Gas City 1.4.0 does not safely quote Pack V2 agent-script paths.

## Foundation Authority

Phase 1 may inspect the repository, create an external mirror, run deterministic
local canaries, create isolated `codex/` worktrees, and record private Beads
evidence. It may not push, merge, sign, notarize, deploy, reset TCC, modify the
Keychain, use personal test accounts, or activate continuous mutation.

Gas City registers an external mirror clone as the Glasstunnel rig. Its
`origin` is a private bare repository under the factory state root; the public
GitHub repository is a fetch-only `upstream` with pushes disabled. This keeps
Beads/Dolt refs private while still refreshing `origin/main` for worker
branches. The primary human checkout is never a rig and never receives `.gc/`
or `.beads/` state.

## Operator Sequence

```bash
pnpm factory:doctor
pnpm factory:bootstrap
pnpm factory:status
pnpm factory:canary
pnpm factory:backup-verify
pnpm factory:down
```

The doctor is read-only. Bootstrap is idempotent and stays under the private
state root. `down` stops the city but preserves its ledger and backups.

## Recovery

Do not recover a factory by deleting the source checkout or resetting Git. Stop
the city, inspect `pnpm factory:status`, recover only expired leases, and restore
the Dolt-native backup into a disposable external directory before changing the
live ledger. Human-gated resources always require explicit approval.
