/**
 * The engine gear, as lila's (ui/lib/src/ceval/view/settings.ts): a panel
 * dropped over the engine lines with one slider per setting. Search time
 * runs from 2 s to ∞ (infinite analysis), lines from 1 to 5, threads from 1
 * to this computer's thread count with a tick on the recommended count (see
 * recommendedThreads), and the time to measure piece values. The bughouse
 * board's search time stops at 5 minutes: HypeBeast decides within a time.
 * The hash follows the device's memory, so lila's Memory slider is left out.
 *
 * The PGN page's Stockfish runs on one thread, so its gear is the first two
 * sliders alone (`SearchGear`).
 */
import { BUGHOUSE_SEARCH_TICKS, SEARCH_TICKS, VALUES_TICKS, type Settings } from './settings';
import { el } from './moves';

export interface GearState {
  settings: Settings;
  /** Seconds to measure piece values now: the setting or the default. */
  valuesSeconds: number;
  /** Threads the engine can use here (1 when the page is not cross-origin isolated). */
  maxThreads: number;
  recommendedThreads: number;
  threads: number;
}

export interface SearchHooks {
  searchSeconds(seconds: number): void;
  lines(n: number): void;
}

export interface GearHooks extends SearchHooks {
  threads(n: number): void;
  valuesSeconds(n: number): void;
}

const seconds = (s: number) => (s === 0 ? '∞' : `${s}s`);

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

/** Search time and Multiple lines: the whole gear for the PGN page, the start of the bughouse board's. */
export class SearchGear {
  private readonly search: HTMLInputElement;
  private readonly searchValue: HTMLElement;
  private readonly lines: HTMLInputElement;
  private readonly linesValue: HTMLElement;

  constructor(protected readonly box: HTMLElement, hooks: SearchHooks, engine = 'the engine', private readonly ticks = SEARCH_TICKS) {
    this.search = range('ch-set-search', ticks.length - 1);
    this.searchValue = el('span', 'ch-setting-value');
    // Lines and search time change at once, as on lila; they only restart the search.
    this.search.oninput = () => hooks.searchSeconds(ticks[Number(this.search.value)]);

    this.lines = range('ch-set-lines', 5, 1);
    this.linesValue = el('span', 'ch-setting-value');
    this.lines.oninput = () => hooks.lines(Number(this.lines.value));
    box.replaceChildren(
      row('ch-set-search', 'Search time', `How long ${engine} searches each new position.${ticks.includes(0) ? ' ∞ searches until you move on.' : ''}`, this.search, this.searchValue),
      row('ch-set-lines', 'Multiple lines', 'Engine lines shown, and their arrows on the board.', this.lines, this.linesValue),
    );
  }

  renderSearch(settings: Settings) {
    const { ticks } = this;
    const search = Math.max(0, ticks.indexOf(settings.searchSeconds));
    this.search.value = String(search);
    this.searchValue.textContent = seconds(ticks[search]);
    this.search.setAttribute('aria-valuetext', ticks[search] === 0 ? 'Infinite' : `${ticks[search]} seconds`);

    this.lines.value = String(settings.multiPv);
    this.linesValue.textContent = `${settings.multiPv} / 5`;
  }

  get open(): boolean { return !this.box.hidden; }
}

/** The bughouse board's gear: the search sliders, then Threads and Piece values. */
export class GearPanel extends SearchGear {
  private readonly threadsRow: HTMLElement;
  private readonly threads: HTMLInputElement;
  private readonly threadsValue: HTMLElement;
  private readonly tick: HTMLButtonElement;
  private readonly values: HTMLInputElement;
  private readonly valuesValue: HTMLElement;
  private state: GearState | null = null;

  constructor(box: HTMLElement, hooks: GearHooks) {
    super(box, hooks, 'HypeBeast', BUGHOUSE_SEARCH_TICKS);
    // Threads restart the search, so they apply when the slider is let go.
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

    this.values = range('ch-set-values', VALUES_TICKS.length - 1);
    this.valuesValue = el('span', 'ch-setting-value');
    this.values.oninput = () => hooks.valuesSeconds(VALUES_TICKS[Number(this.values.value)]);

    this.threadsRow = row('ch-set-threads', 'Threads', 'CPU threads for the search. The tick marks all but one, which keeps the page responsive.', track, this.threadsValue);
    box.append(
      this.threadsRow,
      row('ch-set-values', 'Piece values', 'Time spent measuring what one more piece in hand is worth on the board shown, after its analysis. More is deeper.', this.values, this.valuesValue),
    );
  }

  render(state: GearState) {
    this.state = state;
    const { settings } = state;
    this.renderSearch(settings);

    // Threads need more than one to choose from.
    this.threadsRow.hidden = state.maxThreads < 2;
    this.threads.max = String(state.maxThreads);
    if (document.activeElement !== this.threads) {
      this.threads.value = String(state.threads);
      this.showThreads(state.threads);
    }
    this.tick.title = `Recommended: ${state.recommendedThreads}`;
    this.tick.setAttribute('aria-label', `Use the recommended ${state.recommendedThreads} threads`);

    const values = VALUES_TICKS.indexOf(state.valuesSeconds);
    this.values.value = String(values < 0 ? VALUES_TICKS.findIndex((n) => n >= state.valuesSeconds) : values);
    this.valuesValue.textContent = seconds(state.valuesSeconds);
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
}
