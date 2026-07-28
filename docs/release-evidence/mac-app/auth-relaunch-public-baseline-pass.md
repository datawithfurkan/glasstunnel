# Mac App Release Evidence

- Date: 2026-07-28T07:34:00Z
- Scope: auth-relaunch
- Result: pass
- Environment: published notarized 0.1.4 build with an existing linked account
- Glasstunnel commit: c457c2b2d271186716d7301bad14cb4a3132defd
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

The published app showed the linked Mac online and ready, then remained linked across
a full process termination and relaunch without returning to permission or sign-in
screens. The production web app independently showed the same Mac as connected.

## Limitations

Revoking the account or macOS permissions correctly requires the corresponding flow again.
