# Agent App Release Evidence

- Date: 2026-09-02T09:20:42Z
- App: Claude desktop
- Result: pass
- Environment: Claude desktop app 1.40609.1 installed and running on the development Mac; local contracts and store parsing only
- Glasstunnel commit: 2c4d343e
- Artifact: artifacts/claude-desktop-local-contracts.txt
- Privacy review: pass

## Passed

`/Applications/Claude.app` was verified as `com.anthropic.claudefordesktop` with the
`claude://` scheme registered. The shared Claude Code store held 7 desktop-owned and
3 other sessions, all classified correctly by `entrypoint`; the adapter's parser
reported the running desktop session as working and finished sessions as ready,
with their titles and models. The CLI flag surface and hook state checks passed
(`pnpm qa:claude-desktop`). Every `claude://code` deep-link form was answered with
"deep link gated off" in the app's own log on this build, which is why the adapter
verifies the front window title and falls back to Accessibility navigation.

## Limitations

Accessibility prompt delivery, session switching, and permission-dialog control on
a real Claude window were not exercised (they need an Accessibility-trusted
process), and the phone-driven flow through the mobile browser is not recorded.
The Claude desktop card therefore stays Experimental.
