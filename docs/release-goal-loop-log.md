# Release goal-loop log

Keep only the current public release movement here. Detailed local diagnostics belong
in ignored test output, not in Git. Add a new dated entry only when a release gate
changes or a blocker is materially narrowed.

## 2026-07-27 18:00 - Public repository preparation

- Start commit: 811a8242
- Release gate: Public source privacy, contributor setup, and support-claim clarity.
- Why chosen: Repository visibility would expose historical personal metadata and raw QA artifacts.
- Files changed: Public docs, evidence summaries, privacy audit tooling, community files, and stale terminal-attachment cleanup.
- Validation: Public audit, full-history secret scan, security/privacy audit, clean-clone builds, 323 Swift tests, and local browser lanes pass. The signed local artifact is rebuilt after the final commit before the final release-readiness run.
- Manual testing: Existing supported-scope evidence was reviewed and reduced to sanitized summaries; 493 orphaned attachment clients were removed, the lifecycle regression was fixed, the final suite left zero attachment clients, and five persistent terminal sessions remained intact.
- Evidence recorded: Private recovery archives plus public summary records under docs/release-evidence.
- Outcome: passed
- Uncertainty: Repository visibility still requires explicit maintainer approval; branch protection must be enabled during that transition.
- Stale-loop risk: Low; local release gates are complete and the remaining work is one bounded hosted check.
- Next action: Push the sanitized history once, inspect its CI check once, and leave production deployment manual.
- End commit: The final documentation commit containing this entry is the immutable result of record.
- CI/deploy: CI runs once on the immutable pushed commit; production Deploy is manual and was not triggered.

## 2026-07-28 04:25 - Dependency security remediation

- Start commit: fdf62d7c
- Release gate: Public dependency and runtime security.
- Why chosen: GitHub vulnerability alerts exposed critical and high advisories after the sanitized history push.
- Files changed: JavaScript and Go dependency manifests, lockfiles, CI toolchain pins, compatibility patches, and sanitized release evidence.
- Validation: Frozen install, npm audit, govulncheck, Go build/vet/tests, workspace lint/typecheck/tests/build, security/privacy audit, public audit, Chromium and WebKit Mac Screen lanes, and the Terminal smoke pass.
- Manual testing: Cleanup inspection confirmed the local lab stopped all owned services and did not alter pre-existing Terminal sessions.
- Evidence recorded: Mac Screen and Terminal public baseline records are bound to dependency commit 24f43df4.
- Outcome: passed
- Uncertainty: The unused x/crypto OpenPGP package has a module-level no-fix notice, but it is not imported or reachable; repository visibility still requires explicit maintainer approval.
- Stale-loop risk: Low; future dependency refreshes must retain or replace the minimatch compatibility patches while keeping audits and tooling green.
- Next action: Make one consolidated push, inspect one bounded CI run, and leave production deployment manual.
- End commit: The documentation-only descendant containing this entry is the immutable result of record.
- CI/deploy: The final consolidated push is validated by its single immutable CI run; production Deploy remains manual and is not triggered.
