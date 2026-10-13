/**
 * The puzzle board: one chessground board with each side's frozen reserve
 * above and below it, drawn as lila's pocket. The look,
 * the move dots, dragging a reserve piece on and click-to-drop work as in
 * Bughouse Lab (../bughouse/boards.ts), on one board instead of two.
 */
import { Chessground } from '@lichess-org/chessground';
import type { Api } from '@lichess-org/chessground/api';
import type { Key, Role } from '@lichess-org/chessground/types';
import { placement } from '../bughouse/boards';
import { renderPocket } from '../bughouse/pocket';
import { choosePromotion } from '../bughouse/promotion';
import type { Colour } from '../bughouse/types';
import type { Position } from './puzzle';

const ROLES: Record<string, Role> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };

export interface BoardState {
  pos: Position;
  bottom: Colour;
  /** Legal moves for the side to move as UCI; empty locks the board. */
  legal: string[];
  last: string[];
  check: boolean;
  /** The solver's colour: its pocket is the one that drops. */
  solver: Colour;
}

export class PuzzleBoard {
  private readonly cg: Api;
  private state: BoardState | null = null;
  /** A reserve piece picked up by a click, dropped on the next square clicked. */
  private dropping: string | null = null;

  constructor(
    private readonly boardEl: HTMLElement,
    private readonly rows: { top: HTMLElement; bottom: HTMLElement },
    private readonly onMove: (uci: string) => void,
  ) {
    this.cg = Chessground(boardEl, {
      coordinates: true,
      autoCastle: true,
      highlight: { lastMove: true, check: true },
      animation: { enabled: true, duration: 180 },
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
      events: { select: (key) => this.clicked(key) },
    });
    // chessground keeps the board's place on the page; the pocket above it
    // moves the board without resizing it, so a change there re-measures too.
    const resized = new ResizeObserver(() => this.cg.redrawAll());
    resized.observe(boardEl);
    resized.observe(rows.top);
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
  }

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
      onPick: (letter) => {
        this.cg.selectSquare(null);
        this.dropping = this.dropping === letter ? null : letter;
        this.render(state);
      },
    }));
  }

  private dropTargets(letter: string): string[] {
    return (this.state?.legal ?? []).filter((u) => u.startsWith(`${letter}@`)).map((u) => u.slice(2, 4));
  }

  private moved(orig: Key, dest: Key) {
    this.dropping = null;
    const state = this.state;
    const hit = (state?.legal ?? []).filter((u) => u.startsWith(orig + dest));
    if (!state || !hit.length) { this.rerender(); return; }
    if (hit.length === 1) { this.onMove(hit[0]); return; }
    // A promotion: lila's picker over the board. The choice is the player's,
    // so an underpromotion is never given away.
    void choosePromotion(this.boardEl.parentElement!, hit, state.pos.turn, state.bottom)
      .then((uci) => { if (uci) this.onMove(uci); else this.rerender(); });
  }

  private dropped(role: Role, key: Key) {
    this.dropping = null;
    const letter = Object.keys(ROLES).find((k) => ROLES[k] === role)!.toUpperCase();
    const uci = `${letter}@${key}`;
    if (this.state?.legal.includes(uci)) this.onMove(uci);
    else this.rerender();
  }

  private clicked(key: Key) {
    const letter = this.dropping;
    if (!letter) return;
    this.dropping = null;
    const uci = `${letter}@${key}`;
    if (this.state?.legal.includes(uci)) this.onMove(uci);
    else this.rerender();
  }

  private rerender() { if (this.state) this.render(this.state); }
}
