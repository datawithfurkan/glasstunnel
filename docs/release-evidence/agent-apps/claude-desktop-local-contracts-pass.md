# Agent App Release Evidence

- Date: 2026-09-02T12:13:12Z
- App: Claude desktop
- Result: pass
- Environment: Claude desktop app 1.40609.1 installed and running on the development Mac; local contracts, store parsing, and a read-only Accessibility probe from a trusted process
- Glasstunnel commit: 95c792bf
- Artifact: artifacts/claude-desktop-local-contracts.txt
- Privacy review: pass

## Passed

`/Applications/Claude.app` was verified as `com.anthropic.claudefordesktop` with the
`claude://` scheme registered and the app running. The shared Claude Code store
held 9 desktop-owned and 4 other sessions, all classified correctly by
`entrypoint`; the adapter's parser reported running sessions as working and
finished sessions as ready, with their titles and models. The Glasstunnel hooks
were installed and forward the notification type. The read-only Accessibility
probe (`pnpm qa:claude-desktop:live-ax`) found the app's composer, exposed with the
description "Prompt", and the "<name>, rename session" control that names the
session in front; the adapter's composer hints and front-session check were
updated to match. Every `claude://code` deep-link form was answered with "deep link
gated off" in the app's own log on this build.

## Limitations

Prompt delivery, session switching, permission-dialog control, and AskUserQuestion
answers on a real Claude window are not yet recorded; `pnpm lab:e2e:claude-desktop`
covers them and needs a dedicated app session titled "Glasstunnel live evidence"
with the window left alone. The Claude desktop card stays Experimental.
