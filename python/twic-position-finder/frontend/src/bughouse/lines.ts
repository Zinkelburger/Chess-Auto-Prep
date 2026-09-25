import type { BoardName, Colour } from './types';

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

  snapshot() { return { moves: this.moves.map((move) => ({ ...move })), upto: { ...this.upto }, focus: this.focus, root: this.root }; }

  restore(s: ReturnType<Lines['snapshot']>) { Object.assign(this, { moves: s.moves.map((move) => ({ ...move })), upto: { ...s.upto }, focus: s.focus, root: s.root }); }
}

