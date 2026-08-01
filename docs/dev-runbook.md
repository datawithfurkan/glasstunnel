# Local Development Runbook

The account-first Local Test Lab is the default development path. It runs the
PWA, Cloudflare Worker, local Supabase, and optionally an isolated Swift host
without production credentials or hosted deploys.

## Prerequisites

- Node.js 22+ and pnpm 9+
- Docker Desktop running
- Supabase CLI
- Swift and Xcode command-line tools
- Playwright Chromium and WebKit

```bash
pnpm install
pnpm exec playwright install chromium webkit
pnpm lab:doctor
```

`lab:doctor` is read-only. It reports exact tool versions, Docker readiness,
browser engines, signing availability, fixed-port ownership, and stale lab
state. Follow its `actions` list before starting the stack.

## Fast Start

```bash
pnpm lab:up:host
```

This starts:

- PWA: `http://127.0.0.1:5173`
- Worker signaling and account API: `http://127.0.0.1:8787`
- Supabase API: `http://127.0.0.1:54321`
- An isolated Swift host linked through the local account flow

The lab creates and signs in a disposable `@glasstunnel.test` user. It never
uses a private account or production Supabase credentials. Runtime state,
generated environment files, logs, and browser artifacts stay under ignored
local directories.

```bash
pnpm lab:status
pnpm lab:down
```

Always use `lab:down` for cleanup. It validates its process wrapper and run ID
before stopping anything, and refuses to replace or kill unknown listeners.

## Commands

| Command                   | Purpose                                                          |
| ------------------------- | ---------------------------------------------------------------- |
| `pnpm lab:doctor`         | Inspect prerequisites and stale state without changing anything  |
| `pnpm lab:up`             | Start local Supabase, Worker, and PWA                            |
| `pnpm lab:up:host`        | Start the core lab plus an isolated Swift host                   |
| `pnpm lab:status`         | Show owned services, health, URLs, and host metadata             |
| `pnpm lab:reset -- --yes` | Stop owned services and reset disposable local data              |
| `pnpm lab:down`           | Stop only services owned by the current lab manifest             |
| `pnpm lab:mac`            | Launch the signed development Mac app against a running lab      |
| `pnpm lab:test`           | Run lab unit contracts plus Worker type and runtime tests        |
| `pnpm lab:e2e`            | Run fixtures and the real mobile account/Terminal journey        |
| `pnpm lab:e2e:safari`     | Run responsive fixture coverage in Playwright WebKit             |

The same commands are available as `make lab-*` aliases. `make dev-stack` is
an alias for the account-first `pnpm lab:up`. The Go server on port `18080` is
an explicit legacy compatibility path, not the default stack.

## Testing Lanes

Use the cheapest lane that can prove the behavior:

1. Unit and static checks for pure logic and contracts.
2. Playwright fixture tests for fast responsive rendering and interaction.
3. Local account E2E for auth, Worker relay, Swift host, and Terminal behavior.
4. Signed Mac app testing for TCC, keychain, relaunch, and native lifecycle.
5. Codex Browser, Simulator, or hosted canaries only for gaps the earlier lanes
   cannot prove.

Playwright is the regression runner. Codex Browser is for exploratory and final
acceptance checks. Simulator is reserved for Safari/PWA/WebRTC-specific
behavior. A physical phone is optional unless a release gate explicitly says
otherwise.

## Signed Mac App

Start `pnpm lab:up` first, then run:

```bash
pnpm lab:mac
```

The launch uses the local PWA and Worker URLs, an isolated device key, a stable
scratch path, and a dedicated keychain suffix. It does not reset TCC. Stable
local signing is pinned to the `Glasstunnel Local Development` identity so
installing or removing Xcode certificates cannot invalidate existing lab TCC
grants. The development script documents its fallback when that identity cannot
be prepared. Native permission behavior still requires a real app launch because
command-line tests cannot prove macOS TCC state.

The signed lab app, device key, and trusted-device registry are stored under
`~/Library/Caches/Glasstunnel/LocalLab/<workspace-id>`. Keeping the native
runtime off the repository volume prevents an external checkout from pausing
first launch behind a removable-volume permission prompt. Browser, Worker,
logs, and build artifacts remain under `.cache/glasstunnel-lab`. Set
`GT_LAB_MAC_RUNTIME_DIR` only when an isolated local override is required.
The lab bundle identifier and endpoint configuration remain separate from
`~/Applications/Glasstunnel-Dev.app`.
`pnpm lab:down` and `pnpm lab:reset` stop this isolated app without closing a
personal Glasstunnel build.

## Validation And Shipping

```bash
pnpm agent:validate
pnpm agent:validate:run
git diff --check
```

Iterate locally until the selected lane is green. Then create focused local
commits, make one consolidated push, and inspect one bounded CI/deploy run.
GitHub Actions is a release confirmation layer, not the inner development loop.

On failure, inspect `.cache/glasstunnel-lab/logs` and `test-results`. The E2E
wrapper tears down owned services in `finally` and removes only Terminal screen
sessions created by that run.
