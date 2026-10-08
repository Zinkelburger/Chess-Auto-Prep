/**
 * The puzzle board: one chessground board with a player row above and below,
 * each holding that side's frozen reserve. The look, the move dots, dragging
 * a reserve piece on and click-to-drop work as in Bughouse Lab
 * (../bughouse/boards.ts), on one board instead of two.
 */
import { Chessground } from '@lichess-org/chessground';
import type { Api } from '@lichess-org/chessground/api';
import type { Key, Piece, Role } from '@lichess-org/chessground/types';
import { PIECE_NAMES, pieceImage, placement } from '../bughouse/boards';
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
  players: Record<Colour, string>;
}

export class PuzzleBoard {
  private readonly cg: Api;
  private state: BoardState | null = null;
  /** A reserve piece picked up by a click, dropped on the next square clicked. */
  private dropping: string | null = null;

  constructor(
    boardEl: HTMLElement,
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
    new ResizeObserver(() => this.cg.redrawAll()).observe(boardEl);
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

  private renderRow(box: HTMLElement, colour: Colour) {
    const state = this.state!;
    box.replaceChildren();
    box.classList.toggle('to-move', state.pos.turn === colour);
    const dot = document.createElement('span');
    dot.className = `turn ${colour}`;
    dot.title = `${colour === 'white' ? 'White' : 'Black'} to move`;
    const who = document.createElement('span');
    who.className = 'who';
    who.textContent = state.players[colour];
    box.append(dot, who);
    const pocket = state.pos.pockets[colour];
    if (!pocket) {
      const none = document.createElement('span');
      none.className = 'bp-empty';
      none.textContent = 'No reserve';
      box.append(none);
    }
    for (const p of ['p', 'n', 'b', 'r', 'q']) {
      const count = [...pocket].filter((c) => c.toLowerCase() === p).length;
      if (!count) continue;
      const letter = p.toUpperCase();
      const button = document.createElement('button');
      button.type = 'button';
      button.className = 'bb-pocket';
      button.append(pieceImage(colour === 'white' ? letter : p), document.createTextNode(String(count)));
      button.setAttribute('aria-label', `${count} ${PIECE_NAMES[p]} in reserve`);
      button.setAttribute('aria-pressed', String(this.dropping === letter));
      button.disabled = state.pos.turn !== colour || !this.dropTargets(letter).length;
      if (!button.disabled) {
        const pickUp = (e: MouseEvent | TouchEvent) => {
          if (e instanceof MouseEvent && e.button !== 0) return;
          e.preventDefault();
          this.cg.dragNewPiece({ role: ROLES[p], color: colour } as Piece, e);
        };
        button.addEventListener('mousedown', pickUp);
        button.addEventListener('touchstart', pickUp, { passive: false });
        button.onclick = () => {
          this.cg.selectSquare(null);
          this.dropping = this.dropping === letter ? null : letter;
          this.render(state);
        };
      }
      box.append(button);
    }
  }

  private dropTargets(letter: string): string[] {
    return (this.state?.legal ?? []).filter((u) => u.startsWith(`${letter}@`)).map((u) => u.slice(2, 4));
  }

  private moved(orig: Key, dest: Key) {
    this.dropping = null;
    const hit = (this.state?.legal ?? []).filter((u) => u.startsWith(orig + dest));
    if (!hit.length) { this.rerender(); return; }
    this.onMove(hit.length > 1 ? this.preferredPromotion(hit) : hit[0]);
  }

  /** Set by the page: which of a pawn's promotions to play (default a queen). */
  preferredPromotion: (options: string[]) => string = (options) => options.find((u) => u.endsWith('q')) ?? options[0];

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
