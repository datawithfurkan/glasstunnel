# Mac App Release Evidence

- Date: 2026-09-10T13:31:17Z
- Scope: permission-onboarding
- Result: pass
- Environment: notarized 0.1.10 release build installed over an unreleased 0.1.10 build from 1f980121 (itself installed over the published 0.1.9 app) on macOS 26.6.2
- Glasstunnel commit: 8550bec4
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

The notarized `0.1.10` app, installed by dragging it into Applications over the
previous build, reflected the previously granted Screen Recording and Accessibility
state on launch and advanced directly to the linked app without any new permission
prompt or stale Grant action. From a phone-sized browser (iOS 26.5 Simulator,
Safari) screen sharing started at once in Readable, switched to Fast and back with
the picture following each time, and stopped cleanly, which exercises the persisted
Screen Recording permission; the Codex, Claude, and Cursor cards, which depend on
Accessibility, stayed offered. Gate tests still cover the missing-permission and
disabled Continue states.

## Limitations

macOS can still require an app relaunch after changing Screen Recording permission.
A first install on a Mac that never granted the permissions still goes through the
onboarding prompts; that path was last recorded live on 0.1.4. On iOS Safari the
picture-size readout next to "Screen ready" did not appear in this check; the
stream itself was correct in both qualities.
