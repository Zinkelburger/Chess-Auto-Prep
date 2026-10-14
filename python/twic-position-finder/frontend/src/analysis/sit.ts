/**
 * The sit panel: for the side to move, what the position is worth if it
 * moves now, and if it waits for one more pawn, knight, bishop, rook or queen
 * from its partner, with the best move once that piece arrives. Each row is
 * its own Fairy-Stockfish search of the same size, one after another on a
 * second single-threaded engine, so the rows compare like with like while the
 * main engine keeps the analysis going. A row that mates is marked.
 */
import type { Color, Role } from 'chessops/types';
import type { Extra, ExtraHost } from './app';
import { formatEval } from './ceval';
import { Engine, type EngineResult } from './engine';
import { el } from './moves';
import { adjustHand, outcomeOf, positionOf, sanLine } from './tree';

const ROLES: (Role | null)[] = [null, 'pawn', 'knight', 'bishop', 'rook', 'queen'];
const LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };
const ARTICLE: Record<Role, string> = { pawn: 'a pawn', knight: 'a knight', bishop: 'a bishop', rook: 'a rook', queen: 'a queen', king: 'a king' };
const SETTLE_MS = 250;
/** A row whose search never reports (it should within seconds) is given up on. */
const ROW_TIMEOUT_MS = 120_000;

interface Row {
  role: Role | null;
  /** The position with the piece added, or null when the hand has no room for it. */
  fen: string | null;
  result?: { cp?: number; mate?: number; move?: string; san?: string };
  failed?: string;
}

/** `nodes` is the search size of each row, in thousands of nodes (the setting). */
interface Ladder { fen: string; nodes: number; turn: Color; rows: Row[] }

const keyOf = (fen: string, nodes: number) => `${nodes} ${fen}`;

export class SitPanel implements Extra {
  private engine: Engine | null = null;
  /** The row search waiting for its final report. */
  private pending: { fen: string; resolve: (result: EngineResult | null) => void } | null = null;
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
    // The main engine starts first; this one loads its own copy once that has.
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
    this.engine?.stop();
    this.settle(null);
  }

  private settle(result: EngineResult | null) {
    const pending = this.pending;
    this.pending = null;
    pending?.resolve(result);
  }

  /** One row's search to its end; null when it was stopped. */
  private search(fen: string, nodes: number): Promise<EngineResult | null> {
    this.engine ??= new Engine(
      (status) => { if (status.kind === 'failed') this.settle(null); },
      (result) => { if (result.done && result.fen === this.pending?.fen) this.settle(result); },
    );
    const engine = this.engine;
    return new Promise((resolve) => {
      const timer = window.setTimeout(() => this.settle(null), ROW_TIMEOUT_MS);
      this.pending = { fen, resolve: (result) => { clearTimeout(timer); resolve(result); } };
      engine.load().then(
        () => engine.analyse(fen, { multiPv: 1, threads: 1, hashMb: 16, infinite: false, nodes }),
        () => this.settle(null),
      );
    });
  }

  private async run(ladder: Ladder, generation: number) {
    // One search at a time: let the stopped ladder finish first.
    await this.running.catch(() => undefined);
    if (generation !== this.generation) return;
    this.ladders.set(keyOf(ladder.fen, ladder.nodes), ladder);
    for (const row of ladder.rows.filter((r) => r.fen && !r.result)) {
      const found = await this.search(row.fen!, ladder.nodes * 1000);
      if (generation !== this.generation) return;
      const line = found?.lines[0];
      if (!line) row.failed = 'No search';
      else {
        row.result = line.mate !== undefined ? { mate: line.mate } : { cp: line.cp };
        if (line.pv[0]) row.result = { ...row.result, move: line.pv[0], san: sanLine(row.fen!, [line.pv[0]])[0] };
        delete row.failed;
      }
      if (this.shown === ladder) this.render(ladder);
    }
  }

  private render(ladder: Ladder | null) {
    this.shown = ladder;
    this.box.hidden = !ladder;
    if (!ladder) { this.box.replaceChildren(); return; }
    const table = el('table', 'bs-sit-table');
    table.title = `Each row is its own search of ${ladder.nodes.toLocaleString()} thousand positions`;
    const heading = el('tr', '');
    for (const label of ['Option', 'Eval', 'Best move']) {
      const th = el('th', '', label); th.setAttribute('scope', 'col'); heading.append(th);
    }
    const body = el('tbody', '');
    body.append(...ladder.rows.map((row) => this.row(ladder, row)));
    const thead = el('thead', '');
    thead.append(heading);
    table.append(thead, body);
    this.box.replaceChildren(table);
  }

  private row(ladder: Ladder, row: Row): HTMLElement {
    const color = ladder.turn;
    const mover = color === 'white' ? 1 : -1;
    const item = el('tr', row.role ? 'bs-sit-row' : 'bs-sit-row bs-sit-now');
    const option = el('td', 'bs-sit-option');
    // The whole row gives the piece; its button carries that for the keyboard.
    const giving = row.role !== null && row.fen !== null;
    const label = el(giving ? 'button' : 'span', 'bs-sit-label');
    if (giving) {
      item.dataset.role = row.role!;
      (label as HTMLButtonElement).type = 'button';
      label.title = `Give ${color} ${ARTICLE[row.role!]}`;
    }
    if (row.role) {
      const img = document.createElement('img');
      img.src = `/piece/${color === 'white' ? 'w' : 'b'}${LETTER[row.role]}.svg`;
      img.alt = '';
      label.append(el('span', 'bs-sit-plus', '+'), img, el('span', 'bs-sit-name', row.role[0].toUpperCase() + row.role.slice(1)));
    } else label.textContent = 'Move now';
    option.append(label);

    const score = el('td', 'bs-sit-eval');
    const move = el('td', 'bs-sit-move');
    if (!row.fen) { score.textContent = '—'; move.textContent = 'Hand is full'; }
    else if (row.failed) { score.textContent = '—'; move.textContent = row.failed; move.classList.add('bs-sit-failed'); }
    else if (!row.result) score.append(el('span', 'ch-spinner', ''));
    else {
      score.textContent = formatEval(row.result);
      move.textContent = row.result.san ?? '';
      if (row.result.move) item.dataset.move = row.result.move;
      if ((row.result.mate ?? 0) * mover > 0) item.classList.add('bs-sit-mates');
    }
    item.append(option, score, move);
    return item;
  }
}
