# Mac App Release Evidence

- Date: 2026-07-28T07:33:00Z
- Scope: permission-onboarding
- Result: pass
- Environment: notarized release build on macOS
- Glasstunnel commit: c457c2b2d271186716d7301bad14cb4a3132defd
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

The published `0.1.4` app reflected the previously granted Screen Recording and
Accessibility state on launch and advanced directly to the linked app instead of
showing stale Grant actions. Gate tests still cover the missing-permission and disabled
Continue states.

## Limitations

macOS can still require an app relaunch after changing Screen Recording permission.
