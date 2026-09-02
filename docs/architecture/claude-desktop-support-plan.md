# Claude Code app support — implementation plan

Goal: first-class **Claude Code desktop app** support in Glasstunnel, at parity with the
Codex desktop path, plus hardening the existing Claude Code **CLI** adapter so both can
graduate from Experimental. Product shape mirrors the `codex` / `codex-cli` remote-app
split: two cards, one app.

Every file/line anchor in this plan was verified against the tree at the time of writing.

## Verified premises

Facts checked on a real machine (2026-08) and against the repo:

- The shipping app is `/Applications/Claude.app`, bundle ID
  **`com.anthropic.claudefordesktop`** (Electron). The IDs the repo carried before
  Stage 0 (`com.anthropic.claudecode`, `com.anthropic.claudecode.macos`) matched no
  shipping app. They lived in `AdapterFactory.resolveKind`, the `claude-code`
  RemoteAppDefinition, one factory test, and the two local-app-availability QA
  scripts — all corrected in Stage 0.
- Claude.app registers the **`claude://`** URL scheme (deep-link candidate; accepted
  routes unverified — spike S1.b).
- Desktop-hosted Claude Code sessions share `~/.claude/projects/**/*.jsonl` with the
  CLI. The client discriminator is the **`entrypoint`** field on user/assistant records:
  `"claude-desktop"` vs `"sdk-cli"`/CLI values. Desktop sessions add record types the
  current parser ignores: `bridge-session`, `queue-operation`, `custom-title`,
  `ai-title`, `last-prompt`, `agent-name`, `atis-latch`.
- Hooks configured in `~/.claude/settings.json` fire inside desktop-hosted sessions, so
  hook-based status signals can serve a desktop adapter — but today's hook plumbing is
  single-client (see T0.3). The installed hook command already forwards `session_id`
  (`ClaudeCodeHookInstaller.commandFor`, :80-104), so routing needs no hook-format change.

## Product decisions

- **D1 — naming.** New remoteAppId `claude-desktop` (no collision in the repo), display
  name "Claude", alongside the existing `claude-code` (CLI) card.
- **D2 — its own AdapterKind.** `ADAPTER_KIND_CLAUDE_DESKTOP = 9` (proto max today is
  `CURSOR_AGENT = 8`). Note this deliberately diverges from the Codex precedent — Codex
  desktop reuses `.mirror` (`RemoteAppController.swift:78`). A distinct kind keeps the
  PWA's kind-based classification (`isCliBackedApp`, `AgentCard.tsx:1409-1422`) clean
  and gives the wire an honest label. It is a choice, not a necessity; `.mirror` would
  also work but muddies mobile gating.
- **D3 — no window video** (`hasVideo: false`), same as Codex desktop: the phone gets a
  structured chat UI, not a mirror. Mac Screen stays the escape hatch.
- **D4 — runtime controls read-only at first** (`editable: false`,
  `appliesOn: .managedLocally`, note "Managed in Claude Code"), like Codex desktop.

## Stage 0 — Foundations & CLI hardening

Everything here also stands alone as the path to promoting the CLI adapter out of
Experimental, independent of the desktop work.

- [x] **T0.1 Correct bundle IDs** (S)
  - `AdapterFactory.resolveKind`: drop the fictional `com.anthropic.claudecode[.macos]`
    cases. The real ID stays on the `.mirror` fallback until Stage 1 registers the
    desktop adapter and Stage 2 teaches the PWA about the kind — mapping it earlier
    would turn a dropped Claude.app grid window into an unlabeled card with no adapter
    behind it (the Mac+web same-commit rule in `docs/agent-ui-contract.md`).
  - Remove `bundleIDs` from the `claude-code` CLI definition. Verified safe:
    `isAvailable` ignores bundleIDs when `requiresWindow == false`, `shouldPublish`
    falls through to the executable check, `launchApplication` no-ops on an empty set,
    `makeRemoteApp` falls back to `""` like cursor-agent.
  - The QA scripts `scripts/local-app-availability.sh` and its smoke test also carried
    the fictional IDs; the Claude Code row is now CLI-only, matching the host.
  - Tests: `testLegacyGuessedClaudeBundleIDsFallBackToMirror`,
    `testClaudeDesktopStaysMirrorUntilItsAdapterExists`.

- [x] **T0.2 New AdapterKind + protocol bump** (S)
  - `glasstunnel.proto`: `ADAPTER_KIND_CLAUDE_DESKTOP = 9`.
  - Mirror in the TS shim (`packages/protocol/src/index.ts`) and Swift
    `Identifiers.swift` (displayName :52-64, SF-symbol icon :66-78).
  - Bump the **semver string** `PROTOCOL_VERSION` `'0.2.0'` → `'0.2.1'` (`index.ts:10`)
    — the wire constant `CURRENT_PROTOCOL_VERSION = 4` is untouched by an additive enum
    value — **and its Swift mirror** `GlasstunnelProtocol.version`
    (`Sources/Protocol/ProtocolVersion.swift:4`, surfaced in the handshake and
    `DiagnosticsReport.swift:94`). Changelog entry in `docs/protocol-changelog.md`.

- [x] **T0.3 Multi-client hook routing** (M)
  - Each `ClaudeCodeAdapter` used to own its own `ClaudeCodeHookListener`, and the
    listener `unlink()`s the shared `cc.sock` on start — two Claude adapters would
    steal each other's socket.
  - Done: `ClaudeHookRouter` (`Sources/Adapters/ClaudeCode/ClaudeHookRouter.swift`)
    owns the single listener process-wide (`ClaudeHookRouter.shared`, injectable for
    tests via `ClaudeHookEventSource`). The socket is bound inside the router's critical
    section and a subscriber is registered only once that succeeded, so no subscriber
    can observe a router whose listener failed to start; the last unsubscribe releases
    the socket.
  - CLI adapter ownership is deterministic rather than disk-derived: the adapter launches
    `claude --resume <id>` or `claude --session-id <uuid>` (unless the caller pinned a
    session argument), remembers that id, and its predicate is `session == liveId ||
    session.isEmpty`. No transcript lookup happens on the hook path, a separate `claude`
    in Terminal cannot re-select the adapter, and a failed `super.start()` releases the
    subscription.
  - Tests: `ClaudeHookRouterTests`, `ClaudeCodeSessionOwnershipTests`.

- [x] **T0.4 Session-store client filtering** (M)
  - `parseMetadata` now captures `entrypoint`; `ClaudeCodeSessionOwner(entrypoint:)`
    encodes "missing entrypoint counts as CLI" once. `loadSummaries(owner:)` filters, and
    `ClaudeCodeSessionStore.owner(ofSessionId:)` answers the one-field question from the
    transcript head only (no workspace-root requirement) for the Stage 1 desktop adapter.
  - The CLI adapter lists and resumes only CLI-owned sessions; selection follows the
    live PTY session. Summaries are memoized per (path, mtime) via
    `ClaudeCodeSessionSummaryCache` and the transcript is re-parsed only when its mtime
    changed; a transient parse failure keeps the last good messages.
  - Tests: `testClassifiesSessionOwnerByEntrypoint`, `testOwnerLookupBySessionId`, and
    the opt-in `GT_CLAUDE_REAL_STATE=1` audit against the real store.

- [x] **T0.5 Executable path-list unification** (S)
  - Definition side (`RemoteAppDefinition.executableCandidates(named:)`, :175-186, used
    at :114) lacks `~/.claude/local/bin`; adapter side
    (`ClaudeCodeAdapter.resolveExecutable`, :377-391) lacks `~/.cargo|.bun|.npm-global`.
  - Follow the repo pattern: a static `executableCandidates()` on the adapter that the
    definition references (as Codex/Gemini/CursorAgent/OpenCode already do,
    `RemoteAppController.swift:102,126,138,162`). Decide ordering deliberately — the
    adapter's first hit wins, and today the two lists disagree on where bare `claude`
    sits.

- [x] **T0.6 statusDetail stomping fix** (S)
  - The 2s refresh loop emitted `"Claude context synced"` unconditionally, overwriting
    details the PWA gates on (`'settings updated'`, `/^(opening|switching)\s+/`).
  - Done at the base-class altitude: `PTYAdapterBase.emitSnapshot(detail:)` now records
    the detail it publishes (so `rejectRuntimeSettingsUpdateIfWorking` sees the same
    detail the surface does), and `emitSnapshotKeepingDetail()` re-emits it. The Claude
    loop emits only when the session state changed; OpenCode's identical loop now keeps
    its detail too. Hook events emit with `forceEmit` so a repeated identical Stop still
    publishes the turn's new messages.

- [x] **T0.7 Docs truth-up** (S)
  - `docs/adapters/claude-code.md:53`: the "Claude Code < 1.0 → mirror fallback" claim
    has no code behind it — remove it (or implement version detection); document
    entrypoint filtering and the hook router.

**Acceptance:** `swift test --package-path apps/host-macos` green; with a desktop
session active and the CLI adapter running, desktop hook events no longer move the CLI
adapter's status or selection (manual two-client check); claude-code availability
detects a `~/.claude/local/bin`-only install.

## Stage 1 — ClaudeDesktopAdapter

Spike findings (all three done; details in `docs/adapters/claude-desktop.md`):

- [x] **S1.a AX inventory.** Live AX inspection needs an Accessibility-trusted process,
  so the inventory came from the app's own Code UI bundle (`Contents/Resources/ion-dist`,
  string table `i18n/en-US.json`): composer placeholder "Ask Claude a question or start a
  task…"; permission buttons "Allow once" / "Allow" / "Always allow" / "Deny"; question
  controls "Submit" / "Continue" / "Send"; "Stop" / "Interrupt". The strings hardcoded in
  `AccessibilityInjector.isPlaceholderValue` do not occur in the Claude app at all, so
  they were left alone.
- [x] **S1.b Deep-link probe.** The app's URL handler (in `app.asar`) defines
  `claude://code/continue?session=<last|local_…>`, `claude://code/needs-input`,
  `claude://code/new?folder=<path>`, `claude://code/<cse_…|session_…>` and
  `claude://resume?session=<uuid>`. **Live result:** the ids it validates are the app's
  own (`local_`/`cse_` ids, not the transcript UUID), and on the installed build every
  `claude://code` form logs `claudeURLHandler: … deep link gated off`. The adapter
  therefore verifies the front window title and switches sessions by pressing the
  session row through Accessibility, keeping the link as a first attempt.
- [x] **S1.c Desktop JSONL status semantics.** `assistant.stop_reason` `tool_use` →
  working, `end_turn` → done; a `[Request interrupted by user…]` user record → stopped;
  an `AskUserQuestion` tool call with no `tool_result` → waiting for an answer.
  Permission prompts leave no record, so they come from the `Notification` hook
  (`notification_type: permission_prompt`), and `idle_prompt` notifications are ignored.
  Titles: `custom-title` (user) outranks `ai-title`; newest wins within a type.

Tasks:

- [x] **T1.1 Adapter skeleton** (M) —
  `Sources/Adapters/ClaudeCode/ClaudeDesktopAdapter.swift`, following
  `CodexDesktopAdapter`: no second process; targetPID from the matched window,
  re-resolved per action; 1s poll throttled to 2s, catalog at 5s; optimistic echo.
  Two deliberate divergences from the template:
  - Set `.claudeDesktop` **both** as the `kind` property and in every emitted snapshot
    — `handleSnapshot` overrides `hasVideoTrack` from the definition but does **not**
    rewrite `adapterKind` (`RemoteAppController.swift:1226-1246`); Codex hardcodes
    `.mirror` in both places (:27, :636).
  - Don't copy the 24-message optimistic-echo cap (`applyOptimisticMessage`,
    :659-661) that momentarily truncates the 250-message history.
- [x] **T1.2 Desktop session parsing** (M) — extend `ClaudeCodeSessionParser` (the CLI
  and desktop rightly share one parser; Codex's split exists because its CLI adapter is
  pure PTY). Concretely:
  - Filter summaries by `entrypoint == "claude-desktop"` + skip `isSidechain` — the
    Codex analog is `parseSummary`'s originator/source filtering (:1227-1300); the
    Claude `parseSummary` (:155-167) has no counterpart yet.
  - Thread titles: `custom-title`/`ai-title` newest-wins, overriding the current
    first-user-message derivation (`makeTitle`, :189-200, 251-258). There is no
    session-index sidecar for Claude — titles must come entirely from the JSONL.
  - `parseRecentFile` already does head-256KB + tail-8MB chunked reads (:80-104), but
    `parseSummaryPreview` (:106-111) reads **only the head** — late-appended
    `custom-title`/`ai-title` records are invisible to target listings until it gains
    the tail read (Codex's preview reads both, :1112-1127).
- [x] **T1.3 Prompt injection** (M) — done in `ClaudeDesktopAccessibilityDriver`
  (behind the `ClaudeDesktopUIDriving` protocol so tests inject a fake):
  `AccessibilityInjector.deliver` with the Code UI's composer hints, then the Codex-style
  focus-click → keystrokes fallback; the deep link brings the selected session to the
  front before every prompt.
- [x] **T1.4 Targets & switching** (M) — one `AgentTargetOption` per desktop session
  (kind "thread", grouped by cwd, title from the transcript); `selectTarget` opens
  `claude://code/continue?session=<id>` and re-reads the transcript.
- [x] **T1.5 Status wiring** (S) — transcript-derived status, overridden by hook events
  for the selected session (Stop → done, `permission_prompt` → an Allow/Deny question,
  `idle_prompt` ignored) until the transcript changes again; interrupt presses
  "Stop"/"Interrupt" or sends Escape. The adapter installs the hooks itself, so either
  Claude card can be the first one enabled.
- [x] **T1.6 Registration** (S) — `claude-desktop` RemoteAppDefinition (kind
  `.claudeDesktop`, bundle `com.anthropic.claudefordesktop`, window required, no video);
  `startAdapter` case; bundle → kind mapping in `AdapterFactory`; kind advertised.
- [x] **T1.7 Runtime controls** (S) — read-only model from the newest assistant record
  ("Managed in Claude").
- [x] **T1.8 Tests** (M) — `ClaudeDesktopAdapterTests` (parser semantics, adapter
  behavior with a fake UI driver and hook source) and the opt-in
  `GT_CLAUDE_REAL_STATE=1` audit `testRealDesktopSessionsParse`, which on the
  development Mac reports this very session as "working" with its title and model.
- [x] **T1.9 Adapter doc** (S) — `docs/adapters/claude-desktop.md`.

Review-driven changes beyond the plan: the transcript parser is shared with the CLI
adapter, so both cards gained tool-output rendering, "Stopped" markers, title records,
a hand-rolled timestamp fast path (the formatter cost ~1 s per 8 MB tail), and one
summary cache per store root shared by both adapters.

**Acceptance:** from the PWA, see desktop threads with real titles, send a prompt into
the live app, watch working→done, answer a permission request, switch threads — with
the CLI adapter running untouched alongside.

## Stage 2 — Mobile PWA

- [x] **T2.1 Registry entries** (S): `AppFilterId` + `APP_FILTERS` ("Claude"; the CLI
  chip's short label became "Code"), `adapterDisplayName` case 9, `AppGlyph` reuses
  `ClaudeGlyph`; `?app=claude-desktop` works via the filter list; the
  `workspace-all-apps` dev fixture includes the card.
- [x] **T2.2 Classification** (S): not CLI-backed (kind 9), in
  `shouldShowCommandTargetSwitcher`, out of `isDirectCliApp`; no isActive re-request
  special case needed because the adapter reports `isActive == selected`.
- [x] **T2.3 CLI session picker** (S): `'claude-code'` added to
  `shouldShowCommandTargetSwitcher`; `DIRECT_REMOTE_APP_IDS` untouched.
- [x] **T2.4 Composer polish** (S): the desktop card is a chat surface like Codex, so
  the standard composer applies; no CLI notice.
- [x] **T2.5 Contract compliance**: Mac grid-editor accent for `claude-desktop`;
  membership and fixture tests updated; PWA typecheck, lint, tests, and build green;
  the card was rendered from the dev fixture on a mobile viewport.

## Stage 3 — Evidence & promotion

- [x] **T3.1 QA lanes** (M): `pnpm qa:claude-desktop` (new `scripts/claude-desktop-smoke.sh`:
  bundle id, `claude://` scheme, desktop-owned transcripts, installed hooks, CLI
  flags; `pnpm qa:claude-desktop:live-ax` adds a read-only composer probe that needs
  an Accessibility-trusted terminal) and `pnpm qa:claude-code` now also checks
  `--session-id`.
- [~] **T3.2 Release evidence** (M) — recorded on 2026-09-02:
  `claude-code-live-adapter-pass.md` (the CLI adapter drove the real `claude` binary
  end to end), `claude-desktop-local-contracts-pass.md` (bundle, scheme, store parsing
  against the running app, every `claude://code` deep link gated off on build
  1.40609.1, composer and rename control reachable through Accessibility), and
  `claude-code-phone-driven-pass.md` (`pnpm lab:e2e:claude-code`: a phone-sized
  Chromium signed in, started the card, answered the workspace-trust dialog, watched
  the held-session fallback create a fresh session, got "Response ready" for a prompt,
  and interrupted a second one). Still open: `pnpm lab:e2e:claude-desktop` against a
  dedicated Claude app session with the window left alone (the lane is written), and
  a WebKit pass of the CLI lane.
- [x] **T3.3 Status updates** (S): Claude Code is Preview ("Partial") on the strength of
  the adapter-level evidence; Claude desktop stays Experimental until the Accessibility
  path is exercised. README tiers, known-limitations, and the Unreleased changelog are
  updated. Promotion procedure for the remaining step: `pnpm qa:agent-app:record`,
  `pnpm qa:agent-app-claims`, `pnpm release:readiness`.

### Live evidence checklist (the one part that needs a person at the Mac)

1. Build and run the host from this branch (Local Test Lab per `docs/dev-runbook.md`),
   grant Accessibility, sign in, and pair a phone.
2. Terminal (Accessibility-trusted): `pnpm qa:claude-desktop:live-ax` — expect the
   composer probe to pass while a Claude Code session is open in the app.
3. Enable the **Claude** card. From the phone: pick a session, send a prompt, watch
   working → "Response ready", trigger a tool that needs permission and answer
   Allow/Deny from the phone, let Claude ask a question and answer it, switch sessions.
4. Enable the **Claude Code** card alongside it and repeat a prompt on each; confirm
   neither card's status moves when the other works.
5. `GT_AGENT_APP_NAME="Claude desktop" … pnpm qa:agent-app:record` (and again for
   "Claude Code"), review the raw record, write the concise public summary, flip the
   matrix rows to Preview, then `pnpm qa:agent-app-claims` and
   `pnpm release:readiness`.

## Risks

- **Electron AX flakiness** → layered fallbacks + throw-on-unverified writes; degrade
  loudly via statusDetail, never silently. PID ambiguity: `.first` of
  `runningApplications(withBundleIdentifier:)` may not be the visible window with
  multiple instances/Electron helpers — same mitigation class.
- **Desktop app updates** changing JSONL shapes or composer strings → fixtures pin
  today's shapes; opt-in real-state test catches drift; parser tolerates unknown
  record types.
- **Shared `~/.claude/settings.json` merges** → installer already preserves user hooks
  verbatim with idempotency tests; keep them.
- **CLI + desktop concurrency** → Stage 0 ownership rules are the mitigation; the
  two-client manual test is part of Stage 0 acceptance.

## Sequencing & effort

Stage 0 (≈3–5 focused days) → Stage 1 (≈1–2 weeks incl. spikes) → Stage 2 (≈2–3 days;
can start once D1/D2 land) → Stage 3 (≈3–4 days; CLI evidence can start right after
Stage 0). Stage 0 alone unblocks promoting the CLI adapter out of Experimental.
