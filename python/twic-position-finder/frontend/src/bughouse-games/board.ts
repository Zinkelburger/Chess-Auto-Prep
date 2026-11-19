/**
 * One board of a game, for reading only: chessground with each side's
 * reserve as lila's pocket above and below it, and at the end of each
 * pocket's row the seat's engine over its clock (DESIGN.md, "Bughouse
 * reserve"). Nothing here can be moved; every position is a FEN given to it.
 */
import { Chessground } from '@lichess-org/chessground';
import '@lichess-org/chessground/assets/chessground.base.css';
import '@lichess-org/chessground/assets/chessground.brown.css';
import '@lichess-org/chessground/assets/chessground.cburnett.css';
import type { Api } from '@lichess-org/chessground/api';
import type { Key } from '@lichess-org/chessground/types';
import { placement } from '../bughouse/boards';
import { renderPocket } from '../bughouse/pocket';
import { readBoard } from '../bughouse/setup';
import type { Colour } from '../bughouse/types';
import { seatLabel } from './words';
import type { Seat } from './games';

export interface SeatView { seat: Seat; name: string; clock: string; toMove: boolean }

export interface BoardView {
  fen: string;
  bottom: Colour;
  last: string | null;
  check: boolean;
  seats: Record<Colour, SeatView>;
}

const squares = (uci: string | null): Key[] => (!uci ? [] : uci[1] === '@' ? [uci.slice(2, 4) as Key] : [uci.slice(0, 2) as Key, uci.slice(2, 4) as Key]);

export class GameBoard {
  private readonly cg: Api;

  constructor(boardEl: HTMLElement, private readonly rows: { top: HTMLElement; bottom: HTMLElement }) {
    this.cg = Chessground(boardEl, {
      viewOnly: true,
      coordinates: true,
      highlight: { lastMove: true, check: true },
      animation: { enabled: true, duration: 160 },
      drawable: { enabled: false, visible: true },
    });
    const resized = new ResizeObserver(() => this.cg.redrawAll());
    resized.observe(boardEl);
    resized.observe(rows.top);
  }

  render(v: BoardView) {
    const { pieces, pockets } = readBoard(v.fen);
    const turn: Colour = v.fen.split(' ')[1] === 'b' ? 'black' : 'white';
    this.cg.set({
      fen: placement(pieces),
      orientation: v.bottom,
      turnColor: turn,
      lastMove: squares(v.last),
      check: v.check ? turn : false,
    });
    const top: Colour = v.bottom === 'white' ? 'black' : 'white';
    this.renderRow(this.rows.top, top, pockets[top], v.seats[top]);
    this.renderRow(this.rows.bottom, v.bottom, pockets[v.bottom], v.seats[v.bottom]);
  }

  private renderRow(box: HTMLElement, colour: Colour, pocket: string, seat: SeatView) {
    const label = seatLabel(seat.seat);
    const well = renderPocket({
      colour, pocket, owner: label, selected: null,
      usable: () => false, onDrag: () => {}, onPick: () => {},
    });
    const who = document.createElement('div');
    who.className = 'bg-who';
    const name = document.createElement('span');
    name.className = 'bg-who-name';
    name.textContent = seat.name;
    name.title = `${label}: ${seat.name}`;
    const clock = document.createElement('span');
    clock.className = 'bg-clock num';
    clock.textContent = seat.clock;
    clock.setAttribute('aria-label', `${label} clock ${seat.clock}`);
    who.append(name, clock);
    box.classList.toggle('to-move', seat.toMove);
    box.replaceChildren(well, who);
  }
}
