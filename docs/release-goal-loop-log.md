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
- Evidence recorded: Mac Screen and Terminal public baseline records are bound to tested commit 4a2ef67e.
- Outcome: passed
- Uncertainty: The unused x/crypto OpenPGP package has a module-level no-fix notice, but it is not imported or reachable; repository visibility still requires explicit maintainer approval.
- Stale-loop risk: Low; future dependency refreshes must retain or replace the minimatch compatibility patches while keeping audits and tooling green.
- Next action: Make one consolidated push, inspect one bounded CI run, and leave production deployment manual.
- End commit: The documentation-only descendant containing this entry is the immutable result of record.
- CI/deploy: The final consolidated push is validated by its single immutable CI run; production Deploy remains manual and is not triggered.

## 2026-07-28 09:45 - First public beta

- Start commit: 24781da8
- Release gate: Public source, installable notarized beta, and honest runtime evidence.
- Why chosen: Source preparation was complete, but users still had no immutable public binary or verified cask.
- Files changed: Version metadata, release notes, cask metadata, current release evidence, and bounded release tooling.
- Validation: 323 Swift tests, local account E2E, real installed Codex CLI smoke, Terminal recovery, Mac Screen regression, public-URL Homebrew install, codesign, Gatekeeper, notarization, and production cache headers passed.
- Manual testing: The published `0.1.4` app retained live permissions and account state across relaunch. The linked Mac appeared connected in production. Native Mac Screen reached streaming, stopped, restarted to streaming, and was left off.
- Evidence recorded: The DMG is tied to source commit `c457c2b2d271186716d7301bad14cb4a3132defd`; SHA-256 is `caa5af121773ce379e41d36c8def34c84fc1a706fc6dc3186156c12d128cc570`.
- Outcome: passed
- Uncertainty: Preview integrations remain upstream-sensitive; physical cellular handoff and every TURN path are not release gates.
- Stale-loop risk: Low; one notarization submission, one tag, one prerelease, and one final branch push are used.
- Next action: Inspect the single final CI run, then start the next loop from a documented beta risk.
- End commit: The final release documentation and cask commit is the result of record.
- CI/deploy: The final `main` push is the single result-of-record run; no rerun or production deploy is requested.

## 2026-08-01 13:30 - Codex compatibility beta update

- Start commit: added831
- Release gate: Restore mobile prompt delivery with the current Codex desktop app and publish the accumulated Mac hardening.
- Why chosen: Codex changed its local project schema and generic desktop window title, leaving real projects labeled as raw IDs and the mobile composer disabled.
- Files changed: Codex desktop adapter and tests, Mac release metadata, release notes, cask metadata, local signing stability, and upgrade-smoke source policy.
- Validation: 334 Swift tests, 47 Lab tests, 53 focused mobile tests, live Codex task selection, Developer ID preflight, Apple notarization, stapling, Gatekeeper, isolated `0.1.4` to `0.1.5` upgrade, and disposable Homebrew install passed.
- Manual testing: The signed Local Test Lab opened the exact existing Codex task, loaded its matching history, showed a truthful done state, and accepted then cleared unsent composer text.
- Evidence recorded: The DMG is tied to source commit `8eb429ce`; SHA-256 is `4f74a23ca64df907d7b44c8ab7edbf722c19819f8f9c1118f8b12de2f0409fef`.
- Outcome: passed
- Uncertainty: Codex desktop remains Preview because upstream UI compatibility and broader relaunch behavior still need repeatable coverage.
- Stale-loop risk: Low; one notarization submission, one tag, one prerelease, and one consolidated branch push are used.
- Next action: Continue Preview hardening from the support matrix without widening public support claims.
- End commit: The final release documentation and cask commit is the result of record.
- CI/deploy: The consolidated publication commit is checked by one CI run; no production web deploy is requested.

## 2026-08-16 14:30 - Installer and latest-download beta patch

- Start commit: b360e326
- Release gate: Replace the public DMG that lacked an Applications drag target and prevent stale landing-page download links.
- Why chosen: The published `0.1.5` DMG mounted without an `/Applications` shortcut, the public site hardcoded versioned DMG URLs, and deleting the app alone could be mistaken for sign-out.
- Files changed: Mac release assembly, install smoke, app/PWA icon assets, sign-out wording/identity rotation, website download links, release asset prep, Homebrew cask metadata, and release docs.
- Validation: Developer ID signing, Apple notarization, stapling, Gatekeeper assessment, isolated install/reinstall, stable latest-release asset preparation, site download-link audit, site/workspace builds, workspace tests, lint, shell syntax, and distribution/security/public audits pass.
- Manual testing: The mounted `0.1.6` DMG contains `Glasstunnel.app` and an `Applications` symlink; the mounted app is accepted by Gatekeeper.
- Evidence recorded: The DMG is tied to source commit `54b57fc3`; SHA-256 is `edaa9d317414b03ccf332f6418d11149161ab4de4d2e6125d79bf7df9b41a5c4`; Apple submission ID is `5fe7ba6a-1c00-4a8f-be24-c21f661a23b6`.
- Outcome: passed
- Uncertainty: Public GitHub Release asset and hosted-site behavior still require final upload/deploy verification after the consolidated push.
- Stale-loop risk: Low; one notarization submission was used and the website now resolves the latest DMG through a stable GitHub release asset.
- Next action: Push the consolidated release commit, inspect one CI/deploy run, create `v0.1.6`, upload both immutable and stable DMG assets, then verify the public download URL.
- End commit: The final release documentation and cask commit is the result of record.
- CI/deploy: Pending the final consolidated push for this release slice.
