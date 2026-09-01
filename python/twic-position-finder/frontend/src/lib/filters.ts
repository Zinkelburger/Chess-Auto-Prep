/**
 * The "Filters" block of an alert form: a list of typed rows (FEN, player,
 * ECO, Elo bounds, event) the user adds from a menu, plus the values they
 * hold. FEN is repeatable; everything else appears at most once.
 */
import type { Subscription } from './api';
import { setupAutocomplete } from './autocomplete';
import { bindFenPreview } from './board-preview';
import { loadEcoData, openEcoModal } from './eco-picker';

export type FilterKey = 'fen' | 'player' | 'eco' | 'min_elo' | 'max_elo' | 'event';

export interface FilterDef {
  key: FilterKey;
  label: string;
  inputMode?: 'numeric' | 'text';
  pattern?: string;
  mono?: boolean;
  repeatable?: boolean;
  autocomplete?: 'player' | 'event';
  hasBoardPreview?: boolean;
  hasEcoPicker?: boolean;
  tooltip?: string;
}

export const FILTER_DEFS: FilterDef[] = [
  {
    key: 'fen',
    label: 'Position (FEN)',
    mono: true,
    hasBoardPreview: true,
    repeatable: true,
    tooltip: 'Alert when a game reaches exactly this position. Paste a FEN from Lichess or Chess Auto Prep.',
  },
  { key: 'player', label: 'Player', autocomplete: 'player' },
  { key: 'eco', label: 'Opening (ECO)', hasEcoPicker: true },
  {
    key: 'min_elo',
    label: 'Minimum Elo',
    inputMode: 'numeric',
    pattern: '[0-9]*',
    tooltip: 'At least one player must be rated at or above this.',
  },
  {
    key: 'max_elo',
    label: 'Maximum Elo',
    inputMode: 'numeric',
    pattern: '[0-9]*',
    tooltip: 'Both players must be rated at or below this.',
  },
  { key: 'event', label: 'Event', autocomplete: 'event' },
];

const AUTOCOMPLETE: Record<'player' | 'event', { url: string; label: string }> = {
  player: { url: '/players.json', label: 'player' },
  event: { url: '/events.json', label: 'event' },
};

export interface FilterValues {
  fens: string[];
  player?: string;
  eco?: string;
  min_elo?: number;
  max_elo?: number;
  event?: string;
}

/** True when at least one filter that the server accepts as a match key is set. */
export function hasMatchKey(v: FilterValues): boolean {
  return v.fens.length > 0 || Boolean(v.player) || Boolean(v.eco);
}

export interface FilterBuilderOptions {
  container: HTMLElement;
  addBtn: HTMLButtonElement;
  menu: HTMLElement;
  idPrefix: string;
}

export class FilterBuilder {
  private readonly container: HTMLElement;
  private readonly addBtn: HTMLButtonElement;
  private readonly menu: HTMLElement;
  private readonly idPrefix: string;
  private readonly rows = new Map<string, HTMLElement>();
  private fenCounter = 0;

  constructor(opts: FilterBuilderOptions) {
    this.container = opts.container;
    this.addBtn = opts.addBtn;
    this.menu = opts.menu;
    this.idPrefix = opts.idPrefix;

    this.addBtn.setAttribute('aria-haspopup', 'menu');
    this.addBtn.setAttribute('aria-expanded', 'false');
    this.menu.setAttribute('role', 'menu');

    this.addBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      this.toggleMenu(this.menu.hidden);
    });
    document.addEventListener('click', (e) => {
      if (!(e.target as Element).closest('.add-filter-wrap')) this.toggleMenu(false);
    });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && !this.menu.hidden) {
        this.toggleMenu(false);
        this.addBtn.focus();
      }
    });

    void loadEcoData();
  }

  /** Add a row for [key]; returns its input, or null if the key is already present. */
  add(key: FilterKey, prefill?: string): HTMLInputElement | null {
    const def = FILTER_DEFS.find((d) => d.key === key);
    if (!def) return null;

    let rowKey: string = key;
    if (def.repeatable) rowKey = `${key}-${this.fenCounter++}`;
    else if (this.rows.has(key)) return null;

    const { row, input } = this.buildRow(def, rowKey);
    this.rows.set(rowKey, row);
    this.container.appendChild(row);
    if (prefill) {
      input.value = prefill;
      input.dispatchEvent(new Event('input'));
    }
    this.updateMenu();
    return input;
  }

  clear(): void {
    this.rows.clear();
    this.fenCounter = 0;
    this.container.replaceChildren();
    this.updateMenu();
  }

  /** The empty-form default: one FEN row. */
  resetDefault(): void {
    this.clear();
    this.add('fen');
  }

  setFromSubscription(sub: Subscription): void {
    this.clear();
    const fens = sub.fens ?? (sub.fen ? [sub.fen] : []);
    for (const fen of fens) this.add('fen', fen);
    for (const key of ['player', 'eco', 'min_elo', 'max_elo', 'event'] as const) {
      const value = sub[key];
      if (value) this.add(key, String(value));
    }
  }

  values(): FilterValues {
    const fens: string[] = [];
    this.container.querySelectorAll<HTMLInputElement>('input[data-filter-type="fen"]').forEach((el) => {
      const v = el.value.trim();
      if (v) fens.push(v);
    });
    const text = (key: FilterKey) => this.inputFor(key)?.value.trim() || undefined;
    const num = (key: FilterKey) => {
      const v = text(key);
      if (!v) return undefined;
      const n = Number.parseInt(v, 10);
      return Number.isFinite(n) ? n : undefined;
    };
    return {
      fens,
      player: text('player'),
      eco: text('eco'),
      min_elo: num('min_elo'),
      max_elo: num('max_elo'),
      event: text('event'),
    };
  }

  private inputFor(rowKey: string): HTMLInputElement | null {
    return this.rows.get(rowKey)?.querySelector<HTMLInputElement>('input') ?? null;
  }

  private toggleMenu(open: boolean): void {
    if (open) this.updateMenu();
    this.menu.hidden = !open;
    this.addBtn.setAttribute('aria-expanded', String(open));
    if (open) this.menu.querySelector<HTMLButtonElement>('button:not(:disabled)')?.focus();
  }

  private buildRow(def: FilterDef, rowKey: string): { row: HTMLElement; input: HTMLInputElement } {
    const row = document.createElement('div');
    row.className = 'filter-row';
    row.dataset.filterKey = rowKey;

    const body = document.createElement('div');
    body.className = 'filter-body';

    const inputId = `${this.idPrefix}-${rowKey.replaceAll('_', '-')}`;
    const lbl = document.createElement('label');
    lbl.htmlFor = inputId;
    lbl.textContent = def.label;
    if (def.tooltip) {
      const tip = document.createElement('span');
      tip.className = 'tooltip-trigger';
      tip.title = def.tooltip;
      tip.textContent = '?';
      tip.setAttribute('aria-label', def.tooltip);
      lbl.append(' ', tip);
    }
    body.appendChild(lbl);

    const inputWrap = document.createElement('div');
    inputWrap.className = 'filter-input-wrap';

    const input = document.createElement('input');
    input.type = 'text';
    input.id = inputId;
    if (def.mono) input.className = 'mono';
    if (def.inputMode) input.inputMode = def.inputMode;
    if (def.pattern) input.pattern = def.pattern;
    input.autocomplete = 'off';
    input.spellcheck = false;
    input.dataset.filterType = def.key;
    inputWrap.appendChild(input);
    body.appendChild(inputWrap);

    if (def.autocomplete) {
      const status = document.createElement('span');
      status.className = 'ac-status';
      status.hidden = true;
      inputWrap.appendChild(status);
      const matches = document.createElement('div');
      matches.className = 'ac-matches scroll-thin';
      matches.hidden = true;
      body.appendChild(matches);
      const spec = AUTOCOMPLETE[def.autocomplete];
      setupAutocomplete(spec.url, input, status, matches, spec.label);
    }

    if (def.hasBoardPreview) {
      const board = document.createElement('div');
      board.className = 'board-preview';
      board.hidden = true;
      const err = document.createElement('div');
      err.className = 'board-invalid';
      err.hidden = true;
      body.append(board, err);
      bindFenPreview(input, board, err);
    }

    if (def.hasEcoPicker) {
      const browseBtn = document.createElement('button');
      browseBtn.type = 'button';
      browseBtn.className = 'btn btn-text eco-trigger-btn';
      browseBtn.textContent = 'Browse openings…';
      browseBtn.addEventListener('click', () => openEcoModal(input));
      body.appendChild(browseBtn);
    }

    const removeBtn = document.createElement('button');
    removeBtn.type = 'button';
    removeBtn.className = 'filter-remove';
    removeBtn.innerHTML = '&times;';
    removeBtn.title = 'Remove filter';
    removeBtn.setAttribute('aria-label', `Remove ${def.label} filter`);
    removeBtn.addEventListener('click', () => this.remove(rowKey));

    row.append(body, removeBtn);
    return { row, input };
  }

  private remove(rowKey: string): void {
    this.rows.get(rowKey)?.remove();
    this.rows.delete(rowKey);
    this.updateMenu();
    this.addBtn.focus();
  }

  private updateMenu(): void {
    this.menu.replaceChildren();
    let anyAvailable = false;
    for (const def of FILTER_DEFS) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'filter-menu-item';
      btn.setAttribute('role', 'menuitem');
      btn.textContent = def.label;
      if (!def.repeatable && this.rows.has(def.key)) {
        btn.disabled = true;
      } else {
        anyAvailable = true;
        btn.addEventListener('click', () => {
          const input = this.add(def.key);
          this.toggleMenu(false);
          input?.focus();
        });
      }
      this.menu.appendChild(btn);
    }
    this.addBtn.hidden = !anyAvailable;
  }
}
