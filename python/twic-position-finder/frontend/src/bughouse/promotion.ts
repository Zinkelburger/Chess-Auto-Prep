/**
 * lila's promotion picker (ui/lib/src/game/promotion.ts): the board dims and
 * the four pieces stand in a column on the promotion file, from the promotion
 * square inwards, as grey circles that open into squares under the pointer.
 * A click anywhere else, or Escape, cancels. Opened from the keyboard, the
 * first choice takes the focus, the arrows move between the choices and Enter
 * confirms.
 */
import { pieceImage } from './boards';
import type { Colour } from './types';

/** lila's order: queen first, then knight, rook and bishop. */
const ROLES = ['q', 'n', 'r', 'b'] as const;
const NAMES: Record<string, string> = { q: 'Queen', n: 'Knight', r: 'Rook', b: 'Bishop' };

/**
 * Ask which piece a pawn promotes to. `over` is the element covering the
 * board exactly; `options` are the legal UCI moves for this pawn, each
 * ending in its piece letter. Resolves to the chosen move, or null.
 */
export function choosePromotion(over: HTMLElement, options: string[], colour: Colour, orientation: Colour, keyboard = false): Promise<string | null> {
  const dest = options[0].slice(2, 4);
  const file = dest.charCodeAt(0) - 97;
  const left = (orientation === 'white' ? file : 7 - file) * 12.5;
  const fromTop = colour === orientation;
  return new Promise((resolve) => {
    const layer = document.createElement('div');
    layer.className = 'promotion-choice';
    layer.setAttribute('role', 'dialog');
    layer.setAttribute('aria-label', 'Promote to');
    const done = (uci: string | null) => {
      layer.remove();
      document.removeEventListener('keydown', onKey, true);
      resolve(uci);
    };
    const onKey = (e: KeyboardEvent) => {
      const step = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (e.key !== 'Escape' && !step) return;
      e.preventDefault();
      e.stopPropagation();
      if (!step) { done(null); return; }
      const squares = [...layer.querySelectorAll<HTMLButtonElement>('.promotion-square')];
      const at = squares.indexOf(document.activeElement as HTMLButtonElement);
      squares[(at + step + squares.length) % squares.length]?.focus();
    };
    layer.addEventListener('click', () => done(null));
    layer.addEventListener('contextmenu', (e) => { e.preventDefault(); done(null); });
    ROLES.forEach((role, i) => {
      const uci = options.find((u) => u[4] === role);
      if (!uci) return;
      const square = document.createElement('button');
      square.type = 'button';
      square.className = 'promotion-square';
      square.style.left = `${left}%`;
      square.style.top = `${(fromTop ? i : 7 - i) * 12.5}%`;
      square.setAttribute('aria-label', NAMES[role]);
      square.append(pieceImage(colour === 'white' ? role.toUpperCase() : role));
      square.addEventListener('click', (e) => { e.stopPropagation(); done(uci); });
      layer.append(square);
    });
    document.addEventListener('keydown', onKey, true);
    // With a pointer nothing is focused, so no piece looks chosen before the player picks.
    over.append(layer);
    if (keyboard) layer.querySelector<HTMLButtonElement>('.promotion-square')?.focus();
  });
}
