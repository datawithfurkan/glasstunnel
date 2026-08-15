# Mobile Interaction Fitness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the mobile PWA easier to use at phone width by fixing tap target size, zoom policy, keyboard-safe composer layout, app-strip discoverability, and duplicated mobile chrome.

**Architecture:** Keep this as a web/mobile-only slice. Use deterministic fixture tests for layout regressions, shared CSS helpers for minimum touch sizes and keyboard viewport behavior, and update the product-audit backlog with evidence before moving to the next slice.

**Tech Stack:** React 18, Vite, Tailwind utility classes, Vitest, Playwright fixture E2E, Glasstunnel Local Test Lab.

## Global Constraints

- Work on `main`; the user approved direct execution.
- Do not touch Mac app behavior, protocol schema, signing, Cloudflare, or production deploys.
- Use local-first validation and one consolidated push.
- Keep primary UI copy minimal and user-facing.
- Leave raw/private audit artifacts out of Git.

---

### Task 1: Clean Local Audit Artifact

**Files:**
- Move only: `CLAUDE-PRODUCT-AUDIT-FINDINGS.md`

**Interfaces:**
- Consumes: current untracked raw audit file.
- Produces: clean Git status except intended source changes.

- [x] **Step 1: Archive the raw audit artifact outside the repo**

Run:
```bash
mkdir -p /Users/furkan/Backups/glasstunnel/audit-artifacts
mv CLAUDE-PRODUCT-AUDIT-FINDINGS.md /Users/furkan/Backups/glasstunnel/audit-artifacts/CLAUDE-PRODUCT-AUDIT-FINDINGS-2026-08-15.md
```

- [x] **Step 2: Verify it is not in Git status**

Run:
```bash
git status --short --branch
```

Expected: no `CLAUDE-PRODUCT-AUDIT-FINDINGS.md`.

### Task 2: Add Mobile Fixture Assertions

**Files:**
- Modify: `tests/e2e/fixtures.spec.ts`

**Interfaces:**
- Consumes: existing `workspace-all-apps`, `workspace-terminal-running`, and `workspace-codex-target-unverified` fixtures.
- Produces: regression coverage for 44px touch targets, viewport zoom policy, app-strip overflow affordance, composer reachability, and duplicate status chrome.

- [x] **Step 1: Add assertions**

Add fixture tests that:
- assert viewport meta does not include `user-scalable=no` or `maximum-scale=1`.
- assert visible buttons in the mobile fixture are at least 44px tall/wide where they are icon-only or primary controls.
- assert the coding-app strip can scroll to OpenCode/Gemini/Terminal and exposes scroll affordance text for assistive tech.
- assert the focused command composer remains visible at phone width and the document does not horizontally overflow.
- assert the mobile focused chat header avoids duplicate visible status badges for command surfaces.

- [x] **Step 2: Run the focused fixture lane**

Run:
```bash
pnpm exec playwright test tests/e2e/fixtures.spec.ts --project=fixture-mobile-chromium
```

Expected: tests fail before implementation or pass if current UI already satisfies the assertion.

### Task 3: Implement Mobile Interaction Fixes

**Files:**
- Modify: `apps/mobile-pwa/index.html`
- Modify: `apps/mobile-pwa/src/styles.css`
- Modify: `apps/mobile-pwa/src/ui/HorizontalScrollStrip.tsx`
- Modify: `apps/mobile-pwa/src/agents/AgentCarousel.tsx`
- Modify: `apps/mobile-pwa/src/agents/AgentCard.tsx`

**Interfaces:**
- Consumes: Playwright assertions from Task 2.
- Produces: mobile UI with accessible zoom, predictable touch sizes, clearer app strip, keyboard-safe composer, and reduced duplicate chrome.

- [x] **Step 1: Fix viewport zoom policy**

Remove `maximum-scale=1.0, user-scalable=no` from the mobile PWA viewport meta.

- [x] **Step 2: Add touch and keyboard helpers**

Add reusable CSS helpers for:
- minimum 44px touch target dimensions.
- dynamic viewport height on supported engines.
- mobile composer padding based on safe area and keyboard viewport.

- [x] **Step 3: Improve horizontal app strip discoverability**

Ensure the strip has visible edge affordance on touch/mobile when overflow exists, desktop wheel support remains, and scroll buttons are at least 44px.

- [x] **Step 4: Improve mobile list and command composer sizing**

Apply 44px minimum sizing to primary mobile list buttons, header actions, terminal/session controls, attachment/action buttons, and composer controls.

- [x] **Step 5: Remove duplicate mobile command status**

For mobile focused command/chat surfaces, keep one truthful status in the card header and avoid repeating equivalent status inside the terminal frame where it consumes vertical space.

### Task 4: Validate, Update Evidence, And Ship

**Files:**
- Modify: `docs/product-audit-backlog.md`
- Modify: `docs/current-loop-state.md`

**Interfaces:**
- Consumes: completed Task 1-3 evidence.
- Produces: updated backlog with Mobile Interaction Fitness verified or deferred item evidence, and next active slice set to First-Run Activation if complete.

- [x] **Step 1: Run selected validation**

Run:
```bash
pnpm agent:validate
pnpm agent:validate:run
pnpm exec playwright test tests/e2e/fixtures.spec.ts --project=fixture-mobile-chromium
pnpm exec playwright test tests/e2e/fixtures.spec.ts --project=fixture-mobile-webkit
```

- [x] **Step 2: Cleanup lab state**

Run:
```bash
pnpm lab:down
pnpm lab:status
```

- [x] **Step 3: Update evidence docs**

Mark fixed/deferred mobile interaction rows in `docs/product-audit-backlog.md`. If all active rows are verified, set `docs/current-loop-state.md` active slice to `First-Run Activation`.

- [ ] **Step 4: Commit, push, and inspect one CI run**

Run:
```bash
git diff --check
git add <changed-files>
git commit -m "fix: improve mobile interaction fitness"
git push origin main
gh run list --branch main --limit 10 --json databaseId,headSha,status,conclusion,workflowName,displayTitle,createdAt,url
gh run watch <matching-ci-run-id> --exit-status
```
