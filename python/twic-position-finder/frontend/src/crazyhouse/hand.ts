/**
 * A hand drawn as lila's crazyhouse pocket (grey well, five slots, orange
 * counts), with a − and + under each piece to take one away or add one.
 * The side to move's pieces are dragged or clicked onto the board as usual.
 */
import type { Color, Role } from 'chessops/types';
import { HAND_ROLES, MAX_IN_HAND } from './tree';

const NAMES: Record<Role, string> = { pawn: 'pawn', knight: 'knight', bishop: 'bishop', rook: 'rook', queen: 'queen', king: 'king' };
const LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };

export interface HandView {
  color: Color;
  counts: Record<Role, number>;
  /** Whether a piece of this kind can be put on the board now. */
  usable: (role: Role) => boolean;
  /** Whether one more piece fits (the 64-piece limit). */
  roomForMore: boolean;
  picked: Role | null;
  /** The hand sits above the board: its +/− row goes on top. */
  top: boolean;
}

export interface HandHooks {
  adjust: (color: Color, role: Role, delta: 1 | -1) => void;
  drag: (color: Color, role: Role, e: MouseEvent | TouchEvent) => void;
  pick: (role: Role) => void;
}

export function renderHand(box: HTMLElement, view: HandView, hooks: HandHooks) {
  const side = view.color === 'white' ? 'White' : 'Black';
  const well = document.createElement('div');
  well.className = 'zh-pocket ch-well';
  well.setAttribute('role', 'group');
  well.setAttribute('aria-label', `${side}’s hand`);
  const adjust = document.createElement('div');
  adjust.className = 'ch-adjust';
  adjust.setAttribute('role', 'group');
  adjust.setAttribute('aria-label', `Change ${side.toLowerCase()}’s hand`);
  for (const role of HAND_ROLES) {
    const count = view.counts[role];
    const slot = document.createElement('button');
    slot.type = 'button';
    slot.className = 'zh-slot';
    slot.dataset.nb = String(count);
    slot.dataset.role = role;
    const img = document.createElement('img');
    img.src = `/piece/${view.color === 'white' ? 'w' : 'b'}${LETTER[role]}.svg`;
    img.alt = '';
    img.draggable = false;
    slot.append(img);
    if (count) {
      const nb = document.createElement('span');
      nb.className = 'zh-nb';
      nb.textContent = String(count);
      slot.append(nb);
    }
    slot.setAttribute('aria-label', `${side}: ${count} ${NAMES[role]}${count === 1 ? '' : 's'} in hand`);
    slot.setAttribute('aria-pressed', String(view.picked === role));
    slot.disabled = !count || !view.usable(role);
    if (!slot.disabled) {
      const pickUp = (e: MouseEvent | TouchEvent) => {
        if (e instanceof MouseEvent && e.button !== 0) return;
        e.preventDefault();
        hooks.drag(view.color, role, e);
      };
      slot.addEventListener('mousedown', pickUp);
      slot.addEventListener('touchstart', pickUp, { passive: false });
      slot.onclick = () => hooks.pick(role);
    }
    well.append(slot);

    const pair = document.createElement('div');
    pair.className = 'ch-adjust-pair';
    pair.append(
      stepButton('−', `One ${NAMES[role]} fewer for ${side.toLowerCase()}`, count <= 0, () => hooks.adjust(view.color, role, -1)),
      stepButton('+', `One more ${NAMES[role]} for ${side.toLowerCase()}`, count >= MAX_IN_HAND || !view.roomForMore, () => hooks.adjust(view.color, role, 1)),
    );
    adjust.append(pair);
  }
  box.classList.toggle('ch-hand-top', view.top);
  box.replaceChildren(...(view.top ? [adjust, well] : [well, adjust]));
}

function stepButton(text: string, label: string, disabled: boolean, onClick: () => void): HTMLButtonElement {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = 'ch-step';
  b.textContent = text;
  b.title = label;
  b.setAttribute('aria-label', label);
  b.disabled = disabled;
  b.onclick = onClick;
  return b;
}
