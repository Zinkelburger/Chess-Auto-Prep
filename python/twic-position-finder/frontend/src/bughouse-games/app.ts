/**
 * Bughouse Games page controller. It reads the collection's index from
 * /bughouse-games/, lists the games, and opens one by the URL hash
 * (`#<id>`, `#<id>:<move index>`). A game shows both boards as partners sit
 * (board B turned the other way), the moves of both boards in the order they
 * were played, the current move's note and lines, and steps with the arrow
 * keys. Every position comes from the data (games.ts); where the reader is
 * lives in view.ts, the words in words.ts.
 */
import type { BoardName, Colour } from '../bughouse/types';
import { GameBoard, type SeatView } from './board';
import { GameStore, gameHash, isContractError, parseHash, type Game, type IndexEntry, type Line, type Move, type Seat } from './games';
import {
  START, analysisLink, clocksAt, end, enterLine, evalOn, focusBoard, goTo, home, leaveLine, lineAt, noteStep, notedMoves,
  sameCursor, shown, step, turnOf, type Cursor,
} from './view';
import {
  assumePhrase, boardTitle, entryResult, formatClock, formatEval, formatGameTime, gameResult, kindTitle, lengthLine,
  lineContext, lineTokens, mateWords, moveName, moveNumber, playersLine, scoreWords, seatLabel, sideName, waitPhrase,
} from './words';

type State = 'loading' | 'ready' | 'error' | 'empty';
type View = 'list' | 'game';
const STORE_KEY = 'bughouse-games-v1';
const BOARDS: BoardName[] = ['A', 'B'];
const GLYPH_CLASS: Record<string, string> = { '!': 'good', '!!': 'brilliant', '!?': 'interesting', '?!': 'inaccuracy', '?': 'mistake', '??': 'blunder' };
const GLYPH_NAME: Record<string, string> = { '!': 'Good move', '!!': 'Brilliant move', '!?': 'Interesting move', '?!': 'Inaccuracy', '?': 'Mistake', '??': 'Blunder' };

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
    $('bg-prev-note').onclick = () => this.nav(this.game && noteStep(this.game, this.cursor, -1));
    $('bg-next-note').onclick = () => this.nav(this.game && noteStep(this.game, this.cursor, 1));
    $('bg-flip').onclick = () => this.flip();
    $('bg-var-back').onclick = () => this.nav(leaveLine(this.cursor));
    $('bg-moves').addEventListener('click', (e) => {
      const row = (e.target as HTMLElement).closest<HTMLElement>('[data-i]');
      if (row && this.game) this.nav(goTo(this.game, Number(row.dataset.i)));
    });
    $('bg-note').addEventListener('click', (e) => {
      const token = (e.target as HTMLElement).closest<HTMLElement>('[data-line]');
      if (token && this.game) this.nav(enterLine(this.game, this.cursor, Number(token.dataset.line), Number(token.dataset.ply)));
    });
    window.addEventListener('hashchange', () => this.route());
    window.addEventListener('popstate', () => this.route());
    document.addEventListener('keydown', (e) => {
      if (!this.game || $('bg').dataset.view !== 'game') return;
      if ((e.target as HTMLElement).matches('input, select, textarea') || e.ctrlKey || e.metaKey || e.altKey) return;
      const key = e.key;
      let to: Cursor | null = null;
      if (key === 'ArrowLeft') to = step(this.game, this.cursor, -1);
      else if (key === 'ArrowRight') to = step(this.game, this.cursor, 1);
      else if (key === 'Home' || key === 'ArrowUp') to = home();
      else if (key === 'End' || key === 'ArrowDown') to = end(this.game);
      else if (key === 'n' || key === 'N') to = noteStep(this.game, this.cursor, e.shiftKey ? -1 : 1) ?? this.cursor;
      else if (key === 'p' || key === 'P') to = noteStep(this.game, this.cursor, -1) ?? this.cursor;
      else if (key === 'Escape' && this.cursor.line) to = leaveLine(this.cursor);
      else if (key === 'f' || key === 'F') { e.preventDefault(); this.flip(); return; }
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
      li.append(el('p', 'bg-game-summary', entry.summary));
      const facts = el('p', 'bg-game-facts');
      facts.append(el('span', '', playersLine(entry.seats)), el('span', '', entryResult(entry)), el('span', 'num', lengthLine(entry.moves, entry.notes)));
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
    if (!moved && !force) return;
    const sameMove = to.move === this.cursor.move;
    this.cursor = to;
    history.replaceState(null, '', gameHash(game.id, to.move));
    this.renderBoards();
    if (!sameMove || force) this.renderNote();
    else this.markLineToken();
    this.renderActiveMove();
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
      const turn = turnOf(view.fen[b]);
      const seatView = (colour: Colour): SeatView => {
        const seat = `${b}${colour}` as Seat;
        return { seat, name: game.seats[seat], clock: formatClock(clocks[seat]), toMove: turn === colour };
      };
      this.boards![b].render({ fen: view.fen[b], bottom, last: view.last[b], check: view.check[b], seats: { white: seatView('white'), black: seatView('black') } });
      const score = evalOn(game, this.cursor, b);
      const evalEl = $(`bg-eval-${b}`);
      evalEl.textContent = score ? formatEval(score.eval, score.mate, true) : '';
      evalEl.title = score
        ? `${score.mate !== null ? mateWords(score.mate) : formatEval(score.eval, null)}: the engine’s own score after ${moveName(game.moves[score.move])}, from White’s side of board ${b}`
        : '';
      $(`bg-var-tag-${b}`).hidden = view.variation !== b;
      document.querySelector<HTMLElement>(`.bg-board[data-board="${b}"]`)!.classList.toggle('in-variation', view.variation === b);
    }
    $('bg-flip').setAttribute('aria-pressed', String(this.flipped));
  }

  private renderControls() {
    const game = this.game!;
    const c = this.cursor;
    const inLine = !!c.line;
    const line = lineAt(game, c);
    $<HTMLButtonElement>('bg-first').disabled = c.move < 0 && !inLine;
    $<HTMLButtonElement>('bg-prev').disabled = c.move < 0 && !inLine;
    $<HTMLButtonElement>('bg-next').disabled = inLine ? c.line!.ply >= line!.moves.length - 1 : c.move >= game.moves.length - 1;
    $<HTMLButtonElement>('bg-last').disabled = c.move >= game.moves.length - 1 && !inLine;
    $<HTMLButtonElement>('bg-prev-note').disabled = !noteStep(game, c, -1);
    $<HTMLButtonElement>('bg-next-note').disabled = !noteStep(game, c, 1);
    const bar = $('bg-var-bar');
    bar.hidden = !line;
    if (line) {
      const title = kindTitle(line, game.moves[c.move]);
      $('bg-var-text').textContent = `Variation on board ${line.board}: ${title.charAt(0).toLowerCase()}${title.slice(1)}`;
    }
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
    if (game.moves[0]?.book) rows.push(el('div', 'bg-moves-label', 'Opening book'));
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
    const row = el('button', `bg-mv bg-mv-${m.board}${m.book ? ' book' : ''}${m.note ? ' noted' : ''}`);
    row.type = 'button';
    row.dataset.i = String(m.i);
    const white = m.seat.endsWith('white');
    row.append(el('span', 'bg-mv-time num', m.t !== null ? formatGameTime(m.t) : ''));
    const cell = el('span', 'bg-mv-cell');
    cell.append(el('span', 'bg-mv-num', moveNumber(m.num, white)), el('span', 'bg-mv-san', m.san));
    if (m.glyph) {
      const g = el('span', `bg-glyph bg-glyph-${GLYPH_CLASS[m.glyph]}`, m.glyph);
      g.title = GLYPH_NAME[m.glyph];
      cell.append(g);
    }
    if (m.note) {
      const dot = el('span', 'bg-mv-note');
      dot.title = 'This move has a note';
      cell.append(dot);
    }
    if (m.waited) cell.append(el('span', 'bg-mv-wait', `sat ${Math.round(m.waited.seconds * 10) / 10}s`));
    const empty = el('span', 'bg-mv-cell');
    if (m.board === 'A') row.append(cell, empty); else row.append(empty, cell);
    const label = [`Board ${m.board}`, `${sideName(white ? 'white' : 'black')}`, moveName(m), m.glyph ? GLYPH_NAME[m.glyph] : '', m.note ? 'has a note' : '', m.book ? 'book move' : ''];
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

  /** The current move: who played it, its glyph, its wait, its note and its lines. */
  private renderNote() {
    const game = this.game!;
    const box = $('bg-note');
    const m = game.moves[this.cursor.move];
    const out: HTMLElement[] = [];
    if (!m) {
      const head = el('div', 'bg-note-head');
      head.append(el('b', 'bg-note-move', 'Start of the game'));
      out.push(head, el('p', 'bg-note-text', game.summary));
      const first = notedMoves(game)[0];
      if (first !== undefined) {
        const go = el('button', 'btn btn-outline btn-sm bg-note-first', `First note: ${moveName(game.moves[first])}`);
        go.type = 'button';
        go.onclick = () => this.nav(goTo(game, first));
        out.push(go);
      }
      box.replaceChildren(...out);
      box.scrollTop = 0;
      return;
    }
    const white = m.seat.endsWith('white');
    const head = el('div', 'bg-note-head');
    head.append(el('span', `bg-note-board bg-note-board-${m.board}`, m.board), el('b', 'bg-note-move', moveName(m)));
    if (m.glyph) {
      const g = el('span', `bg-glyph bg-glyph-${GLYPH_CLASS[m.glyph]}`, m.glyph);
      g.title = GLYPH_NAME[m.glyph];
      head.append(g, el('span', 'bg-note-glyph-name', GLYPH_NAME[m.glyph]));
    }
    const noted = notedMoves(game);
    const at = noted.indexOf(m.i);
    if (at >= 0) head.append(el('span', 'bg-note-count num', `note ${at + 1} of ${noted.length}`));
    out.push(head);

    const facts = [`${sideName(white ? 'white' : 'black')} on board ${m.board}`, game.seats[m.seat]];
    if (m.t !== null) facts.push(`at ${formatGameTime(m.t)}`);
    if (m.book) facts.push('opening book');
    if (m.eval !== null || m.mate !== null) facts.push(m.mate !== null ? mateWords(m.mate) : `score ${formatEval(m.eval, null, true)}`);
    out.push(el('p', 'bg-note-facts', facts.join(' · ')));
    if (m.waited) out.push(el('p', 'bg-note-wait', `Before this move, ${seatLabel(m.seat)} ${waitPhrase(m.waited)}.`));
    if (m.note) out.push(el('p', 'bg-note-text', m.note));
    if (m.i === game.moves.length - 1) out.push(el('p', 'bg-note-result', gameResult(game)));
    if (m.lines.length) {
      const lines = el('div', 'bg-lines');
      m.lines.forEach((line, index) => lines.append(this.lineBlock(m, line, index)));
      out.push(lines);
    }
    box.replaceChildren(...out);
    box.scrollTop = 0;
    this.markLineToken();
  }

  private lineBlock(m: Move, line: Line, index: number): HTMLElement {
    const block = el('section', `bg-line bg-line-${line.kind}`);
    block.dataset.lineBlock = String(index);
    const head = el('div', 'bg-line-head');
    const score = el('span', `bg-line-eval${line.mate !== null ? ' mate' : ' num'}`, scoreWords(line.eval, line.mate));
    if (line.eval !== null && line.mate === null) score.title = `${formatEval(line.eval, null)}: the engine’s score at the end of this search, from White’s side`;
    head.append(el('b', 'bg-line-kind', kindTitle(line, m)), score);
    block.append(head, el('p', 'bg-line-context', lineContext(line, m)));
    if (line.assume) block.append(el('p', 'bg-line-assume', assumePhrase(line.assume)));
    const moves = el('div', 'bg-line-moves');
    for (const t of lineTokens(line)) {
      if (t.number) moves.append(el('span', 'bg-line-num', t.number));
      const b = el('button', 'bg-line-move', t.san);
      b.type = 'button';
      b.dataset.line = String(index);
      b.dataset.ply = String(t.ply);
      b.setAttribute('aria-label', `Show ${t.san} in this line on board ${line.board}`);
      moves.append(b);
    }
    block.append(moves);
    if (line.note) block.append(el('p', 'bg-line-note', line.note));
    return block;
  }

  /** Highlight the line move on the board, if any. */
  private markLineToken() {
    const box = $('bg-note');
    for (const t of box.querySelectorAll('.bg-line-move.active')) t.classList.remove('active');
    for (const b of box.querySelectorAll('.bg-line.active')) b.classList.remove('active');
    const c = this.cursor.line;
    if (!c) return;
    box.querySelector(`.bg-line-move[data-line="${c.index}"][data-ply="${c.ply}"]`)?.classList.add('active');
    const block = box.querySelector<HTMLElement>(`.bg-line[data-line-block="${c.index}"]`);
    if (!block) return;
    block.classList.add('active');
    // Keep the line being walked in view inside the card (never scroll the page).
    const r = block.getBoundingClientRect();
    const b = box.getBoundingClientRect();
    if (r.top < b.top) box.scrollTop += r.top - b.top - 8;
    else if (r.bottom > b.bottom) box.scrollTop += Math.min(r.bottom - b.bottom + 8, r.top - b.top - 8);
  }
}
