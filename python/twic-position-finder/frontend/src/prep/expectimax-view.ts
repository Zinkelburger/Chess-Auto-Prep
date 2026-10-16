/**
 * The Expectimax tab, as the desktop app's (DESIGN.md, "Tool panes"): one
 * bar with the Search / Stop button, Rating and Depth, and a gear for the
 * rest; one status line; and the table of the moves at the board's position:
 *
 *   Move · Played · White · Black · Engine
 *
 * Played is how often Maia expects the move at that rating. White is the
 * move's value when White is the prepared side (White plays its best, Black
 * replies the way players do); Black the same with the roles swapped; Engine
 * is Stockfish's. All read from White's side as engine scores, so a reply
 * whose White value sits far above the engine's is one players go wrong
 * after. The table shows only what a search stored; it never searches while
 * the player browses.
 */
import type { Color } from 'chessops/types';
import { formatEval } from '../analysis/ceval';
import { el } from '../analysis/moves';
import { DEFAULT_OPTIONS, valueText, type ExpectimaxOptions } from './expectimax';
import type { ExpectimaxRunner, FoundAt } from './expectimax-runner';
import { outcomeOf } from './tree';

export interface ExpectimaxHost {
  readonly fen: string;
  readonly orientation: Color;
  options: ExpectimaxOptions;
  optionsChanged(): void;
  /** A row is hovered (null when the pointer leaves): its move is drawn on the board. */
  hover(uci: string | null): void;
  play(uci: string): void;
}

interface Row {
  uci: string;
  san: string;
  share?: number;
  white?: number;
  black?: number;
  cp?: number;
}

/** The moves at a position from the two searches: the bottom side's first, in its order, then the other's. */
export function rows(found: FoundAt, bottom: Color): Row[] {
  const out = new Map<string, Row>();
  const policy = found.white?.node.policy ?? found.black?.node.policy;
  for (const side of [bottom, bottom === 'white' ? 'black' : 'white'] as const) {
    const node = found[side]?.node;
    if (!node?.children) continue;
    const ours = node.fen.split(' ')[1] === side[0];
    const kids = [...node.children].sort((a, b) => ours ? b.value - a.value : (b.share ?? 0) - (a.share ?? 0));
    for (const child of kids) {
      const row = out.get(child.uci) ?? { uci: child.uci, san: child.san };
      row[side] = side === 'white' ? child.value : 1 - child.value;
      row.cp ??= child.cp;
      out.set(child.uci, row);
    }
  }
  for (const row of out.values()) row.share = policy?.[row.uci];
  return [...out.values()];
}

const pct = (share: number) => share >= 0.995 ? '99%' : share < 0.01 ? '<1%' : `${Math.round(share * 100)}%`;
/** Stockfish's score with the value columns' two decimals, so the two read side by side. */
const engineText = (cp: number) => (Math.abs(cp) > 9000 ? formatEval({ mate: Math.sign(cp) * (10000 - Math.abs(cp)) }) : `${cp > 0 ? '+' : ''}${(cp / 100).toFixed(2)}`);

export class ExpectimaxView {
  private readonly button: HTMLButtonElement;
  private readonly gear: HTMLButtonElement;
  private readonly settings: HTMLElement;
  private readonly status: HTMLElement;
  private readonly table: HTMLElement;
  private readonly steppers: { input: HTMLInputElement; minus: HTMLButtonElement; plus: HTMLButtonElement; min: number; max: number; key: 'elo' | 'plies' }[];
  private readonly sliders: { key: keyof ExpectimaxOptions; input: HTMLInputElement; value: HTMLElement; ticks: number[]; text: (v: number) => string }[] = [];

  constructor(box: HTMLElement, private readonly runner: ExpectimaxRunner, private readonly host: ExpectimaxHost) {
    const bar = el('div', 'px-bar');
    this.button = el('button', 'btn btn-primary btn-sm px-run') as HTMLButtonElement;
    this.button.type = 'button';
    this.button.id = 'px-run';
    this.button.onclick = () => this.press();
    // Rating and Depth: a box to type in with − and + beside it, as the desktop's steppers.
    const stepper = (key: 'elo' | 'plies', label: string, id: string, min: number, max: number, step: number, title: string) => {
      const wrap = el('div', 'px-field');
      wrap.title = title;
      const name = el('label', '', label) as HTMLLabelElement;
      name.htmlFor = id;
      const input = document.createElement('input');
      input.type = 'text';
      input.id = id;
      input.inputMode = 'numeric';
      input.autocomplete = 'off';
      input.setAttribute('aria-valuemin', String(min));
      input.setAttribute('aria-valuemax', String(max));
      const set = (n: number) => {
        host.options[key] = Number.isFinite(n) ? Math.min(max, Math.max(min, Math.round(n / step) * step)) : DEFAULT_OPTIONS[key];
        host.optionsChanged();
        this.render();
      };
      input.onchange = () => set(Number(input.value));
      input.onkeydown = (e) => {
        if (e.key !== 'ArrowUp' && e.key !== 'ArrowDown') return;
        e.preventDefault();
        e.stopPropagation();
        set(host.options[key] + (e.key === 'ArrowUp' ? step : -step));
      };
      const button = (sign: 1 | -1) => {
        const b = el('button', 'px-step', sign > 0 ? '+' : '−') as HTMLButtonElement;
        b.type = 'button';
        b.setAttribute('aria-label', `${sign > 0 ? 'More' : 'Less'} ${label.toLowerCase()}`);
        b.onclick = () => set(host.options[key] + sign * step);
        return b;
      };
      const minus = button(-1), plus = button(1);
      wrap.append(name, minus, input, plus);
      return { wrap, input, minus, plus, min, max, key };
    };
    const elo = stepper('elo', 'Rating', 'px-elo', 600, 2600, 100, 'The rating Maia plays the replies at');
    const plies = stepper('plies', 'Depth', 'px-plies', 1, 8, 1, 'Half-moves the search looks ahead. Each one costs several times the last.');
    this.steppers = [elo, plies];
    this.gear = el('button', 'ch-icon') as HTMLButtonElement;
    this.gear.type = 'button';
    this.gear.id = 'px-gear';
    this.gear.title = 'Expectimax settings';
    this.gear.setAttribute('aria-label', 'Expectimax settings');
    this.gear.setAttribute('aria-expanded', 'false');
    this.gear.innerHTML = document.getElementById('ch-gear')!.innerHTML;
    this.gear.onclick = () => this.showSettings(this.settings.hidden);
    bar.append(this.button, elo.wrap, plies.wrap, el('span', 'ch-controls-gap'), this.gear);

    this.settings = el('div', 'ch-settings px-settings');
    this.settings.hidden = true;
    this.settings.setAttribute('role', 'group');
    this.settings.setAttribute('aria-label', 'Expectimax settings');
    this.slider('engineDepth', 'Engine depth', 'Stockfish’s depth for every position. Deeper is steadier and slower.', [8, 9, 10, 11, 12, 13, 14, 15, 16, 18, 20], (v) => String(v));
    this.slider('rootMoves', 'First moves', 'Your moves kept at the first move: Stockfish’s best few.', [1, 2, 3, 4, 5, 6, 8], (v) => String(v));
    this.slider('candidates', 'Later moves', 'Your moves kept at every later move.', [1, 2, 3, 4, 5, 6], (v) => String(v));
    this.slider('maxReplies', 'Replies', 'At most this many replies at each of their moves, the likeliest first.', [1, 2, 3, 4, 5, 6, 8, 10], (v) => String(v));
    this.slider('replyMass', 'Reply share', 'Replies are kept until they cover this share of Maia’s moves.', [0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1], (v) => `${Math.round(v * 100)}%`);
    this.slider('rareOnceIn', 'Rare lines', 'A line met less than once in this many games keeps its engine score and is not searched further.', [10, 20, 50, 100, 200, 500, 1000, 0], (v) => (v === 0 ? 'Off' : `1 in ${v}`));
    const reset = el('button', 'ch-link px-reset', 'Defaults') as HTMLButtonElement;
    reset.type = 'button';
    reset.onclick = () => {
      Object.assign(host.options, { ...DEFAULT_OPTIONS, elo: host.options.elo, plies: host.options.plies });
      host.optionsChanged();
      this.render();
    };
    this.settings.append(reset);
    document.addEventListener('pointerdown', (e) => {
      const target = e.target as Node;
      if (!this.settings.hidden && !this.settings.contains(target) && !this.gear.contains(target)) this.showSettings(false);
    });

    this.status = el('p', 'px-status');
    this.status.setAttribute('role', 'status');
    this.table = el('div', 'px-table');
    this.table.addEventListener('mouseover', (e) => host.hover((e.target as HTMLElement).closest<HTMLElement>('[data-uci]')?.dataset.uci ?? null));
    this.table.addEventListener('mouseleave', () => host.hover(null));
    this.table.addEventListener('click', (e) => {
      const uci = (e.target as HTMLElement).closest<HTMLElement>('[data-uci]')?.dataset.uci;
      if (uci) { host.hover(null); host.play(uci); }
    });
    // The gear's panel drops from under the bar, over the status and the table.
    const top = el('div', 'px-top');
    top.append(bar, this.settings);
    box.replaceChildren(top, this.status, this.table);
  }

  private slider(key: keyof ExpectimaxOptions, label: string, title: string, ticks: number[], text: (v: number) => string) {
    const row = el('div', 'ch-setting');
    row.title = title;
    const id = `px-set-${key}`;
    const l = el('label', '', label) as HTMLLabelElement;
    l.htmlFor = id;
    const input = document.createElement('input');
    input.type = 'range';
    input.className = 'ch-range';
    input.id = id;
    input.min = '0';
    input.max = String(ticks.length - 1);
    input.step = '1';
    const value = el('span', 'ch-setting-value');
    input.oninput = () => {
      this.host.options[key] = ticks[Number(input.value)];
      value.textContent = text(ticks[Number(input.value)]);
      this.host.optionsChanged();
    };
    row.append(l, input, value);
    this.settings.append(row);
    this.sliders.push({ key, input, value, ticks, text });
  }

  private showSettings(open: boolean) {
    this.settings.hidden = !open;
    this.gear.setAttribute('aria-expanded', String(open));
    if (open) this.render();
  }

  /** Esc closes the gear; true when it was open. */
  closeSettings(): boolean {
    if (this.settings.hidden) return false;
    this.showSettings(false);
    this.gear.focus();
    return true;
  }

  private press() {
    if (this.runner.running) { this.runner.stop(); return; }
    if (outcomeOf(this.host.fen)) return;
    this.showSettings(false);
    this.runner.start(this.host.fen, { ...this.host.options });
  }

  render() {
    const { options, fen } = this.host;
    const running = this.runner.running;
    this.button.textContent = running ? 'Stop' : 'Search';
    this.button.classList.toggle('btn-primary', !running);
    this.button.classList.toggle('btn-outline', !!running);
    const over = outcomeOf(fen);
    this.button.disabled = !running && !!over;
    for (const s of this.steppers) {
      const v = options[s.key];
      if (document.activeElement !== s.input) s.input.value = String(v);
      s.input.setAttribute('aria-valuenow', String(v));
      s.minus.disabled = v <= s.min;
      s.plus.disabled = v >= s.max;
    }
    for (const s of this.sliders) {
      const v = options[s.key];
      const i = Math.max(0, s.ticks.indexOf(v));
      s.input.value = String(i);
      s.value.textContent = s.text(s.ticks[i]);
    }
    const found = this.runner.at(fen);
    this.status.textContent = this.statusText(found, over);
    this.status.classList.toggle('px-status-error', !!(found.white?.search.error || found.black?.search.error || this.runner.saveError));
    this.renderTable(found);
  }

  private statusText(found: FoundAt, over: string | null): string {
    const running = this.runner.running;
    const any = found.white ?? found.black;
    const loading = running && this.runner.loading ? ` · ${this.runner.loading.text}` : '';
    const error = found.white?.search.error ?? found.black?.search.error ?? this.runner.saveError;
    if (over && !any) return over === 'Checkmate' ? 'Checkmate.' : `${over}: nothing to search.`;
    if (!any) {
      if (running) return `Searching from another position · ${running.white.positions + running.black.positions} positions${loading}`;
      return 'Not searched from here. Search looks for your most practical moves.';
    }
    const { search, node } = any;
    const left = search.options.plies - node.ply;
    const positions = (found.white?.search.positions ?? 0) + (found.black?.search.positions ?? 0);
    const rating = `Maia ${search.options.elo}`;
    if (search.state === 'running') {
      const reached = Math.min(found.white?.search.reached ?? 0, found.black?.search.reached ?? 0);
      return `Searching · depth ${reached + 1} of ${search.options.plies} · ${positions.toLocaleString()} positions${loading}`;
    }
    if (error) return error;
    const plies = (n: number) => `${n} ${n === 1 ? 'ply' : 'plies'}`;
    const depth = node.ply === 0 ? `${Math.min(search.reached, search.options.plies)} of ${plies(search.options.plies)}` : `${plies(left)} from here`;
    const stopped = search.state === 'stopped' ? 'Stopped · ' : '';
    return `${stopped}${rating} · ${depth} · ${positions.toLocaleString()} positions · ${(search.millis / 1000).toFixed(0)} s`;
  }

  private renderTable(found: FoundAt) {
    const list = rows(found, this.host.orientation);
    if (!list.length) { this.table.replaceChildren(); return; }
    const turn = this.host.fen.split(' ')[1] === 'w' ? 'white' : 'black';
    const best = (side: 'white' | 'black') => {
      if (side !== turn) return undefined;
      const values = list.map((r) => r[side]).filter((v): v is number => v !== undefined);
      if (!values.length) return undefined;
      return side === 'white' ? Math.max(...values) : Math.min(...values);
    };
    const bestWhite = best('white'), bestBlack = best('black');
    const head = el('div', 'px-row px-head');
    const cell = (cls: string, text: string, title?: string) => {
      const c = el('span', cls, text);
      if (title) c.title = title;
      return c;
    };
    const elo = (found.white ?? found.black)!.search.options.elo;
    head.append(
      cell('px-move', turn === this.host.orientation ? 'Your move' : 'Their reply'),
      cell('px-num', 'Played', `How often players rated ${elo} play the move, by Maia`),
      cell('px-num', 'White', `White plays its best moves; Black replies the way ${elo} players do. Read as an engine score from White’s side.`),
      cell('px-num', 'Black', `Black plays its best moves; White replies the way ${elo} players do. Read as an engine score from White’s side.`),
      cell('px-num', 'Engine', 'Stockfish’s score from White’s side'),
    );
    const body = list.map((r) => {
      const row = el('button', 'px-row') as HTMLButtonElement;
      row.type = 'button';
      row.dataset.uci = r.uci;
      row.title = `Play ${r.san}`;
      const value = (v: number | undefined, top: number | undefined) => {
        const c = cell('px-num', v === undefined ? '' : valueText(v), v === undefined ? undefined : `Expected score ${Math.round(100 * v)}% for White`);
        if (v !== undefined && top !== undefined && Math.abs(v - top) < 1e-9) c.classList.add('px-best');
        return c;
      };
      row.append(
        cell('px-move', r.san),
        cell('px-num px-share', r.share === undefined ? '' : pct(r.share)),
        value(r.white, bestWhite),
        value(r.black, bestBlack),
        cell('px-num px-engine', r.cp === undefined ? '' : engineText(r.cp)),
      );
      return row;
    });
    this.table.replaceChildren(head, ...body);
  }
}
