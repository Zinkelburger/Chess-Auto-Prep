/**
 * The sit panel: for the side to move, what the position is worth if it
 * moves now, and if it waits for one more pawn, knight, bishop, rook or queen
 * from its partner, with the best move once that piece arrives. Each row is
 * its own Hivemind search of the same size on spare workers, so the rows
 * compare like with like; the main engine keeps the analysis going meanwhile.
 * The cheapest piece that mates is called out: "Sit for a knight".
 */
import type { Color, Role } from 'chessops/types';
import { BrowserEngine } from '../bughouse/engine';
import type { FrozenSearch } from '../bughouse/types';
import type { Extra, ExtraHost } from '../crazyhouse/app';
import { formatEval } from '../crazyhouse/ceval';
import { winningChances } from '../crazyhouse/judge';
import { el } from '../crazyhouse/moves';
import { adjustHand, outcomeOf, positionOf, sanLine } from '../crazyhouse/tree';
import { centipawns, mateMoves } from './engine';

const ROLES: (Role | null)[] = [null, 'pawn', 'knight', 'bishop', 'rook', 'queen'];
const LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };
const ARTICLE: Record<Role, string> = { pawn: 'a pawn', knight: 'a knight', bishop: 'a bishop', rook: 'a rook', queen: 'a queen', king: 'a king' };
/** Spare workers hold their own copy of the network (about 150 MB each). */
export const MAX_SIT_WORKERS = 4;
const SETTLE_MS = 250;

interface Row {
  role: Role | null;
  /** The position with the piece added, or null when the hand has no room for it. */
  fen: string | null;
  result?: { cp?: number; mate?: number; move?: string; san?: string };
  failed?: string;
}

interface Ladder { fen: string; nodes: number; turn: Color; rows: Row[] }

const keyOf = (fen: string, nodes: number) => `${nodes} ${fen}`;

export class SitPanel implements Extra {
  private engines: BrowserEngine[] = [];
  private ladders = new Map<string, Ladder>();
  private shown: Ladder | null = null;
  private generation = 0;
  private running: Promise<void> = Promise.resolve();
  private timer = 0;

  constructor(private readonly host: ExtraHost, private readonly box: HTMLElement) {
    box.addEventListener('click', (e) => {
      const row = (e.target as HTMLElement).closest<HTMLElement>('[data-role]');
      if (row?.dataset.role) host.give(row.dataset.role as Role);
    });
    box.addEventListener('mouseover', (e) => {
      const row = (e.target as HTMLElement).closest<HTMLElement>('[data-move]');
      host.hover(row?.dataset.move ?? null);
    });
    box.addEventListener('mouseleave', () => host.hover(null));
  }

  update() {
    clearTimeout(this.timer);
    const { fen, settings } = this.host;
    if (!this.host.active || outcomeOf(fen) === 'Checkmate' || outcomeOf(fen) === 'Stalemate') {
      this.stop();
      this.render(null);
      return;
    }
    const key = keyOf(fen, settings.sitNodes);
    const known = this.ladders.get(key);
    if (known) { this.stop(); this.render(known); if (known.rows.some((r) => r.fen && !r.result && !r.failed)) this.schedule(known); return; }
    const turn = positionOf(fen).turn;
    const ladder: Ladder = {
      fen, nodes: settings.sitNodes, turn,
      rows: ROLES.map((role) => ({ role, fen: role ? adjustHand(fen, turn, role, 1) : fen })),
    };
    this.render(ladder);
    // Wait for the main engine to have the network in this browser's cache:
    // the spare workers then read it instead of downloading it again.
    if (!this.host.engineReady) return;
    this.schedule(ladder);
  }

  /** Searches the ladder once the board has stayed on it a moment (stepping through moves starts nothing). */
  private schedule(ladder: Ladder) {
    this.stop();
    const generation = this.generation;
    this.timer = window.setTimeout(() => { this.running = this.run(ladder, generation); }, SETTLE_MS);
  }

  private stop() {
    this.generation++;
    for (const engine of this.engines) engine.cancel();
  }

  private engine(i: number): BrowserEngine {
    while (this.engines.length <= i) this.engines.push(new BrowserEngine(() => {}));
    return this.engines[i];
  }

  private async run(ladder: Ladder, generation: number) {
    // A worker answers one search at a time: let the stopped ones finish first.
    await this.running.catch(() => undefined);
    if (generation !== this.generation) return;
    this.ladders.set(keyOf(ladder.fen, ladder.nodes), ladder);
    const queue = ladder.rows.filter((r) => r.fen && !r.result);
    const lanes = Math.max(1, Math.min(MAX_SIT_WORKERS, this.host.settings.threads, queue.length));
    const lane = async (i: number) => {
      for (let row = queue.shift(); row && generation === this.generation; row = queue.shift()) {
        try {
          const found = await this.engine(i).request<FrozenSearch>('frozen', {
            fen: row.fen, nodes: ladder.nodes, movetime_ms: 120_000, lines: 1, report_ms: 0,
          });
          if (generation !== this.generation) { queue.unshift(row); return; }
          const line = found.lines[0];
          const sign = ladder.turn === 'white' ? 1 : -1;
          const value = line?.mate ?? found.mate;
          row.result = value !== null && value !== undefined
            ? { mate: sign * mateMoves(value) }
            : { cp: sign * centipawns(line?.q ?? found.q) };
          if (line?.pv[0]) row.result = { ...row.result, move: line.pv[0], san: sanLine(row.fen!, [line.pv[0]])[0] };
          delete row.failed;
        } catch (error) {
          if (generation !== this.generation) { queue.unshift(row); return; }
          row.failed = error instanceof Error ? error.message : String(error);
        }
        if (this.shown === ladder) this.render(ladder);
      }
    };
    await Promise.all(Array.from({ length: lanes }, (_, i) => lane(i)));
  }

  private render(ladder: Ladder | null) {
    this.shown = ladder;
    this.box.hidden = !ladder;
    if (!ladder) { this.box.replaceChildren(); return; }
    const side = ladder.turn === 'white' ? 'White' : 'Black';
    const now = ladder.rows[0].result;
    const head = el('div', 'bs-sit-head');
    head.append(el('strong', '', `Sit or move · ${side} to play`));
    head.append(el('span', 'bs-sit-note', `${ladder.nodes.toLocaleString()} positions each`));
    const verdict = this.verdict(ladder);
    const rows = ladder.rows.map((row) => this.row(ladder, row, now));
    this.box.replaceChildren(head, ...(verdict ? [verdict] : []), ...rows);
  }

  /** The cheapest piece that mates, when moving now does not. */
  private verdict(ladder: Ladder): HTMLElement | null {
    const mover = ladder.turn === 'white' ? 1 : -1;
    const mates = (row: Row) => (row.result?.mate ?? 0) * mover > 0;
    if (mates(ladder.rows[0])) return null;
    const row = ladder.rows.slice(1).find(mates);
    if (!row?.role || !row.result?.san) return null;
    const box = el('p', 'bs-sit-verdict');
    const moves = Math.abs(row.result.mate!);
    box.append(el('strong', '', `Sit for ${ARTICLE[row.role]}`),
      document.createTextNode(moves === 1 ? ` · ${row.result.san}` : ` · mate in ${moves}, starting ${row.result.san}`));
    return box;
  }

  private row(ladder: Ladder, row: Row, now: Row['result']): HTMLElement {
    const color = ladder.turn;
    const item = row.role && row.fen ? el('button', 'bs-sit-row') as HTMLButtonElement : el('div', row.role ? 'bs-sit-row' : 'bs-sit-row bs-sit-now');
    if (item instanceof HTMLButtonElement) {
      item.type = 'button';
      item.dataset.role = row.role!;
      item.title = `Give ${color} ${ARTICLE[row.role!]}`;
    }
    const label = el('span', 'bs-sit-label');
    if (row.role) {
      const img = document.createElement('img');
      img.src = `/piece/${color === 'white' ? 'w' : 'b'}${LETTER[row.role]}.svg`;
      img.alt = '';
      label.append(document.createTextNode('+'), img, el('span', 'bs-sit-name', row.role));
    } else label.append(el('span', 'bs-sit-name', 'Move now'));
    item.append(label);

    const score = el('strong', 'bs-sit-eval');
    const gain = el('span', 'bs-sit-gain');
    const move = el('span', 'bs-sit-move');
    if (!row.fen) { score.textContent = '—'; move.textContent = 'Hand is full'; }
    else if (row.failed) { score.textContent = '—'; move.textContent = row.failed; move.classList.add('bs-sit-failed'); }
    else if (!row.result) { score.append(el('span', 'ch-spinner', '')); }
    else {
      score.textContent = formatEval(row.result);
      move.textContent = row.result.san ?? '';
      if (row.result.move) item.dataset.move = row.result.move;
      if (row.role && now) {
        const mover = color === 'white' ? 1 : -1;
        // Winning chances run from −1 to 1; a full bar is a swing of half that range.
        const delta = mover * (winningChances(row.result) - winningChances(now));
        const bar = el('span', 'bs-sit-bar');
        bar.style.transform = `scaleX(${Math.min(1, Math.max(0, delta)).toFixed(3)})`;
        gain.append(bar);
        gain.title = `${delta >= 0 ? '+' : '−'}${Math.abs(Math.round(50 * delta))}% winning chances`;
      }
      if ((row.result.mate ?? 0) * (color === 'white' ? 1 : -1) > 0) item.classList.add('bs-sit-mates');
    }
    item.append(score, gain, move);
    return item;
  }
}
