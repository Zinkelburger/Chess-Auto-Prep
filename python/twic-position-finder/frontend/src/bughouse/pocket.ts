/**
 * A player's reserve drawn as lila's crazyhouse pocket: five slots, pawn to
 * queen, in a grey well. A held piece shows in full with its count on an
 * orange badge; an empty slot keeps its place, faint. When the pocket is
 * usable, pressing a piece and dragging carries it onto the board, and a
 * plain click or tap picks it up for the next square clicked.
 */
import type { Piece, Role } from '@lichess-org/chessground/types';
import { PIECE_NAMES, pieceImage } from './boards';
import type { Colour } from './types';

const ROLES: Record<string, Role> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen' };
/** A touch that ends within this many pixels of where it started, over the slot, is a tap. */
const TAP_SLOP = 10;

/** How a slot was picked: a click or tap, or Enter or Space on the focused slot. */
export type PickedBy = 'pointer' | 'keyboard';

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
  onPick: (letter: string, by: PickedBy) => void;
}

/**
 * A usable reserve slot's presses. Mouse and touch events, as lila's pockets
 * use: chessground follows the drag through them, and cancelling a
 * pointerdown would suppress them. The cancelled touchstart stops the page
 * scrolling and the browser's synthetic mouse events, so it also stops the
 * click: a tap is decided on touchend instead, by how far the finger went,
 * and runs on the next task, once chessground has ended its drag on the same
 * touchend (which takes the piece it was carrying off the board).
 */
export function bindSlot(slot: HTMLButtonElement, drag: (e: MouseEvent | TouchEvent) => void, pick: (by: PickedBy) => void) {
  let start: { x: number; y: number } | null = null;
  let tapped = -Infinity;
  slot.addEventListener('mousedown', (e) => {
    if (e.button !== 0) return;
    e.preventDefault();
    drag(e);
  });
  slot.addEventListener('touchstart', (e) => {
    const t = e.touches.length === 1 ? e.touches[0] : null;
    start = t ? { x: t.clientX, y: t.clientY } : null;
    e.preventDefault();
    drag(e);
  }, { passive: false });
  slot.addEventListener('touchcancel', () => { start = null; });
  slot.addEventListener('touchend', (e) => {
    const t = e.changedTouches[0];
    const from = start;
    start = null;
    if (!from || !t || Math.hypot(t.clientX - from.x, t.clientY - from.y) >= TAP_SLOP) return;
    const r = slot.getBoundingClientRect();
    if (t.clientX < r.left || t.clientX > r.right || t.clientY < r.top || t.clientY > r.bottom) return;
    tapped = performance.now();
    setTimeout(() => pick('pointer'), 0);
  });
  slot.addEventListener('click', (e) => {
    // A browser that still sends a click after the tap must not undo the pick.
    if (performance.now() - tapped < 800) return;
    pick(e.detail === 0 ? 'keyboard' : 'pointer');
  });
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
    slot.dataset.letter = letter;
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
      bindSlot(slot, (e) => o.onDrag({ role: ROLES[p], color: o.colour }, e), (by) => o.onPick(letter, by));
    }
    box.append(slot);
  }
  box.classList.toggle('usable', anyUsable);
  return box;
}
