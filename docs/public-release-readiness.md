# Public release readiness

Last updated: 2026-07-27.

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
- [x] Support tiers and known limitations are documented without overclaiming Preview integrations.

## Before changing repository visibility

- [ ] Run the public repository audit and full-history secret scan.
- [ ] Confirm the sanitized public-history rewrite and private recovery bundle.
- [ ] Verify a clean clone can install, run `pnpm lab:doctor`, build, and execute the local test lane.
- [ ] Run `pnpm release:readiness` from the release candidate.
- [ ] Push once, then confirm the bounded CI and deploy run.
- [ ] Complete `docs/public-visibility-checklist.md` with no unresolved blocker.

## Before the first downloadable public beta

- [ ] Publish the accepted, notarized DMG and SHA-256 checksum through GitHub Releases.
- [ ] Point the Homebrew cask at the immutable release asset and checksum.
- [ ] Verify a clean-machine Homebrew install and Gatekeeper first launch.
- [ ] Publish release notes that identify Supported, Preview, and Experimental features.

Developer ID signing/notarization is complete as a tested distribution path. A
public repository and a public binary release are separate decisions: opening the
source does not imply that an installable binary is already available.
