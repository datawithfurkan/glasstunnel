# Release goal-loop log

Keep only the current public release movement here. Detailed local diagnostics belong
in ignored test output, not in Git. Add a new dated entry only when a release gate
changes or a blocker is materially narrowed.

## 2026-07-27 18:00 - Public repository preparation

- Start commit: 811a8242
- Release gate: Public source privacy, contributor setup, and support-claim clarity.
- Why chosen: Repository visibility would expose historical personal metadata and raw QA artifacts.
- Files changed: Public docs, evidence summaries, privacy audit tooling, community files, and stale terminal-attachment cleanup.
- Validation: Public audit, full-history secret scan, security/privacy audit, clean-clone builds, 322 Swift tests, and local browser lanes pass. The signed local artifact is rebuilt after the final commit before the final release-readiness run.
- Manual testing: Existing supported-scope evidence was reviewed and reduced to sanitized summaries; 493 orphaned attachment clients were removed while five persistent terminal sessions remained intact.
- Evidence recorded: Private recovery archives plus public summary records under docs/release-evidence.
- Outcome: passed
- Uncertainty: Repository visibility still requires explicit maintainer approval; branch protection must be enabled during that transition.
- Stale-loop risk: Low; local release gates are complete and the remaining work is one bounded hosted check.
- Next action: Push the sanitized history once, inspect its CI check once, and leave production deployment manual.
- End commit: The final documentation commit containing this entry is the immutable result of record.
- CI/deploy: CI runs once on the immutable pushed commit; production Deploy is manual and was not triggered.
