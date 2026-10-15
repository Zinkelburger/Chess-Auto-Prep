/**
 * The engine gear, as lila's (ui/lib/src/ceval/view/settings.ts): a panel
 * dropped over the engine lines with one slider per setting. Search time
 * runs from 2 s to ∞ (infinite analysis), lines from 1 to 5, threads from 1
 * to this computer's thread count with a tick on the recommended count (see
 * recommendedThreads), and
 * the sit panel's search per row. Hivemind has no hash table, so lila's
 * Memory slider has no counterpart; where lila picks an engine, this picks
 * where the network runs (GPU or CPU) when the browser has a GPU.
 */
import { SEARCH_TICKS, SIT_TICKS, type Settings } from './settings';
import { el } from './moves';

export interface GearState {
  settings: Settings;
  /** The sit panel's search per row now: the setting or the backend's default. */
  sitNodes: number;
  /** Whether this browser offers WebGPU; null until the engine has loaded. */
  gpuAvailable: boolean | null;
  /** The network runs on the GPU now. */
  onGpu: boolean;
  /** Threads the CPU path can use here (1 when the page is not cross-origin isolated). */
  maxThreads: number;
  recommendedThreads: number;
  threads: number;
}

export interface GearHooks {
  searchSeconds(seconds: number): void;
  lines(n: number): void;
  gpu(on: boolean): void;
  threads(n: number): void;
  sitNodes(n: number): void;
}

const seconds = (s: number) => (s === 0 ? '∞' : `${s}s`);

export class GearPanel {
  private readonly search: HTMLInputElement;
  private readonly searchValue: HTMLElement;
  private readonly lines: HTMLInputElement;
  private readonly linesValue: HTMLElement;
  private readonly hardwareRow: HTMLElement;
  private readonly hardware: HTMLButtonElement[];
  private readonly threadsRow: HTMLElement;
  private readonly threads: HTMLInputElement;
  private readonly threadsValue: HTMLElement;
  private readonly tick: HTMLButtonElement;
  private readonly sit: HTMLInputElement;
  private readonly sitValue: HTMLElement;
  private state: GearState | null = null;

  constructor(private readonly box: HTMLElement, hooks: GearHooks) {
    const row = (id: string, label: string, title: string, control: HTMLElement, value?: HTMLElement) => {
      const r = el('div', 'ch-setting');
      r.title = title;
      const l = el('label', '', label) as HTMLLabelElement;
      l.htmlFor = id;
      r.append(l, control);
      if (value) r.append(value);
      return r;
    };
    const range = (id: string, max: number, min = 0) => {
      const input = document.createElement('input');
      input.type = 'range';
      input.className = 'ch-range';
      input.id = id;
      input.min = String(min);
      input.max = String(max);
      input.step = '1';
      return input;
    };

    this.search = range('ch-set-search', SEARCH_TICKS.length - 1);
    this.searchValue = el('span', 'ch-setting-value');
    // Lines and search time change at once, as on lila; they only restart the search.
    this.search.oninput = () => hooks.searchSeconds(SEARCH_TICKS[Number(this.search.value)]);

    this.lines = range('ch-set-lines', 5, 1);
    this.linesValue = el('span', 'ch-setting-value');
    this.lines.oninput = () => hooks.lines(Number(this.lines.value));

    const choice = el('div', 'ch-choice ch-setting-choice');
    choice.setAttribute('role', 'radiogroup');
    choice.setAttribute('aria-label', 'Hardware');
    choice.id = 'ch-set-hardware';
    this.hardware = (['GPU', 'CPU'] as const).map((name) => {
      const b = el('button', '', name) as HTMLButtonElement;
      b.type = 'button';
      b.setAttribute('role', 'radio');
      b.dataset.hardware = name.toLowerCase();
      b.onclick = () => { if (b.getAttribute('aria-checked') !== 'true') hooks.gpu(name === 'GPU'); };
      return b;
    });
    choice.append(...this.hardware);

    // Threads start a new engine, so they apply when the slider is let go.
    this.threads = range('ch-set-threads', 1, 1);
    this.threadsValue = el('span', 'ch-setting-value');
    this.threads.oninput = () => this.showThreads(Number(this.threads.value));
    this.threads.onchange = () => hooks.threads(Number(this.threads.value));
    this.tick = el('button', 'ch-tick') as HTMLButtonElement;
    this.tick.type = 'button';
    this.tick.onclick = () => { if (this.state) hooks.threads(this.state.recommendedThreads); };
    const track = el('span', 'ch-range-track');
    track.append(this.threads, this.tick);
    new ResizeObserver(() => this.placeTick()).observe(track);

    this.sit = range('ch-set-sit', SIT_TICKS.length - 1);
    this.sitValue = el('span', 'ch-setting-value');
    this.sit.oninput = () => hooks.sitNodes(SIT_TICKS[Number(this.sit.value)]);

    this.hardwareRow = row('ch-set-hardware', 'Hardware', 'Where Hivemind’s network runs. A GPU is usually several times faster.', choice);
    this.threadsRow = row('ch-set-threads', 'Threads', 'CPU threads for the network. The tick marks the usual best: one evaluation at a time gains little from more.', track, this.threadsValue);
    box.replaceChildren(
      row('ch-set-search', 'Search time', 'How long the engine searches each new position. ∞ searches until you move on.', this.search, this.searchValue),
      row('ch-set-lines', 'Multiple lines', 'Engine lines shown, and their arrows on the board.', this.lines, this.linesValue),
      this.hardwareRow,
      this.threadsRow,
      row('ch-set-sit', 'Sit search', 'Positions searched for each row of the sit panel. More is steadier and slower.', this.sit, this.sitValue),
    );
  }

  render(state: GearState) {
    this.state = state;
    const { settings } = state;
    const search = Math.max(0, SEARCH_TICKS.indexOf(settings.searchSeconds));
    this.search.value = String(search);
    this.searchValue.textContent = seconds(SEARCH_TICKS[search]);
    this.search.setAttribute('aria-valuetext', SEARCH_TICKS[search] === 0 ? 'Infinite' : `${SEARCH_TICKS[search]} seconds`);

    this.lines.value = String(settings.multiPv);
    this.linesValue.textContent = `${settings.multiPv} / 5`;

    // Shown once the engine knows the browser has a GPU; without one there is nothing to choose.
    this.hardwareRow.hidden = state.gpuAvailable !== true;
    for (const b of this.hardware) b.setAttribute('aria-checked', String((b.dataset.hardware === 'gpu') === settings.gpu));

    // Threads apply to the CPU path only, and need more than one to choose from.
    this.threadsRow.hidden = state.onGpu || state.maxThreads < 2;
    this.threads.max = String(state.maxThreads);
    if (document.activeElement !== this.threads) {
      this.threads.value = String(state.threads);
      this.showThreads(state.threads);
    }
    this.tick.title = `Recommended: ${state.recommendedThreads}`;
    this.tick.setAttribute('aria-label', `Use the recommended ${state.recommendedThreads} threads`);

    const sit = SIT_TICKS.indexOf(state.sitNodes);
    this.sit.value = String(sit < 0 ? SIT_TICKS.findIndex((n) => n >= state.sitNodes) : sit);
    this.sitValue.textContent = state.sitNodes.toLocaleString();
    this.placeTick();
  }

  private showThreads(n: number) {
    if (!this.state) return;
    this.threadsValue.textContent = `${n} / ${this.state.maxThreads}`;
    this.tick.classList.toggle('recommended', n === this.state.recommendedThreads);
  }

  /** The tick sits under the thumb's centre at the recommended count (the thumb is 14 px, from analysis.css). */
  private placeTick() {
    const state = this.state;
    if (!state || this.threadsRow.hidden) return;
    const width = this.threads.offsetWidth;
    const ratio = (state.recommendedThreads - 1) / Math.max(1, state.maxThreads - 1);
    this.tick.style.left = `${Math.round(7 + (width - 14) * ratio)}px`;
  }

  get open(): boolean { return !this.box.hidden; }
}
