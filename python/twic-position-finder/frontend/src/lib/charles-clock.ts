/**
 * Charles Clock — blitz where capturing a piece permanently raises the
 * increment for both players, so the game ends in a real endgame instead of
 * a scramble.
 *
 * The two halves carry identical markup (see `ClockSide.astro`); which way
 * each faces is a runtime rotation, and "flip" swaps the two players' state
 * rather than rotating the page. The clock is delta-based, so a backgrounded
 * tab that stops firing frames still charges the right time when it returns.
 */

// ── Types ─────────────────────────────────────────────────────────

export type Side = 'top' | 'bottom';

/** The three rungs of the capture ladder, keyed as they are in `Settings`. */
export type CaptureKind = 'minor' | 'rook' | 'queen';

type Pair<T> = { top: T; bottom: T };

export interface Settings {
  minutes: number;
  base: number;
  minor: number;
  rook: number;
  queen: number;
  sound: boolean;
  facing: boolean;
}

/** Everything undo has to restore. `history` and the loop fields are not in it. */
interface Snapshot {
  ms: Pair<number>;
  active: Side | null;
  started: boolean;
  running: boolean;
  cumInc: number;
  moves: Pair<number>;
  flagged: Side | null;
  lowFired: Pair<boolean>;
}

interface State extends Snapshot {
  history: Snapshot[];
  lastTick: number;
  raf: number;
}

interface SideElements {
  root: HTMLElement;
  time: HTMLElement;
  moves: HTMLElement;
  cum: HTMLElement;
  flagChip: HTMLElement;
  who: HTMLElement;
  hint: HTMLElement;
  caps: HTMLButtonElement[];
}

// ── Config ────────────────────────────────────────────────────────

const STORAGE_KEY = 'charles-clock-settings-v2';
const DEFAULTS: Settings = { minutes: 2, base: 0, minor: 2, rook: 4, queen: 6, sound: true, facing: true };
const SIDES: readonly Side[] = ['top', 'bottom'];
const CAPTURES: readonly CaptureKind[] = ['minor', 'rook', 'queen'];
const TENTHS_UNDER = 10_000; // show tenths below this
const HIT_DEBOUNCE = 70; // ms — swallow a bouncing double-slap
const HISTORY_MAX = 200;
const MIN_EMERGENCY = 5_000; // never warn later than 5s left

function loadSettings(): Settings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (raw) return { ...DEFAULTS, ...(JSON.parse(raw) as Partial<Settings>) };
  } catch { /* private mode, or a settings blob we can't read */ }
  return { ...DEFAULTS };
}

function saveSettings(s: Settings): void {
  try { localStorage.setItem(STORAGE_KEY, JSON.stringify(s)); } catch { /* ignore */ }
}

// ── DOM helpers ───────────────────────────────────────────────────

function $<T extends Element = HTMLElement>(sel: string, root: ParentNode = document): T {
  const el = root.querySelector<T>(sel);
  if (!el) throw new Error(`Charles Clock: missing ${sel}`);
  return el;
}

function $$<T extends Element = HTMLElement>(sel: string, root: ParentNode = document): T[] {
  return Array.from(root.querySelectorAll<T>(sel));
}

/** The capture ladder is keyed by the same names in the markup and in settings. */
function asCapture(value: string | undefined): CaptureKind | null {
  return CAPTURES.includes(value as CaptureKind) ? (value as CaptureKind) : null;
}

export function initCharlesClock(): void {
  let settings = loadSettings();

  const state: State = {
    ms: { top: 0, bottom: 0 }, // remaining time
    active: null, // side to move
    started: false,
    running: false,
    cumInc: 0, // cumulative increment (s), shared by both
    moves: { top: 0, bottom: 0 },
    flagged: null,
    lowFired: { top: false, bottom: false },
    history: [], // snapshots, newest last
    lastTick: 0,
    raf: 0,
  };
  let lastHitAt = -1e9;

  const other = (s: Side): Side => (s === 'top' ? 'bottom' : 'top');
  const snapshot = (): Snapshot => ({
    ms: { ...state.ms },
    active: state.active,
    started: state.started,
    running: state.running,
    cumInc: state.cumInc,
    moves: { ...state.moves },
    flagged: state.flagged,
    lowFired: { ...state.lowFired },
  });

  // ── DOM ─────────────────────────────────────────────────────────

  const app = $('#app');
  const sideEls: Pair<HTMLElement> = { top: $('.side-top'), bottom: $('.side-bottom') };
  const el = {} as Pair<SideElements>;
  for (const side of SIDES) {
    const root = sideEls[side];
    el[side] = {
      root,
      time: $('[data-time]', root),
      moves: $('[data-moves]', root),
      cum: $('[data-cum]', root),
      flagChip: $('[data-flagchip]', root),
      who: $('[data-who]', root),
      hint: $('[data-hint]', root),
      caps: $$<HTMLButtonElement>('.cap', root),
    };
  }
  const btn = {
    primary: $<HTMLButtonElement>('[data-action="startpause"]'),
    undo: $<HTMLButtonElement>('[data-action="undo"]'),
    reset: $<HTMLButtonElement>('[data-action="reset"]'),
    settings: $<HTMLButtonElement>('[data-action="settings"]'),
    flip: $<HTMLButtonElement>('[data-action="flip"]'),
    fullscreen: $<HTMLButtonElement>('[data-action="fullscreen"]'),
  };
  const primaryLabel = $('[data-primary-label]');
  const queenTrade = $('[data-queen-trade]');
  const sheet = $('[data-sheet]');
  const form = $<HTMLFormElement>('[data-settings-form]');

  /** Named form access, typed — `form.minutes` is untyped on HTMLFormElement. */
  const field = (name: string): HTMLInputElement =>
    form.elements.namedItem(name) as HTMLInputElement;

  // ── Audio ───────────────────────────────────────────────────────

  let ac: AudioContext | null = null;
  function ensureAudio(): AudioContext | null {
    try {
      const Ctor = window.AudioContext
        ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      if (!Ctor) return null;
      ac ??= new Ctor();
      if (ac.state === 'suspended') void ac.resume().catch(() => {});
    } catch { /* no audio available */ }
    return ac;
  }

  function tone(freq: number, dur: number, vol: number, delay = 0, type: OscillatorType = 'square'): void {
    if (!settings.sound) return;
    const ctx = ensureAudio();
    if (!ctx) return;
    try {
      const t0 = ctx.currentTime + delay;
      const o = ctx.createOscillator();
      const g = ctx.createGain();
      o.type = type;
      o.frequency.setValueAtTime(freq, t0);
      g.gain.setValueAtTime(0.0001, t0);
      g.gain.exponentialRampToValueAtTime(vol, t0 + 0.008);
      g.gain.exponentialRampToValueAtTime(0.0001, t0 + dur);
      o.connect(g).connect(ctx.destination);
      o.start(t0);
      o.stop(t0 + dur + 0.02);
    } catch { /* the context died under us */ }
  }

  const SFX = {
    hit: () => tone(1000, 0.05, 0.13),
    capture: () => { tone(700, 0.05, 0.16); tone(1350, 0.09, 0.16, 0.05); },
    undo: () => { tone(900, 0.05, 0.11); tone(520, 0.08, 0.11, 0.05); },
    swap: () => { tone(520, 0.05, 0.11); tone(900, 0.08, 0.11, 0.05); },
    low: () => { tone(460, 0.08, 0.2); tone(460, 0.08, 0.2, 0.17); tone(460, 0.08, 0.2, 0.34); },
    flag: () => tone(180, 0.55, 0.25, 0, 'sawtooth'),
  };

  function buzz(pattern: number | number[]): void {
    try { navigator.vibrate?.(pattern); } catch { /* not supported */ }
  }

  // ── Wake lock ───────────────────────────────────────────────────

  let wakeLock: WakeLockSentinel | null = null;
  async function acquireWakeLock(): Promise<void> {
    try {
      if ('wakeLock' in navigator && !wakeLock) {
        wakeLock = await navigator.wakeLock.request('screen');
        wakeLock.addEventListener('release', () => { wakeLock = null; });
      }
    } catch { /* denied, or the document lost visibility mid-request */ }
  }
  function releaseWakeLock(): void {
    try { void wakeLock?.release(); } catch { /* already gone */ }
    wakeLock = null;
  }
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && state.running) void acquireWakeLock();
  });

  // ── Layout: rotate each half so it faces its player ─────────────
  // Both halves carry identical markup; rotation decides who reads what.
  // Portrait facing → far half 180°. Landscape facing → ±90°, so the two
  // players sit at the short ends of the phone. Sizes are swapped for the
  // quarter turns, which CSS alone cannot do.

  function rotFor(side: Side, cols: boolean): number {
    if (!settings.facing) return 0;
    if (cols) return side === 'top' ? 270 : 90;
    return side === 'top' ? 180 : 0;
  }

  let lastLayout = '';
  function layout(): void {
    const cols = window.innerWidth > window.innerHeight;
    app.classList.toggle('cols', cols);
    let sig = cols ? 'c' : 'r';
    for (const side of SIDES) {
      const node = sideEls[side];
      const rot = rotFor(side, cols);
      const w = node.clientWidth;
      const h = node.clientHeight;
      const quarter = rot % 180 !== 0;
      sig += `|${side}:${rot}:${w}x${h}`;
      // A quarter turn maps the column's top→bottom onto the screen's
      // left→right, which would land the capture buttons on the player's
      // near edge. Reverse the column so the digits stay nearest them.
      node.classList.toggle('quarter', quarter);
      node.style.setProperty('--rot', `${rot}deg`);
      node.style.setProperty('--iw', `${quarter ? h : w}px`);
      node.style.setProperty('--ih', `${quarter ? w : h}px`);
    }
    lastLayout = sig;
  }

  const ro = new ResizeObserver(() => {
    // Cheap guard: only re-layout when something actually moved.
    const cols = window.innerWidth > window.innerHeight;
    let sig = cols ? 'c' : 'r';
    for (const side of SIDES) {
      sig += `|${side}:${rotFor(side, cols)}:${sideEls[side].clientWidth}x${sideEls[side].clientHeight}`;
    }
    if (sig !== lastLayout) layout();
  });
  SIDES.forEach((s) => ro.observe(sideEls[s]));
  window.addEventListener('resize', layout);
  window.addEventListener('orientationchange', () => setTimeout(layout, 120));

  // ── Formatting ──────────────────────────────────────────────────

  function fmt(msIn: number): string {
    const ms = Math.max(0, msIn);
    if (ms < TENTHS_UNDER) {
      const tenths = Math.ceil(ms / 100);
      return `0:${String(Math.floor(tenths / 10)).padStart(2, '0')}.${tenths % 10}`;
    }
    const total = Math.ceil(ms / 1000);
    const h = Math.floor(total / 3600);
    const m = Math.floor((total % 3600) / 60);
    const s = String(total % 60).padStart(2, '0');
    return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${s}` : `${m}:${s}`;
  }

  const emergencyMs = (): number => Math.max(MIN_EMERGENCY, settings.minutes * 60_000 * 0.1);
  const isLow = (side: Side): boolean => state.ms[side] > 0 && state.ms[side] <= emergencyMs();

  // ── Painting ────────────────────────────────────────────────────
  // paintTime() runs every animation frame and only writes when the string
  // actually changed; render() runs on state transitions only.

  const painted: Pair<string> = { top: '', bottom: '' };
  function paintTime(): void {
    for (const side of SIDES) {
      const t = fmt(state.ms[side]);
      if (t !== painted[side]) {
        painted[side] = t;
        el[side].time.textContent = t;
      }
    }
  }

  let classSig: Pair<string> = { top: '', bottom: '' };
  function render(): void {
    const idle = !state.started || !state.running || !!state.flagged;

    for (const side of SIDES) {
      const e = el[side];
      const yourTurn = state.active === side && !state.flagged;
      const ticking = yourTurn && state.running;
      const low = isLow(side) && ticking;
      const flagged = state.flagged === side;

      const sig = `${yourTurn ? 1 : 0}${ticking ? 1 : 0}${low ? 1 : 0}${flagged ? 1 : 0}${state.started ? 1 : 0}`;
      if (sig !== classSig[side]) {
        classSig[side] = sig;
        e.root.classList.toggle('turn', yourTurn);
        e.root.classList.toggle('ticking', ticking);
        e.root.classList.toggle('low', low);
        e.root.classList.toggle('flagged', flagged);
        e.flagChip.hidden = !flagged;
        e.hint.hidden = state.started;
      }

      const canCapture = ticking;
      for (const c of e.caps) if (c.disabled === canCapture) c.disabled = !canCapture;

      const mv = String(state.moves[side]);
      if (e.moves.textContent !== mv) e.moves.textContent = mv;
      const inc = `+${state.cumInc}s`;
      if (e.cum.textContent !== inc) e.cum.textContent = inc;
    }
    paintTime();

    // Primary button
    btn.primary.disabled = !!state.flagged;
    // The play/pause glyphs both live in the markup; .app.running picks one.
    const label = state.flagged ? 'Done' : state.running ? 'Pause' : state.started ? 'Resume' : 'Start';
    if (primaryLabel.textContent !== label) {
      primaryLabel.textContent = label;
      btn.primary.setAttribute('aria-label', label);
    }

    btn.undo.disabled = state.history.length === 0;
    btn.reset.disabled = !idle;
    btn.settings.disabled = !idle;

    app.classList.toggle('running', state.running);
    app.classList.toggle('game-over', !!state.flagged);

    for (const key of CAPTURES) {
      for (const node of $$(`[data-inc="${key}"]`)) {
        const v = String(settings[key]);
        if (node.textContent !== v) node.textContent = v;
      }
    }
    // Both players pay a queen bump in a queen trade, so the help text's
    // example is twice the ladder's top rung.
    const trade = String(settings.queen * 2);
    if (queenTrade.textContent !== trade) queenTrade.textContent = trade;
  }

  let bumpTimer: ReturnType<typeof setTimeout> | undefined;
  function bumpIncrement(): void {
    for (const side of SIDES) {
      const node = el[side].cum;
      node.classList.remove('bump');
      void node.offsetWidth;
      node.classList.add('bump');
    }
    btn.undo.classList.add('urgent');
    clearTimeout(bumpTimer);
    bumpTimer = setTimeout(() => btn.undo.classList.remove('urgent'), 5000);
  }

  // ── Clock loop ──────────────────────────────────────────────────

  function loop(): void {
    cancelAnimationFrame(state.raf);
    state.raf = requestAnimationFrame(tick);
  }

  function tick(now: number): void {
    if (!state.running) return;
    const side = state.active;
    if (!side) return;
    // Delta-based, so a backgrounded tab that stops firing frames still
    // charges the right amount of time the moment it comes back.
    const dt = now - state.lastTick;
    state.lastTick = now;
    const wasLow = isLow(side);
    state.ms[side] = Math.max(0, state.ms[side] - dt);

    if (state.ms[side] <= 0) return flag(side);

    if (isLow(side)) {
      if (!state.lowFired[side]) {
        state.lowFired[side] = true;
        SFX.low();
        buzz([30, 60, 30]);
      }
      if (!wasLow) render();
    }
    paintTime();
    state.raf = requestAnimationFrame(tick);
  }

  function flag(side: Side): void {
    state.ms[side] = 0;
    state.running = false;
    state.flagged = side;
    cancelAnimationFrame(state.raf);
    releaseWakeLock();
    SFX.flag();
    buzz([200, 100, 200, 100, 400]);
    render();
  }

  function pushHistory(): void {
    state.history.push(snapshot());
    if (state.history.length > HISTORY_MAX) state.history.shift();
  }

  // ── Actions ─────────────────────────────────────────────────────

  function start(): void {
    if (state.flagged) return;
    ensureAudio();
    if (!state.started) {
      state.started = true;
      state.active = 'bottom'; // bottom = "white", moves first
    }
    state.running = true;
    state.lastTick = performance.now();
    loop();
    void acquireWakeLock();
    render();
  }

  function pause(): void {
    if (!state.running) return;
    state.running = false;
    cancelAnimationFrame(state.raf);
    releaseWakeLock();
    render();
  }

  function reset(): void {
    state.running = false;
    cancelAnimationFrame(state.raf);
    releaseWakeLock();
    state.ms.top = state.ms.bottom = Math.round(settings.minutes * 60_000);
    state.active = null;
    state.started = false;
    state.cumInc = settings.base;
    state.moves.top = state.moves.bottom = 0;
    state.flagged = null;
    state.lowFired.top = state.lowFired.bottom = false;
    state.history.length = 0;
    classSig = { top: '', bottom: '' };
    painted.top = painted.bottom = '';
    render();
  }

  // Hit the clock. Mirrors the VBA: pay the cumulative increment to the side
  // that just moved, THEN (optionally) arm more increment, THEN flip.
  function hit(side: Side, capture: CaptureKind | null): void {
    if (state.flagged) return;
    const now = performance.now();
    if (now - lastHitAt < HIT_DEBOUNCE) return;
    ensureAudio();

    if (!state.started) {
      // First tap means "I've moved, your clock runs now". Unlike a plain
      // move it pays no increment and counts no move — a real clock does not
      // hand the starting player a free bump.
      if (capture) return;
      pushHistory();
      state.started = true;
      state.running = true;
      state.active = other(side);
      state.lastTick = now;
      lastHitAt = now;
      SFX.hit();
      buzz(12);
      loop();
      void acquireWakeLock();
      render();
      return;
    }

    if (!state.running) return; // paused → use Resume
    if (state.active !== side) return; // not your turn

    pushHistory();
    state.ms[side] += state.cumInc * 1000;
    state.moves[side] += 1;
    if (capture) {
      state.cumInc += settings[capture];
      SFX.capture();
      buzz(35);
    } else {
      SFX.hit();
      buzz(12);
    }
    // Gaining time can lift you back out of the danger zone; re-arm the
    // warning so it fires again on the way down.
    if (!isLow(side)) state.lowFired[side] = false;

    state.active = other(side);
    state.lastTick = now;
    lastHitAt = now;
    loop();
    render();
    if (capture) bumpIncrement();
  }

  // Undo restores the exact instant before the last hit and keeps ticking
  // for whoever was on move, so a mis-tapped capture costs a second, not a
  // game. This is the one thing lichess's clock has no need for.
  function undo(): void {
    const s = state.history.pop();
    if (!s) return;
    state.ms = { ...s.ms };
    state.active = s.active;
    state.started = s.started;
    state.cumInc = s.cumInc;
    state.moves = { ...s.moves };
    state.flagged = s.flagged;
    state.lowFired = { ...s.lowFired };
    state.running = s.running && !s.flagged;
    lastHitAt = -1e9;
    cancelAnimationFrame(state.raf);
    classSig = { top: '', bottom: '' };
    painted.top = painted.bottom = '';
    if (state.running) {
      state.lastTick = performance.now();
      loop();
      void acquireWakeLock();
    } else {
      releaseWakeLock();
    }
    SFX.undo();
    btn.undo.classList.remove('urgent');
    render();
  }

  // Swap the two halves. That is what "flip" means on a clock sitting
  // between two people: the phone stays put, the players change ends —
  // you set it up backwards, or you genuinely swapped seats. Rotating the
  // whole thing 180° would be a no-op in facing mode (the far half reads
  // upside-down either way), so the flip lives in the state, not in the
  // transform. Everything per-side travels, history included, or an undo
  // taken after a flip would restore the pre-flip arrangement. cumInc is
  // shared by both players and stays where it is.
  function swap<T>(o: Pair<T>): void {
    const t = o.top;
    o.top = o.bottom;
    o.bottom = t;
  }

  function swapSides(): void {
    swap(state.ms);
    swap(state.moves);
    swap(state.lowFired);
    if (state.active) state.active = other(state.active);
    if (state.flagged) state.flagged = other(state.flagged);
    for (const s of state.history) {
      swap(s.ms);
      swap(s.moves);
      swap(s.lowFired);
      if (s.active) s.active = other(s.active);
      if (s.flagged) s.flagged = other(s.flagged);
    }
    const who = el.top.who.textContent;
    el.top.who.textContent = el.bottom.who.textContent;
    el.bottom.who.textContent = who;
    // Force a full repaint: both caches are keyed by side, and the side
    // they describe just changed underneath them.
    classSig = { top: '', bottom: '' };
    painted.top = painted.bottom = '';
    SFX.swap();
    buzz(12);
    render();
  }

  // ── Events ──────────────────────────────────────────────────────

  for (const side of SIDES) {
    sideEls[side].addEventListener('pointerdown', (e) => {
      if ((e.target as Element).closest('.cap:not(:disabled)')) return;
      e.preventDefault();
      hit(side, null);
    }, { passive: false });

    for (const c of el[side].caps) {
      c.addEventListener('pointerdown', (e) => {
        e.preventDefault();
        e.stopPropagation();
        hit(side, asCapture(c.dataset.cap));
      }, { passive: false });
      c.addEventListener('click', (e) => e.preventDefault());
    }
  }

  btn.primary.addEventListener('click', () => (state.running ? pause() : start()));
  btn.undo.addEventListener('click', undo);
  btn.reset.addEventListener('click', reset);
  btn.flip.addEventListener('click', swapSides);

  if (document.documentElement.requestFullscreen) {
    btn.fullscreen.hidden = false;
    btn.fullscreen.addEventListener('click', () => {
      if (document.fullscreenElement) void document.exitFullscreen().catch(() => {});
      else void document.documentElement.requestFullscreen({ navigationUI: 'hide' }).catch(() => {});
    });
  }

  // ── Settings sheet ──────────────────────────────────────────────

  function openSettings(): void {
    pause();
    field('minutes').value = String(settings.minutes);
    field('base').value = String(settings.base);
    field('minor').value = String(settings.minor);
    field('rook').value = String(settings.rook);
    field('queen').value = String(settings.queen);
    field('sound').checked = !!settings.sound;
    field('facing').checked = !!settings.facing;
    sheet.hidden = false;
  }
  function closeSettings(): void { sheet.hidden = true; }

  btn.settings.addEventListener('click', openSettings);
  $('[data-action="settings-cancel"]').addEventListener('click', closeSettings);
  field('facing').addEventListener('change', () => {
    settings.facing = field('facing').checked;
    saveSettings(settings);
    layout();
  });
  sheet.addEventListener('click', (e) => { if (e.target === sheet) closeSettings(); });

  $$('[data-preset-min]').forEach((b) => b.addEventListener('click', () => {
    field('minutes').value = b.dataset.presetMin ?? String(DEFAULTS.minutes);
  }));
  $$('[data-preset-ladder]').forEach((b) => b.addEventListener('click', () => {
    const [minor, rook, queen] = (b.dataset.presetLadder ?? '').split(',');
    if (minor === undefined || rook === undefined || queen === undefined) return;
    field('minor').value = minor;
    field('rook').value = rook;
    field('queen').value = queen;
  }));

  const clampInt = (v: string, lo: number, hi: number, dflt: number): number => {
    const n = Number.parseInt(v, 10);
    return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : dflt;
  };

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    const mins = Number.parseFloat(field('minutes').value);
    settings = {
      minutes: Number.isFinite(mins) ? Math.min(180, Math.max(0.25, mins)) : DEFAULTS.minutes,
      base: clampInt(field('base').value, 0, 60, DEFAULTS.base),
      minor: clampInt(field('minor').value, 0, 60, DEFAULTS.minor),
      rook: clampInt(field('rook').value, 0, 60, DEFAULTS.rook),
      queen: clampInt(field('queen').value, 0, 60, DEFAULTS.queen),
      sound: field('sound').checked,
      facing: field('facing').checked,
    };
    saveSettings(settings);
    closeSettings();
    layout();
    reset();
  });

  // ── Keyboard (desktop testing) ──────────────────────────────────

  document.addEventListener('keydown', (e) => {
    if (!sheet.hidden) {
      if (e.key === 'Escape') closeSettings();
      return;
    }
    if (e.metaKey || e.ctrlKey || e.altKey) return;
    switch (e.code) {
      case 'Space': e.preventDefault(); if (state.running) pause(); else start(); break;
      case 'ArrowUp': e.preventDefault(); hit('top', null); break;
      case 'ArrowDown': e.preventDefault(); hit('bottom', null); break;
      case 'KeyU': e.preventDefault(); undo(); break;
      case 'KeyR': if (!btn.reset.disabled) { e.preventDefault(); reset(); } break;
      case 'KeyF': e.preventDefault(); btn.flip.click(); break;
    }
  });

  // Don't lose a live game to a stray back-swipe or pull-to-refresh.
  window.addEventListener('beforeunload', (e) => {
    if (!state.running) return;
    e.preventDefault();
    // Deprecated, and preventDefault() alone is enough on current Chrome —
    // but Safari and older Firefox still read returnValue, and this is a
    // live game. Keep it until they don't.
    (e as BeforeUnloadEvent & { returnValue: string }).returnValue = '';
  });
  document.addEventListener('contextmenu', (e) => {
    if ((e.target as Element).closest('.side')) e.preventDefault();
  });

  // ── Go ──────────────────────────────────────────────────────────

  reset();
  layout();
}
