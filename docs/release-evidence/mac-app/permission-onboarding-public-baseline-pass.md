# Mac App Release Evidence

- Date: 2026-10-30T08:45:13Z
- Scope: permission-onboarding
- Result: pass
- Environment: notarized 0.1.11 release build installed over the published 0.1.10 app on macOS 27.0.1
- Glasstunnel commit: 2033fef2
- Artifact: artifacts/mac-live-public-baseline.txt
- Privacy review: pass

## Passed

The notarized `0.1.11` app, installed over 0.1.10 in Applications, kept the
previously granted Screen Recording and Accessibility permissions: the system
privacy database still lists both as allowed for `io.glasstunnel.host`, and the
app launched straight to its linked Access page without any permission prompt or
stale Grant action. The bundle keeps the same bundle identifier, Developer ID team,
and designated requirement, which the isolated install smoke also checked. Gate
tests still cover the missing-permission and disabled Continue states.

## Limitations

macOS can still require an app relaunch after changing Screen Recording permission.
A first install on a Mac that never granted the permissions still goes through the
onboarding prompts; that path was last recorded live on 0.1.4. Screen sharing from
a phone against the installed app was not repeated in this check; the Mac Screen
lanes at `2033fef2` exercised capture with the lab host.
