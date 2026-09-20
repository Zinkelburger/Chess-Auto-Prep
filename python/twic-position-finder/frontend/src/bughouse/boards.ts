/**
 * The two-board view shared by Bughouse Lab and BughouseDB (markup in
 * components/BughouseBoards.astro): squares, players and reserves, last-move
 * and hover highlights, click and drag moves, and the setup boxes. Each page
 * supplies what is on the boards and what playing a move means.
 */
import { balance, checkFen, parseReserve, splitBoard } from './setup';

export type BoardName = 'A' | 'B';
export type Colour = 'white' | 'black';
export const BOARDS: BoardName[] = ['A', 'B'];
const COLOURS: Colour[] = ['white', 'black'];
/** Seats: board A has A (White) and B (Black); board B has D (White) and C (Black). */
// Partners hold opposite colours, so the teams read A + B and C + D.
export const SEAT: Record<BoardName, Record<Colour, string>> = { A: { white: 'A', black: 'C' }, B: { white: 'D', black: 'B' } };
export const PIECE_NAMES: Record<string, string> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };

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

type Selection = { board: BoardName; from?: string; drop?: string };

export class Boards {
  selected: Selection | null = null;
  private drag: (Selection & { piece: string; x: number; y: number; ghost?: HTMLImageElement }) | null = null;
  private swallowClick = false;

  constructor(private readonly prefix: string, private readonly hooks: BoardsHooks) {
    document.addEventListener('pointermove', (e) => this.dragMove(e));
    document.addEventListener('pointerup', (e) => this.dragEnd(e));
    document.addEventListener('pointercancel', () => { this.drag?.ghost?.remove(); this.drag = null; this.selected = null; this.render(); });
    // The click that ends a drag is not a second, separate click.
    document.addEventListener('click', (e) => { if (this.swallowClick) { this.swallowClick = false; e.stopPropagation(); e.preventDefault(); } }, true);
  }

  private el(id: string): HTMLElement { return document.getElementById(`${this.prefix}-${id}`)!; }

  render() { for (const name of BOARDS) this.renderBoard(name); }

  deselect() { if (this.selected) { this.selected = null; this.render(); } }

  renderArrows() { for (const name of BOARDS) this.drawArrow(name, this.hooks.view(name)); }

  private targets(name: BoardName, view: BoardView): string[] {
    const s = this.selected;
    if (s?.board !== name) return [];
    return view.legal.filter((u) => (s.drop ? u.startsWith(`${s.drop}@`) : !u.includes('@') && u.startsWith(s.from ?? '?')));
  }

  private renderBoard(name: BoardName) {
    const view = this.hooks.view(name);
    const files = view.bottom === 'white' ? 'abcdefgh' : 'hgfedcba';
    const ranks = view.bottom === 'white' ? '87654321' : '12345678';
    const container = this.el(`board-${name}`);
    // Keep focus across redraws so keyboard users can keep moving.
    const focused = container.contains(document.activeElement) ? (document.activeElement as HTMLElement).dataset.square : null;
    container.replaceChildren();
    const targets = this.targets(name, view).map((u) => u.slice(2, 4));
    for (let row = 0; row < 8; row++) for (let col = 0; col < 8; col++) {
      const square = files[col] + ranks[row];
      const piece = view.pieces[square];
      const button = document.createElement('button');
      button.type = 'button';  // the boards can sit inside a form
      button.className = `bb-square${(row + col) % 2 ? ' dark' : ''}`;
      button.dataset.board = name;
      button.dataset.square = square;
      button.disabled = !!view.disabled;
      if (view.last.includes(square)) button.classList.add('last');
      if (this.selected?.board === name && this.selected.from === square) button.classList.add('selected');
      if (targets.includes(square)) button.classList.add('target');
      if (this.drag?.ghost && this.drag.board === name && this.drag.from === square) button.classList.add('dragging');
      button.setAttribute('aria-label', `Board ${name === 'A' ? 1 : 2} ${square}${piece ? ` ${piece === piece.toUpperCase() ? 'white' : 'black'} ${PIECE_NAMES[piece.toLowerCase()]}` : ' empty'}`);
      if (piece) button.append(pieceImage(piece));
      if (row === 7) button.append(coord('file', files[col]));
      if (col === 0) button.append(coord('rank', ranks[row]));
      if (piece && view.legal.some((u) => u.startsWith(square))) {
        button.onpointerdown = (e) => this.dragStart(e, { board: name, from: square, piece });
      }
      button.onclick = () => this.clickSquare(name, square);
      button.onkeydown = (e) => {
        const delta = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -8, ArrowDown: 8 }[e.key];
        if (delta !== undefined) {
          e.preventDefault();
          e.stopPropagation();
          (container.children[Math.max(0, Math.min(63, row * 8 + col + delta))] as HTMLButtonElement).focus();
        } else if (e.key === 'Escape') this.deselect();
      };
      container.append(button);
    }
    if (focused) container.querySelector<HTMLButtonElement>(`[data-square="${focused}"]`)?.focus();
    this.drawArrow(name, view);
    for (const [where, colour] of [['top', view.bottom === 'white' ? 'black' : 'white'], ['bottom', view.bottom]] as const) {
      this.renderPlayer(this.el(`player-${where}-${name}`), name, colour, view);
    }
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
      const piece = colour === 'white' ? letter : p;
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'bb-pocket';
      button.append(pieceImage(piece), document.createTextNode(String(count)));
      button.setAttribute('aria-label', `Player ${SEAT[name][colour]}: ${count} ${PIECE_NAMES[p]} in reserve`);
      button.setAttribute('aria-pressed', String(this.selected?.board === name && this.selected.drop === letter));
      button.disabled = !!view.disabled || view.turn !== colour || !view.legal.some((u) => u.startsWith(`${letter}@`));
      button.onclick = () => {
        this.selected = this.selected?.board === name && this.selected.drop === letter ? null : { board: name, drop: letter };
        this.render();
      };
      if (!button.disabled) button.onpointerdown = (e) => this.dragStart(e, { board: name, drop: letter, piece });
      box.append(button);
    }
  }

  private clickSquare(name: BoardName, square: string) {
    const view = this.hooks.view(name);
    if (view.disabled) return;
    if (this.selected?.board === name) {
      const hit = this.targets(name, view).filter((u) => u.slice(2, 4) === square);
      if (hit.length) { this.selected = null; this.hooks.play(name, hit); return; }
    }
    const start = view.legal.some((u) => !u.includes('@') && u.startsWith(square));
    this.selected = start && !(this.selected?.board === name && this.selected.from === square) ? { board: name, from: square } : null;
    this.render();
  }

  /** Lichess's explorer arrow; a drop gets a ring on its square. */
  private drawArrow(name: BoardName, view: BoardView) {
    const svg = this.el(`arrow-${name}`);
    const uci = view.arrow;
    if (!uci) { svg.innerHTML = ''; return; }
    const centre = (square: string): [number, number] => {
      const file = 'abcdefgh'.indexOf(square[0]);
      const rank = Number(square[1]);
      return view.bottom === 'white' ? [file + 0.5, 8 - rank + 0.5] : [7 - file + 0.5, rank - 0.5];
    };
    const [x2, y2] = centre(uci.slice(2, 4));
    const brush = 'stroke="#003088" stroke-opacity="0.5"';
    if (uci.includes('@')) {
      svg.innerHTML = `<circle cx="${x2}" cy="${y2}" r="0.44" fill="none" ${brush} stroke-width="0.08"/>`;
      return;
    }
    const [x1, y1] = centre(uci.slice(0, 2));
    const len = Math.hypot(x2 - x1, y2 - y1);
    const [ex, ey] = [x2 - ((x2 - x1) / len) * 0.3, y2 - ((y2 - y1) / len) * 0.3];
    const id = `${this.prefix}-head-${name}`;
    svg.innerHTML = `<defs><marker id="${id}" orient="auto" markerWidth="4" markerHeight="4" refX="2.05" refY="2">`
      + '<path d="M0,0 V4 L3,2 Z" fill="#003088" fill-opacity="0.5"/></marker></defs>'
      + `<line x1="${x1}" y1="${y1}" x2="${ex}" y2="${ey}" ${brush} stroke-width="0.2" stroke-linecap="round" marker-end="url(#${id})"/>`;
  }

  // A press that moves more than a few pixels becomes a drag; a still press
  // stays a click, so click-to-move keeps working.
  private dragStart(e: PointerEvent, from: Selection & { piece: string }) {
    if (e.button !== 0) return;
    e.preventDefault();
    this.drag = { ...from, x: e.clientX, y: e.clientY };
  }

  private dragMove(e: PointerEvent) {
    const d = this.drag;
    if (!d) return;
    if (!d.ghost) {
      if (Math.hypot(e.clientX - d.x, e.clientY - d.y) < 5) return;
      const size = this.el(`board-${d.board}`).getBoundingClientRect().width / 8;
      d.ghost = pieceImage(d.piece);
      d.ghost.className = 'bb-ghost';
      d.ghost.style.width = d.ghost.style.height = `${size}px`;
      document.body.append(d.ghost);
      this.selected = { board: d.board, from: d.from, drop: d.drop };
      this.render();
    }
    d.ghost.style.left = `${e.clientX}px`;
    d.ghost.style.top = `${e.clientY}px`;
  }

  private dragEnd(e: PointerEvent) {
    const d = this.drag;
    this.drag = null;
    if (!d?.ghost) return;
    d.ghost.remove();
    this.swallowClick = true;
    setTimeout(() => { this.swallowClick = false; });
    const target = (document.elementFromPoint(e.clientX, e.clientY) as HTMLElement | null)?.closest<HTMLElement>(`#${this.prefix}-board-${d.board} .bb-square`);
    const hit = target ? this.targets(d.board, this.hooks.view(d.board)).filter((u) => u.slice(2, 4) === target.dataset.square) : [];
    this.selected = null;
    if (hit.length) { this.hooks.play(d.board, hit); return; }
    this.render();
  }
}

function coord(kind: 'file' | 'rank', text: string): HTMLSpanElement {
  const span = document.createElement('span');
  span.className = `bb-coord ${kind}`;
  span.textContent = text;
  return span;
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
