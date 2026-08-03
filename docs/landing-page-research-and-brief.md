# Glasstunnel landing page research and design brief

Status: approved continuity design implemented and live at
`https://glasstunnel.io`; production validation completed August 3, 2026

## 1. Objective

Create a public homepage for `https://glasstunnel.io` that makes the product
understandable in seconds, demonstrates the real Mac-to-phone experience, and
gives visitors credible paths to download, inspect the source, read security
details, and start using the hosted web app.

The operational product remains at `https://app.glasstunnel.io`. The homepage
must not imitate an authenticated dashboard or blur the boundary between the
marketing site and the web app.

Primary audience:

- Developers who already use local coding agents on a Mac.
- Open-source contributors evaluating the project before installing it.
- Privacy-conscious developers comparing local and cloud execution.

Primary conversion:

1. Understand the product.
2. Download the notarized Mac app or install it with Homebrew.
3. Open the web app on a phone and sign in with the same account.

Secondary conversions are opening GitHub, reading the security model, and
self-hosting.

## 2. Product truth to preserve

The homepage must follow the current support contract, not an aspirational
feature list.

- Public beta.
- Supported: Mac Screen and scoped Terminal.
- Preview: Codex desktop, Codex CLI, Cursor, Cursor Agent, Gemini CLI, and
  OpenCode.
- Experimental: Claude Code and generic window mirroring.
- The hosted account plane handles sign-in, linking, and device authorization.
- WebRTC media and DataChannel content are encrypted end to end with DTLS-SRTP.
- Hosted infrastructure still processes routing, account, device, request, and
  network metadata needed to operate the service.
- Secret redaction is useful but best effort, not a guarantee that every secret
  is detected.
- The Mac app is a signed and notarized public beta distributed through GitHub
  Releases and Homebrew.
- The project is Apache 2.0 and can be self-hosted.

Do not claim that every coding-agent integration is release-ready, that no
metadata leaves the device, that the app updates itself, or that redaction can
catch every secret.

## 3. Current-site audit

The repository already contains a small static Vite prototype under `site/`.
It has useful raw material but should be treated as a content sketch rather
than the visual target.

What is worth keeping:

- The existing Glasstunnel mark and wordmark assets.
- Direct Download and GitHub actions.
- Clear self-hosting and security destinations.
- A lightweight static-site build.

What should change:

- The current hero is text-led and does not show the actual product.
- The dark blue radial-gradient treatment is generic and too close to a single
  color theme.
- The page depends heavily on cards and explanatory copy instead of a visual
  product story.
- Some copy is framed around criticizing cloud agents rather than explaining
  Glasstunnel's unique job.
- Current support tiers, beta status, platform requirements, and the real
  three-step setup are not visible enough.
- No current deployment job builds or deploys `site/`; the production Deploy
  workflow only publishes the PWA and signaling worker.

## 4. Benchmark research

This research uses two complementary reference sets. Established open-source
products reveal durable information architecture and trust patterns. Newer,
high-traction projects reveal the sharper visual and launch conventions now
spreading through developer communities. The useful lesson is the product
communication pattern, not a request to copy any project's identity.

### Durable open-source patterns

| Reference | Observed pattern | Glasstunnel takeaway |
| --- | --- | --- |
| [Zed](https://zed.dev/) | A literal category statement, immediate Download and Clone Source actions, platform availability, and a large real product demonstration. | Put the real Mac and phone experience in the first viewport and pair Download with GitHub. |
| [Bun](https://bun.sh/) | A bold one-line promise, product personality, and executable developer proof instead of long prose. | Make the promise concrete and let the install command act as proof. |
| [Supabase](https://supabase.com/) | A short hero promise followed by interactive product surfaces, integrated capability framing, social proof, and a distinct open-source section. | Demonstrate the workflow first, then show architecture, source ownership, and community paths. |
| [Tauri](https://tauri.app/) | A compact technical promise, copyable setup command, and four trust pillars: platform reach, security, size, and implementation flexibility. | Keep installation close to the top and reduce trust claims to a few verifiable properties. |
| [RustDesk](https://rustdesk.com/) | Direct category language, Download and Self-host paths, visible product screenshots, and open-source/community proof. | Treat self-hosting as a credible alternative path, not the hero's main burden. |
| [Tailscale](https://tailscale.com/) | Complex networking is explained through product visuals and trust evidence rather than protocol-heavy hero copy. | Explain the Mac-to-phone trust model visually; keep WebRTC and device-key detail below the primary story. |
| [Cal.com](https://cal.com/) | The public site, operational app, downloads, developer docs, self-hosting, security, and GitHub are separate but well-connected destinations. | Preserve the clean `glasstunnel.io` versus `app.glasstunnel.io` boundary. |

### 2025-2026 high-traction open-source references

These projects were selected from recently created, actively maintained GitHub
repositories with unusually strong community traction as of August 2, 2026.
This is a point-in-time reference set, not a claim that every project appears on
GitHub Trending every day.

| Reference | Observed pattern | Glasstunnel takeaway |
| --- | --- | --- |
| [OpenCode](https://opencode.ai/) | A white, monospaced page with the literal promise "The open source AI coding agent" and an install command in the first viewport. | Category clarity and executable proof can feel current without decorative complexity. |
| [OpenClaw](https://openclaw.ai/) | A black-and-red visual identity, mascot and ASCII texture, two clear actions, and Quick Start immediately below the hero. | A memorable identity works best when installation remains obvious and close. |
| [Paperclip](https://paperclip.ing/) | A singular, vivid abstract mark, one large centered claim, short support copy, and a direct action. | Give the page one ownable visual motif rather than decorating every section differently. |
| [Voicebox](https://voicebox.sh/) | A literal microphone object, strong dark-and-gold art direction, Download and GitHub, and the real product peeking into the first viewport. | Make the product or its controlling object unmistakable, then reveal the UI before the fold ends. |
| [DeerFlow](https://deerflow.tech/) | A coherent branded world around a technical agent product, balanced with direct documentation and source routes. | Personality can support credibility when technical paths remain easy to find. |
| [Impeccable](https://impeccable.style/) | Editorial typography, a textured visual world, and visible before/after interface transformation. | Show the outcome of using Glasstunnel, not a generic collection of feature labels. |
| [agent-browser](https://agent-browser.dev/) | Documentation-first presentation with install and command proof dominating the experience. | Technical visitors should reach installation and operational evidence without crossing a long marketing page. |

### Social-native landing-page research

Recent high-engagement X posts show a second design culture around AI-built
landing pages. These examples are valuable as launch and motion references, not
as product-truth references.

| Reference | Why it spread | Guardrail for Glasstunnel |
| --- | --- | --- |
| [MotionSites](https://motionsites.ai/) and its [launch post](https://x.com/Hartdrawss/status/2070832184307396671) | A searchable gallery of animated hero prompts made the result immediately reusable with Codex and Claude Code. Its own hero places filters and a dense visual gallery directly under a high-energy headline. | Use it as a motion and composition catalog. Do not assemble Glasstunnel from unrelated prompt templates or copy its maximal visual density. |
| [Kimi K3 versus Fable 5 comparison](https://x.com/nicos_ai/status/2077841576760381455) | A direct same-prompt comparison made dramatic, editorial first viewports easy to judge and share. | Evaluate multiple concepts against the same brief, but choose by product comprehension, mobile behavior, and implementation quality rather than spectacle alone. |
| [Elaya's animated landing page](https://x.com/elayadesigns/status/2081325937229210107) | A strong puppet metaphor, oversized editorial type, cohesive color, and cinematic motion created one memorable frame. | Build one clear visual metaphor around remote agency. The post's own replies questioned responsive behavior, so desktop virality is not acceptance evidence. |
| [Claude Design system masterclass](https://x.com/nateherk/status/2049671821193036006) | The creator generated brand, guidelines, pitch materials, landing page, mobile states, and launch media as one system. | Establish Glasstunnel's visual rules in Pen before composing isolated screens or motion clips. |

The strongest shared pattern is not a particular model, gradient, or animation
library. It is a singular first-viewport idea, a coherent design system, and an
artifact that is immediately understandable in a short clip or screenshot.
Glasstunnel's ownable idea is continuity: the same coding task visibly moving
between a real Mac and a phone while execution stays on the Mac.

### Patterns to adopt

1. A literal H1 that says what the product is.
2. Real product media in the first viewport.
3. A primary install action and a visible source action.
4. A short, copyable installation path.
5. Progressive disclosure: use case first, architecture and security second.
6. Honest support status instead of a wall of integration logos.
7. Open-source proof that includes license, self-hosting, docs, and contribution
   paths.
8. Evidence over adjectives: show connected states, a remote prompt, Terminal,
   screen sharing, and the real permission/login journey.
9. A singular visual metaphor or product moment that remains legible in a still
   image, a short social clip, and a phone viewport.
10. A design system defined before motion production, so the website, product
    captures, launch media, and Open Graph image feel related.

### Patterns to reject

- Generic gradient or orb decoration.
- A split hero with marketing copy on one side and an arbitrary illustration
  card on the other.
- Fake terminals, fake app windows, or hand-drawn product screenshots.
- Large unsupported statements such as "all agents" or "nothing leaves your
  Mac."
- A logo cloud that implies unsupported integrations.
- Auto-playing motion that obscures controls or ignores reduced-motion settings.
- Scroll hijacking, horizontal-only navigation, or a page that is impressive on
  desktop but awkward on a phone.
- Dense pricing-style card grids for a free open-source beta.
- A collage of fashionable AI-landing-page motifs that has no relationship to
  Glasstunnel's product.
- Desktop-only cinematic composition accepted without phone, reduced-motion,
  keyboard, and performance verification.
- Treating the model or generator name as the design strategy.

## 5. Recommended positioning

Hero category line:

> Control your coding agents from your phone.

Supporting line:

> Check progress, send prompts, and keep your coding agents moving from
> anywhere.

Recommended proof line:

> Your Mac keeps the project, tools, and local context. Glasstunnel gives your
> phone a secure way back in.

Primary action: `Download for Mac`

Secondary action: `View on GitHub`

Quiet tertiary action: `Open web app`

The hero should also show `Public beta`, the current macOS requirement, and a
short path to the latest release. These are trust details, not decorative tags.

## 6. Recommended information architecture

### Navigation

- Product
- How it works
- Supported apps
- Security
- Docs
- GitHub
- Download for Mac

### Page sequence

1. **Hero: the complete promise**
   - Literal H1 and the approved supporting line.
   - Full-bleed real product scene with the Mac app and mobile PWA showing the
     same active task.
   - Download, GitHub, and Open web app actions.
   - A hint of the next section in every viewport.

2. **The away-from-desk workflow**
   - Check an agent's progress.
   - Send a prompt or approval.
   - Use Mac Screen or Terminal when direct control is needed.
   - Use three real states from one coherent scenario, not three abstract
     feature cards.

3. **Interactive product walkthrough**
   - A scroll-driven sequence moves between Mac and phone states while the page
     remains normally scrollable.
   - The user can manually select `Check`, `Reply`, and `Control` states.
   - The experience degrades to static images with reduced motion or disabled
     JavaScript.

4. **Supported-app truth**
   - Separate Supported, Preview, and Experimental tiers.
   - Mac Screen and Terminal lead the section.
   - Agent integrations appear with their current tier and a link to the full
     support matrix.

5. **How the connection works**
   - Mac app, signaling/account plane, and phone.
   - Clearly distinguish end-to-end encrypted content from operational metadata.
   - Link to the complete security model instead of reproducing it.

6. **Open source and self-hosting**
   - Apache 2.0.
   - Source, contributing guide, security policy, and self-hosting paths.
   - A copyable local/self-host setup command only where the current docs can
     support it.

7. **Install**
   - Direct GitHub release download.
   - Homebrew command.
   - Three setup steps: install, grant permissions and sign in, open the web app
     on the phone.

8. **FAQ**
   - Does my code leave my Mac?
   - What data can the hosted service see?
   - Which coding agents are supported?
   - Does my Mac have to stay awake?
   - Does this require an iPhone app?
   - Can I self-host it?
   - Why are Screen Recording and Accessibility required?
   - How do updates work?

9. **Final action and footer**
   - Download for Mac and View on GitHub.
   - Docs, security, contributing, releases, contact, and web app.

## 7. Visual direction

The page should feel like a native developer tool with editorial discipline,
not a generic SaaS dashboard.

- Use near-black and warm graphite as the base, crisp off-white for type,
  Glasstunnel blue for primary interaction, green for connected/success, and a
  restrained amber for approvals or attention.
- Avoid a page dominated by blue gradients. Color should communicate product
  state.
- Preserve the current rounded Glasstunnel mark but do not put every section in
  a rounded container.
- Use real Mac and mobile captures at legible scale. The product must be
  inspectable, not blurred or hidden in atmospheric imagery.
- Use a clean sans family for narrative text and a mono family only for command,
  status, protocol, and code details. A self-hosted Geist Sans/Mono pair would
  fit; system fonts are the lowest-maintenance fallback.
- Keep letter spacing at zero. Hero-scale type belongs only in the actual hero.
- Use Lucide icons for familiar commands. Keep cards to 8px radius or less and
  reserve them for repeated, genuinely framed content.

### Hero art direction

Use a real, full-bleed product capture or short rendered product film as the
background. Compose the desktop workspace and phone PWA around the same active
task so the connection is immediately obvious. Keep the heading and actions on
an uncluttered part of the frame; do not place them in a card.

The preferred story is:

1. Mac agent is working.
2. The user leaves the desk.
3. The phone shows the same task and sends the next prompt.
4. The Mac continues locally.

## 8. Motion direction

Motion should explain continuity between devices, not decorate the page.

- Use one restrained hero loop, 8 to 12 seconds, muted and without a sound
  dependency.
- Use small state transitions for connected, waiting, needs input, and done.
- Use scroll-linked progress only in the walkthrough section, never to lock the
  entire page.
- Respect `prefers-reduced-motion` and provide a high-quality static frame.
- Pause video when outside the viewport and avoid large uncompressed assets.

Recommended runtime animation library: [Motion](https://motion.dev/docs). It
supports JavaScript and React, scroll and layout animation, and lets the site
keep interaction code focused.

Recommended media-production tool: [Remotion](https://www.remotion.dev/docs)
for a controlled product walkthrough rendered from real captures. Use Remotion
to make media assets, not as the website runtime.

Do not add Three.js, Rive, GSAP, or Lottie for the first version. None is needed
to explain this product, and each would add a second animation system or asset
pipeline before the core page is proven.

## 9. Asset plan

The current repository contains brand assets but no landing-page product media.
Before mockup approval, capture a coherent, privacy-safe set:

1. Mac app Workspace with a real connected state.
2. Mac Screen running from the mobile PWA.
3. Terminal session with a harmless demo command.
4. A Supported app flow and a Preview app flow clearly labeled.
5. Permission onboarding and account linking for the setup section.
6. Matching desktop and mobile frames from the same demo account and task.

Capture rules:

- Use a dedicated demo account and a disposable demo repository.
- Remove personal email, device names, absolute paths, prompts, and tokens.
- Use the local Glasstunnel test environment before production.
- Capture desktop, wide desktop, and phone aspect ratios intentionally; do not
  crop one master screenshot into every slot.
- Use ImageGen only for a non-product background plate or art-directed context
  that cannot be captured. Never use it to fabricate the product UI.

## 10. Recommended implementation stack

Keep the existing `site/` workspace and Vite build for the first public page.
A single-page marketing site does not yet justify a framework migration.

- Vite + TypeScript.
- Semantic HTML and custom CSS aligned with the product tokens.
- Motion for the small interactive walkthrough and state transitions.
- Lucide for interface icons.
- Responsive `<picture>` sources with AVIF/WebP and explicit dimensions.
- Native `<details>` for FAQ unless the design needs a more elaborate but still
  accessible disclosure component.
- No CMS for the first release. Keep public claims reviewable in Git.

Reconsider Astro only when the site gains a real multi-page documentation or
content system. Astro is optimized for content-driven sites, ships minimal
client JavaScript by default, and supports component islands and Cloudflare,
but migrating now would create work without improving the first landing page's
core story. See [Astro's official overview](https://astro.build/).

## 11. Codex tools and integrations

The useful capabilities are already installed. No broad plugin installation is
needed before design starts.

### Primary design canvas: Pen

[Pen](https://pen.dev/) is the primary design tool for this project. Its
Codex integration is exposed through a local MCP server still named `pencil`.
The installed Pen desktop app and the existing Codex MCP configuration were
verified on August 2, 2026:

- Pen desktop version 1.2.3 is installed at `/Applications/Pen.app`.
- `codex mcp list` reports the `pencil` server as enabled.
- A direct MCP handshake returned server `pencil` version 1.0.0 and the expected
  design, screenshot, browser, and export tools.
- No duplicate or additional MCP configuration is needed.

Pen must be running before a fresh Codex task starts. Confirm that `pencil`
appears in `/mcp` before starting the visual concept pass. A task created before
the MCP server loads will not gain those tools retroactively; start a new task
or restart Codex instead of editing configuration again.

The approved design artifact should eventually live at a stable project path
such as `design/glasstunnel-landing.pen`. Do not create that file until the
concept phase begins. Pen should hold the page grid, type scale, color and state
tokens, desktop and phone hero frames, major section layouts, and reduced-motion
key frames. It replaces Figma as the editable source of truth for this work.

### Recommended supporting tools

- **Product Design skills:** research, ideation, audit, visual comparison, and
  design QA before and after Pen work.
- **MotionSites:** inspiration catalog for current animated hero conventions
  and prompt vocabulary. It is research input, not a dependency or source of
  templates to copy.
- **ImageGen:** produce only missing art-directed background assets or an Open
  Graph image, grounded in real product captures.
- **Remotion skills:** create the hero/product walkthrough film from approved
  Pen frames and real captures.
- **Motion:** implement restrained runtime transitions only after the static
  hierarchy and reduced-motion version are approved.
- **Browser/Chrome plus Computer Use:** compare the finished page at real
  desktop and mobile viewports and verify navigation, FAQ, download, and GitHub
  actions.
- **Cloudflare tools:** create and configure the separate marketing Pages
  project and apex custom domain after local approval.
- **Glasstunnel local test skill:** generate safe, repeatable product states for
  screenshots and interactions.

### Not recommended yet

- A new CMS, analytics SDK, design-system dependency, or 3D engine.
- A general site-builder plugin that replaces the existing repository setup.
- Live GitHub API calls in the browser for basic release information. Link to
  `/releases/latest` or resolve release metadata at build time instead.

### Tooling readiness audit

Verified on August 2, 2026:

| Capability | Status | Decision |
| --- | --- | --- |
| Pen design canvas | Ready | Pen 1.2.3 is running and its local `pencil` MCP handshake passed. No new MCP is needed. |
| Research and visual QA | Ready | Product Design, signed-in browser research, Chrome, Computer Use, and image generation are available. |
| Local product captures | Ready | The Glasstunnel Local Test Lab passes `pnpm lab:doctor`; stable local signing is present. |
| Browser coverage | Ready | Playwright Chromium and WebKit are installed. Use Playwright for deterministic checks and Codex Browser for visual acceptance. |
| GitHub | Ready | The GitHub CLI is authenticated and repository-scoped operations are available. |
| Cloudflare | Live | The separate `glasstunnel-site` Pages project serves `glasstunnel.io`; the existing `glasstunnel` project continues serving `app.glasstunnel.io`. |
| Motion production | Deferred intentionally | Remotion skills are available. Add pinned Remotion or Motion packages only after an approved concept proves they are needed. |
| Accessibility automation | Add during implementation | Integrate `@axe-core/playwright` with the landing-page Playwright suite after real interactive states exist. Automated checks supplement keyboard, zoom, contrast, and reduced-motion review. |
| Performance budgets | Add during implementation | Add pinned Lighthouse CI configuration after the first representative build and media payload exist, then establish evidence-based budgets. |
| Image and video optimization | Add after asset selection | Prefer a repository script using a pinned tool such as `sharp`, plus the chosen Remotion pipeline, over untracked global ImageMagick, WebP, AVIF, or FFmpeg installations. |

No additional MCP should be installed before the Pen concept pass. In
particular, Figma, a generic scraping MCP, a component-gallery MCP, a CMS,
analytics, or a second deployment MCP would duplicate an existing capability or
bias the design before the product story is approved.

## 12. Deployment architecture

Do not deploy the landing page into the current `glasstunnel` Cloudflare Pages
project. That project serves the operational PWA at `app.glasstunnel.io`.

Recommended structure:

- Existing Pages project `glasstunnel` -> `app.glasstunnel.io`.
- New Pages project such as `glasstunnel-site` -> `glasstunnel.io` and optional
  `www.glasstunnel.io` redirect.
- Existing Worker -> `signaling.glasstunnel.io`.

Cloudflare documents custom apex-domain setup through a Pages project's Custom
Domains settings, with the apex zone using Cloudflare nameservers. See the
[Cloudflare Pages custom-domain guide](https://developers.cloudflare.com/pages/configuration/custom-domains/).

The approved implementation adds the site build and deployment to the existing
Deploy workflow rather than creating another billable runner. It includes:

- `pnpm --filter=@glasstunnel/site typecheck`
- `pnpm --filter=@glasstunnel/site build`
- Dedicated Pages project name and deployment target.
- Canonical URL, Open Graph image, metadata, sitemap, robots policy, favicon,
  security contact, and cache headers.
- Preview deployments for design review before apex-domain activation.

## 13. Design and build workflow

1. Turn the durable, high-traction, X, and MotionSites references above into a
   compact Pen moodboard. Label what is product evidence, visual inspiration,
   and a pattern to reject.
2. Define a small Glasstunnel visual system in Pen: grid, type, color, state,
   motion principles, capture treatment, and mobile behavior.
3. Capture the required real Glasstunnel product states with sanitized data.
4. Produce two materially different Pen concepts using the same brief, product
   truth, and asset set. Each must include a desktop first viewport, phone first
   viewport, one lower-page section, and a reduced-motion frame.
5. Review the concepts with the user before changing `site/`. Compare them on
   comprehension, product truth, distinctiveness, responsiveness, feasibility,
   accessibility, and expected performance.
6. Implement only the approved concept locally.
7. Verify desktop and mobile layouts, reduced motion, keyboard navigation,
   contrast, loading behavior, and asset fallbacks.
8. Run the site build plus repository-selected validation.
9. Create a separate Cloudflare deployment for final review.
10. Attach `glasstunnel.io` only after the deployed build passes production
    smoke checks.

### Readiness decision

The approved continuity concept is implemented. The landing page uses a real
DOM-based Mac-to-phone product sequence, truthful support tiers, explicit
security boundaries, release and Homebrew install paths, and responsive layouts
without changing the authenticated web app. Future design work should improve
measured product evidence or launch media rather than restart concept selection.

## 14. Production implementation record

Deployed August 3, 2026:

- `glasstunnel.io` -> Cloudflare Pages project `glasstunnel-site`.
- `app.glasstunnel.io` -> existing operational Pages project `glasstunnel`
  (unchanged).
- Canonical metadata, Open Graph artwork, sitemap, robots policy, favicon,
  restrictive CSP, Permissions Policy, COOP, referrer policy, and asset caching
  ship with the marketing site.
- Desktop, laptop, and 390 px phone layouts were checked for overlap and
  horizontal overflow in the local build and on the production domain.
- The animated prompt handoff, pause/play control, mobile navigation,
  walkthrough tabs, and install-command copy feedback were exercised.
- Site typecheck/build, workspace build/lint/tests, public-repository audit, and
  `git diff --check` passed before deployment.

The page deliberately presents Codex, Cursor, and other agent integrations by
their documented support tier. It does not claim that preview or experimental
adapters are fully supported.

## 15. Acceptance criteria

- A first-time visitor can explain Glasstunnel after the first viewport.
- The first viewport contains a real product signal, Download, and GitHub.
- Public-beta status and macOS availability are visible.
- Support tiers match `docs/agent-app-support-matrix.md`.
- Security wording matches `docs/security.md`.
- All major claims are either demonstrated or linked to evidence.
- Desktop, tablet, and phone layouts have no horizontal overflow or overlapping
  text.
- The page works with reduced motion and without JavaScript.
- Download, GitHub, web app, docs, security, self-hosting, and FAQ paths work.
- The marketing deployment cannot overwrite the operational PWA project.

## 16. Research sources

- [Zed](https://zed.dev/)
- [Bun](https://bun.sh/)
- [Supabase](https://supabase.com/)
- [Tauri](https://tauri.app/)
- [Astro](https://astro.build/)
- [RustDesk](https://rustdesk.com/)
- [Tailscale](https://tailscale.com/)
- [Cal.com](https://cal.com/)
- [OpenCode](https://opencode.ai/)
- [OpenCode repository](https://github.com/anomalyco/opencode)
- [OpenClaw](https://openclaw.ai/)
- [OpenClaw repository](https://github.com/openclaw/openclaw)
- [Paperclip](https://paperclip.ing/)
- [Paperclip repository](https://github.com/paperclipai/paperclip)
- [Voicebox](https://voicebox.sh/)
- [Voicebox repository](https://github.com/jamiepine/voicebox)
- [DeerFlow](https://deerflow.tech/)
- [DeerFlow repository](https://github.com/bytedance/deer-flow)
- [Impeccable](https://impeccable.style/)
- [Impeccable repository](https://github.com/pbakaus/impeccable)
- [agent-browser](https://agent-browser.dev/)
- [agent-browser repository](https://github.com/vercel-labs/agent-browser)
- [GitHub Trending](https://github.com/trending)
- [MotionSites](https://motionsites.ai/)
- [MotionSites launch post](https://x.com/Hartdrawss/status/2070832184307396671)
- [Kimi K3 versus Fable 5 landing-page comparison](https://x.com/nicos_ai/status/2077841576760381455)
- [Elaya animated landing-page post](https://x.com/elayadesigns/status/2081325937229210107)
- [Claude Design system masterclass](https://x.com/nateherk/status/2049671821193036006)
- [Pen installation](https://docs.pencil.dev/getting-started/installation)
- [Pen AI integration](https://docs.pencil.dev/getting-started/ai-integration)
- [Pen troubleshooting](https://docs.pencil.dev/troubleshooting)
- [Pen CLI](https://docs.pencil.dev/for-developers/pencil-cli)
- [Motion documentation](https://motion.dev/docs)
- [Remotion documentation](https://www.remotion.dev/docs)
- [Cloudflare Pages custom domains](https://developers.cloudflare.com/pages/configuration/custom-domains/)
