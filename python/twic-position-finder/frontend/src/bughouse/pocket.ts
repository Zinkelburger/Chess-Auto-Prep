/**
 * A player's reserve drawn as lila's crazyhouse pocket: five slots, pawn to
 * queen, in a grey well. A held piece shows in full with its count on an
 * orange badge; an empty slot keeps its place, faint. When the pocket is
 * usable, pressing a piece and dragging carries it onto the board, and a
 * plain click picks it up for the next square clicked.
 */
import type { Piece, Role } from '@lichess-org/chessground/types';
import { PIECE_NAMES, pieceImage } from './boards';
import type { Colour } from './types';

const ROLES: Record<string, Role> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen' };

export interface PocketOptions {
  colour: Colour;
  /** The reserve as FEN letters, either case: `PPn`. */
  pocket: string;
  /** Spoken before each slot: `Player A` or `Your`. */
  owner: string;
  /** The piece letter (`N`) picked up by a click, if any. */
  selected: string | null;
  /** Whether this piece can be dropped now; false for every slot when it is not this player's turn. */
  usable: (letter: string) => boolean;
  onDrag: (piece: Piece, e: MouseEvent | TouchEvent) => void;
  onPick: (letter: string) => void;
}

export function renderPocket(o: PocketOptions): HTMLElement {
  const box = document.createElement('div');
  box.className = 'zh-pocket';
  box.setAttribute('role', 'group');
  box.setAttribute('aria-label', `${o.owner} reserve`);
  let anyUsable = false;
  for (const p of Object.keys(ROLES)) {
    const count = [...o.pocket].filter((c) => c.toLowerCase() === p).length;
    const letter = p.toUpperCase();
    const slot = document.createElement('button');
    slot.type = 'button';
    slot.className = 'zh-slot';
    slot.dataset.nb = String(count);
    slot.append(pieceImage(o.colour === 'white' ? letter : p));
    if (count) {
      const nb = document.createElement('span');
      nb.className = 'zh-nb';
      nb.textContent = String(count);
      slot.append(nb);
    }
    slot.setAttribute('aria-label', `${o.owner}: ${count} ${PIECE_NAMES[p]}${count === 1 ? '' : 's'}`);
    slot.setAttribute('aria-pressed', String(o.selected === letter));
    slot.disabled = !count || !o.usable(letter);
    if (!slot.disabled) {
      anyUsable = true;
      // Mouse and touch events, as lila's pockets use: chessground follows the
      // drag through them, and cancelling a pointerdown would suppress them.
      const pickUp = (e: MouseEvent | TouchEvent) => {
        if (e instanceof MouseEvent && e.button !== 0) return;
        e.preventDefault();
        o.onDrag({ role: ROLES[p], color: o.colour }, e);
      };
      slot.addEventListener('mousedown', pickUp);
      slot.addEventListener('touchstart', pickUp, { passive: false });
      slot.onclick = () => o.onPick(letter);
    }
    box.append(slot);
  }
  box.classList.toggle('usable', anyUsable);
  return box;
}
