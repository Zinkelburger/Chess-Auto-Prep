/**
 * The engine gear for Stockfish, as lila's: a panel dropped over the engine
 * lines with a slider for the search time (2 s to ∞, infinite analysis) and
 * one for the lines shown. The browser build runs on one thread, so lila's
 * Threads and Memory sliders have nothing to set here.
 */
import { el } from '../analysis/moves';
import { SEARCH_TICKS, type Settings } from '../analysis/settings';

export interface GearHooks {
  searchSeconds(seconds: number): void;
  lines(n: number): void;
}

const seconds = (s: number) => (s === 0 ? '∞' : `${s}s`);

export class GearPanel {
  private readonly search: HTMLInputElement;
  private readonly searchValue: HTMLElement;
  private readonly lines: HTMLInputElement;
  private readonly linesValue: HTMLElement;

  constructor(box: HTMLElement, hooks: GearHooks) {
    const row = (id: string, label: string, title: string, control: HTMLElement, value: HTMLElement) => {
      const r = el('div', 'ch-setting');
      r.title = title;
      const l = el('label', '', label) as HTMLLabelElement;
      l.htmlFor = id;
      r.append(l, control, value);
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
    this.search.oninput = () => hooks.searchSeconds(SEARCH_TICKS[Number(this.search.value)]);
    this.lines = range('ch-set-lines', 5, 1);
    this.linesValue = el('span', 'ch-setting-value');
    this.lines.oninput = () => hooks.lines(Number(this.lines.value));
    box.replaceChildren(
      row('ch-set-search', 'Search time', 'How long Stockfish searches each new position. ∞ searches until you move on.', this.search, this.searchValue),
      row('ch-set-lines', 'Multiple lines', 'Engine lines shown, and their arrows on the board.', this.lines, this.linesValue),
    );
  }

  render(settings: Settings) {
    const search = Math.max(0, SEARCH_TICKS.indexOf(settings.searchSeconds));
    this.search.value = String(search);
    this.searchValue.textContent = seconds(SEARCH_TICKS[search]);
    this.search.setAttribute('aria-valuetext', SEARCH_TICKS[search] === 0 ? 'Infinite' : `${SEARCH_TICKS[search]} seconds`);
    this.lines.value = String(settings.multiPv);
    this.linesValue.textContent = `${settings.multiPv} / 5`;
  }
}
