# Public release readiness

Last updated: 2026-09-02.

This checklist is the current release baseline. Historical investigations and raw
test artifacts are intentionally not stored in the public repository.

## Ready

- [x] Supported scope is limited to Mac Screen and the scoped Terminal path.
- [x] Permission onboarding reads current macOS Screen Recording and Accessibility state.
- [x] Account-first sign-in and relaunch persistence have live Mac evidence.
- [x] Local Test Lab covers disposable auth, Worker relay, PWA, and isolated host testing.
- [x] Mobile Chromium and WebKit regression lanes are available locally.
- [x] Developer ID signing path is documented and tested.
- [x] Notarization path is documented and tested.
- [x] Gatekeeper launch and install/upgrade scripts are documented.
- [x] Secret-bearing local files and raw release artifacts are ignored.
- [x] npm audit reports zero advisories and Go reports zero reachable vulnerabilities.
- [x] Support tiers and known limitations are documented without overclaiming Preview integrations.

## Public repository

- [x] Run the public repository audit and full-history secret scan.
- [x] Confirm the sanitized public-history rewrite and private recovery bundle.
- [x] Verify a clean clone can install, run `pnpm lab:doctor`, build, and execute the local test lane.
- [x] Run `pnpm release:readiness` from the committed release candidate and rebuilt local artifact.
- [x] Use one sanitized push and the immutable CI check on that commit as the result of record.
- [x] Complete `docs/public-visibility-checklist.md` with no source-readiness blocker.

- [x] Maintainer approved the visibility change and the repository is public.
- [x] Repository description, homepage, topics, vulnerability alerts, secret scanning,
      and push protection are configured.
- [x] Protect `main` with the five required CI checks, linear history, one approving
      review for contributor pull requests, and force-push/deletion prevention.

## First downloadable public beta

- [x] Publish the accepted, notarized DMG and SHA-256 checksum through GitHub Releases.
- [x] Point the Homebrew cask at the immutable release asset and checksum.
- [x] Verify a clean-prefix Homebrew install and Gatekeeper first launch from the public URL.
- [x] Publish release notes that identify Supported, Preview, and Experimental features.
- [x] Verify the published Mac app retains live permissions, account linking, and relaunch state.
- [x] Verify Supported Terminal and Mac Screen paths plus one real Codex CLI Preview smoke.
- [x] Verify production app-shell and service-worker cache headers revalidate.

The `0.1.4` prerelease is the first downloadable public beta. Its signed and notarized
DMG is intentionally tied to source commit `c457c2b2d271186716d7301bad14cb4a3132defd`;
release-only documentation and cask updates are descendants of that immutable source.
Developer ID signing/notarization, stapling, and Gatekeeper verification all passed for
that published artifact.

The `0.1.6` public beta release is the current public beta. Its signed and notarized DMG is tied
to source commit `54b57fc3` and SHA-256
`edaa9d317414b03ccf332f6418d11149161ab4de4d2e6125d79bf7df9b41a5c4`.
Developer ID signing/notarization, stapling, Gatekeeper verification, isolated
install/reinstall, stable latest-download asset preparation, and cask metadata
validation passed. It replaces the `0.1.5` DMG, whose installer volume lacked an
Applications drag target.

The `0.1.7` public beta release is the current public beta. Its signed and notarized DMG is tied
to source commit `dbf8a90d` and SHA-256
`17420e334e9e280212c7aa4db550c953a43b0b20b7057d1d6d2fa1c5d75bb334`.
Developer ID signing/notarization, stapling, Gatekeeper verification, isolated
install/reinstall and 0.1.6 → 0.1.7 upgrade, stable latest-download asset preparation, and
cask metadata validation passed. It adds the Claude desktop and Claude Code cards in Preview
with recorded real-app evidence, and fixes the relay authentication race and the Mac Screen
reconnect bug.
