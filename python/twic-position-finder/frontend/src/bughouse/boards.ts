/**
 * The two-board view shared by Bughouse Lab and BughouseDB (markup in
 * components/BughouseBoards.astro). Each board is Lichess's own board,
 * chessground: its pieces, move and drop dots, dragging, last-move squares
 * and arrows are Lichess's. Around it sit the players and their reserves,
 * and under it the setup boxes. Each page supplies what is on the boards and
 * what playing a move means.
 */
import { Chessground } from '@lichess-org/chessground';
import type { Api } from '@lichess-org/chessground/api';
import type { DrawShape } from '@lichess-org/chessground/draw';
import type { Key, Piece, Role } from '@lichess-org/chessground/types';
import '@lichess-org/chessground/assets/chessground.base.css';
import '@lichess-org/chessground/assets/chessground.brown.css';
import '@lichess-org/chessground/assets/chessground.cburnett.css';
import { balance, checkFen, parseReserve, splitBoard } from './setup';

export type BoardName = 'A' | 'B';
export type Colour = 'white' | 'black';
export const BOARDS: BoardName[] = ['A', 'B'];
const COLOURS: Colour[] = ['white', 'black'];
// Partners hold opposite colours, so the teams read A + B and C + D.
export const SEAT: Record<BoardName, Record<Colour, string>> = { A: { white: 'A', black: 'C' }, B: { white: 'D', black: 'B' } };
export const PIECE_NAMES: Record<string, string> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };
const ROLES: Record<string, Role> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };

export function pieceImage(piece: string): HTMLImageElement {
  const img = document.createElement('img');
  img.src = `/piece/${piece === piece.toUpperCase() ? 'w' : 'b'}${piece.toUpperCase()}.svg`;
  img.alt = '';
  img.draggable = false;
  return img;
}

/** The squares a move touches: from and to, or only the square of a drop. */
export function squaresOf(uci: string): string[] {
  return uci.includes('@') ? [uci.slice(2, 4)] : [uci.slice(0, 2), uci.slice(2, 4)];
}

/** Pieces by square and the two reserves, from one board's FEN. */
export function readBoard(fen: string): { pieces: Record<string, string>; pockets: Record<Colour, string> } {
  const field = fen.split(' ')[0];
  const open = field.indexOf('[');
  const placement = (open >= 0 ? field.slice(0, open) : field).replace(/~/g, '');
  const pocket = open >= 0 ? field.slice(open + 1, field.indexOf(']', open)) : '';
  const pieces: Record<string, string> = {};
  placement.split('/').forEach((rank, r) => {
    let file = 0;
    for (const ch of rank) {
      if (/\d/.test(ch)) { file += Number(ch); continue; }
      pieces['abcdefgh'[file] + String(8 - r)] = ch;
      file += 1;
    }
  });
  return { pieces, pockets: { white: [...pocket].filter((c) => c === c.toUpperCase()).join(''), black: [...pocket].filter((c) => c !== c.toUpperCase()).join('') } };
}

/** The piece placement chessground reads, from pieces by square. */
function placement(pieces: Record<string, string>): string {
  const rows: string[] = [];
  for (let rank = 8; rank >= 1; rank--) {
    let row = '';
    let empty = 0;
    for (const file of 'abcdefgh') {
      const piece = pieces[file + rank];
      if (!piece) { empty += 1; continue; }
      if (empty) { row += empty; empty = 0; }
      row += piece;
    }
    rows.push(empty ? row + empty : row);
  }
  return rows.join('/');
}

export interface BoardView {
  pieces: Record<string, string>;
  pockets: Record<Colour, string>;
  turn: Colour | null;
  bottom: Colour;
  /** Legal moves on this board, as UCI (drops like N@e4). */
  legal: string[];
  /** Squares of the last move on this board. */
  last: string[];
  /** A move to draw as an arrow (hover), or null. */
  arrow: string | null;
  disabled?: boolean;
}

export interface BoardsHooks {
  view(name: BoardName): BoardView;
  /** The chosen move: several when a pawn promotes, one per piece. */
  play(name: BoardName, moves: string[]): void;
}

export class Boards {
  private readonly cg: Record<BoardName, Api>;
  /** A reserve piece picked up by a click, to drop on the next square clicked. */
  private dropping: { board: BoardName; letter: string } | null = null;

  constructor(private readonly prefix: string, private readonly hooks: BoardsHooks) {
    this.cg = { A: this.mount('A'), B: this.mount('B') };
    // The boards follow the window; chessground measures its squares once.
    new ResizeObserver(() => { for (const name of BOARDS) this.cg[name].redrawAll(); }).observe(this.el('board-A'));
  }

  private el(id: string): HTMLElement { return document.getElementById(`${this.prefix}-${id}`)!; }

  private mount(name: BoardName): Api {
    return Chessground(this.el(`board-${name}`), {
      coordinates: true,
      autoCastle: true,
      highlight: { lastMove: true, check: false },
      animation: { enabled: true, duration: 150 },
      premovable: { enabled: false },
      predroppable: { enabled: false },
      draggable: { showGhost: true },
      movable: {
        free: false,
        showDests: true,
        events: {
          after: (orig, dest) => this.moved(name, orig, dest),
          afterNewPiece: (role, key) => this.dropped(name, role, key),
        },
      },
      events: { select: (key) => this.clicked(name, key) },
    });
  }

  render() { for (const name of BOARDS) this.renderBoard(name); }

  deselect() {
    for (const name of BOARDS) this.cg[name].selectSquare(null);
    if (this.dropping) { this.dropping = null; this.render(); }
  }

  renderArrows() { for (const name of BOARDS) this.cg[name].setAutoShapes(this.shapes(this.hooks.view(name))); }

  private renderBoard(name: BoardName) {
    const view = this.hooks.view(name);
    if (this.dropping?.board === name && (view.disabled || !this.dropTargets(view, this.dropping.letter).length)) this.dropping = null;
    const dests = new Map<Key, Key[]>();
    for (const uci of view.legal) {
      if (uci.includes('@')) continue;
      const from = uci.slice(0, 2) as Key;
      const to = uci.slice(2, 4) as Key;
      const list = dests.get(from) ?? [];
      if (!list.includes(to)) list.push(to);
      dests.set(from, list);
    }
    const drops = this.dropping?.board === name ? this.dropTargets(view, this.dropping.letter) : [];
    this.cg[name].set({
      fen: placement(view.pieces),
      orientation: view.bottom,
      turnColor: view.turn ?? 'white',
      lastMove: view.last as Key[],
      movable: { color: view.disabled || !view.turn ? undefined : view.turn, dests },
      // The picked-up reserve piece's squares, drawn as Lichess's move dots.
      highlight: { custom: new Map(drops.map((square) => [square as Key, 'move-dest'])) },
      drawable: { autoShapes: this.shapes(view) },
    });
    for (const [where, colour] of [['top', view.bottom === 'white' ? 'black' : 'white'], ['bottom', view.bottom]] as const) {
      this.renderPlayer(this.el(`player-${where}-${name}`), name, colour, view);
    }
  }

  /** Lichess's explorer arrow for a move; for a drop, the piece on its square. */
  private shapes(view: BoardView): DrawShape[] {
    const uci = view.arrow;
    if (!uci) return [];
    if (uci.includes('@')) {
      const piece = { role: ROLES[uci[0].toLowerCase()], color: view.turn ?? 'white', scale: 0.8 };
      return [{ orig: uci.slice(2, 4) as Key, brush: 'paleBlue', piece }];
    }
    return [{ orig: uci.slice(0, 2) as Key, dest: uci.slice(2, 4) as Key, brush: 'paleBlue' }];
  }

  private dropTargets(view: BoardView, letter: string): string[] {
    return view.legal.filter((u) => u.startsWith(`${letter}@`)).map((u) => u.slice(2, 4));
  }

  private renderPlayer(box: HTMLElement, name: BoardName, colour: Colour, view: BoardView) {
    box.replaceChildren();
    box.classList.toggle('to-move', view.turn === colour);
    const dot = document.createElement('span');
    dot.className = `turn ${colour}`;
    dot.title = `${colour === 'white' ? 'White' : 'Black'} to move`;
    const who = document.createElement('span');
    who.className = 'who';
    who.textContent = `Player ${SEAT[name][colour]}`;
    box.append(dot, who);
    const pocket = view.pockets[colour];
    for (const p of ['p', 'n', 'b', 'r', 'q']) {
      const count = [...pocket].filter((c) => c.toLowerCase() === p).length;
      if (!count) continue;
      const letter = p.toUpperCase();
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'bb-pocket';
      button.append(pieceImage(colour === 'white' ? letter : p), document.createTextNode(String(count)));
      button.setAttribute('aria-label', `Player ${SEAT[name][colour]}: ${count} ${PIECE_NAMES[p]} in reserve`);
      button.setAttribute('aria-pressed', String(this.dropping?.board === name && this.dropping.letter === letter));
      button.disabled = !!view.disabled || view.turn !== colour || !this.dropTargets(view, letter).length;
      if (!button.disabled) {
        // Pressing and dragging carries the piece onto the board, as on Lichess;
        // a plain click picks it up for the next square clicked. Mouse and touch
        // events, as Lichess's reserves use: chessground follows the drag through
        // them, and cancelling a pointerdown would suppress exactly those.
        const pickUp = (e: MouseEvent | TouchEvent) => {
          if (e instanceof MouseEvent && e.button !== 0) return;
          e.preventDefault();
          this.cg[name].dragNewPiece({ role: ROLES[p], color: colour } as Piece, e);
        };
        button.addEventListener('mousedown', pickUp);
        button.addEventListener('touchstart', pickUp, { passive: false });
        button.onclick = () => {
          const same = this.dropping?.board === name && this.dropping.letter === letter;
          for (const other of BOARDS) this.cg[other].selectSquare(null);
          this.dropping = same ? null : { board: name, letter };
          this.render();
        };
      }
      box.append(button);
    }
  }

  private moved(name: BoardName, orig: Key, dest: Key) {
    this.dropping = null;
    const hit = this.hooks.view(name).legal.filter((u) => u.startsWith(orig + dest));
    if (hit.length) this.hooks.play(name, hit); else this.render();
  }

  /** A reserve piece dragged onto a square; chessground has already put it there. */
  private dropped(name: BoardName, role: Role, key: Key) {
    this.dropping = null;
    const letter = Object.keys(ROLES).find((k) => ROLES[k] === role)!.toUpperCase();
    const uci = `${letter}@${key}`;
    if (this.hooks.view(name).legal.includes(uci)) this.hooks.play(name, [uci]);
    else this.render();  // not legal here: take it back off
  }

  /** A square clicked while a reserve piece is picked up drops it there. */
  private clicked(name: BoardName, key: Key) {
    const d = this.dropping;
    if (!d) return;
    const uci = `${d.letter}@${key}`;
    if (d.board === name && this.hooks.view(name).legal.includes(uci)) {
      this.dropping = null;
      this.hooks.play(name, [uci]);
    } else {
      this.dropping = null;
      this.render();
    }
  }
}

// ── Setting a position by hand ────────────────────────────────────

/**
 * The FEN and reserve boxes under the boards, and the live count of pieces
 * still to place. `read()` checks them and returns the dual FEN, or null
 * after marking what is wrong.
 */
export class SetupBoxes {
  constructor(private readonly prefix: string) {
    for (const box of document.querySelectorAll<HTMLInputElement>(`[id^="${prefix}-fen-"], [id^="${prefix}-reserve-"]`)) {
      box.addEventListener('input', () => { box.removeAttribute('aria-invalid'); this.renderBalance(); });
    }
  }

  private input(id: string) { return document.getElementById(`${this.prefix}-${id}`) as HTMLInputElement; }

  /** A message under board 1's boxes, e.g. the position the server refused. */
  error(text: string) { document.getElementById(`${this.prefix}-fen-error-A`)!.textContent = text; }

  fill(dual: string) {
    const boards = dual.split('|');
    BOARDS.forEach((name, i) => {
      const setup = splitBoard(boards[i] ?? '');
      this.input(`fen-${name}`).value = setup.fen;
      this.input(`reserve-${name}-white`).value = setup.white;
      this.input(`reserve-${name}-black`).value = setup.black;
    });
    this.renderBalance();
  }

  /** Both boards from their boxes; a pasted dual FEN in either box fills both. */
  read(): string | null {
    for (const name of BOARDS) {
      const pasted = this.input(`fen-${name}`).value;
      if (pasted.includes('|')) { this.fill(pasted); break; }
    }
    const boards: string[] = [];
    let ok = true;
    for (const name of BOARDS) {
      const errors: string[] = [];
      const fen = checkFen(this.input(`fen-${name}`).value);
      this.input(`fen-${name}`).setAttribute('aria-invalid', String('error' in fen));
      if ('error' in fen) errors.push(fen.error);
      const pockets: string[] = [];
      for (const colour of COLOURS) {
        const box = this.input(`reserve-${name}-${colour}`);
        const reserve = parseReserve(box.value);
        box.setAttribute('aria-invalid', String('error' in reserve));
        if ('error' in reserve) errors.push(`Player ${SEAT[name][colour]}: ${reserve.error}`);
        else pockets.push(colour === 'white' ? reserve.pieces : reserve.pieces.toLowerCase());
      }
      // A pocket pasted in brackets counts too, beside what the reserve boxes say.
      if (!('error' in fen)) boards.push(`${fen.placement}[${pockets.join('')}${fen.pocket}] ${fen.rest}`);
      document.getElementById(`${this.prefix}-fen-error-${name}`)!.textContent = errors.join(' ');
      ok &&= errors.length === 0;
    }
    return ok ? boards.join('|') : null;
  }

  /** What the boxes leave unplaced, live as they are edited. */
  private renderBalance() {
    const reserves = BOARDS.flatMap((name) => COLOURS.map((colour) => {
      const r = parseReserve(this.input(`reserve-${name}-${colour}`).value);
      return 'error' in r ? '' : colour === 'white' ? r.pieces : r.pieces.toLowerCase();
    })).join('');
    const b = balance([this.input('fen-A').value, this.input('fen-B').value], reserves);
    const out = document.getElementById(`${this.prefix}-balance`)!;
    out.replaceChildren();
    if (!b) return;
    const part = (label: string, sides: Record<Colour, string>, cls: string) => {
      const text = COLOURS.filter((c) => sides[c]).map((c) => `${c === 'white' ? 'White' : 'Black'}: ${sides[c]}`).join(' · ');
      if (!text) return;
      const span = document.createElement('span');
      span.className = cls;
      span.textContent = `${label} ${text}`;
      out.append(span);
    };
    part('Pieces outstanding:', b.missing, 'missing');
    part('Too many:', b.extra, 'extra');
    if (!out.childElementCount) out.textContent = 'Pieces outstanding: none';
  }
}

// ── Each board's own move list ────────────────────────────────────

export interface LineMove { board: BoardName; uci: string; san: string; colour: Colour; num: number }

/**
 * Both boards' moves in the order they were played, with a cursor per
 * board. The position is the start plus each board's first `upto[board]`
 * moves, replayed in played order, so either board steps back and forth on
 * its own. (A capture crosses boards, so stepping one board back can make
 * the other's drop impossible; the page then refuses the step.)
 */
export class Lines {
  moves: LineMove[] = [];
  upto: Record<BoardName, number> = { A: 0, B: 0 };
  /** The board the step buttons and arrow keys act on. */
  focus: BoardName = 'A';

  constructor(public root: string) {}

  reset(root: string) { this.root = root; this.moves = []; this.upto = { A: 0, B: 0 }; }

  of(name: BoardName): LineMove[] { return this.moves.filter((m) => m.board === name); }

  applied(): LineMove[] {
    const seen = { A: 0, B: 0 };
    return this.moves.filter((m) => seen[m.board]++ < this.upto[m.board]);
  }

  /** Board-tagged UCI of the moves on the boards, e.g. ["A:e2e4", "B:P@e6"]. */
  tokens(): string[] { return this.applied().map((m) => `${m.board}:${m.uci}`); }

  current(name: BoardName): LineMove | undefined { return this.of(name)[this.upto[name] - 1]; }

  go(name: BoardName, count: number) {
    this.focus = name;
    this.upto[name] = Math.max(0, Math.min(this.of(name).length, count));
  }

  /** A move on `move.board`: the next one in its list, or a new one replacing what followed. */
  play(move: LineMove) {
    const name = move.board;
    this.focus = name;
    const own = this.of(name);
    if (own[this.upto[name]]?.uci === move.uci) { this.upto[name] += 1; return; }
    const dropped = new Set(own.slice(this.upto[name]));
    this.moves = this.moves.filter((m) => !dropped.has(m));
    const onBoards = new Set(this.applied());
    let at = 0;
    this.moves.forEach((m, i) => { if (onBoards.has(m)) at = i + 1; });
    this.moves.splice(at, 0, move);
    this.upto[name] += 1;
  }

  snapshot() { return { moves: [...this.moves], upto: { ...this.upto }, focus: this.focus, root: this.root }; }

  restore(s: ReturnType<Lines['snapshot']>) { Object.assign(this, { moves: s.moves, upto: s.upto, focus: s.focus, root: s.root }); }
}

/**
 * Each board's move list and step buttons. Moving on a board, or clicking
 * anywhere in its half, makes it the one the arrow keys step through.
 */
export class LineView {
  constructor(private readonly prefix: string, private readonly lines: Lines, private readonly changed: () => void) {
    for (const name of BOARDS) {
      const step = (id: string, to: () => number) => {
        document.getElementById(`${prefix}-${id}-${name}`)!.onclick = () => { this.lines.go(name, to()); this.changed(); };
      };
      step('first', () => 0);
      step('prev', () => this.lines.upto[name] - 1);
      step('next', () => this.lines.upto[name] + 1);
      step('last', () => this.lines.of(name).length);
      document.getElementById(`${prefix}-panel-${name}`)!.addEventListener('pointerdown', () => {
        if (this.lines.focus !== name) { this.lines.focus = name; this.render(); }
      });
    }
    document.addEventListener('keydown', (e) => {
      const t = e.target as HTMLElement;
      if (t.closest('input, textarea, select, dialog')) return;
      const name = this.lines.focus;
      const to = { ArrowLeft: this.lines.upto[name] - 1, ArrowRight: this.lines.upto[name] + 1, Home: 0, End: this.lines.of(name).length }[e.key];
      if (to === undefined) return;
      e.preventDefault();
      this.lines.go(name, to);
      this.changed();
    });
  }

  render() {
    for (const name of BOARDS) {
      const own = this.lines.of(name);
      const upto = this.lines.upto[name];
      const list = document.getElementById(`${this.prefix}-history-${name}`)!;
      list.replaceChildren();
      let row: HTMLLIElement | null = null;
      own.forEach((move, i) => {
        if (!row || move.colour === 'white') {
          row = document.createElement('li');
          const num = document.createElement('span');
          num.className = 'num';
          num.textContent = `${move.num}.`;
          row.append(num);
          if (move.colour === 'black') { const gap = document.createElement('span'); gap.className = 'none'; gap.textContent = '…'; row.append(gap); }
          list.append(row);
        }
        const b = document.createElement('button');
        b.type = 'button';
        b.textContent = move.san;
        b.title = `Player ${SEAT[name][move.colour]}`;
        if (i >= upto) b.classList.add('future');
        b.setAttribute('aria-current', String(i === upto - 1));
        b.onclick = () => { this.lines.go(name, i + 1); this.changed(); };
        row.append(b);
        if (move.colour === 'black') row = null;
      });
      list.querySelector('[aria-current="true"]')?.scrollIntoView({ block: 'nearest' });
      const set = (id: string, off: boolean) => { (document.getElementById(`${this.prefix}-${id}-${name}`) as HTMLButtonElement).disabled = off; };
      set('first', upto === 0); set('prev', upto === 0);
      set('next', upto === own.length); set('last', upto === own.length);
      document.getElementById(`${this.prefix}-panel-${name}`)!.classList.toggle('focused', this.lines.focus === name);
    }
  }
}
