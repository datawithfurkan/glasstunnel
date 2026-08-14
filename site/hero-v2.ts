/* =============================================================================
   Glasstunnel — Hero v2 · four-scene product story
   Paced to be *read*, not skimmed: ~46s total, ~11s per scene, with dwell
   time after every state change. Compositor-only motion.
   ========================================================================== */

type El = HTMLElement | null;
type Scene = 'codex' | 'terminal' | 'claude' | 'screen';

const stage = document.querySelector<HTMLElement>('[data-stage]');

if (stage) {
  const q = <T extends HTMLElement>(s: string) => stage.querySelector<T>(s);
  const qa = (s: string) => Array.from(stage.querySelectorAll<HTMLElement>(s));

  const osApp = q('[data-os-app]');
  const cursor = q('[data-cursor]');
  const macScenes = qa('[data-mac-scene]');
  const phScenes = qa('[data-ph-scene]');
  const chips = qa('[data-chip]');
  const legends = qa('[data-legend]');

  const phInput = q('[data-ph-input]');
  const phUser = q('[data-ph-user] span');
  const phUser2 = q('[data-ph-user2] span');
  const phTerm = q('[data-ph-term]');
  const phTermOut = q('[data-ph-term-out]');
  const gmSheet = q('[data-gm-sheet]');
  const gmDone = q('[data-gm-done]');

  const codexPrompt = q('[data-codex-prompt]');
  const codexReply = q('[data-codex-reply]');
  const codexDiff = q('[data-codex-diff]');
  const codexStatus = q('[data-codex-status]');
  const macProgress = q('[data-mac-progress]');

  const termCmd = q('[data-term-cmd]');
  const termOut = q('[data-term-out]');

  const claudePrompt = q('[data-claude-prompt]');
  const claudeOut = q('[data-claude-out]');

  const macPerm = q('[data-mac-perm]');
  const macAllow = q('[data-mac-allow]');
  const macPermDone = q('[data-mac-perm-done]');
  const phApprove = q('[data-ph-approve]');
  const phAllow = q('[data-ph-allow]');
  const phApproved = q('[data-ph-approved]');

  const toggle = q<HTMLButtonElement>('[data-motion-toggle]');
  const reduce = window.matchMedia('(prefers-reduced-motion: reduce)');

  const APP: Record<Scene, string> = {
    codex: 'Codex', terminal: 'Terminal', claude: 'Claude Code', screen: 'Codex',
  };

  let token = 0;
  let paused = false;
  let onScreen = true;

  const sleep = (ms: number, id: number) =>
    new Promise<void>((r) => window.setTimeout(() => id === token && r(), ms));

  const show = (scene: Scene) => {
    macScenes.forEach((el) => el.classList.toggle('is-on', el.dataset.macScene === scene));
    phScenes.forEach((el) => el.classList.toggle('is-on', el.dataset.phScene === scene));
    chips.forEach((el) => el.classList.toggle('is-on', el.dataset.chip === scene));
    legends.forEach((el) => el.classList.toggle('is-on', el.dataset.legend === scene));
    stage.dataset.scene = scene;
    if (osApp) osApp.textContent = APP[scene];

    // Scroll the app strip to the selected chip, the way the real app does,
    // so the active chip is never clipped at the phone's narrow width.
    const strip = stage.querySelector<HTMLElement>('.g-strip');
    const chip = stage.querySelector<HTMLElement>(`[data-chip="${scene}"]`);
    if (strip && chip) {
      const target = chip.offsetLeft - (strip.clientWidth - chip.offsetWidth) / 2;
      strip.scrollLeft = Math.max(0, target);
    }
  };

  /** deliberately unhurried typing so a viewer can read along */
  const type = async (el: El, text: string, id: number, per = 58) => {
    if (!el) return;
    el.textContent = '';
    for (let i = 0; i < text.length; i += 1) {
      if (id !== token) return;
      el.textContent = text.slice(0, i + 1);
      await sleep(per, id);
    }
  };

  const grow = (el: El, ms: number) => {
    el?.animate([{ transform: 'scaleX(0)' }, { transform: 'scaleX(1)' }],
      { duration: ms, easing: 'ease-in-out', fill: 'forwards' });
  };

  const macHost = stage.querySelector<HTMLElement>('.mb');

  /** Where the cursor waits between scenes: bottom-right, i.e. the phone's side,
   *  so it reads as arriving from the phone. */
  const restPoint = () => {
    if (!macHost) return { x: 0, y: 0 };
    const h = macHost.getBoundingClientRect();
    return { x: Math.round(h.width * 0.78), y: Math.round(h.height * 0.94) };
  };

  /** Point the remote cursor at a real element on the Mac.
   *  NOTE: transform percentages resolve against the cursor's own box, not the
   *  Mac, so these must be pixels measured against the cursor's offset parent. */
  const pointAt = (selector: string, ms: number) => {
    if (!cursor || !macHost) return;
    const target = stage.querySelector<HTMLElement>(selector);
    if (!target) return;
    const t = target.getBoundingClientRect();
    const h = macHost.getBoundingClientRect();
    // arrow tip sits at the element's top-left corner, so aim slightly inside centre
    const x = Math.round(t.left - h.left + t.width / 2 - 4);
    const y = Math.round(t.top - h.top + t.height / 2 - 5);
    const from = cursor.style.transform || `translate3d(${restPoint().x}px, ${restPoint().y}px, 0)`;
    const to = `translate3d(${x}px, ${y}px, 0)`;
    cursor.classList.add('is-on');
    cursor.animate([{ transform: from }, { transform: to }],
      { duration: ms, easing: 'cubic-bezier(.35,.7,.25,1)', fill: 'forwards' });
    cursor.style.transform = to;
  };

  const resetAll = () => {
    if (macProgress) macProgress.style.transform = 'scaleX(0)';
    termOut?.classList.remove('is-on');
    claudeOut?.classList.remove('is-on');
    codexDiff?.classList.remove('is-on');
    macPerm?.classList.remove('is-off');
    macAllow?.classList.remove('is-hit');
    macPermDone?.classList.remove('is-on');
    phApprove?.classList.remove('is-off');
    phAllow?.classList.remove('is-hit');
    phApproved?.classList.remove('is-on');
    phTermOut?.classList.remove('is-on');
    gmSheet?.classList.remove('is-off');
    gmDone?.classList.remove('is-on');
    cursor?.classList.remove('is-on');
    if (cursor) { const p = restPoint(); cursor.style.transform = `translate3d(${p.x}px, ${p.y}px, 0)`; }
    [phUser, phUser2, phTerm, termCmd, codexPrompt, claudePrompt].forEach((el) => {
      if (el) el.textContent = '';
    });
    if (phInput) phInput.textContent = 'Send a prompt…';
    if (codexReply) codexReply.innerHTML = 'Waiting for a prompt…';
    if (codexStatus) codexStatus.textContent = 'Idle';
  };

  async function story(id: number) {
    while (id === token) {
      resetAll();

      /* ================= 1 · Codex  (~12s) ================= */
      show('codex');
      await sleep(1400, id); if (id !== token) return;

      const p1 = 'Add keyboard navigation to the nav bar.';
      await type(phInput, p1, id, 52);              // typed on the phone
      await sleep(700, id); if (id !== token) return;

      if (phUser) phUser.textContent = p1;          // sent
      if (phInput) phInput.textContent = 'Send a prompt…';
      await sleep(600, id); if (id !== token) return;

      await type(codexPrompt, p1, id, 26);          // lands in Codex on the Mac
      await sleep(700, id); if (id !== token) return;

      if (codexStatus) codexStatus.textContent = 'Thinking…';
      if (codexReply) codexReply.innerHTML = 'Reading <code>src/Nav.tsx</code>…';
      grow(macProgress, 3400);
      await sleep(2600, id); if (id !== token) return;

      codexDiff?.classList.add('is-on');            // the edit appears
      await sleep(1400, id); if (id !== token) return;
      if (codexStatus) codexStatus.textContent = 'Edited src/Nav.tsx';
      await sleep(2400, id); if (id !== token) return;

      /* ================= 2 · Terminal  (~11s) ================= */
      show('terminal');
      await sleep(1600, id); if (id !== token) return;

      const cmd = 'npm test';
      // typed character-by-character on BOTH screens at once — the sync is the point
      await Promise.all([
        type(phTerm, cmd, id, 130),
        type(termCmd, cmd, id, 130),
      ]);
      await sleep(1200, id); if (id !== token) return;

      termOut?.classList.add('is-on');              // Mac prints…
      await sleep(320, id); if (id !== token) return;
      phTermOut?.classList.add('is-on');            // …phone follows a beat later
      await sleep(4200, id); if (id !== token) return;

      /* ================= 3 · Claude Code  (~11s) ================= */
      show('claude');
      await sleep(1600, id); if (id !== token) return;

      const p3 = 'Write tests for the new nav.';
      await type(phInput, p3, id, 52);
      await sleep(700, id); if (id !== token) return;
      if (phUser2) phUser2.textContent = p3;
      if (phInput) phInput.textContent = 'Send a prompt…';
      await sleep(600, id); if (id !== token) return;

      await type(claudePrompt, p3, id, 30);
      await sleep(900, id); if (id !== token) return;
      claudeOut?.classList.add('is-on');
      await sleep(3800, id); if (id !== token) return;

      /* ================= 4 · Screen + approval  (~12s) ================= */
      show('screen');
      await sleep(2400, id); if (id !== token) return;   // let the sheet register

      // the finger presses Approve on the phone…
      phAllow?.classList.add('is-hit');
      await sleep(700, id); if (id !== token) return;

      // …and the remote cursor performs the same click on the Mac
      pointAt('[data-mac-allow]', 1100);
      await sleep(1300, id); if (id !== token) return;
      macAllow?.classList.add('is-hit');
      await sleep(500, id); if (id !== token) return;

      macPerm?.classList.add('is-off');
      macPermDone?.classList.add('is-on');
      gmSheet?.classList.add('is-off');   // the mirror reflects the Mac
      gmDone?.classList.add('is-on');
      phApprove?.classList.add('is-off');
      phApproved?.classList.add('is-on');
      await sleep(4200, id);                            // hold the payoff
    }
  }

  /* ------------------------------- control -------------------------------- */
  const start = () => {
    if (reduce.matches || paused || !onScreen) return;
    if (document.visibilityState === 'hidden') return;
    token += 1;
    void story(token);
  };
  const halt = () => { token += 1; };

  toggle?.addEventListener('click', () => {
    paused = !paused;
    toggle.setAttribute('aria-label',
      paused ? 'Play the product animation' : 'Pause the product animation');
    if (paused) halt(); else start();
  });

  new IntersectionObserver(([e]) => {
    onScreen = e.isIntersecting;
    if (onScreen) start(); else halt();
  }, { threshold: 0.12 }).observe(stage);

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'hidden') halt(); else start();
  });

  reduce.addEventListener('change', () => { halt(); if (!reduce.matches) start(); });

  if (!reduce.matches) start();
}

export {};
