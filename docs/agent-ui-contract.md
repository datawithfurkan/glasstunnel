# Agent UI Contract

Glasstunnel changes must ship as product changes, not just code changes. A feature is not complete until the Mac app, web app, and user-visible states make the new behavior understandable.

## Core Rule

When behavior changes, update the UI that explains, triggers, or confirms that behavior.

This applies to:

- Mac app UI under `apps/host-macos/Sources/App/UI/`.
- Web/mobile UI under `apps/mobile-pwa/src/`.
- Protocol state under `apps/host-macos/Sources/Protocol/` and `packages/protocol/`.
- Worker or relay behavior under `apps/signaling/` and Cloudflare-related code.
- Adapter behavior under `apps/host-macos/Sources/Adapters/`.

## Required Change Checklist

Before finishing any feature or bug fix, answer these questions in code or documentation:

- Does the user need a new button, menu item, toggle, status, empty state, or error message?
- Does the Mac app need to show the same state that the web app depends on?
- Does the web app need to explain what the Mac app is doing?
- Does a command now have a pending, success, failure, retry, unavailable, or offline state?
- Does a reconnect, cache, relay, auth, or adapter change affect what the user sees after closing and reopening mobile Safari/Chrome?
- Does this introduce internal wording that should be hidden from normal users?
- Does this require updated screenshots/manual test notes because the expected UI changed?
- Does the menu bar popover show this control or state too? Keep it in step with the main window.
- Does this flow need the main window open? The host keeps running with the window closed, so a request a phone waits on must also reach the user from the menu bar, or reopen the window.

If the answer is yes, update the relevant UI in the same pull/commit.

## Product Language Rules

Use simple product language in primary UI:

- Prefer `Connected`, `Reconnecting`, `Offline`, `Opening`, `Starting`, `Syncing`, `Ready`, `Not available`.
- Avoid exposing internal terms like `DataChannel`, `Durable Object`, `snapshot`, `adapter`, `approval polling`, or `host device ID` in normal flows.
- Do not expose direct local setup in onboarding. The supported path is account sign-in and host linking.
- Show one primary action per screen or state.

## Mac And Web Parity

When editing the Mac app:

- Check whether `apps/mobile-pwa/src/agents/`, `apps/mobile-pwa/src/auth/`, or `apps/mobile-pwa/src/lib/store.ts` also needs a state or wording update.
- If a Mac action can be started remotely, the web UI must show immediate pending feedback and then wait for Mac confirmation.
- If a Mac action can fail, the web UI must show a clear failure state and a retry path.
- The menu bar popover (`apps/host-macos/Sources/App/UI/MenuBarContent.swift`, hosted by `MenuBarController`) repeats host status, permissions, Open Workspace, Open Web App, Open Access, Read-only mode, Keep Mac awake, the access device count, Check for Updates…, and Quit Glasstunnel. When one of those changes in the main window, change it in the popover in the same pull request.
- Closing the main window does not stop the host. Glasstunnel stays online from the menu bar, hides its Dock icon and app menu until the window opens again, and goes offline only on Quit. Do not word Mac or web UI as if closing the window disconnects the phone.

When editing the web app:

- Check whether `apps/host-macos/Sources/App/UI/` needs matching status, settings, or access wording.
- If the web app depends on a Mac-published field, make sure the Mac publishes it consistently.
- If the web app sends a command, make sure the Mac emits a visible acknowledgement, not just a silent state mutation.

## Testing Expectations

Run the smallest useful validation for the touched surfaces:

- Web UI changes: run `pnpm --filter @glasstunnel/mobile-pwa build`.
- Mac UI or transport changes: run `swift test --package-path apps/host-macos`.
- Protocol changes: run both Mac tests and web build.
- Connection or relay changes: manually verify connected, reconnecting, offline, cached, and retry states when practical.

If a live browser or signed-in session cannot be tested, say that explicitly and explain what was verified instead.

## Done Means Visible

A task is not done if the backend works but users cannot tell what happened.

Finish with a short note covering:

- What changed in behavior.
- What changed in the Mac UI, web UI, or why UI did not need changes.
- What verification ran.
