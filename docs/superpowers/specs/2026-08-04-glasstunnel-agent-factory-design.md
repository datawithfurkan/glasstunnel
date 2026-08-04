# Glasstunnel Agent Factory Design

**Status:** Approved for foundation implementation
**Date:** 2026-08-04  
**Scope:** Long-term engineering control plane for autonomous, multi-agent Glasstunnel development

## Purpose

Glasstunnel will move from long, single-agent goal loops to a durable software
factory that can plan, execute, verify, review, and integrate work continuously.
The factory must preserve context across agent sessions, recover from failed
workers, prevent duplicated effort, protect scarce Mac resources, control cost,
and keep humans involved at the decisions that genuinely require them.

This design targets the next one to two years of development. Its architecture
is intentionally capable of supporting multiple repositories, machines, agent
providers, and execution environments, even though activation will begin on the
current Mac mini with Glasstunnel as the first rig.

The factory does not weaken Glasstunnel's existing product-truth rules. A node
is complete only when its required evidence exists; an agent's written claim of
success is never sufficient by itself.

## Platform Decision

The orchestration layer will use **Gas City**, with **Beads** as its durable work
graph and audit ledger.

Gas City is the primitive-first orchestration SDK that succeeds the fixed-role
Gas Town architecture. It provides declarative city configuration, pluggable
agent runtimes, controller-owned supervision, formulas, orders, work routing,
health patrol, and local or Kubernetes execution. Glasstunnel will define its
own roles and policies in a versioned Pack V2 package rather than embedding Gas
Town's role names into the product workflow.

Beads will store granular work nodes, dependencies, claims, attempts, blockers,
discoveries, decisions, and completion evidence. Server mode will be used when
multiple workers need concurrent writes. The implementation will pin mutually
compatible Gas City, Beads, and Dolt versions after a live preflight; it will not
silently track unreviewed latest releases.

GitHub remains the public collaboration and release boundary. It is not the
high-frequency internal scheduler.

## Source-Of-Truth Boundaries

Each kind of information has one canonical home:

| Information | Canonical system |
| --- | --- |
| Fine-grained work, dependencies, attempts, leases, blockers | Beads |
| Agent lifecycle, formulas, schedules, health, routing | Gas City |
| Source code and reviewed change history | Git branches and commits |
| Public roadmap, contributor discussion, pull requests | GitHub |
| Product support claims and release gates | Existing Glasstunnel docs |
| Raw screenshots, traces, transcripts, and native test captures | Restricted local or artifact storage |
| Human-only approvals and intervention | Telegram request plus recorded Beads decision |

The system must not maintain competing Markdown todo lists or duplicate process
logs. Existing historical goal-loop logs remain evidence, but new granular
factory work is recorded in Beads. Publicly useful conclusions are backfilled
into the current release-readiness and support-matrix documents.

## Repository And Runtime Layout

Portable, reviewable factory definitions will live in the Glasstunnel repository
under `ops/agent-factory/`. This directory will contain the Pack V2 definition,
role prompts, formulas, policy configuration, validation routing, and schemas.
It must contain no credentials, personal account details, raw transcripts, or
machine-specific paths.

Mutable control-plane state will live outside the public repository. This
includes the Gas City runtime directory, Dolt working state, sessions, leases,
temporary worktrees, local artifacts, and secrets. A private, restorable backup
target will protect the Beads/Dolt ledger. Sanitized operational summaries may
be committed when they improve public project understanding.

An external mirror clone of the Glasstunnel GitHub repository is registered as
the Gas City rig. Gas City and rig-scoped Beads metadata therefore remain under
the private factory state root instead of adding `.beads/` to the human's source
checkout. Every code worker receives an isolated Git worktree from that mirror
and a `codex/`-prefixed task branch. Workers may not edit or register the primary
checkout.

## Agent Roles

Roles are conventions defined by the Glasstunnel pack, not hard-coded controller
types:

- **Portfolio planner:** converts approved goals and evidence into bounded epics
  and dependency graphs.
- **Product architect:** owns cross-surface contracts, decomposition, and design
  decisions.
- **Mac runtime engineer:** owns Swift host behavior, permissions, lifecycle,
  signing-safe code, and native testability.
- **Web and mobile engineer:** owns the PWA, browser behavior, responsive UX, and
  deterministic browser tests.
- **Adapter engineers:** separate Codex, Cursor, OpenCode, and future provider
  roles, each constrained by the current support matrix.
- **Protocol and relay engineer:** owns schemas, signaling, Cloudflare Worker,
  transport compatibility, and cross-surface acknowledgement semantics.
- **Security reviewer:** reviews trust boundaries, secret handling, permissions,
  public claims, and dependency changes.
- **QA and evidence engineer:** selects the cheapest sufficient lane, runs it,
  and records reproducible evidence.
- **Change reviewer:** independently reviews implementation correctness and test
  quality without sharing the implementer's context assumptions.
- **Integrator:** serializes accepted branches, resolves integration failures,
  and creates the bounded GitHub pull request.
- **Release operator:** handles versioning, signing, notarization, deployment,
  and release evidence only after a human release gate.

No agent is continuously active merely because a role exists. Gas City scales
sessions according to ready work and configured concurrency limits.

## Work Graph And Node Contract

Every executable node must include:

- a measurable objective and explicit non-goals;
- parent epic and dependency relationships;
- touched product surfaces and expected file ownership;
- risk class and required reviewer roles;
- model, token, time, and external-service budget;
- required resource leases;
- validation commands and acceptance evidence;
- maximum evidence-free attempts;
- human-gate conditions;
- links to predecessor failures and discovered follow-up work.

The normal lifecycle is:

`proposed -> specified -> ready -> claimed -> implementing -> locally_verified -> reviewed -> integration_ready -> ci_verified -> accepted`

`blocked`, `replan_required`, `rejected`, and `cancelled` are explicit terminal or
side states. Only the controller or assigned gate role may advance gate-owned
transitions. A worker may submit evidence and request advancement, but may not
approve its own implementation.

New work discovered during implementation is linked with
`discovered-from:<node>`. Discovery does not silently expand the current node's
scope. The planner decides whether it blocks the current objective or enters the
future queue.

## Formulas And Gates

The first Glasstunnel formulas will encode these reusable workflows:

1. **Product change:** specify, implement, targeted verification, independent
   review, integration, CI.
2. **Bug investigation:** reproduce, isolate, failing regression test, fix,
   verification, review.
3. **Cross-surface change:** contract review, protocol or backend work, Mac/web
   parity, multi-surface verification, review.
4. **Release evidence:** local readiness, security review, signed build, native
   smoke, notarization, hosted canary, human release approval.
5. **Dependency update:** compatibility check, security assessment, local test,
   bounded CI, rollback record.

Gates call existing repository commands instead of rebuilding test logic inside
the orchestrator. `pnpm agent:validate` selects touched-surface checks. The local
test lab remains the default cross-surface environment.

## Exclusive Resource Leases

The factory must serialize resources that cannot safely be shared:

- `mac-ui`
- `ios-simulator`
- `tcc-screen-recording`
- `tcc-accessibility`
- `keychain-signing`
- `notarization`
- `production-deploy`
- shared signaling and local-lab ports
- authenticated test identities with mutable state

A lease records owner node, acquisition time, expiry, heartbeat, cleanup action,
and recovery policy. Expired leases are not blindly stolen: the supervisor first
checks process and session health, then runs the resource's cleanup procedure.
Signing, notarization, production deployment, credential changes, and TCC resets
always require an explicit human gate.

Pure source work can later run on cloud or Kubernetes workers. Native Mac,
Simulator, signing, and real-app verification remain on dedicated trusted Mac
workers. Public-fork code must never execute on an unrestricted trusted Mac.

## Git And Integration Model

Direct agent pushes to `main` are removed from the default workflow.

1. The controller creates a clean worktree from the current protected baseline.
2. A worker claims one node and one branch.
3. Local gates run before review.
4. An independent reviewer accepts or returns the node with concrete findings.
5. The integrator serializes accepted branches onto an integration branch.
6. One pull request represents a coherent, bounded batch.
7. Required GitHub checks run once for that batch.
8. The merge queue lands it on protected `main` only when current checks pass.

Workers do not merge their own changes. Force pushes, destructive resets,
history rewriting, and automatic production deployment are prohibited. Failed
integration is returned to a dedicated fix node with the conflicting evidence.

## Testing Strategy

The factory follows an evidence ladder:

1. unit and static checks;
2. deterministic fixture tests;
3. Playwright browser regression tests;
4. local account-first end-to-end tests;
5. signed Mac and native lifecycle tests;
6. iOS Simulator or controlled computer-use checks;
7. a single hosted canary when local evidence cannot prove deployment behavior.

Midscene supplements this ladder for exploratory, screenshot-driven testing,
unexpected UI-state discovery, and difficult cross-origin or canvas behavior.
Any stable regression found by Midscene must be converted into the cheapest
deterministic test practical. Midscene output alone does not approve a release
gate.

Every evidence record includes command or scenario, environment, code revision,
result, artifact reference, and known limitation. Secrets, prompts, user chat
content, screen content, private paths, and personal account details are never
stored in the public ledger.

## Cost And Stale-Loop Control

The scheduler enforces both global and per-node budgets:

- maximum concurrent model sessions;
- model tier allowed by task class;
- token and wall-clock ceilings;
- external API and paid-model ceilings;
- maximum GitHub Actions runs per integration batch;
- maximum evidence-free retries.

Cheap deterministic checks precede expensive models and remote services. A
worker receives one retry when it produces materially new evidence. A second
failure with no new evidence moves the node to `replan_required`; it is not
automatically restarted.

The supervisor detects duplicate objectives, cyclic dependencies, abandoned
claims, spawn storms, repeated identical failures, orphan worktrees, and resource
leaks. Agents cannot generate unbounded follow-up nodes or raise their own
budgets. Cost policy changes require human approval.

GitHub Actions is an integration confirmation layer, not the inner development
loop. The default is one consolidated push and one inspected CI run per accepted
batch.

## Human-In-The-Loop Policy

Telegram is used when progress requires a human for:

- credentials, authentication, or account recovery;
- macOS permission or Keychain interaction;
- signing, notarization, or production approval;
- destructive or irreversible operations;
- product decisions with material ambiguity;
- budget increases;
- a repeated blocker after the allowed diagnostic attempt.

Notifications are deduplicated by node and blocker fingerprint. Each message
states what is blocked, what was attempted, the exact requested action, safety
impact, and how work resumes. Ordinary engineering choices and recoverable test
failures do not notify the user.

Human responses are recorded as decisions in Beads without copying secrets into
the ledger.

## Security Boundaries

- Runtime secrets stay in local secret storage and are passed only to the role
  that needs them.
- Beads descriptions, agent mail, GitHub comments, and transcripts are treated
  as potentially public and must not contain secrets.
- Agent roles receive least-privilege command and credential access.
- Untrusted pull-request code runs only in isolated, disposable environments.
- Trusted Mac workers do not execute public-fork code.
- Signing identities and notarization credentials are unavailable to ordinary
  implementation workers.
- Production changes require independent review and a human gate.
- Every automatic action has an owner node, bounded scope, audit event, and
  recovery path.

## Observability And Recovery

Operators need one dashboard showing current runs, node state, resource leases,
agent sessions, retry counts, token rate, estimated burn, integration queue,
human blockers, and recent failures. Gas City's run APIs and structured
transcripts are the primary runtime source; Beads is the durable work source.

Session death must not lose task state. A replacement worker receives the node,
accepted evidence, relevant prior attempts, current branch revision, and the
next uncompleted gate. It does not receive an unbounded transcript dump.

Daily automated maintenance backs up the Dolt ledger, expires safe temporary
artifacts, audits orphan worktrees, verifies control-plane health, and reports
budget anomalies. Recovery procedures are executable runbooks and are tested
before unattended operation is enabled.

## Activation Stages

The target is full factory operation, but each control layer is proven before it
is entrusted with broader authority:

1. **Foundation:** install pinned dependencies, create the city and Glasstunnel
   rig, load the custom pack, configure external mutable state, and verify backup
   and restore.
2. **Shadow control:** import a small set of real tasks, exercise dependency and
   lease logic, and observe scheduling without source mutation.
3. **Bounded workers:** allow two workers on disjoint low-risk nodes, with local
   tests and mandatory human-reviewed pull requests.
4. **Automated review and integration:** enable independent reviewers, the
   serialized integration branch, required checks, and automatic recovery.
5. **Continuous operation:** enable schedules and unattended low-risk work under
   explicit concurrency and cost limits.
6. **Distributed capacity:** move pure source workloads to isolated cloud or
   Kubernetes workers while retaining dedicated trusted Mac execution.

These are activation gates, not reduced architecture. Configuration, schemas,
and role boundaries are designed for the final system from the first stage.

## Foundation Acceptance Criteria

The first implementation phase is complete when:

- compatible Gas City, Beads, Dolt, tmux, Git, jq, and GitHub CLI versions are
  installed and recorded;
- a recoverable Glasstunnel city starts cleanly and passes its doctor checks;
- an external mirror clone is registered as the rig without rewriting the
  primary checkout or existing agent instructions;
- the checked-in Glasstunnel pack validates and loads;
- one canary graph exercises dependencies, a resource lease, a failed attempt,
  replanning, successful local validation, independent review, and integration
  readiness;
- no canary worker can push or merge to `main`;
- Telegram escalation is verified in dry-run mode without exposing secrets;
- the ledger backup can be restored into a disposable location;
- all generated machine state and raw artifacts remain outside Git;
- the existing repository validation remains green.

The foundation phase will not enable 24/7 mutation, automatic merges, release
signing, notarization, or production deployment.

## References

- Gas City: <https://github.com/gastownhall/gascity>
- Gas City releases: <https://github.com/gastownhall/gascity/releases>
- Gas City migration model: <https://github.com/gastownhall/gascity/blob/main/docs/getting-started/coming-from-gastown.md>
- Beads: <https://github.com/gastownhall/beads>
- Midscene: <https://www.midscenejs.com/introduction>
