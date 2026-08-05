# Glasstunnel Agent Factory

This directory contains the portable, reviewable definition of Glasstunnel's
agent factory. Mutable Gas City, Beads, Dolt, worktree, lease, notification, and
artifact state belongs outside the repository. The default private state root
is `~/.local/share/glasstunnel-factory`; override it with `GT_FACTORY_HOME`
only when the replacement is also outside the checkout and contains no
whitespace. Gas City 1.4.0 does not safely quote Pack V2 agent-script paths.

The durable architecture and its completed foundation record are documented in
`docs/architecture/agent-factory-design.md` and
`docs/architecture/agent-factory-foundation-plan.md`.

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
state root. `down` stops the city but preserves its ledger and backups. A normal
dormant state is: city stopped, rig suspended, no active leases, no worker
worktrees, and no factory-owned Dolt or tmux process.

## Roles And Workflows

The factory defines planner, architect, Mac, web, adapter, and protocol
engineers, security and QA reviewers, an integrator, and a release operator.
Their authority is intentionally narrower than their names: no role gains
production access merely by receiving work.

Six bounded Formula V2 workflows cover the current foundation:

- `product-change`
- `bug-investigation`
- `cross-surface-change`
- `dependency-update`
- `release-evidence`
- `foundation-canary`

Production paths require declared validation and independent review before
integration. The canary is deterministic: its first implementation attempt
fails with a classified transient result, the second passes, review passes,
and integration records completion. This proves bounded retry and dependency
ordering without changing product code.

## Resource And Cost Controls

Exclusive local resources use atomic audited leases. Sensitive leases include
Mac UI, Simulator, TCC, Keychain, notarization, and production deployment.
Expired leases may be recovered only through the audited recovery path.

Workers run local validation in isolated external worktrees and never push.
One completed batch may produce one consolidated branch or pull request and one
bounded CI inspection. Telegram alerts are redacted and deduplicated; they are
reserved for genuine human-only blockers, not routine progress.

## Verified Foundation Evidence

The foundation was verified locally with Gas City 1.4.0, Beads 1.1.2, and Dolt
2.2.3. The live canary completed the controlled retry, review, and integration
path in about four minutes. The backup verifier restored a disposable Dolt
database and matched 40 source issues, including canary metadata, before
cleaning up the provider it started. A provider that was already running is
preserved.

The rig uses a private external `origin`; the public GitHub remote is fetch-only
with pushes disabled. After verification, the city was stopped, the rig was
suspended, leases and worker worktrees were absent, and factory-owned Dolt and
tmux processes were not running.

## Recovery

Do not recover a factory by deleting the source checkout or resetting Git. Stop
the city, inspect `pnpm factory:status`, recover only expired leases, and restore
the Dolt-native backup into a disposable external directory before changing the
live ledger. Human-gated resources always require explicit approval. The backup
verifier stops only a provider it caused to start and verifies the exact managed
watchdog and child commands before signaling either process.
