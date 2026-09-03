# Mac App Release Evidence

- Date: 2026-09-03T19:26:29Z
- Scope: auth-relaunch
- Result: pass
- Environment: notarized 0.1.9 release build installed over the published 0.1.8 app with an existing linked account
- Glasstunnel commit: f660996b
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

After the `0.1.8` app was quit and the `0.1.9` build was dragged into Applications
and launched, the app remained signed in and linked without returning to a sign-in,
device-link, or permission screen, and its settings showed version 0.1.9. The lab
lanes recorded earlier the same evening had run against the same commit with the
installed app quit, so the relaunch also confirms the installed app takes the Claude
hooks back on start.

## Limitations

Revoking the account or macOS permissions correctly requires the corresponding flow again.
