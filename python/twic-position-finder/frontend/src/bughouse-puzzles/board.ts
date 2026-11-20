/**
 * The puzzle board: one chessground board with each side's frozen reserve
 * above and below it, drawn as lila's pocket. The look,
 * the move dots, dragging a reserve piece on and click-to-drop work as in
 * the shared bughouse board (../bughouse/boards.ts).
 *
 * The board is also one Tab stop for the keyboard: the arrows move a square
 * cursor (drawn only once a key is pressed on the board), Enter or Space
 * picks up and puts down, Escape puts back what is picked. A polite live
 * line says where the cursor is and what was picked.
 */
import { Chessground } from '@lichess-org/chessground';
import '@lichess-org/chessground/assets/chessground.base.css';
import '@lichess-org/chessground/assets/chessground.brown.css';
import '@lichess-org/chessground/assets/chessground.cburnett.css';
import type { Api } from '@lichess-org/chessground/api';
import type { Key, Role } from '@lichess-org/chessground/types';
import { PIECE_NAMES, placement } from '../bughouse/boards';
import { renderPocket, type PickedBy } from '../bughouse/pocket';
import { choosePromotion } from '../bughouse/promotion';
import type { Colour } from '../bughouse/types';
import { moveCursor, type CursorKey, type Position } from './puzzle';

const ROLES: Record<string, Role> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };
const ARROWS: string[] = ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'];
const plural = (n: number, word: string) => `${n} ${word}${n === 1 ? '' : 's'}`;

export interface BoardState {
  pos: Position;
  bottom: Colour;
  /** Legal moves for the side to move as UCI; empty locks the board. */
  legal: string[];
  last: string[];
  check: boolean;
  /** The solver's colour: its pocket is the one that drops. */
  solver: Colour;
  /** The puzzle is over and its last board is shown: Enter on the board goes on to the next one. */
  finished: boolean;
}

export interface BoardHooks {
  move: (uci: string) => void;
  next: () => void;
}

export class PuzzleBoard {
  private readonly cg: Api;
  private state: BoardState | null = null;
  /** A reserve piece picked up by a click, dropped on the next square clicked. */
  private dropping: string | null = null;
  /** The keyboard cursor's square; null until a key places it. */
  private cursor: string | null = null;
  private cursorShown = false;
  private readonly cursorEl: HTMLElement;
  /** Whether the move being made came from the keyboard, so a promotion picker takes the focus. */
  private byKey = false;
  private readonly reduceMotion = matchMedia('(prefers-reduced-motion: reduce)');

  constructor(
    private readonly boardEl: HTMLElement,
    private readonly rows: { top: HTMLElement; bottom: HTMLElement },
    private readonly hooks: BoardHooks,
    private readonly live: HTMLElement,
  ) {
    this.cg = Chessground(boardEl, {
      coordinates: true,
      autoCastle: true,
      highlight: { lastMove: true, check: true },
      animation: { enabled: !this.reduceMotion.matches, duration: 180 },
      premovable: { enabled: false },
      predroppable: { enabled: false },
      draggable: { showGhost: true },
      movable: {
        free: false,
        showDests: true,
        events: {
          after: (orig, dest) => this.moved(orig, dest),
          afterNewPiece: (role, key) => this.dropped(role, key),
        },
      },
      events: {
        select: (key) => this.clicked(key),
        // The board's drawing layers say nothing to a screen reader.
        insert: () => { for (const svg of boardEl.querySelectorAll('svg')) svg.setAttribute('aria-hidden', 'true'); },
      },
    });
    this.reduceMotion.addEventListener('change', () => this.cg.set({ animation: { enabled: !this.reduceMotion.matches } }));
    // chessground keeps the board's place on the page; the pocket above it
    // moves the board without resizing it, so a change there re-measures too.
    const resized = new ResizeObserver(() => this.cg.redrawAll());
    resized.observe(boardEl);
    resized.observe(rows.top);

    this.cursorEl = document.createElement('div');
    this.cursorEl.className = 'bp-cursor';
    this.cursorEl.hidden = true;
    this.cursorEl.setAttribute('aria-hidden', 'true');
    boardEl.after(this.cursorEl);
    boardEl.addEventListener('keydown', (e) => this.keydown(e));
    boardEl.addEventListener('blur', () => this.hideCursor());
    // A mouse or a finger on the board takes over from the keyboard.
    for (const type of ['mousedown', 'touchstart'] as const) boardEl.addEventListener(type, () => this.hideCursor(), { capture: true, passive: true });
  }

  render(state: BoardState) {
    this.state = state;
    const { pos, legal } = state;
    if (this.dropping && !this.dropTargets(this.dropping).length) this.dropping = null;
    const dests = new Map<Key, Key[]>();
    for (const uci of legal) {
      if (uci[1] === '@') continue;
      const from = uci.slice(0, 2) as Key;
      const list = dests.get(from) ?? [];
      const to = uci.slice(2, 4) as Key;
      if (!list.includes(to)) list.push(to);
      dests.set(from, list);
    }
    const drops = this.dropping ? this.dropTargets(this.dropping) : [];
    this.cg.set({
      fen: placement(pos.pieces),
      orientation: state.bottom,
      turnColor: pos.turn,
      lastMove: state.last as Key[],
      check: state.check ? pos.turn : false,
      movable: { color: legal.length ? pos.turn : undefined, dests },
      highlight: { custom: new Map(drops.map((sq) => [sq as Key, 'move-dest'])) },
    });
    const top: Colour = state.bottom === 'white' ? 'black' : 'white';
    this.renderRow(this.rows.top, top);
    this.renderRow(this.rows.bottom, state.bottom);
    this.drawCursor();
  }

  /** A new puzzle: the cursor waits for a key and then starts from the new board. */
  resetCursor() {
    this.cursor = null;
    this.hideCursor();
  }

  /** Say something on the board's live line. */
  announce(text: string) { this.live.textContent = text; }

  /** A seat is only its pocket: the board says whose move it is. */
  private renderRow(box: HTMLElement, colour: Colour) {
    const state = this.state!;
    const yours = colour === state.solver;
    box.classList.toggle('to-move', state.pos.turn === colour);
    box.replaceChildren(renderPocket({
      colour,
      pocket: state.pos.pockets[colour],
      owner: yours ? 'Your' : 'Their',
      selected: yours ? this.dropping : null,
      usable: (letter) => state.pos.turn === colour && this.dropTargets(letter).length > 0,
      onDrag: (piece, e) => {
        // The pocket may have scrolled into view since the last board event.
        this.cg.state.dom.bounds.clear();
        this.cg.dragNewPiece(piece, e);
      },
      onPick: (letter, by) => this.pick(letter, by),
    }));
  }

  /** A reserve piece picked or put back; from the keyboard the board takes the focus, cursor showing. */
  private pick(letter: string, by: PickedBy) {
    const state = this.state;
    if (!state) return;
    // A tap's drag has ended by now; make sure its piece is gone.
    if (this.cg.state.draggable.current) this.cg.cancelMove();
    this.cg.selectSquare(null);
    this.dropping = this.dropping === letter ? null : letter;
    this.render(state);
    if (by !== 'keyboard') return;
    this.boardEl.focus({ preventScroll: true });
    this.showCursor();
    if (this.dropping) this.announce(`${PIECE_NAMES[letter.toLowerCase()]} from the reserve, ${plural(this.dropTargets(letter).length, 'square')}`);
  }

  private dropTargets(letter: string): string[] {
    return (this.state?.legal ?? []).filter((u) => u.startsWith(`${letter}@`)).map((u) => u.slice(2, 4));
  }

  private moved(orig: Key, dest: Key) {
    this.dropping = null;
    const byKey = this.byKey;
    this.byKey = false;
    const state = this.state;
    const hit = (state?.legal ?? []).filter((u) => u.startsWith(orig + dest));
    if (!state || !hit.length) { this.rerender(); return; }
    if (hit.length === 1) { this.hooks.move(hit[0]); return; }
    // A promotion: lila's picker over the board. The choice is the player's,
    // so an underpromotion is never given away.
    void choosePromotion(this.boardEl.parentElement!, hit, state.pos.turn, state.bottom, byKey)
      .then((uci) => {
        if (byKey) this.boardEl.focus();
        if (uci) this.hooks.move(uci); else this.rerender();
      });
  }

  private dropped(role: Role, key: Key) {
    this.dropping = null;
    const letter = Object.keys(ROLES).find((k) => ROLES[k] === role)!.toUpperCase();
    const uci = `${letter}@${key}`;
    if (this.state?.legal.includes(uci)) this.hooks.move(uci);
    else this.rerender();
  }

  private clicked(key: Key) {
    const letter = this.dropping;
    if (!letter) return;
    this.dropping = null;
    const uci = `${letter}@${key}`;
    if (this.state?.legal.includes(uci)) this.hooks.move(uci);
    else this.rerender();
  }

  private rerender() { if (this.state) this.render(this.state); }

  // ── Keyboard ───────────────────────────────────────────────────

  private keydown(e: KeyboardEvent) {
    const state = this.state;
    if (!state || e.ctrlKey || e.metaKey || e.altKey) return;
    if (ARROWS.includes(e.key)) {
      // While the board has focus the arrows belong to the cursor, not the page.
      e.preventDefault();
      e.stopPropagation();
      if (this.cursorShown && this.cursor) {
        this.cursor = moveCursor(this.cursor, e.key as CursorKey, state.bottom);
        this.drawCursor();
      } else {
        this.showCursor();
      }
      this.announceSquare();
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      e.stopPropagation();
      if (state.finished) { this.hooks.next(); return; }
      if (!this.cursorShown) { this.showCursor(); this.announceSquare(); return; }
      if (state.legal.length) this.press(this.cursor!);
    } else if (e.key === 'Escape' && (this.dropping || this.cg.state.selected)) {
      e.preventDefault();
      e.stopPropagation();
      this.cg.selectSquare(null);
      this.dropping = null;
      this.rerender();
    }
  }

  /** Enter or Space on a square: pick up, put down, move or drop; an illegal target does nothing. */
  private press(key: string) {
    const legal = this.state!.legal;
    if (this.dropping) {
      const uci = `${this.dropping}@${key}`;
      if (!legal.includes(uci)) return;
      this.dropping = null;
      this.hooks.move(uci);
      return;
    }
    const moves = (from: string) => new Set(legal.filter((u) => u[1] !== '@' && u.startsWith(from)).map((u) => u.slice(2, 4)));
    const selected = this.cg.state.selected;
    if (selected === key) { this.cg.selectSquare(null); return; }
    if (selected && moves(selected).has(key)) {
      // chessground plays it, as a click on the square would, and reports it a moment later.
      this.byKey = true;
      this.cg.selectSquare(key as Key);
      return;
    }
    const n = moves(key).size;
    if (!n) return;
    this.cg.selectSquare(key as Key);
    const piece = this.state!.pos.pieces[key];
    this.announce(`${PIECE_NAMES[piece.toLowerCase()]} ${key} picked, ${plural(n, 'move')}`);
  }

  /** The cursor starts on the last move's square, else the solver's king. */
  private showCursor() {
    const state = this.state;
    if (!state) return;
    if (!this.cursor) {
      const king = state.solver === 'white' ? 'K' : 'k';
      this.cursor = state.last.at(-1) ?? Object.keys(state.pos.pieces).find((sq) => state.pos.pieces[sq] === king) ?? 'e1';
    }
    this.cursorShown = true;
    this.drawCursor();
  }

  private hideCursor() {
    this.cursorShown = false;
    this.drawCursor();
  }

  private drawCursor() {
    const el = this.cursorEl;
    const state = this.state;
    el.hidden = !this.cursorShown || !this.cursor || !state;
    if (el.hidden) return;
    const file = this.cursor!.charCodeAt(0) - 97;
    const rank = Number(this.cursor![1]) - 1;
    const white = state!.bottom === 'white';
    el.dataset.square = this.cursor!;
    el.style.left = `${(white ? file : 7 - file) * 12.5}%`;
    el.style.top = `${(white ? 7 - rank : rank) * 12.5}%`;
  }

  private announceSquare() {
    const key = this.cursor;
    const piece = key ? this.state?.pos.pieces[key] : undefined;
    if (!key) return;
    this.announce(piece ? `${key}, ${piece === piece.toUpperCase() ? 'white' : 'black'} ${PIECE_NAMES[piece.toLowerCase()]}` : `${key}, empty`);
  }
}
