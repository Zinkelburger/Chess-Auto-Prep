/**
 * Bughouse Games page controller. It reads the collection's index from
 * /bughouse-games/, lists the games, and opens one by the URL hash
 * (`#<id>`, `#<id>:<move index>`). A game shows both boards as partners sit
 * (board B turned the other way), the moves of both boards in the order they
 * were played, what is known of the current move (who, when, the engine's
 * score, a wait), and steps with the arrow keys. The annotator's notes,
 * lines and glyphs in the files are not shown. Every position comes from
 * the data (games.ts); where the reader is lives in view.ts, the words in
 * words.ts. HypeBeast analyses the board in
 * focus when switched on (engine.ts); a click on a move of its line shows the
 * line on that board until the reader moves on.
 */
import { playLine, positionOf } from '../analysis/tree';
import type { BoardName, Colour } from '../bughouse/types';
import { GameBoard, type SeatView } from './board';
import { GameEngine } from './engine';
import { GameStore, gameHash, isContractError, parseHash, type Game, type IndexEntry, type Move, type Seat } from './games';
import { START, analysisLink, clocksAt, end, evalOn, focusBoard, goTo, home, sameCursor, shown, step, turnOf, type Cursor } from './view';
import {
  boardTitle, entryResult, formatClock, formatEval, formatGameTime, gameResult, lengthLine, mateWords, moveName, moveNumber,
  playersLine, seatLabel, sideName, startWords, waitPhrase,
} from './words';

type State = 'loading' | 'ready' | 'error' | 'empty';
type View = 'list' | 'game';
const STORE_KEY = 'bughouse-games-v1';
const BOARDS: BoardName[] = ['A', 'B'];

function $<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing #${id}`);
  return el as T;
}

function el<K extends keyof HTMLElementTagNameMap>(tag: K, cls = '', text?: string): HTMLElementTagNameMap[K] {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function loadFlipped(): boolean {
  try { return (JSON.parse(localStorage.getItem(STORE_KEY) ?? 'null') as { flipped?: boolean } | null)?.flipped === true; } catch { return false; }
}

function problemCopy(e: unknown, what: string): string {
  if (isContractError(e)) return `${what} does not follow the games format.`;
  if (e instanceof Error && /^\d{3} /.test(e.message)) return `The server answered ${e.message.slice(0, 3)} for ${what.toLowerCase()}.`;
  return `${what} did not load. Check the connection.`;
}

export class BughouseGamesApp {
  private readonly store = new GameStore();
  private entries: IndexEntry[] = [];
  private entry: IndexEntry | null = null;
  private game: Game | null = null;
  private cursor: Cursor = START;
  private flipped = loadFlipped();
  private boards: Record<BoardName, GameBoard> | null = null;
  /** Counts up on every opened game, so a slow file cannot land on a later choice. */
  private generation = 0;
  private indexLoaded = false;
  private readonly engine = new GameEngine($<HTMLInputElement>('bg-engine-on'), {
    showLine: (board, fen, pv, upTo) => this.showEngineLine(board, fen, pv, upTo),
  });
  /** An engine line shown on one board, over the game, until the reader moves. */
  private preview: { board: BoardName; fen: string; last: string; text: string } | null = null;

  constructor() {
    this.bind();
    void this.start();
  }

  // ── Loading and routing ────────────────────────────────────────

  private async start() {
    this.setView('list');
    this.setState('loading');
    this.listMessage('Reading games…');
    try {
      const index = await this.store.loadIndex();
      this.entries = index.games;
      this.indexLoaded = true;
      $('bg-source').textContent = index.source;
      this.renderList();
    } catch (e) {
      console.error(e);
      this.setView('list');
      this.setState('error');
      this.listMessage(`Could not read the games. ${problemCopy(e, 'The list of games')}`, true);
      return;
    }
    this.route();
  }

  private route() {
    if (!this.indexLoaded) return;
    const link = parseHash(location.hash);
    if (!link) { this.showList(); return; }
    const entry = this.entries.find((e) => e.id === link.id);
    if (!entry) { this.showList(`No game “${link.id}” in the collection.`); return; }
    if (this.game && this.game.id === entry.id && this.entry === entry) {
      this.setView('game');
      if (link.move !== null) this.go(goTo(this.game, link.move));
      return;
    }
    this.openGame(entry, link.move);
  }

  private showList(message?: string) {
    this.generation += 1;
    this.preview = null;
    this.engine.hide();
    this.setView('list');
    document.title = 'Bughouse Games — Chess Auto Prep';
    this.renderList(message);
  }

  private openGame(entry: IndexEntry, move: number | null) {
    const generation = ++this.generation;
    this.entry = entry;
    this.game = null;
    this.setView('game');
    this.setState('loading');
    $('bg-title').textContent = entry.title;
    $('bg-meta').textContent = playersLine(entry.seats);
    $('bg-problem').hidden = true;
    $('bg-note').replaceChildren();
    $('bg-moves').replaceChildren();
    document.title = `${entry.title} — Bughouse Games — Chess Auto Prep`;
    this.store.get(entry).then((game) => {
      if (generation !== this.generation) return;
      this.game = game;
      this.setState('ready');
      if (!this.boards) {
        this.boards = {
          A: new GameBoard($('bg-cg-A'), { top: $('bg-seat-A-top'), bottom: $('bg-seat-A-bottom') }),
          B: new GameBoard($('bg-cg-B'), { top: $('bg-seat-B-top'), bottom: $('bg-seat-B-bottom') }),
        };
      }
      $('bg-meta').textContent = `${playersLine(game.seats, game.teams)}. ${gameResult(game)}`;
      this.renderMoves();
      this.cursor = START;
      this.go(move !== null ? goTo(game, move) : START, true);
    }, (e: unknown) => {
      if (generation !== this.generation) return;
      console.error(e);
      this.setState('error');
      $('bg-problem-text').textContent = `Could not read this game. ${problemCopy(e, 'The game file')}`;
      $('bg-problem').hidden = false;
    });
  }

  private bind() {
    $('bg-list-retry').onclick = () => void this.start();
    $('bg-game-retry').onclick = () => { if (this.entry) this.openGame(this.entry, parseHash(location.hash)?.move ?? null); };
    $('bg-back').addEventListener('click', (e) => {
      e.preventDefault();
      history.pushState(null, '', location.pathname + location.search);
      this.showList();
    });
    $('bg-first').onclick = () => this.nav(home());
    $('bg-prev').onclick = () => this.nav(this.game && step(this.game, this.cursor, -1));
    $('bg-next').onclick = () => this.nav(this.game && step(this.game, this.cursor, 1));
    $('bg-last').onclick = () => this.nav(this.game && end(this.game));
    $('bg-flip').onclick = () => this.flip();
    $('bg-var-back').onclick = () => this.back();
    $('bg-moves').addEventListener('click', (e) => {
      const row = (e.target as HTMLElement).closest<HTMLElement>('[data-i]');
      if (row && this.game) this.nav(goTo(this.game, Number(row.dataset.i)));
    });
    window.addEventListener('hashchange', () => this.route());
    window.addEventListener('popstate', () => this.route());
    document.addEventListener('keydown', (e) => {
      if (!this.game || $('bg').dataset.view !== 'game') return;
      // The engine switch keeps focus after a click; only Space is its key.
      if ((e.target as HTMLElement).matches('input:not([type="checkbox"]), select, textarea') || e.ctrlKey || e.metaKey || e.altKey) return;
      const key = e.key;
      let to: Cursor | null = null;
      if (key === 'ArrowLeft') to = step(this.game, this.cursor, -1);
      else if (key === 'ArrowRight') to = step(this.game, this.cursor, 1);
      else if (key === 'Home' || key === 'ArrowUp') to = home();
      else if (key === 'End' || key === 'ArrowDown') to = end(this.game);
      else if (key === 'Escape' && this.preview) { e.preventDefault(); this.back(); return; }
      else if (key === 'f' || key === 'F') { e.preventDefault(); this.flip(); return; }
      else if (key === 'l' || key === 'L') { e.preventDefault(); this.engine.setOn(!this.engine.enabled); return; }
      if (!to) return;
      e.preventDefault();
      this.nav(to);
    });
  }

  private setView(view: View) { $('bg').dataset.view = view; }
  private setState(state: State) { $('bg').dataset.state = state; }

  // ── The list ───────────────────────────────────────────────────

  private listMessage(text: string, retry = false) {
    const m = $('bg-list-message');
    m.textContent = text;
    m.hidden = !text;
    $('bg-list-retry').hidden = !retry;
  }

  private renderList(message?: string) {
    const list = $('bg-games');
    if (!this.entries.length) {
      this.setState('empty');
      list.replaceChildren();
      this.listMessage(message ?? 'No games yet.');
      return;
    }
    this.setState('ready');
    this.listMessage(message ?? '');
    list.replaceChildren(...this.entries.map((entry) => {
      const li = el('li', 'bg-game');
      const a = el('a', 'bg-game-link');
      a.href = gameHash(entry.id, -1);
      a.append(el('span', 'bg-game-title', entry.title));
      li.append(a);
      const facts = el('p', 'bg-game-facts');
      facts.append(el('span', '', playersLine(entry.seats)), el('span', '', entryResult(entry)), el('span', 'num', lengthLine(entry.moves)));
      li.append(facts);
      const sub = el('p', 'bg-game-event', [entry.event, entry.date].filter(Boolean).join(' · '));
      li.append(sub);
      return li;
    }));
  }

  // ── Moving through a game ──────────────────────────────────────

  private nav(to: Cursor | null) {
    if (to && this.game) this.go(to);
  }

  private go(to: Cursor, force = false) {
    const game = this.game!;
    const moved = !sameCursor(to, this.cursor);
    if (!moved && !force && !this.preview) return;
    this.preview = null;
    this.cursor = to;
    history.replaceState(null, '', gameHash(game.id, to.move));
    this.renderBoards();
    this.renderNote();
    this.renderActiveMove();
    this.renderControls();
  }

  /** "Back to the game": out of an engine line. */
  private back() {
    if (!this.preview) return;
    this.preview = null;
    this.renderBoards();
    this.renderControls();
  }

  /** Shows HypeBeast's line on `board` up to and including move `upTo`; the engine keeps searching the game's position. */
  private showEngineLine(board: BoardName, fen: string, pv: string[], upTo: number) {
    if (!this.game) return;
    const moves = playLine(fen, pv, upTo + 1);
    const at = moves.at(-1);
    if (!at) return;
    this.preview = { board, fen: at.fen, last: at.uci, text: `HypeBeast’s line on board ${board}: ${moves.map((m) => m.san).join(' ')}` };
    this.renderBoards();
    this.renderControls();
  }

  private flip() {
    this.flipped = !this.flipped;
    try { localStorage.setItem(STORE_KEY, JSON.stringify({ flipped: this.flipped })); } catch { /* not kept; fine */ }
    if (this.game) this.renderBoards();
    $('bg-flip').setAttribute('aria-pressed', String(this.flipped));
  }

  // ── Rendering a game ───────────────────────────────────────────

  private renderBoards() {
    const game = this.game!;
    const view = shown(game, this.cursor);
    const clocks = clocksAt(game, this.cursor);
    for (const b of BOARDS) {
      // Partners sit side by side: board A with White at the bottom, board B with Black.
      const bottom: Colour = (b === 'A') !== this.flipped ? 'white' : 'black';
      const seatView = (colour: Colour, fen: string): SeatView => {
        const seat = `${b}${colour}` as Seat;
        return { seat, name: game.seats[seat], clock: formatClock(clocks[seat]), toMove: turnOf(fen) === colour };
      };
      const p = this.preview?.board === b ? this.preview : null;
      const fen = p ? p.fen : view.fen[b];
      this.boards![b].render({
        fen, bottom, last: p ? p.last : view.last[b], check: p ? positionOf(p.fen).isCheck() : view.check[b],
        seats: { white: seatView('white', fen), black: seatView('black', fen) },
      });
      const score = evalOn(game, this.cursor, b);
      const evalEl = $(`bg-eval-${b}`);
      evalEl.textContent = score ? formatEval(score.eval, score.mate, true) : '';
      evalEl.title = score
        ? `${score.mate !== null ? mateWords(score.mate) : formatEval(score.eval, null)}: the engine’s own score after ${moveName(game.moves[score.move])}, from White’s side of board ${b}`
        : '';
      $(`bg-var-tag-${b}`).hidden = !p;
      document.querySelector<HTMLElement>(`.bg-board[data-board="${b}"]`)!.classList.toggle('in-variation', !!p);
    }
    $('bg-flip').setAttribute('aria-pressed', String(this.flipped));
    const focus = focusBoard(game, this.cursor);
    this.engine.show({ fens: view.fen, board: focus, orientation: (focus === 'A') !== this.flipped ? 'white' : 'black' });
  }

  private renderControls() {
    const game = this.game!;
    const c = this.cursor;
    $<HTMLButtonElement>('bg-first').disabled = c.move < 0;
    $<HTMLButtonElement>('bg-prev').disabled = c.move < 0;
    $<HTMLButtonElement>('bg-next').disabled = c.move >= game.moves.length - 1;
    $<HTMLButtonElement>('bg-last').disabled = c.move >= game.moves.length - 1;
    $('bg-var-bar').hidden = !this.preview;
    if (this.preview) $('bg-var-text').textContent = this.preview.text;
    const link = $<HTMLAnchorElement>('bg-analysis');
    link.href = analysisLink(game, c);
    link.textContent = `Analyse board ${focusBoard(game, c)} ↗`;
  }

  /** The move list: one row per move in the order played, board A's moves in the left lane and B's in the right. */
  private renderMoves() {
    const game = this.game!;
    const box = $('bg-moves');
    const rows: HTMLElement[] = [];
    const head = el('div', 'bg-moves-head');
    head.append(el('span', 'bg-moves-time', ''), el('span', '', boardTitle('A')), el('span', '', boardTitle('B')));
    rows.push(head);
    if (game.moves[0]?.book) rows.push(el('div', 'bg-moves-label', 'Starting moves, from a human game'));
    let bookEnded = !game.moves[0]?.book;
    for (const m of game.moves) {
      if (!bookEnded && !m.book) {
        bookEnded = true;
        rows.push(el('div', 'bg-moves-label', 'Engines’ own moves'));
      }
      rows.push(this.moveRow(m));
    }
    box.replaceChildren(...rows);
  }

  private moveRow(m: Move): HTMLElement {
    const row = el('button', `bg-mv bg-mv-${m.board}${m.book ? ' book' : ''}`);
    row.type = 'button';
    row.dataset.i = String(m.i);
    const white = m.seat.endsWith('white');
    row.append(el('span', 'bg-mv-time num', m.t !== null ? formatGameTime(m.t) : ''));
    const cell = el('span', 'bg-mv-cell');
    cell.append(el('span', 'bg-mv-num', moveNumber(m.num, white)), el('span', 'bg-mv-san', m.san));
    if (m.waited) cell.append(el('span', 'bg-mv-wait', `sat ${Math.round(m.waited.seconds * 10) / 10}s`));
    const empty = el('span', 'bg-mv-cell');
    if (m.board === 'A') row.append(cell, empty); else row.append(empty, cell);
    const label = [`Board ${m.board}`, `${sideName(white ? 'white' : 'black')}`, moveName(m), m.book ? 'starting move from a human game' : ''];
    row.setAttribute('aria-label', label.filter(Boolean).join(', '));
    return row;
  }

  private renderActiveMove() {
    const box = $('bg-moves');
    box.querySelector('.bg-mv.active')?.classList.remove('active');
    box.querySelector('[aria-current]')?.removeAttribute('aria-current');
    const row = box.querySelector<HTMLElement>(`.bg-mv[data-i="${this.cursor.move}"]`);
    if (!row) { if (this.cursor.move < 0) box.scrollTop = 0; return; }
    row.classList.add('active');
    row.setAttribute('aria-current', 'true');
    // Scroll the list itself, never the page: on a phone the list sits below the boards.
    const r = row.getBoundingClientRect();
    const b = box.getBoundingClientRect();
    const headH = box.querySelector<HTMLElement>('.bg-moves-head')?.offsetHeight ?? 0;
    if (r.top < b.top + headH) box.scrollTop += r.top - b.top - headH - r.height;
    else if (r.bottom > b.bottom) box.scrollTop += r.bottom - b.bottom + r.height;
  }

  /** The current move: who played it, when, the engine's score and any wait before it. */
  private renderNote() {
    const game = this.game!;
    const box = $('bg-note');
    const m = game.moves[this.cursor.move];
    const out: HTMLElement[] = [];
    if (!m) {
      const head = el('div', 'bg-note-head');
      head.append(el('b', 'bg-note-move', 'Start of the game'));
      out.push(head, el('p', 'bg-note-facts', [game.event, game.date].filter(Boolean).join(' · ')));
      const given = game.moves.filter((x) => x.book).length;
      if (given) out.push(el('p', 'bg-note-text', startWords(given)));
      box.replaceChildren(...out);
      box.scrollTop = 0;
      return;
    }
    const white = m.seat.endsWith('white');
    const head = el('div', 'bg-note-head');
    head.append(el('span', `bg-note-board bg-note-board-${m.board}`, m.board), el('b', 'bg-note-move', moveName(m)));
    out.push(head);

    const facts = [`${sideName(white ? 'white' : 'black')} on board ${m.board}`, game.seats[m.seat]];
    if (m.t !== null) facts.push(`at ${formatGameTime(m.t)}`);
    if (m.book) facts.push('from a human game, not an engine move');
    if (m.eval !== null || m.mate !== null) facts.push(m.mate !== null ? mateWords(m.mate) : `score ${formatEval(m.eval, null, true)}`);
    out.push(el('p', 'bg-note-facts', facts.join(' · ')));
    if (m.waited) out.push(el('p', 'bg-note-wait', `Before this move, ${seatLabel(m.seat)} ${waitPhrase(m.waited)}.`));
    if (m.i === game.moves.length - 1) out.push(el('p', 'bg-note-result', gameResult(game)));
    box.replaceChildren(...out);
    box.scrollTop = 0;
  }
}
