# Glasstunnel Agent Factory Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish a pinned, recoverable Gas City and Beads control-plane foundation that can orchestrate isolated Glasstunnel work safely and prove its lifecycle with a deterministic canary.

**Architecture:** Reviewable Pack V2 definitions and factory policy live under `ops/agent-factory/`; all mutable Gas City, Dolt, lease, worktree, and artifact state lives under a configurable external state root. A small Node CLI owns safe bootstrap, doctor, lease, canary, backup, and teardown operations while delegating scheduling and durable work to Gas City and Beads.

**Tech Stack:** Gas City 1.4.0, Beads 1.1.2, Dolt 2.1.0 or newer, Codex provider, Node.js 22 or newer ESM, Gas City Formula v2, Git worktrees, GitHub protected branches, existing Glasstunnel local test lab, Telegram blocker script.

## Global Constraints

- Never initialize `.gc/` or `.beads/` in the Glasstunnel source checkout.
- Never store credentials, personal accounts, raw transcripts, screenshots, private paths, or machine-specific state in Git.
- Every implementation worker uses an external worktree and a `codex/`-prefixed branch.
- No factory command may push, merge, sign, notarize, deploy, reset TCC, or mutate Keychain state in the foundation phase.
- `main` remains protected by the existing five CI checks, one approving review, linear history, conversation resolution, and force-push/deletion denial.
- Do not enable admin enforcement until a separate non-admin factory GitHub identity exists; otherwise the single maintainer cannot satisfy independent approval.
- Maximum foundation concurrency is two implementation sessions and one session per specialized role.
- A second failure without materially new evidence moves work to replanning instead of starting another automatic attempt.
- GitHub Actions remains a final integration confirmation. Push the completed foundation once and inspect exactly one CI run.
- The public repository contains portable definitions only. Mutable city state and Dolt backups remain local/private.
- Keep Gas City usage metrics disabled with `DO_NOT_TRACK=1` and `GC_DISABLE_USAGE_METRICS=1` in factory-managed processes.

---

## File Map

### Repository-owned definitions

- `ops/agent-factory/README.md`: operator overview, authority boundaries, and recovery entry points.
- `ops/agent-factory/versions.env`: reviewed dependency contract.
- `ops/agent-factory/template/city.toml`: portable city configuration copied to external state.
- `ops/agent-factory/template/pack.toml`: root Pack V2 imports pinned to reviewed revisions.
- `ops/agent-factory/template/packs/glasstunnel/pack.toml`: Glasstunnel role catalog.
- `ops/agent-factory/template/packs/glasstunnel/agents/*`: reviewed roles plus deterministic non-LLM canary agents.
- `ops/agent-factory/template/packs/glasstunnel/formulas/*.toml`: reusable workflow graphs.
- `ops/agent-factory/template/packs/glasstunnel/assets/scripts/*.yaml`: deterministic canary agents.
- `ops/agent-factory/policies/node-contract.schema.json`: machine-checkable node metadata contract.
- `ops/agent-factory/policies/resources.json`: exclusive-resource definitions and recovery rules.

### Safe local control CLI

- `scripts/agent-factory/config.mjs`: paths, version policy, and environment loading.
- `scripts/agent-factory/process.mjs`: injectable subprocess runner.
- `scripts/agent-factory/doctor.mjs`: read-only dependency and safety preflight.
- `scripts/agent-factory/bootstrap.mjs`: external city creation and rig registration.
- `scripts/agent-factory/lease.mjs`: atomic local lease plus Beads audit bead.
- `scripts/agent-factory/branch-guard.mjs`: worktree and protected-branch enforcement.
- `scripts/agent-factory/notify.mjs`: deduplicated Telegram escalation adapter.
- `scripts/agent-factory/canary.mjs`: deterministic lifecycle and recovery proof.
- `scripts/agent-factory/backup.mjs`: Dolt-native backup and disposable restore proof.
- `scripts/agent-factory/cli.mjs`: command dispatch.
- `scripts/agent-factory/*.test.mjs`: focused tests using temporary directories and fake runners.

---

### Task 1: Pin The Toolchain And Add A Read-Only Doctor

**Files:**

- Create: `ops/agent-factory/versions.env`
- Create: `scripts/agent-factory/config.mjs`
- Create: `scripts/agent-factory/process.mjs`
- Create: `scripts/agent-factory/doctor.mjs`
- Create: `scripts/agent-factory/cli.mjs`
- Create: `scripts/agent-factory/doctor.test.mjs`
- Modify: `package.json`

**Interfaces:**

- Produces: `loadVersionPolicy(repoRoot) -> VersionPolicy`
- Produces: `resolveFactoryPaths({ repoRoot, env }) -> FactoryPaths`
- Produces: `runDoctor({ repoRoot, env, runner }) -> DoctorReport`
- `DoctorReport.ok` is true only when every required tool and path invariant passes.

- [ ] **Step 1: Write the failing doctor tests**

```js
import assert from 'node:assert/strict';
import test from 'node:test';
import { runDoctor } from './doctor.mjs';

test('doctor rejects a factory home inside the source checkout', async () => {
  const report = await runDoctor({
    repoRoot: '/repo/glasstunnel',
    env: { GT_FACTORY_HOME: '/repo/glasstunnel/.factory-state' },
    runner: async () => ({ code: 0, stdout: '1.4.0\n', stderr: '' }),
  });
  assert.equal(report.ok, false);
  assert.match(report.checks.find((check) => check.id === 'external-state').detail, /outside/i);
});

test('doctor reports an incompatible Beads version', async () => {
  const runner = async (command) => ({
    code: 0,
    stdout: command === 'bd' ? 'bd version 0.49.0\n' : '1.4.0\n',
    stderr: '',
  });
  const report = await runDoctor({
    repoRoot: '/repo/glasstunnel',
    env: { GT_FACTORY_HOME: '/state/glasstunnel-factory' },
    runner,
  });
  assert.equal(report.ok, false);
  assert.equal(report.checks.find((check) => check.id === 'bd-version').status, 'fail');
});
```

- [ ] **Step 2: Run the tests and confirm the imports fail**

Run: `node --test scripts/agent-factory/doctor.test.mjs`  
Expected: FAIL because `doctor.mjs` does not exist.

- [ ] **Step 3: Add the reviewed version contract**

```dotenv
GC_VERSION=1.4.0
GC_RELEASE_COMMIT=a7297c511d637a3609947386f3389d76ddb2f23b
BD_VERSION=1.1.2
DOLT_MIN_VERSION=2.1.0
NODE_MIN_MAJOR=22
FACTORY_SCHEMA_VERSION=1
```

- [ ] **Step 4: Implement config parsing, safe path resolution, and an injectable runner**

`resolveFactoryPaths` must default to
`$HOME/.local/share/glasstunnel-factory` and derive `city`,
`backups`, `leases`, `rigs`, `worktrees`, `artifacts`, and `notifications`
beneath it.
It must reject any state root equal to or contained by the Git top-level.
It must also reject roots containing whitespace because Gas City 1.4.0 does
not safely quote Pack V2 agent-script paths when launching tmux sessions.

The runner must use `spawn` with an argument array, `shell: false`, captured
UTF-8 output, and a configurable timeout. It must never interpolate a complete
command through a shell.

- [ ] **Step 5: Implement `runDoctor`**

Check `gc`, `bd`, `dolt`, `tmux`, `git`, `jq`, `flock`, `gh`, `codex`, Node 22 or newer,
the external-state invariant, GitHub authentication, a clean current worktree,
and available disk space of at least 20 GiB. Use exact version equality for Gas
City and Beads and semver-at-least for Dolt.

- [ ] **Step 6: Implement the initial CLI dispatch**

`cli.mjs doctor` loads the repository root from `git rev-parse --show-toplevel`,
runs `runDoctor`, prints one line per check, redacts environment values, and
exits non-zero when `DoctorReport.ok` is false. Unknown commands print usage and
exit 2.

- [ ] **Step 7: Add package commands**

```json
{
  "factory:doctor": "node scripts/agent-factory/cli.mjs doctor",
  "factory:test": "node --test scripts/agent-factory/*.test.mjs"
}
```

- [ ] **Step 8: Run focused tests**

Run: `pnpm factory:test`  
Expected: PASS without installing or starting Gas City.

- [ ] **Step 9: Commit the doctor foundation**

```bash
git add ops/agent-factory/versions.env scripts/agent-factory package.json
git commit -m "feat: add agent factory preflight"
```

### Task 2: Protect The Repository From Local Control-Plane State

**Files:**

- Modify: `.gitignore`
- Create: `scripts/agent-factory/safety.test.mjs`
- Create: `ops/agent-factory/README.md`

**Interfaces:**

- Extends: `runDoctor` safety checks from Task 1.
- Produces: explicit public/private state boundary documented for operators and agents.

- [ ] **Step 1: Write the failing repository-safety test**

```js
test('git ignores accidental Gas City and Beads runtime roots', async () => {
  const gitignore = await readFile(new URL('../../.gitignore', import.meta.url), 'utf8');
  assert.match(gitignore, /^\.gc\/$/m);
  assert.match(gitignore, /^\.beads\/$/m);
  assert.match(gitignore, /^\.factory-state\/$/m);
});
```

- [ ] **Step 2: Run the test and confirm it fails**

Run: `node --test scripts/agent-factory/safety.test.mjs`  
Expected: FAIL because the runtime entries are absent.

- [ ] **Step 3: Add defensive ignore rules**

```gitignore
# Agent-factory runtime state must stay outside the public checkout. These rules
# are a final guard if an operator accidentally points the tools at the repo.
.gc/
.beads/
.factory-state/
```

- [ ] **Step 4: Document authority and state boundaries**

The README must name the external default state directory, explain why the
public repo contains only templates, list prohibited authority in Phase 1, and
include `pnpm factory:doctor`, `bootstrap`, `status`, `canary`, `backup-verify`,
and `down` as the operator sequence.

- [ ] **Step 5: Run safety tests and whitespace validation**

Run: `pnpm factory:test && git diff --check`  
Expected: PASS.

- [ ] **Step 6: Commit state isolation**

```bash
git add .gitignore ops/agent-factory/README.md scripts/agent-factory/safety.test.mjs
git commit -m "docs: define factory state isolation"
```

### Task 3: Create The Portable Gas City Pack And Role Catalog

**Files:**

- Create: `ops/agent-factory/template/city.toml`
- Create: `ops/agent-factory/template/pack.toml`
- Create: `ops/agent-factory/template/packs/glasstunnel/pack.toml`
- Create: `ops/agent-factory/template/packs/glasstunnel/agents/*/agent.toml`
- Create: `ops/agent-factory/template/packs/glasstunnel/agents/*/prompt.template.md`
- Create: `scripts/agent-factory/pack.test.mjs`

**Interfaces:**

- Produces Gas City rig agents: `planner`, `architect`, `mac-engineer`,
  `web-engineer`, `adapter-engineer`, `protocol-engineer`, `security-reviewer`,
  `qa`, `reviewer`, `integrator`, and `release-operator`.
- All implementation roles default to zero running sessions and at most one
  active session; the aggregate implementation ceiling is enforced by city
  convergence config.

- [ ] **Step 1: Write the failing pack-contract test**

The test must parse the TOML files with `smol-toml`, assert Pack V2 schema 2,
assert the core and bd imports are pinned to
`a7297c511d637a3609947386f3389d76ddb2f23b`, assert the default provider is
Codex, and assert every role is rig-scoped with `max_active_sessions = 1`.

- [ ] **Step 2: Install the TOML parser and confirm the test fails**

Run: `pnpm add -D -w smol-toml && node --test scripts/agent-factory/pack.test.mjs`  
Expected: FAIL because the template does not exist.

- [ ] **Step 3: Create the root city configuration**

```toml
[workspace]
name = "glasstunnel-factory"
provider = "codex"

[providers.codex]
base = "builtin:codex"

[defaults.rig.imports.glasstunnel]
source = "packs/glasstunnel"

[beads]
provider = "bd"
backend = "dolt"
bd_compatibility = "bd-1.0.4"
conditional_writes = "auto"
guarded_release = "auto"

[convergence]
max_per_agent = 1
max_total = 2

[daemon]
formula_v2 = true
patrol_interval = "30s"
max_restarts = 3
restart_window = "1h"
session_circuit_breaker = true
```

- [ ] **Step 4: Create the pinned root pack**

```toml
[pack]
name = "glasstunnel-factory"
schema = 2

[imports.core]
source = "https://github.com/gastownhall/gascity.git//internal/bootstrap/packs/core"
version = "sha:a7297c511d637a3609947386f3389d76ddb2f23b"

[imports.bd]
source = "https://github.com/gastownhall/gascity.git//examples/bd"
version = "sha:a7297c511d637a3609947386f3389d76ddb2f23b"
```

- [ ] **Step 5: Create the Glasstunnel role pack**

```toml
[pack]
name = "glasstunnel"
schema = 2
```

Each role's `agent.toml` uses this safe initial shape:

```toml
scope = "rig"
provider = "codex"
lifecycle = "one_shot"
idle_timeout = "10m"
min_active_sessions = 0
max_active_sessions = 1
```

Prompts must include the role's ownership, the node contract, resource-lease
requirements, local-first validation, no-main/no-deploy authority, retry limit,
and structured close evidence. The reviewer prompt must be read-only. The
integrator prompt may prepare an integration branch but must not push or merge.

- [ ] **Step 6: Run static pack tests**

Run: `pnpm factory:test`  
Expected: PASS.

- [ ] **Step 7: Commit the portable role catalog**

```bash
git add ops/agent-factory/template scripts/agent-factory/pack.test.mjs package.json pnpm-lock.yaml
git commit -m "feat: define Glasstunnel factory roles"
```

### Task 4: Define The Node Contract And Exclusive Resources

**Files:**

- Create: `ops/agent-factory/policies/node-contract.schema.json`
- Create: `ops/agent-factory/policies/resources.json`
- Create: `scripts/agent-factory/policy.test.mjs`

**Interfaces:**

- Produces JSON Schema `glasstunnel.factory.node.v1`.
- Produces resource definitions consumed by `lease.mjs` in Task 5.

- [ ] **Step 1: Write failing schema tests with Ajv**

Test one valid node and rejection of nodes missing `objective`, `nonGoals`,
`surfaces`, `fileOwnership`, `risk`, `budgets`, `resources`, `validation`,
`maxEvidenceFreeAttempts`, `humanGates`, or `evidence`.

```js
const validNode = {
  schema: 'glasstunnel.factory.node.v1',
  objective: 'Prove the deterministic canary lifecycle',
  nonGoals: ['Modify product source'],
  surfaces: ['factory'],
  fileOwnership: ['ops/agent-factory/**'],
  risk: 'low',
  budgets: { wallClockMinutes: 10, modelTokens: 0, githubRuns: 0 },
  resources: ['canary-exclusive'],
  validation: ['pnpm factory:test'],
  maxEvidenceFreeAttempts: 1,
  humanGates: [],
  evidence: [],
};
```

- [ ] **Step 2: Install Ajv and verify failure**

Run: `pnpm add -D -w ajv && node --test scripts/agent-factory/policy.test.mjs`  
Expected: FAIL because the schema is absent.

- [ ] **Step 3: Implement the node schema**

Use `additionalProperties: false`, explicit enums for risk and surfaces, positive
integer budgets, unique resource names, and `maxEvidenceFreeAttempts` constrained
to `0..1` in the foundation phase.

- [ ] **Step 4: Define exclusive resources**

`resources.json` must define `mac-ui`, `ios-simulator`,
`tcc-screen-recording`, `tcc-accessibility`, `keychain-signing`,
`notarization`, `production-deploy`, `local-lab`, and `canary-exclusive`.
Every entry includes `humanGate`, `defaultTtlSeconds`, `heartbeatSeconds`, and a
non-destructive `recoveryCommand`. Sensitive resources set `humanGate: true`.

- [ ] **Step 5: Run policy tests and commit**

Run: `pnpm factory:test && git diff --check`  
Expected: PASS.

```bash
git add ops/agent-factory/policies scripts/agent-factory/policy.test.mjs package.json pnpm-lock.yaml
git commit -m "feat: define factory work and resource policy"
```

### Task 5: Implement Audited Resource Leases

**Files:**

- Create: `scripts/agent-factory/lease.mjs`
- Create: `scripts/agent-factory/lease.test.mjs`
- Modify: `scripts/agent-factory/cli.mjs`

**Interfaces:**

- Produces: `acquireLease({ resource, nodeId, holder, ttlSeconds, paths, runner }) -> Lease`
- Produces: `heartbeatLease({ resource, nodeId, paths }) -> Lease`
- Produces: `releaseLease({ resource, nodeId, paths, runner }) -> void`
- Produces: `recoverExpiredLease({ resource, now, paths, runner }) -> RecoveryResult`

- [ ] **Step 1: Write failing concurrency and expiry tests**

Tests must prove that two concurrent acquisitions produce one winner, the wrong
node cannot heartbeat or release a lease, an unexpired lease cannot be
recovered, and recovery closes the audit bead only after expiry.

- [ ] **Step 2: Run the tests and confirm failure**

Run: `node --test scripts/agent-factory/lease.test.mjs`  
Expected: FAIL because `lease.mjs` is absent.

- [ ] **Step 3: Implement atomic local ownership**

Use `fs.open(path, 'wx', 0o600)` for acquisition. Store schema, resource,
nodeId, holder, acquiredAt, heartbeatAt, expiresAt, and auditBeadId. Never use a
read-then-write sequence for initial ownership.

- [ ] **Step 4: Mirror ownership into Beads**

After the file claim succeeds, run `bd create --type=gate --title` with labels
`factory:resource-lease` and the computed label
`` `factory:resource:${resource}` ``, then record holder,
node, and expiry metadata. If Beads creation fails, remove only the just-created
local claim and return failure. Release closes the audit bead before deleting
the claim file.

- [ ] **Step 5: Add CLI commands and dry-run output**

Expose `lease acquire`, `lease heartbeat`, `lease release`, `lease status`, and
`lease recover`. Recovery requires `--expired-only`; sensitive resources also
require `--human-approved`.

- [ ] **Step 6: Run lease tests and commit**

Run: `pnpm factory:test`  
Expected: PASS.

```bash
git add scripts/agent-factory/lease.mjs scripts/agent-factory/lease.test.mjs scripts/agent-factory/cli.mjs
git commit -m "feat: add audited factory resource leases"
```

### Task 6: Enforce Worktree And Branch Authority

**Files:**

- Create: `scripts/agent-factory/branch-guard.mjs`
- Create: `scripts/agent-factory/branch-guard.test.mjs`
- Modify: `scripts/agent-factory/cli.mjs`

**Interfaces:**

- Produces: `assertWorkerCheckout({ repoRoot, cwd, branch, primaryCheckout })`.
- Produces: `createWorkerWorktree({ nodeId, baseRef, paths, runner }) -> { path, branch }`.

- [ ] **Step 1: Write failing authority tests**

Cover rejection of `main`, `master`, detached HEAD, a branch without the
`codex/` prefix, the primary checkout, a dirty base checkout, path traversal in
the node ID, and a worktree path outside the configured worktree root.

- [ ] **Step 2: Run tests and confirm failure**

Run: `node --test scripts/agent-factory/branch-guard.test.mjs`  
Expected: FAIL because the guard is absent.

- [ ] **Step 3: Implement creation and validation**

Normalize node IDs to `[A-Za-z0-9-]+`, create branch
`` `codex/factory-${nodeId}` `` from `origin/main`, and place the worktree under
`path.join(FactoryPaths.worktrees, nodeId)`. Refuse an existing branch whose recorded
head does not match its Beads metadata.

- [ ] **Step 4: Add cleanup without destructive source operations**

Cleanup may run `git worktree remove` only for paths under the configured
factory worktree root and only after the node is closed or explicitly
cancelled. It must not use `git reset --hard`, `git checkout --`, or remove the
primary checkout.

- [ ] **Step 5: Run tests and commit**

Run: `pnpm factory:test`  
Expected: PASS.

```bash
git add scripts/agent-factory/branch-guard.mjs scripts/agent-factory/branch-guard.test.mjs scripts/agent-factory/cli.mjs
git commit -m "feat: enforce isolated factory worktrees"
```

### Task 7: Add Workflow Formulas And Deterministic Canary Agents

**Files:**

- Create: `ops/agent-factory/template/packs/glasstunnel/formulas/product-change.toml`
- Create: `ops/agent-factory/template/packs/glasstunnel/formulas/bug-investigation.toml`
- Create: `ops/agent-factory/template/packs/glasstunnel/formulas/cross-surface-change.toml`
- Create: `ops/agent-factory/template/packs/glasstunnel/formulas/release-evidence.toml`
- Create: `ops/agent-factory/template/packs/glasstunnel/formulas/dependency-update.toml`
- Create: `ops/agent-factory/template/packs/glasstunnel/formulas/foundation-canary.toml`
- Create: `ops/agent-factory/template/packs/glasstunnel/assets/scripts/canary-worker.yaml`
- Create: `ops/agent-factory/template/packs/glasstunnel/assets/scripts/canary-reviewer.yaml`
- Create: `scripts/agent-factory/formula.test.mjs`

**Interfaces:**

- All formulas require `formula_compiler = ">=2.0.0"`.
- Every implementation step is followed by validation and independent review.
- Release formula ends at a human gate and cannot execute release commands.

- [ ] **Step 1: Write failing graph-structure tests**

Parse each formula and assert unique step IDs, resolvable `needs` edges, an
acyclic graph, retry ceilings of one additional attempt, explicit run targets,
and presence of validation and review dependencies.

- [ ] **Step 2: Run tests and confirm missing formulas**

Run: `node --test scripts/agent-factory/formula.test.mjs`  
Expected: FAIL.

- [ ] **Step 3: Implement the five production formulas**

Use Formula v2 TOML. `product-change` follows
`specify -> implement -> validate -> review -> integration-ready`.
`bug-investigation` follows
`reproduce -> regression-test -> fix -> validate -> review -> integration-ready`.
`cross-surface-change` fans out Mac and web work after contract review, then
joins at parity validation. `dependency-update` begins with compatibility and
security assessment. `release-evidence` performs read-only readiness and ends
at a Beads human gate.

- [ ] **Step 4: Implement the foundation canary graph**

The canary must acquire `canary-exclusive`, fail its first scripted validation,
record `gc.failure_class=transient`, pass on its only retry, run a read-only
scripted review, mark `integration_ready=true`, release the lease, and finalize.
It writes artifacts only below the external factory artifact root.

- [ ] **Step 5: Run static formula tests and commit**

Run: `pnpm factory:test`  
Expected: PASS.

```bash
git add ops/agent-factory/template/packs/glasstunnel scripts/agent-factory/formula.test.mjs
git commit -m "feat: add factory workflow formulas"
```

### Task 8: Bootstrap And Stop An External City Safely

**Files:**

- Create: `scripts/agent-factory/bootstrap.mjs`
- Create: `scripts/agent-factory/bootstrap.test.mjs`
- Modify: `scripts/agent-factory/cli.mjs`
- Modify: `package.json`

**Interfaces:**

- Produces: `bootstrapFactory({ repoRoot, env, runner }) -> BootstrapReport`.
- Produces: `stopFactory({ paths, runner }) -> StopReport`.

- [ ] **Step 1: Write failing command-sequence tests**

Use a fake runner to assert the sequence: doctor, create external directories,
clone or fast-forward the external rig mirror, `gc init --from`, `gc rig add`,
`gc doctor`, `gc config show --validate`, and `gc formula list`. Assert idempotent
reruns do not create a second city, mirror, or rig.

- [ ] **Step 2: Run tests and confirm failure**

Run: `node --test scripts/agent-factory/bootstrap.test.mjs`  
Expected: FAIL.

- [ ] **Step 3: Implement bootstrap with explicit environment**

Every Gas City process receives the following fixed privacy flags, plus the
absolute factory home returned by `resolveFactoryPaths`:

```text
DO_NOT_TRACK=1
GC_DISABLE_USAGE_METRICS=1
```

Copy the repository template to a fresh external city root. Clone the public
origin into `FactoryPaths.rigs/glasstunnel` with `--no-tags`, verify its origin
URL and clean state, then run `gc init --from` for the city and `gc rig add` for
that external mirror. Never register the human's primary checkout. Do not run
`bd setup codex` or any command that edits `AGENTS.md`.

- [ ] **Step 4: Implement safe stop and status**

`down` stops only the registered Glasstunnel city and leaves backups and Beads
history intact. `status` is read-only and reports city, rig, sessions, open
leases, disk usage, and whether the primary repo is clean.

- [ ] **Step 5: Add package commands**

```json
{
  "factory:bootstrap": "node scripts/agent-factory/cli.mjs bootstrap",
  "factory:status": "node scripts/agent-factory/cli.mjs status",
  "factory:down": "node scripts/agent-factory/cli.mjs down"
}
```

- [ ] **Step 6: Run tests and commit**

Run: `pnpm factory:test`  
Expected: PASS.

```bash
git add scripts/agent-factory/bootstrap.mjs scripts/agent-factory/bootstrap.test.mjs scripts/agent-factory/cli.mjs package.json
git commit -m "feat: bootstrap external factory city"
```

### Task 9: Add Deduplicated Human Escalation

**Files:**

- Create: `scripts/agent-factory/notify.mjs`
- Create: `scripts/agent-factory/notify.test.mjs`
- Modify: `scripts/agent-factory/cli.mjs`

**Interfaces:**

- Produces: `notifyBlocker({ nodeId, blocker, requestedAction, safety, resume, paths, runner, dryRun })`.
- Uses existing `scripts/notify-telegram-blocker.sh`; it does not read or print the bot token.

- [ ] **Step 1: Write failing deduplication tests**

Prove that the same node plus normalized blocker fingerprint sends once, a
materially changed requested action sends again, successful resume clears the
fingerprint, and dry-run never invokes the network path.

- [ ] **Step 2: Run tests and confirm failure**

Run: `node --test scripts/agent-factory/notify.test.mjs`  
Expected: FAIL.

- [ ] **Step 3: Implement the adapter**

Persist only SHA-256 fingerprint, node ID, timestamp, and status beneath the
external notifications directory. The message contains blocker, attempted
diagnostic, exact requested action, safety impact, and resume command. Reject
messages containing values matching configured secret-variable contents.

- [ ] **Step 4: Add CLI and run dry-run smoke**

Add this package command:

```json
{
  "factory:notify": "node scripts/agent-factory/cli.mjs notify"
}
```

Run:

```bash
GT_TELEGRAM_DRY_RUN=1 pnpm factory:notify -- \
  send \
  --node foundation-canary \
  --blocker "Human gate canary" \
  --action "Acknowledge the dry-run message" \
  --safety "No system mutation" \
  --resume "pnpm factory:canary"
```

Expected: one formatted local message and no Telegram API call.

- [ ] **Step 5: Run tests and commit**

Run: `pnpm factory:test`  
Expected: PASS.

```bash
git add scripts/agent-factory/notify.mjs scripts/agent-factory/notify.test.mjs scripts/agent-factory/cli.mjs package.json
git commit -m "feat: add factory human escalation"
```

### Task 10: Prove Backup, Restore, And Canary Recovery

**Files:**

- Create: `scripts/agent-factory/backup.mjs`
- Create: `scripts/agent-factory/backup.test.mjs`
- Create: `scripts/agent-factory/canary.mjs`
- Create: `scripts/agent-factory/canary.test.mjs`
- Modify: `scripts/agent-factory/cli.mjs`
- Modify: `package.json`

**Interfaces:**

- Produces: `verifyBackupRestore({ paths, runner }) -> BackupEvidence`.
- Produces: `runCanary({ paths, runner }) -> CanaryEvidence`.

- [ ] **Step 1: Write failing backup and canary tests**

The backup test asserts `bd backup init`, `bd backup sync`, disposable
`bd init --server`, and `bd backup restore --force` are run against paths under
the external state root. The canary test asserts the state sequence includes
one transient failure, one retry, review, integration readiness, and lease
release, with no `git push`, GitHub workflow, signing, or deploy command.

- [ ] **Step 2: Run tests and confirm failure**

Run: `node --test scripts/agent-factory/backup.test.mjs scripts/agent-factory/canary.test.mjs`  
Expected: FAIL.

- [ ] **Step 3: Implement backup verification**

Create a timestamped filesystem backup, sync the current ledger, restore into a
new disposable directory, compare open/closed counts and canary node metadata,
then unregister and remove only the disposable restore directory after all
processes stop. Never treat JSONL export as the restorable backup.

- [ ] **Step 4: Implement the canary runner**

Cook and route `foundation-canary`, wait with a 10-minute ceiling, capture
structured status and run evidence, verify exactly two validation attempts,
verify reviewer read-only state, verify `integration_ready=true`, and verify no
open `canary-exclusive` lease remains.

- [ ] **Step 5: Add package commands and run unit tests**

```json
{
  "factory:canary": "node scripts/agent-factory/cli.mjs canary",
  "factory:backup-verify": "node scripts/agent-factory/cli.mjs backup-verify"
}
```

Run: `pnpm factory:test`  
Expected: PASS.

- [ ] **Step 6: Commit recovery automation**

```bash
git add scripts/agent-factory package.json
git commit -m "feat: verify factory recovery lifecycle"
```

### Task 11: Install And Validate The Real Local Control Plane

**Files:**

- Modify only if live output reveals a reproducible defect in the files above.
- Record sanitized results in `ops/agent-factory/README.md`.

**Interfaces:**

- Consumes all previous tasks.
- Produces a running but mutation-disabled Glasstunnel city and sanitized foundation evidence.

- [ ] **Step 1: Install the pinned release and dependencies**

Run:

```bash
brew install gastownhall/gascity/gascity
command gc version
bd version
dolt version
tmux -V
```

Expected: Gas City 1.4.0, Beads 1.1.2, Dolt at least 2.1.0, and tmux present.
If Homebrew resolves a newer Gas City or Beads release, stop and review its
release notes before changing `versions.env`.

- [ ] **Step 2: Run the real doctor**

Run: `pnpm factory:doctor`  
Expected: PASS. The command may identify Git state from the feature branch but
must report the external-state and disk checks green.

- [ ] **Step 3: Bootstrap the external city**

Run: `pnpm factory:bootstrap`  
Expected: one registered `glasstunnel-factory` city, one external `glasstunnel`
rig mirror, no changes to `AGENTS.md`, and no `.gc/` or `.beads/` under the
source checkout.

- [ ] **Step 4: Run Gas City native validation**

Run:

```bash
command gc doctor
command gc config validate
command gc formula list
command gc status
```

Expected: no fatal findings; all six Glasstunnel formulas visible; no worker
sessions running before work is routed.

- [ ] **Step 5: Run the deterministic canary and recovery proof**

Run:

```bash
pnpm factory:canary
pnpm factory:backup-verify
pnpm factory:status
```

Expected: canary passes after one controlled retry, review and integration
readiness are recorded, no lease remains, and the backup restores successfully.

- [ ] **Step 6: Stop the city and inspect cleanup**

Run:

```bash
pnpm factory:down
git status --short --branch
git worktree list
```

Expected: city stopped, primary worktree intact, no orphan canary worktree, and
only intentional repository files changed.

- [ ] **Step 7: Record sanitized versions and evidence summary**

Add only version numbers, pass/fail states, canary duration, and backup/restore
result to the README. Do not record the external state path, usernames, tokens,
device IDs, or transcript content.

- [ ] **Step 8: Commit live foundation evidence**

```bash
git add ops/agent-factory/README.md
git commit -m "test: verify agent factory foundation"
```

### Task 12: Validate, Open One Pull Request, And Preserve The CI Budget

**Files:**

- Modify: `docs/agentic-workflows.md`
- Modify: `docs/current-loop-state.md`
- Modify: `AGENTS.md`

**Interfaces:**

- Makes Beads/Gas City the canonical factory workflow while retaining existing
  task packets for ordinary single-agent work.
- Does not activate continuous mutation or automatic merge.

- [ ] **Step 1: Update repository workflow guidance**

Document that factory-managed tasks begin with Beads, run in isolated
worktrees, use one driver/integrator, obey exclusive leases, and produce one
reviewed batch PR. Keep current source-of-truth and UI parity rules unchanged.

- [ ] **Step 2: Audit GitHub protection without mutating it**

Run:

```bash
gh api repos/datawithfurkan/glasstunnel/branches/main/protection
gh api repos/datawithfurkan/glasstunnel/rulesets
```

Expected: the existing five CI contexts, strict checks, one review, linear
history, conversation resolution, and force-push/deletion denial remain.
Record that `enforce_admins=false` is intentionally temporary until a separate
factory service identity exists.

- [ ] **Step 3: Run complete local validation**

Run:

```bash
pnpm factory:test
pnpm factory:doctor
pnpm agent:validate
git diff --check
pnpm qa:security-privacy
pnpm qa:public-repo
```

Run `pnpm agent:validate:run` only if its recommended matrix includes checks not
already covered. Do not run release readiness because this foundation does not
change product or release behavior.

- [ ] **Step 4: Review the complete branch**

Run:

```bash
git status --short --branch
git log --oneline origin/main..HEAD
git diff --stat origin/main...HEAD
git diff --check origin/main...HEAD
```

Expected: no secrets, runtime state, absolute personal paths, product behavior,
or unrelated changes.

- [ ] **Step 5: Commit workflow integration**

```bash
git add AGENTS.md docs/agentic-workflows.md docs/current-loop-state.md
git commit -m "docs: adopt graph-based factory workflow"
```

- [ ] **Step 6: Push once and open one pull request**

```bash
git push -u origin codex/agent-factory-foundation
gh pr create \
  --base main \
  --head codex/agent-factory-foundation \
  --title "Build Glasstunnel agent factory foundation" \
  --body "Builds the reviewed Gas City and Beads foundation with external runtime state, isolated worktrees, audited resource leases, bounded retries, dry-run Telegram escalation, deterministic canary evidence, and verified backup recovery. It does not enable autonomous merge, signing, notarization, deployment, TCC resets, or continuous mutation."
```

The PR body summarizes architecture, safety boundaries, canary evidence,
validation, remaining activation stages, and confirms no autonomous mutation is
enabled.

- [ ] **Step 7: Inspect exactly one CI run**

Run `gh pr checks --watch --fail-fast` once. If a check fails, reproduce it
locally and make one focused corrective push. Do not rerun successful workflows.

- [ ] **Step 8: Leave the branch and runtime in a recoverable state**

Run `pnpm factory:down`, confirm the primary checkout is clean, and preserve the
external ledger and backup. The user performs the required independent PR
approval and merge.

---

## Plan Self-Review Results

- **Spec coverage:** Platform pinning, external state, roles, formulas, node
  contract, resource leases, worktrees, Telegram, backup/restore, canary,
  protected integration, cost control, and activation limits all map to tasks.
- **Scope:** This plan implements the foundation and shadow-control proof only.
  Continuous scheduling, cloud/Kubernetes workers, a separate GitHub service
  identity, automatic review integration, Midscene exploration, and production
  authority remain later activation plans.
- **Authority:** No task grants workers push, merge, signing, notarization,
  deployment, Keychain, or TCC-reset authority.
- **Cost:** All development validation is local; there is one final push, one
  pull request, and one observed CI run.
- **Recovery:** Runtime state is external, Dolt receives a restorable backup,
  canary cleanup is verified, and the city is stopped at handoff.
