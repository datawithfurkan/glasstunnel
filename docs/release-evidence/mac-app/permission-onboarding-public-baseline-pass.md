# Mac App Release Evidence

- Date: 2026-10-30T09:16:05Z
- Scope: permission-onboarding
- Result: pass
- Environment: published 0.1.11 app updated in place to the notarized 0.1.12 release by its own updater on macOS 27.0.1
- Glasstunnel commit: f094160b
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

After the in-app update from 0.1.11 to 0.1.12, the system privacy database still
lists Screen Recording and Accessibility as allowed for `io.glasstunnel.host`, and
the relaunched app opened straight to its linked Access page without any permission
prompt or stale Grant action. The bundle keeps the same bundle identifier,
Developer ID team, and designated requirement, which the isolated install smoke
also checked. Gate tests still cover the missing-permission and disabled Continue
states.

## Limitations

macOS can still require an app relaunch after changing Screen Recording permission.
A first install on a Mac that never granted the permissions still goes through the
onboarding prompts; that path was last recorded live on 0.1.4. Screen sharing from
a phone against the updated app was not repeated in this check.
