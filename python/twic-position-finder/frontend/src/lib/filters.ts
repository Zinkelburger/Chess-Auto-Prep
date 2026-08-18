import { previewBoard, type Subscription } from './api';
import { setupAutocomplete } from './autocomplete';
import { loadEcoData, openEcoModal } from './eco-picker';

export interface FilterDef {
  key: string;
  label: string;
  inputType: string;
  inputMode?: 'numeric' | 'text' | 'decimal' | 'tel' | 'search' | 'email' | 'url';
  pattern?: string;
  mono?: boolean;
  repeatable?: boolean;
  autocomplete?: 'player' | 'event';
  hasBoardPreview?: boolean;
  hasEcoPicker?: boolean;
  tooltip?: string;
}

export const FILTER_DEFS: FilterDef[] = [
  { key: 'fen', label: 'FEN', inputType: 'text', mono: true, hasBoardPreview: true, repeatable: true },
  { key: 'player', label: 'Player name', inputType: 'text', autocomplete: 'player' },
  { key: 'eco', label: 'ECO code', inputType: 'text', hasEcoPicker: true },
  {
    key: 'min_elo',
    label: 'Minimum Elo',
    inputType: 'text',
    inputMode: 'numeric',
    pattern: '[0-9]*',
    tooltip: 'At least one player must be at or above this rating',
  },
  {
    key: 'max_elo',
    label: 'Maximum Elo',
    inputType: 'text',
    inputMode: 'numeric',
    pattern: '[0-9]*',
    tooltip: 'Both players must be at or below this rating',
  },
  { key: 'event', label: 'Event name', inputType: 'text', autocomplete: 'event' },
];

const AUTOCOMPLETE: Record<string, { url: string; label: string }> = {
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

export interface FilterBuilderOptions {
  container: HTMLElement;
  addBtn: HTMLElement;
  menu: HTMLElement;
  idPrefix: string;
  enableAutocomplete?: boolean;
}

function slug(key: string): string {
  return key.replaceAll('_', '-');
}

export class FilterBuilder {
  private readonly container: HTMLElement;
  private readonly addBtn: HTMLElement;
  private readonly menu: HTMLElement;
  private readonly idPrefix: string;
  private readonly enableAutocomplete: boolean;
  private readonly active = new Set<string>();
  private fenCounter = 0;
  private readonly onDocClick: (e: MouseEvent) => void;

  constructor(opts: FilterBuilderOptions) {
    this.container = opts.container;
    this.addBtn = opts.addBtn;
    this.menu = opts.menu;
    this.idPrefix = opts.idPrefix;
    this.enableAutocomplete = Boolean(opts.enableAutocomplete);

    this.addBtn.addEventListener('click', (e) => {
      e.stopPropagation();
      if (this.menu.hidden) {
        this.updateMenu();
        this.menu.hidden = false;
      } else {
        this.menu.hidden = true;
      }
    });

    this.onDocClick = (e) => {
      if (!(e.target as Element).closest('.add-filter-wrap')) this.menu.hidden = true;
    };
    document.addEventListener('click', this.onDocClick);

    void loadEcoData();
  }

  add(key: string, prefill?: string): void {
    const def = FILTER_DEFS.find((d) => d.key === key);
    if (!def) return;

    let instanceId: string | undefined;
    if (def.repeatable) {
      instanceId = `${key}-${this.fenCounter++}`;
    } else if (this.active.has(key)) {
      return;
    }

    const rowKey = instanceId || key;
    this.active.add(rowKey);
    const row = this.buildRow(def, instanceId);
    this.container.appendChild(row);

    const input = this.inputFor(instanceId || key);
    if (prefill && input) input.value = prefill;

    if (def.hasBoardPreview && input) {
      const board = row.querySelector('.board-preview') as HTMLElement;
      const error = row.querySelector('.board-invalid') as HTMLElement;
      input.addEventListener('input', () => previewBoard(input.value, board, error));
      if (prefill) previewBoard(prefill, board, error);
    }

    this.updateMenu();
    this.menu.hidden = true;
  }

  clear(): void {
    this.active.clear();
    this.fenCounter = 0;
    this.container.replaceChildren();
    this.updateMenu();
  }

  resetDefault(): void {
    this.clear();
    this.add('fen');
  }

  setFromSubscription(sub: Subscription): void {
    this.clear();
    const fens = sub.fens || (sub.fen ? [sub.fen] : []);
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

    const text = (key: string) => {
      const el = this.inputFor(key);
      const v = el?.value.trim();
      return v || undefined;
    };
    const num = (key: string) => {
      const v = text(key);
      if (!v) return undefined;
      const n = parseInt(v, 10);
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
    return document.getElementById(`${this.idPrefix}-${slug(rowKey)}`) as HTMLInputElement | null;
  }

  private buildRow(def: FilterDef, instanceId?: string): HTMLElement {
    const rowKey = instanceId || def.key;
    const row = document.createElement('div');
    row.className = 'filter-row';
    row.dataset.filterKey = rowKey;

    const body = document.createElement('div');
    body.className = 'filter-body';

    const inputId = `${this.idPrefix}-${slug(rowKey)}`;
    const lbl = document.createElement('label');
    lbl.htmlFor = inputId;
    lbl.textContent = def.label;
    if (def.tooltip) {
      const tip = document.createElement('span');
      tip.className = 'tooltip-trigger';
      tip.title = def.tooltip;
      tip.textContent = '?';
      lbl.append(' ', tip);
    }
    body.appendChild(lbl);

    const inputWrap = document.createElement('div');
    inputWrap.className = 'filter-input-wrap';

    const input = document.createElement('input');
    input.type = def.inputType;
    input.id = inputId;
    if (def.mono) input.className = 'mono';
    if (def.inputMode) input.inputMode = def.inputMode;
    if (def.pattern) input.pattern = def.pattern;
    input.autocomplete = 'off';
    if (def.repeatable) input.dataset.filterType = def.key;
    inputWrap.appendChild(input);

    if (this.enableAutocomplete && def.autocomplete) {
      const status = document.createElement('span');
      status.className = 'ac-status';
      status.hidden = true;
      inputWrap.appendChild(status);

      const matches = document.createElement('div');
      matches.className = 'ac-matches';
      matches.hidden = true;

      body.append(inputWrap, matches);
      const spec = AUTOCOMPLETE[def.autocomplete];
      setupAutocomplete(spec.url, input, status, matches, spec.label);
    } else {
      body.appendChild(inputWrap);
    }

    if (def.hasBoardPreview) {
      const board = document.createElement('div');
      board.className = 'board-preview';
      const err = document.createElement('div');
      err.className = 'board-invalid';
      body.append(board, err);
    }

    if (def.hasEcoPicker) {
      const browseBtn = document.createElement('button');
      browseBtn.type = 'button';
      browseBtn.className = 'eco-trigger-btn';
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
    return row;
  }

  private remove(rowKey: string): void {
    this.active.delete(rowKey);
    this.container.querySelector(`[data-filter-key="${CSS.escape(rowKey)}"]`)?.remove();
    this.updateMenu();
  }

  private updateMenu(): void {
    this.menu.replaceChildren();
    let anyAvailable = false;
    for (const def of FILTER_DEFS) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'filter-menu-item';
      btn.textContent = def.label;
      if (!def.repeatable && this.active.has(def.key)) {
        btn.disabled = true;
      } else {
        anyAvailable = true;
        btn.addEventListener('click', () => this.add(def.key));
      }
      this.menu.appendChild(btn);
    }
    this.addBtn.hidden = !anyAvailable;
  }
}
