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

Spikes first (each ≤ half a day; findings land in the draft of
`docs/adapters/claude-desktop.md`):

- [ ] **S1.a AX inventory.** With Claude.app open, capture composer role,
  placeholder/description strings, send control, sidebar rows, and window-title format.
  Provenance check: `AccessibilityInjector.isPlaceholderValue` (:382-396) hardcodes
  "Plan, Build, / for skills, @ for context" and "Send follow-up" — Claude-flavored
  strings in shared code. It is `private` and only consulted when verifying an
  intended-empty composer, so relocating it to per-adapter config is an API change that
  ripples through `CursorInputDelivering` (`CursorAdapter.swift:6-15`) — fold into T1.3
  rather than a blind "move it".
- [ ] **S1.b Deep-link probe.** Does `claude://` accept a session/project route? If not,
  target switching is pure AX (T1.4 fallback is grounded either way).
- [ ] **S1.c Desktop JSONL status semantics.** Map turn start/end from desktop-session
  records (assistant cadence, `queue-operation`, hook events) → working/done/
  waitingInput rules.

Tasks:

- [ ] **T1.1 Adapter skeleton** (M) —
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
- [ ] **T1.2 Desktop session parsing** (M) — extend `ClaudeCodeSessionParser` (the CLI
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
- [ ] **T1.3 Prompt injection** (M) — `AccessibilityInjector.deliver` with Claude
  composer hints from S1.a; Codex-style fallback chain (focus-click → keystrokes →
  pasteboard) with a Claude-tuned click anchor; synthetic Return on submit. Note
  `deliver` **throws** on write-verification failure (it never returns
  `verified: false`) — handle the throw, as Cursor does.
- [ ] **T1.4 Targets & switching** (M) — `AgentTargetOption` per desktop session (kind
  "thread", project grouping by cwd, mtime as lastActivity); isActive via front-window
  title; `selectTarget` via deep link (S1.b) or AX press with exact-then-substring
  fallbacks.
- [ ] **T1.5 Status wiring** (S) — hook-router subscription scoped to desktop-owned
  sessions (Stop→done, Notification→waitingInput), JSONL polling as fallback;
  interrupt = focus + Escape initially.
- [ ] **T1.6 Registration** (S) — `RemoteAppDefinition` entry `claude-desktop`
  (adapterKind `.claudeDesktop`, bundleIDs `["com.anthropic.claudefordesktop"]`,
  `requiresWindow: true` [the init default], `hasVideo: false`, `symbolName`, openHint
  "Open Claude on this Mac"); `startAdapter` case; default-enabled set unchanged.
- [ ] **T1.7 Runtime controls** (S) — read-only per D4.
- [ ] **T1.8 Tests** (M) — fixture-driven parser/status/catalog tests in
  `apps/host-macos/Tests/GTAdaptersTests/`, mirroring `CodexDesktopAdapterTests`;
  opt-in real-state audit gated on `GT_CLAUDE_DESKTOP_REAL_STATE=1` (Codex pattern,
  :569-572).
- [ ] **T1.9 Adapter doc** (S) — `docs/adapters/claude-desktop.md` per the de-facto
  template (source paths, mechanism, status mapping, limitations, compatibility table
  deferring to the support matrix).

**Acceptance:** from the PWA, see desktop threads with real titles, send a prompt into
the live app, watch working→done, answer a permission request, switch threads — with
the CLI adapter running untouched alongside.

## Stage 2 — Mobile PWA

- [ ] **T2.1 Registry entries** (S): `AppFilterId` union (`AgentCarousel.tsx:11-21`) +
  `APP_FILTERS` (:72-83); `adapterDisplayName` (`remoteApps.ts:119-138`); `AppGlyph` →
  reuse `ClaudeGlyph` (:1711-1720). Free side effect: `?app=claude-desktop` deep link
  starts working (`workspaceInitialAppIdFromSearch`, :1443-1448) — verify in T2.5.
- [ ] **T2.2 Classification** (S): `claude-desktop` must NOT be CLI-backed (guaranteed
  by kind 9 vs `isCliBackedApp`, `AgentCard.tsx:1409-1422`); add it to
  `shouldShowCommandTargetSwitcher` (:1427-1434); keep it out of `isDirectCliApp`
  (:1635-1643, stall detection); decide whether it needs the codex-style isActive
  re-request special case (`shouldRequestTargetSelection`, :1436-1441).
- [ ] **T2.3 CLI session picker** (S — cheaper than expected): the in-card switcher
  renders from `snapshot.availableTargets` (`AgentCard.tsx:569`) and the CLI adapter
  already publishes full targets + `selectTarget`/`--resume`
  (`ClaudeCodeAdapter.swift:190-216, 166-178`). The **only** change is adding
  `'claude-code'` to `shouldShowCommandTargetSwitcher` — do NOT touch
  `DIRECT_REMOTE_APP_IDS` (removal has side effects in the All view and start-panel
  logic; `opencode` proves direct + switcher coexist).
- [ ] **T2.4 Composer polish** (S): placeholder/notice strings, attachments flag.
- [ ] **T2.5 Contract compliance**: emitted statusDetail strings match mobile gating;
  product language only; Mac UI + web UI in the same commit
  (`docs/agent-ui-contract.md`); update membership tests
  (`AgentCarousel.test.tsx:562-569`, `AgentCard.test.ts:60-67`);
  `pnpm --filter @glasstunnel/mobile-pwa build` green.

## Stage 3 — Evidence & promotion

- [ ] **T3.1 QA lanes** (M): extend `scripts/claude-code-smoke.sh` (already wired as
  `qa:claude-code`); new claude-desktop smoke (app installed, window visible, AX
  injection dry-run).
- [ ] **T3.2 Release evidence** (M): add a Claude-desktop entry to the
  `GT_AGENT_APP_NAME` allowlist in `scripts/record-agent-app-evidence.sh:98` (it lists
  'Claude Code' but no desktop variant), then record
  prompt/result/stop/recovery/relaunch/mobile-browser evidence for the CLI first, then
  desktop → `docs/release-evidence/agent-apps/`.
- [ ] **T3.3 Status updates** (S): support matrix rows
  (`docs/agent-app-support-matrix.md:25`; CLI → Preview when evidence lands;
  claude-desktop enters Experimental → Preview), README status lines,
  known-limitations, release notes. Promotion procedure: `pnpm qa:agent-app:record`,
  `pnpm qa:agent-app-claims`, `pnpm release:readiness`.

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
