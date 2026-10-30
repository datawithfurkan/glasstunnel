# Packaging and distributing the Mac host

The Swift package under `apps/host-macos` builds as an `executable` target, which is perfect for `swift run` and for Xcode. Turning it into a distributable `.app` bundle with Developer ID signing + notarization requires a few extra steps.

## Verified baseline

Apple accepted and notarized `Glasstunnel-0.1.13.dmg` from source commit
`a1d3537f`. Stapling, Gatekeeper assessment, isolated install/reinstall and
0.1.12 → 0.1.13 upgrade, an in-app update from the published 0.1.12, stable
latest-download asset preparation, the signed update feed (`appcast.xml`), and
cask metadata validation all passed. The published artifact and cask use SHA-256
`9138bceccd8e5af33a7e0a71e0b881afee62d3274aa3f1293a63966e56ed60b1`.

## One-time setup

1. Join Apple's Developer Program ($99/year). This is what unlocks a Developer ID certificate.
2. In Xcode → Settings → Accounts, sign in and download your Developer ID Application + Developer ID Installer certificates.
3. Create a notarization app-specific password in https://appleid.apple.com/account/manage and stash it:

   ```bash
   xcrun notarytool store-credentials glasstunnel-notary \
     --apple-id YOU@YOURDOMAIN.com \
     --team-id YOURTEAMID \
     --password abcd-efgh-ijkl-mnop
   ```

## Local packaging verification

Before building, run the preflight:

```bash
pnpm release:mac:preflight
```

This checks local tools, installed Developer ID identity status, optional existing `dist/` artifacts, and Homebrew availability. It does not contact Apple by default and should not trigger keychain password prompts intentionally.

It also verifies that `apps/host-macos/Metadata/entitlements.plist`
contains the release entitlements required by the package script:

- `com.apple.security.device.screen-capture`
- `com.apple.security.automation.apple-events`
- `com.apple.security.cs.disable-library-validation`

The preflight also verifies the stable bundle identifiers that macOS uses for
permission grants:

- Release app: `io.glasstunnel.host`
- Development wrapper: `io.glasstunnel.host.dev`

If either identifier drifts, fix that before testing Screen Recording or
Accessibility again. Otherwise macOS may treat the rebuilt app as a different
application and users can see permission prompts that do not match the visible
System Settings state.

For repeatable local permission, reinstall, and upgrade testing, use the stable
local signing identity created by `scripts/ensure-dev-codesign-identity.sh`:

```bash
./scripts/build-app.sh --local-sign 0.1.0
```

`--local-sign` invokes the helper automatically before building. The helper
creates or unlocks `~/Library/Keychains/glasstunnel-dev-signing.keychain-db`,
restores non-interactive `codesign` access, and keeps its random password in
`~/Library/Application Support/Glasstunnel/dev-signing-keychain-password` with
user-only permissions. That password lives outside the repository and must
never be copied into an `.env`, tracked file, CI variable, screenshot, or log.

`--local-sign` preserves the app's designated signing requirement across local
rebuilds, so macOS can attach TCC decisions consistently. It is still local-only:
it does not prove Developer ID signing, notarization, or public Gatekeeper behavior.

For a deliberately ad-hoc assembly check without a stable local identity:

```bash
./scripts/build-app.sh --ad-hoc 0.1.0
```

Both local modes embed the exact source commit and source-cleanliness state in
the app bundle. The preflight and install smoke reject stale, unbound, or dirty
artifacts instead of reporting an old DMG as current release evidence.

The ad-hoc command builds the Release Swift package, assembles
`dist/Glasstunnel.app`, signs it with the same entitlements shape used for
release signing, and creates `dist/Glasstunnel-0.1.0.dmg`.

This mode is for local packaging checks only. It does not prove Developer ID signing, notarization, Gatekeeper behavior, or production macOS TCC identity.

### Installer window

`scripts/build-app.sh` packages the app with `scripts/dmg/build-dmg.sh`: a
660x400 window with the drag-to-Applications artwork, the app and an
`/Applications` link placed on it, and the app icon as the disk icon.
[dmgbuild](https://github.com/dmgbuild/dmgbuild) (pinned, installed once into
`apps/host-macos/.build/dmg-tools`) writes the Finder layout, so no Finder
scripting or Automation permission is involved. The artwork lives in
`apps/host-macos/Metadata/dmg/`; after changing `scripts/dmg/background.py`,
regenerate it with that venv's Python after `pip install Pillow` there, and keep the icon
positions in `scripts/dmg/settings.py` in step with it.

After a current DMG exists, verify the install/reinstall artifact path without touching
your real `/Applications` folder:

```bash
pnpm release:mac:install-smoke
```

This mounts the newest `dist/Glasstunnel-*.dmg`, verifies the installer volume
contains both `Glasstunnel.app` and an `/Applications` drag target, copies
`Glasstunnel.app` into an isolated temporary Applications folder, reinstalls
that version, and verifies the bundle ID, source commit, clean-source marker,
version, executable, code signature, required signed entitlements, both
supported Mac architectures, and the embedded signed `WebRTC.framework` plus
its runtime search path.

To prove a real version-to-version upgrade, build two clean-commit artifacts
with the same stable identity and pass both DMGs explicitly:

```bash
GT_MAC_INSTALL_REQUIRE_UPGRADE=1 pnpm release:mac:install-smoke -- \
  dist/Glasstunnel-0.1.0.dmg \
  dist/Glasstunnel-0.1.1.dmg
```

The smoke requires the second version to be newer and the designated signing
requirement to remain identical. It does not launch the app, reset macOS
permissions, prove Gatekeeper first launch, or verify notarization.

To require release credentials and verify the notary profile against Apple, run:

```bash
GT_DEVELOPER_ID="Developer ID Application: YOUR NAME (TEAMID)" \
  GT_NOTARY_PROFILE=glasstunnel-notary \
  pnpm release:mac:preflight -- --live-notary --require-release-creds
```

## Building a signed `.app`

We ship a `scripts/build-app.sh` that does:

- Builds arm64 and x86_64 releases in isolated SwiftPM scratch directories,
  then merges the executable into one universal binary.
- Assembles a proper `Glasstunnel.app` bundle under `dist/`, copying
  `Metadata/Info.plist` and the universal `WebRTC.framework` into the correct
  bundle locations and adding the app Frameworks runtime search path.
- Code-signs the embedded framework, any packaged dynamic libraries, and the
  app bundle with your Developer ID and `apps/host-macos/Metadata/entitlements.plist`.
- Rejects dirty source trees before a Developer ID build.
- Invokes `notarytool submit --wait`, requires Apple's `Accepted` status, and
  retains both the submission response and Apple's notarization log under
  `dist/notarization/`.
- Requires the SHA-256 in Apple's log to match the exact DMG being verified.
- Bounds the initial Apple wait to 30 minutes. If Apple is still processing,
  retains the submission ID even when `notarytool` emits its timeout response
  on stderr, then resumes that ID with `GT_NOTARY_SUBMISSION_ID` instead of
  uploading a duplicate submission.
- Staples and validates the DMG ticket.
- Requires Gatekeeper to accept both the DMG and its mounted app before the
  build reports success.

Run:

```bash
GT_DEVELOPER_ID="Developer ID Application: YOUR NAME (TEAMID)" ./scripts/build-app.sh 0.1.0
```

Outputs:

- `dist/Glasstunnel.app` — Developer ID-signed app used to create the DMG
- `dist/Glasstunnel-0.1.0.dmg` — notarized, stapled, Gatekeeper-accepted download
- `dist/notarization/Glasstunnel-0.1.0-notary-submit.plist` — Apple submission result
- `dist/notarization/Glasstunnel-0.1.0-notary-log.json` — Apple diagnostic log

If you need to verify Developer ID signing without notarizing, use:

```bash
GT_DEVELOPER_ID="Developer ID Application: YOUR NAME (TEAMID)" ./scripts/build-app.sh --skip-notarize 0.1.0
```

This mode verifies Developer ID signatures and packaging only. It deliberately
does not claim notarization, stapling, or Gatekeeper acceptance.

The deterministic notarization smoke exercises accepted and rejected Apple
responses, a non-zero submit, a timeout response emitted on stderr, an Apple log
issue, and existing-submission resume without contacting Apple:

```bash
pnpm qa:mac:notarization
```

For a submission that exceeded the bounded wait, use the ID retained in the
submission plist:

```bash
GT_DEVELOPER_ID="Developer ID Application: YOUR NAME (TEAMID)" \
  GT_NOTARY_SUBMISSION_ID="EXISTING-SUBMISSION-UUID" \
  ./scripts/notarize-mac-release.sh dist/Glasstunnel-0.1.0.dmg
```

## In-app updates

Release builds update themselves with [Sparkle](https://sparkle-project.org)
(pinned in `apps/host-macos/Package.swift`). The app checks
`https://glasstunnel.io/appcast.xml` once a day, and on **Glasstunnel >
Check for Updates…**, the menu bar icon's **Check for Updates…**, or
**Settings > Updates**. When a newer version exists it
shows the release notes and an **Install Update** button, then installs the new
version and relaunches. People can turn off the daily check or let new versions
download and install the next time the app quits.

What protects an update:

- The app only accepts a signed feed (`SURequireSignedFeed`), and checks each
  DMG's EdDSA signature before opening it (`SUVerifyUpdateBeforeExtraction`).
  Both use the update key pair below.
- The DMG and the app inside are also Developer ID signed and notarized, as
  for a manual download. A code-signed DMG also lets the update key be rotated.
- `glasstunnel.io/appcast.xml` redirects (`site/public/_redirects`) to the
  latest GitHub Release's `appcast.xml`, so publishing a release needs no site
  deploy.

Only Developer ID builds get the public key (`SUPublicEDKey`), from
`apps/host-macos/Metadata/sparkle-public-ed-key.txt`. Ad-hoc, local-sign and
development builds get none, never update themselves, and open GitHub Releases
from the same menu item instead.

### One-time update key setup

The private key lives in the maintainer's login Keychain and nowhere else.
Losing it means existing installs can no longer verify updates, so back it up.

```bash
swift package resolve --package-path apps/host-macos
SPARKLE_BIN=apps/host-macos/.build/artifacts/sparkle/Sparkle/bin
# Creates the key pair in the login Keychain (account "glasstunnel").
"$SPARKLE_BIN/generate_keys" --account glasstunnel
# Save the public key as the release key file:
"$SPARKLE_BIN/generate_keys" --account glasstunnel -p > apps/host-macos/Metadata/sparkle-public-ed-key.txt
# Export the private key once, outside the checkout, store it in a password
# manager, then delete the file:
"$SPARKLE_BIN/generate_keys" --account glasstunnel -x ~/sparkle-private-key.txt
```

Commit `sparkle-public-ed-key.txt`; never commit the private key. Release builds
fail until the public key file exists.

### Releasing an update

`pnpm release:mac:assets -- VERSION dist/Glasstunnel-VERSION.dmg` now also writes
`dist/appcast.xml`: one item for the new DMG, with the CHANGELOG section
`## VERSION` as its release notes. It signs the DMG entry and the feed with the
Keychain key (account `glasstunnel`, or `GT_SPARKLE_PRIVATE_KEY_FILE`), then
verifies both. Upload
`appcast.xml` with the DMGs. To write only the feed:

```bash
pnpm release:mac:appcast -- 0.1.0 dist/Glasstunnel-0.1.0.dmg
```

Installs older than the first Sparkle release (0.1.10 and earlier) cannot update
themselves; their owners install the next version once by hand.

To prove the whole path on this Mac without the real key or app, run the update
smoke. It builds a tiny throwaway app with the same embedded, signed Sparkle,
serves a signed feed from `127.0.0.1`, and checks that version 1.0.0 replaces
itself with 1.0.1:

```bash
pnpm qa:mac:update-smoke
```

## Homebrew cask

`Casks/glasstunnel.rb` is the Homebrew cask recipe. It points at the `.dmg` you publish to GitHub Releases. Glasstunnel updates itself, so the cask declares `auto_updates true` and `brew upgrade` only replaces it with `--greedy`. Users install from the project tap with:

```bash
brew tap datawithfurkan/glasstunnel https://github.com/datawithfurkan/glasstunnel
brew install --cask datawithfurkan/glasstunnel/glasstunnel
```

The app's own updater is the usual way to upgrade. To upgrade through Homebrew
after a newer release and matching cask revision are published:

```bash
brew update
brew upgrade --cask --greedy datawithfurkan/glasstunnel/glasstunnel
```

Cask updates use `scripts/update-homebrew-cask.sh`, which bumps the version and SHA256 in the recipe:

```bash
./scripts/update-homebrew-cask.sh 0.1.0 dist/Glasstunnel-0.1.0.dmg
```

If the DMG is already remote, pass the SHA256 directly:

```bash
./scripts/update-homebrew-cask.sh 0.1.0 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef
```

Then audit the recipe through the disposable local audit tap before copying it
into a public Homebrew tap:

```bash
pnpm qa:mac:cask-audit
```

The local updater smoke verifies the cask bump flow without editing the tracked
recipe:

```bash
pnpm qa:mac:cask-update
```

## Website download button

The public site should not hardcode a versioned DMG URL. It points at GitHub's
latest-release asset instead:

```text
https://github.com/datawithfurkan/glasstunnel/releases/latest/download/Glasstunnel.dmg
```

Every GitHub Release should still include the immutable, versioned asset for
auditing and Homebrew, the stable alias used by the website, and the signed
update feed:

```bash
pnpm release:mac:assets -- 0.1.0 dist/Glasstunnel-0.1.0.dmg
gh release upload v0.1.0 \
  dist/Glasstunnel-0.1.0.dmg dist/Glasstunnel-0.1.0.dmg.sha256 \
  dist/Glasstunnel.dmg dist/Glasstunnel.dmg.sha256 \
  dist/appcast.xml
```

`pnpm qa:site-download-links` rejects versioned DMG links in the public site so
future release bumps do not leave the download buttons stale.

To exercise a real Homebrew cask install without publishing a release or
touching `/Applications`, pass a current local DMG to the isolated cask smoke:

```bash
pnpm qa:mac:cask-install -- dist/Glasstunnel-0.1.0.dmg
```

The smoke creates a temporary no-git tap, installs the cask into a temporary
Applications directory with Homebrew updates and cleanup disabled, verifies the
installed app, then removes its cask receipt, tap, and temporary files while
restoring the user's original Homebrew developer-mode state.

Current Homebrew refuses to load casks from untrusted taps. Both the audit and
the install smoke trust only their disposable cask (`brew trust --cask`) for
the run and put that one trust entry back the way it was on exit, so the
user's other `brew trust` settings are never touched.

## App assembly source of truth

Do not assemble release bundles manually. The universal executable, embedded
WebRTC framework, nested signing order, source metadata, notarization log,
staple validation, and Gatekeeper assessments in `scripts/build-app.sh` and
`scripts/notarize-mac-release.sh` are one release contract.

## Entitlements

The release script signs with `apps/host-macos/Metadata/entitlements.plist`.
It must include:

- `com.apple.security.device.screen-capture` — ScreenCaptureKit
- `com.apple.security.automation.apple-events` — if any AppleScript paths are used (future)
- `com.apple.security.cs.disable-library-validation` — required for loading WebRTC.framework from Swift package

If you change entitlements, re-notarize.
