# Mac App Release Evidence

- Date: 2026-09-03T08:45:00Z
- Scope: permission-onboarding
- Result: pass
- Environment: notarized 0.1.8 release build installed over the published 0.1.7 app on macOS 26.6.2
- Glasstunnel commit: 2e4b25ff
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

The notarized `0.1.8` app, installed over `0.1.7` by dragging it into Applications,
reflected the previously granted Screen Recording and Accessibility state on launch
and advanced directly to the linked app without any new permission prompt or stale
Grant action. The Claude card, which depends on Accessibility, was offered in the Mac
app. Gate tests still cover the missing-permission and disabled Continue states.

## Limitations

macOS can still require an app relaunch after changing Screen Recording permission.
A first install on a Mac that never granted the permissions still goes through the
onboarding prompts; that path was last recorded live on 0.1.4.
