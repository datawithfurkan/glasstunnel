# Mobile QA

Use local automation first and choose the narrowest environment that can prove
the behavior. Historical mobile evidence is preserved in
`docs/archive/mobile-qa-evidence-through-2026-06-27.md`; it is context, not a
current execution contract.

## Fast Regression

```bash
pnpm lab:e2e
pnpm lab:e2e:safari
```

`lab:e2e` runs desktop/mobile fixtures and the real disposable-account journey
at a Pixel-class mobile Chromium viewport. The account journey signs in, links
the isolated host, delivers a Terminal command, renders output, interrupts a
long-running command, proves recovery, and creates, renames, and closes a second
session. `lab:e2e:safari` runs the mobile fixture project in WebKit. Both own
their local lab lifecycle, save failure artifacts, and restore the process and
Terminal-session baseline.

Playwright WebKit is not Mobile Safari. It is fast regression evidence for
layout and browser behavior, not proof of iOS Safari chrome, lifecycle,
keyboard, installed-PWA, or device WebRTC behavior.

## Environment Roles

| Environment           | Use it for                                                                |
| --------------------- | ------------------------------------------------------------------------- |
| Playwright Chromium   | Deterministic account, relay, Terminal, and desktop/mobile regression     |
| Playwright WebKit     | Responsive WebKit fixture regressions                                     |
| Codex Browser         | Exploratory inspection and final local acceptance                         |
| iOS Simulator Safari  | Safari viewport, keyboard, PWA, backgrounding, and WebRTC-specific checks |
| Physical iPhone       | Optional final confidence or an explicitly named release gate             |
| Hosted browser/device | One canary after local checks are green                                   |

Do not use repeated production deploys as a browser test runner.

## Simulator

Run Simulator only when the selected change needs Safari-specific evidence:

```bash
pnpm qa:mobile:ios
```

Record the exact viewport, route, state, and visible result. Simulator evidence
does not become a physical-phone claim. Existing `qa:*:ios-safari*` scripts are
focused adapter checks and should be selected only for their matching surface.

## Acceptance Checklist

- No horizontal page overflow at phone width.
- Primary controls remain reachable with the software keyboard visible.
- Loading, offline, retry, success, and interruption states are truthful.
- Desktop wheel/trackpad and mobile touch can reach the same actions.
- Terminal output scrolls inside its panel and session controls do not create
  duplicate sessions.
- Refresh provides visible progress and updates device presence from the
  account API.
