import { animate, inView } from 'motion';
import {
  Activity,
  ArrowRight,
  ArrowUp,
  ArrowUpRight,
  Beaker,
  Check,
  CheckCircle2,
  Code2,
  Copy,
  Download,
  FlaskConical,
  Folder,
  FolderGit2,
  Github,
  KeyRound,
  Laptop,
  LockKeyhole,
  Menu,
  MessageSquareText,
  MonitorSmartphone,
  MonitorUp,
  MousePointer2,
  PanelsTopLeft,
  Pause,
  Play,
  Plus,
  Route,
  ShieldCheck,
  SlidersHorizontal,
  Smartphone,
  SquareTerminal,
  Terminal,
  X,
  createIcons,
} from 'lucide';

const siteIcons = {
  Activity,
  ArrowRight,
  ArrowUp,
  ArrowUpRight,
  Beaker,
  Check,
  CheckCircle2,
  Code2,
  Copy,
  Download,
  FlaskConical,
  Folder,
  FolderGit2,
  Github,
  KeyRound,
  Laptop,
  LockKeyhole,
  Menu,
  MessageSquareText,
  MonitorSmartphone,
  MonitorUp,
  MousePointer2,
  PanelsTopLeft,
  Pause,
  Play,
  Plus,
  Route,
  ShieldCheck,
  SlidersHorizontal,
  Smartphone,
  SquareTerminal,
  Terminal,
  X,
};

createIcons({ icons: siteIcons });

const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const sleep = (milliseconds: number) => new Promise((resolve) => window.setTimeout(resolve, milliseconds));

const header = document.querySelector<HTMLElement>('[data-header]');
const nav = document.querySelector<HTMLElement>('[data-nav]');
const navToggle = document.querySelector<HTMLButtonElement>('[data-nav-toggle]');

const closeNavigation = () => {
  nav?.classList.remove('is-open');
  navToggle?.setAttribute('aria-expanded', 'false');
};

navToggle?.addEventListener('click', () => {
  const open = nav?.classList.toggle('is-open') ?? false;
  navToggle.setAttribute('aria-expanded', String(open));
});

nav?.querySelectorAll('a').forEach((link) => link.addEventListener('click', closeNavigation));

const updateHeader = () => header?.classList.toggle('is-scrolled', window.scrollY > 20);
updateHeader();
window.addEventListener('scroll', updateHeader, { passive: true });

const scene = document.querySelector<HTMLElement>('[data-hero-scene]');
const motionToggle = document.querySelector<HTMLButtonElement>('[data-motion-toggle]');
const macStatus = document.querySelector<HTMLElement>('[data-mac-status]');
const phoneStatus = document.querySelector<HTMLElement>('[data-phone-status]');
const agentState = document.querySelector<HTMLElement>('[data-agent-state]');
const agentPanelState = document.querySelector<HTMLElement>('[data-agent-panel-state]');
const agentDetail = document.querySelector<HTMLElement>('[data-agent-detail]');
const agentProgress = document.querySelector<HTMLElement>('[data-agent-progress]');
const testResult = document.querySelector<HTMLElement>('[data-test-result]');
const phonePrompt = document.querySelector<HTMLElement>('[data-phone-prompt]');
const phoneResult = document.querySelector<HTMLElement>('[data-phone-result]');
const composerText = document.querySelector<HTMLElement>('[data-composer-text]');
const phoneComposer = document.querySelector<HTMLElement>('[data-phone-composer]');
const transitPrompt = document.querySelector<HTMLElement>('[data-transit-prompt]');
const transitResult = document.querySelector<HTMLElement>('[data-transit-result]');

const prompt = 'Add keyboard navigation and run the tests.';
let heroCycle = 0;
let motionPlaying = !reducedMotion.matches;
let heroVisible = true;

const setStatus = (status: 'READY' | 'WORKING' | 'DONE') => {
  const label = status === 'READY' ? 'Ready' : status === 'WORKING' ? 'Working' : 'Done';
  macStatus && (macStatus.textContent = status);
  phoneStatus && (phoneStatus.textContent = status);
  agentState && (agentState.textContent = label);
  scene?.setAttribute('data-status', status.toLowerCase());
};

const updateMotionToggle = () => {
  if (!motionToggle) return;
  motionToggle.setAttribute('aria-label', motionPlaying ? 'Pause product animation' : 'Play product animation');
  motionToggle.innerHTML = `<i data-lucide="${motionPlaying ? 'pause' : 'play'}" aria-hidden="true"></i>`;
  createIcons({ icons: siteIcons });
};

const resetHero = () => {
  setStatus('READY');
  agentPanelState && (agentPanelState.textContent = 'WAITING');
  agentDetail && (agentDetail.textContent = 'Waiting for your next prompt');
  composerText && (composerText.textContent = 'Send a prompt…');
  phoneComposer?.classList.remove('is-typing');
  phonePrompt?.classList.remove('is-visible');
  phoneResult?.classList.remove('is-visible');
  testResult?.classList.remove('is-visible');
  if (agentProgress) agentProgress.style.width = '0%';
  for (const element of [transitPrompt, transitResult]) {
    if (!element) continue;
    element.style.opacity = '0';
    element.style.transform = 'translate3d(0, 0, 0) scale(.94)';
  }
};

const setCompletedHero = () => {
  resetHero();
  setStatus('DONE');
  agentPanelState && (agentPanelState.textContent = 'COMPLETE');
  agentDetail && (agentDetail.textContent = 'Keyboard navigation is live');
  phonePrompt?.classList.add('is-visible');
  phoneResult?.classList.add('is-visible');
  testResult?.classList.add('is-visible');
  if (agentProgress) agentProgress.style.width = '100%';
};

const typePrompt = async (cycle: number) => {
  if (!composerText || !phoneComposer) return;
  phoneComposer.classList.add('is-typing');
  for (let index = 1; index <= prompt.length; index += 1) {
    if (cycle !== heroCycle || !motionPlaying || !heroVisible) return;
    composerText.textContent = prompt.slice(0, index);
    await sleep(22);
  }
  await sleep(180);
  phoneComposer.classList.remove('is-typing');
  phonePrompt?.classList.add('is-visible');
};

const travel = async (element: HTMLElement | null, from: Element | null, to: Element | null, cycle: number) => {
  if (!element || !from || !to || !scene) return;
  const sceneBox = scene.getBoundingClientRect();
  const fromBox = from.getBoundingClientRect();
  const toBox = to.getBoundingClientRect();
  const start = {
    x: fromBox.left + fromBox.width / 2 - sceneBox.left - element.offsetWidth / 2,
    y: fromBox.top + fromBox.height / 2 - sceneBox.top - element.offsetHeight / 2,
  };
  const end = {
    x: toBox.left + toBox.width / 2 - sceneBox.left - element.offsetWidth / 2,
    y: toBox.top + toBox.height / 2 - sceneBox.top - element.offsetHeight / 2,
  };
  element.style.left = '0';
  element.style.top = '0';
  const controls = animate(
    element,
    {
      opacity: [0, 1, 1, 0],
      x: [start.x, start.x + (end.x - start.x) * 0.45, end.x],
      y: [start.y, Math.min(start.y, end.y) - sceneBox.height * 0.08, end.y],
      scale: [0.94, 1, 0.94],
    },
    { duration: 1.05, ease: [0.33, 1, 0.68, 1], times: [0, 0.55, 1] },
  );
  await controls;
  if (cycle !== heroCycle) controls.stop();
};

const runHeroLoop = async () => {
  const cycle = ++heroCycle;
  resetHero();
  if (!motionPlaying || !heroVisible) return;
  await sleep(650);
  await typePrompt(cycle);
  if (cycle !== heroCycle || !motionPlaying || !heroVisible) return;
  await travel(transitPrompt, phoneComposer, document.querySelector('[data-agent-panel]'), cycle);
  if (cycle !== heroCycle || !motionPlaying || !heroVisible) return;
  setStatus('WORKING');
  agentPanelState && (agentPanelState.textContent = 'WORKING');
  agentDetail && (agentDetail.textContent = 'Editing CommandPalette.tsx');
  if (agentProgress) animate(agentProgress, { width: ['8%', '62%'] }, { duration: 1.55, ease: 'easeInOut' });
  await sleep(1450);
  agentDetail && (agentDetail.textContent = 'Running accessibility tests');
  if (agentProgress) await animate(agentProgress, { width: ['62%', '100%'] }, { duration: 1.15, ease: 'easeInOut' });
  if (cycle !== heroCycle || !motionPlaying || !heroVisible) return;
  setStatus('DONE');
  agentPanelState && (agentPanelState.textContent = 'COMPLETE');
  agentDetail && (agentDetail.textContent = 'Keyboard navigation is live');
  testResult?.classList.add('is-visible');
  await sleep(450);
  await travel(transitResult, document.querySelector('[data-agent-panel]'), phoneResult, cycle);
  if (cycle !== heroCycle || !motionPlaying || !heroVisible) return;
  phoneResult?.classList.add('is-visible');
  await sleep(2100);
  if (cycle === heroCycle && motionPlaying && heroVisible) void runHeroLoop();
};

if (scene) {
  const observer = new IntersectionObserver(
    ([entry]) => {
      heroVisible = entry.isIntersecting;
      heroCycle += 1;
      if (heroVisible && motionPlaying) void runHeroLoop();
    },
    { threshold: 0.15 },
  );
  observer.observe(scene);
}

if (reducedMotion.matches) {
  motionPlaying = false;
  setCompletedHero();
  updateMotionToggle();
}

reducedMotion.addEventListener('change', ({ matches }) => {
  motionPlaying = !matches;
  heroCycle += 1;
  matches ? setCompletedHero() : void runHeroLoop();
  updateMotionToggle();
});

motionToggle?.addEventListener('click', () => {
  motionPlaying = !motionPlaying;
  heroCycle += 1;
  if (motionPlaying) void runHeroLoop();
  else setCompletedHero();
  updateMotionToggle();
});

document.addEventListener('visibilitychange', () => {
  heroVisible = document.visibilityState === 'visible' && (scene?.getBoundingClientRect().bottom ?? 0) > 0;
  heroCycle += 1;
  if (heroVisible && motionPlaying) void runHeroLoop();
});

document.querySelectorAll<HTMLElement>('.reveal').forEach((element) => {
  if (reducedMotion.matches) return;
  element.style.opacity = '0';
  element.style.transform = 'translateY(28px)';
  inView(
    element,
    () => {
      animate(element, { opacity: 1, transform: 'translateY(0)' }, { duration: 0.65, ease: [0.16, 1, 0.3, 1] });
    },
    { amount: 0.2 },
  );
});

const walkthroughContent = {
  check: {
    copy: 'Open your phone and see the state your Mac already knows. No duplicate environment and no second copy of the project.',
    title: 'Working on keyboard navigation',
    status: 'WORKING',
    phone: 'Codex is working',
    detail: 'Last update just now',
  },
  reply: {
    copy: 'Send the next prompt into the same local conversation. Your agent keeps its tools, files, and accumulated context.',
    title: 'Prompt received from phone',
    status: 'PROMPT RECEIVED',
    phone: 'Prompt delivered',
    detail: 'Continuing on Demo Mac',
  },
  control: {
    copy: 'When the agent UI is not enough, open Mac Screen or a scoped Terminal session and take direct control.',
    title: 'Mac Screen is ready',
    status: 'CONNECTED',
    phone: 'Mac Screen is live',
    detail: 'Encrypted WebRTC session',
  },
} as const;

const walkthroughCopy = document.querySelector<HTMLElement>('[data-walkthrough-copy]');
const walkthroughTitle = document.querySelector<HTMLElement>('[data-walkthrough-title]');
const walkthroughStatus = document.querySelector<HTMLElement>('[data-walkthrough-status]');
const walkthroughPhone = document.querySelector<HTMLElement>('[data-walkthrough-phone]');
const walkthroughDetail = document.querySelector<HTMLElement>('[data-walkthrough-detail]');
const walkthroughVisual = document.querySelector<HTMLElement>('[data-walkthrough-visual]');
const modeButtons = [...document.querySelectorAll<HTMLButtonElement>('[data-mode]')];

const selectMode = (mode: keyof typeof walkthroughContent) => {
  const content = walkthroughContent[mode];
  modeButtons.forEach((button) => button.setAttribute('aria-selected', String(button.dataset.mode === mode)));
  walkthroughCopy && (walkthroughCopy.textContent = content.copy);
  walkthroughTitle && (walkthroughTitle.textContent = content.title);
  walkthroughStatus && (walkthroughStatus.textContent = content.status);
  walkthroughPhone && (walkthroughPhone.textContent = content.phone);
  walkthroughDetail && (walkthroughDetail.textContent = content.detail);
  walkthroughVisual?.setAttribute('data-mode', mode);
  if (walkthroughVisual && !reducedMotion.matches) {
    animate(walkthroughVisual, { opacity: [0.75, 1], scale: [0.985, 1] }, { duration: 0.36, ease: [0.16, 1, 0.3, 1] });
  }
};

modeButtons.forEach((button, index) => {
  button.addEventListener('click', () => selectMode(button.dataset.mode as keyof typeof walkthroughContent));
  button.addEventListener('keydown', (event) => {
    if (!['ArrowLeft', 'ArrowRight'].includes(event.key)) return;
    event.preventDefault();
    const delta = event.key === 'ArrowRight' ? 1 : -1;
    const next = modeButtons[(index + delta + modeButtons.length) % modeButtons.length];
    next.focus();
    next.click();
  });
});

document.querySelector<HTMLButtonElement>('[data-copy-command]')?.addEventListener('click', async (event) => {
  const button = event.currentTarget as HTMLButtonElement;
  const command = document.querySelector<HTMLElement>('#install-command')?.textContent ?? '';
  try {
    await navigator.clipboard.writeText(command.trim());
    button.innerHTML = '<i data-lucide="check" aria-hidden="true"></i><span>Copied</span>';
    createIcons({ icons: siteIcons });
    window.setTimeout(() => {
      button.innerHTML = '<i data-lucide="copy" aria-hidden="true"></i><span>Copy</span>';
      createIcons({ icons: siteIcons });
    }, 1800);
  } catch {
    button.innerHTML = '<i data-lucide="x" aria-hidden="true"></i><span>Copy failed</span>';
    createIcons({ icons: siteIcons });
  }
});

import './hero-v2';
