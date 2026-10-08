/**
 * Bughouse Puzzles: the puzzle data and one attempt at a puzzle, with no DOM.
 *
 * Every puzzle is one board of a real FICS bughouse game, mined by
 * `python3 -m bughouse_db puzzles`. The board's reserves are frozen: nothing
 * arrives from the partner, and a capture goes to the partner instead of the
 * capturer's hand. So a move here only ever removes pieces from a reserve.
 */
import { readBoard } from '../bughouse/setup';
import type { BoardName, Colour } from '../bughouse/types';

export interface Puzzle {
  id: string;
  /** This board's FEN with both reserves, solver to move. */
  fen: string;
  /** Both boards at the puzzle, for opening it in Bughouse Lab. */
  dual: string;
  board: BoardName;
  /** The opponent's move that led here, as UCI. */
  last: string | null;
  mate: number;
  /** Solver and defender moves alternately, as UCI; ends with the mate. */
  line: string[];
  san: string[];
  /** Legal moves at each solver step, space-separated UCI. */
  legal: string[];
  /** Every mating move at the last step; any of them solves it. */
  mates: string[];
  /** What the player actually played here, and whether it was the solution. */
  played: string | null;
  found: boolean;
  game: number;
  date: string;
  tc: string;
  white: string;
  black: string;
  welo: number;
  belo: number;
}

export interface PuzzleSet { version: 1; source: string; puzzles: Puzzle[] }

export interface Position {
  pieces: Record<string, string>;
  pockets: Record<Colour, string>;
  turn: Colour;
}

const FILES = 'abcdefgh';
const colourOf = (piece: string): Colour => (piece === piece.toUpperCase() ? 'white' : 'black');
const other = (c: Colour): Colour => (c === 'white' ? 'black' : 'white');

export function startPosition(fen: string): Position {
  const { pieces, pockets } = readBoard(fen);
  return { pieces, pockets, turn: fen.split(' ')[1] === 'b' ? 'black' : 'white' };
}

/** Play `uci` with the reserves frozen: captures leave the board for good. */
export function applyMove(pos: Position, uci: string): Position {
  const pieces = { ...pos.pieces };
  const pockets = { ...pos.pockets };
  const mover = pos.turn;
  if (uci[1] === '@') {
    const letter = uci[0];
    const piece = mover === 'white' ? letter.toUpperCase() : letter.toLowerCase();
    pieces[uci.slice(2, 4)] = piece;
    const at = pockets[mover].indexOf(piece);
    pockets[mover] = pockets[mover].slice(0, at) + pockets[mover].slice(at + 1);
  } else {
    const from = uci.slice(0, 2);
    const to = uci.slice(2, 4);
    const piece = pieces[from];
    const kind = piece.toLowerCase();
    // En passant: a pawn moving diagonally onto an empty square.
    if (kind === 'p' && from[0] !== to[0] && !pieces[to]) delete pieces[to[0] + from[1]];
    // Castling: the king moves two files and the rook jumps over it.
    if (kind === 'k' && Math.abs(FILES.indexOf(from[0]) - FILES.indexOf(to[0])) === 2) {
      const rank = from[1];
      const [rookFrom, rookTo] = to[0] === 'g' ? ['h', 'f'] : ['a', 'd'];
      pieces[rookTo + rank] = pieces[rookFrom + rank];
      delete pieces[rookFrom + rank];
    }
    delete pieces[from];
    const promo = uci[4];
    pieces[to] = promo ? (mover === 'white' ? promo.toUpperCase() : promo) : piece;
  }
  return { pieces, pockets, turn: other(mover) };
}

function attacked(pieces: Record<string, string>, square: string, by: Colour): boolean {
  const f = FILES.indexOf(square[0]);
  const r = Number(square[1]);
  const at = (df: number, dr: number) => {
    const ff = f + df;
    const rr = r + dr;
    return ff >= 0 && ff < 8 && rr >= 1 && rr <= 8 ? FILES[ff] + rr : null;
  };
  const is = (sq: string | null, kind: string) => !!sq && !!pieces[sq] && colourOf(pieces[sq]) === by && pieces[sq].toLowerCase() === kind;
  const forward = by === 'white' ? -1 : 1;
  if (is(at(-1, forward), 'p') || is(at(1, forward), 'p')) return true;
  if ([[1, 2], [2, 1], [-1, 2], [-2, 1], [1, -2], [2, -1], [-1, -2], [-2, -1]].some(([a, b]) => is(at(a, b), 'n'))) return true;
  for (let a = -1; a <= 1; a++) for (let b = -1; b <= 1; b++) if ((a || b) && is(at(a, b), 'k')) return true;
  const ray = (dirs: number[][], kinds: string) => dirs.some(([a, b]) => {
    for (let k = 1; k < 8; k++) {
      const sq = at(a * k, b * k);
      if (!sq) return false;
      const piece = pieces[sq];
      if (piece) return colourOf(piece) === by && kinds.includes(piece.toLowerCase());
    }
    return false;
  });
  return ray([[1, 0], [-1, 0], [0, 1], [0, -1]], 'rq') || ray([[1, 1], [1, -1], [-1, 1], [-1, -1]], 'bq');
}

/** Is the side to move in check? */
export function inCheck(pos: Position): boolean {
  const king = pos.turn === 'white' ? 'K' : 'k';
  const square = Object.keys(pos.pieces).find((sq) => pos.pieces[sq] === king);
  return !!square && attacked(pos.pieces, square, other(pos.turn));
}

/** A drop is written `N@f3`; normalize the letter so `n@f3` matches too. */
const norm = (uci: string) => (uci[1] === '@' ? uci[0].toUpperCase() + uci.slice(1) : uci);

export type Verdict = 'right' | 'wrong' | 'solved';

/**
 * One go at a puzzle. The solver plays with `play`; after a right move that
 * is not the last, the caller plays the defender's reply with `reply`.
 */
export class Attempt {
  pos: Position;
  /** How many moves of the line are on the board. */
  ply = 0;
  /** Any wrong move or a revealed solution makes the attempt a fail. */
  failed = false;
  /** Squares of the last move on the board. */
  last: string[];
  readonly solver: Colour;
  /** SAN of what was actually played, which differs from `san` only for another mate at the end. */
  readonly played: string[] = [];

  constructor(readonly puzzle: Puzzle) {
    this.pos = startPosition(puzzle.fen);
    this.solver = this.pos.turn;
    this.last = puzzle.last ? squaresOf(puzzle.last) : [];
  }

  get done(): boolean { return this.ply >= this.puzzle.line.length; }
  get solverToMove(): boolean { return !this.done && this.ply % 2 === 0; }
  get finalStep(): boolean { return this.ply === this.puzzle.line.length - 1; }

  /** Legal moves for the solver now (empty while the defender is to move). */
  legal(): string[] {
    return this.solverToMove ? (this.puzzle.legal[this.ply / 2] ?? '').split(' ').filter(Boolean) : [];
  }

  /** The moves that count as right at this step. */
  accepted(): string[] {
    return this.finalStep ? this.puzzle.mates.map(norm) : [norm(this.puzzle.line[this.ply])];
  }

  play(uci: string): Verdict {
    if (!this.solverToMove) return 'wrong';
    if (!this.accepted().includes(norm(uci))) { this.failed = true; return 'wrong'; }
    const isLine = norm(uci) === norm(this.puzzle.line[this.ply]);
    this.advance(uci, isLine ? this.puzzle.san[this.ply] : altSan(uci));
    return this.done ? 'solved' : 'right';
  }

  /** The defender's reply from the line; null if it is not their turn. */
  reply(): string | null {
    if (this.done || this.solverToMove) return null;
    const uci = this.puzzle.line[this.ply];
    this.advance(uci, this.puzzle.san[this.ply]);
    return uci;
  }

  /** Play the next move of the line whoever is to move (for "View solution"). */
  step(): boolean {
    if (this.done) return false;
    this.failed = true;
    this.advance(this.puzzle.line[this.ply], this.puzzle.san[this.ply]);
    return true;
  }

  private advance(uci: string, san: string) {
    this.pos = applyMove(this.pos, uci);
    this.last = squaresOf(uci);
    this.played.push(san);
    this.ply += 1;
  }
}

export function squaresOf(uci: string): string[] {
  return uci[1] === '@' ? [uci.slice(2, 4)] : [uci.slice(0, 2), uci.slice(2, 4)];
}

/** A mate other than the line's: its SAN is not in the data, so spell it simply. */
function altSan(uci: string): string {
  return uci[1] === '@' ? `${uci[0].toUpperCase()}@${uci.slice(2, 4)}#` : `${uci.slice(0, 2)}-${uci.slice(2, 4)}#`;
}

/** "2 0" — FICS writes a time control as minutes and increment seconds. */
export function formatTimeControl(tc: string): string {
  const [base, inc] = tc.split('+');
  const minutes = Number(base) / 60;
  return Number.isFinite(minutes) ? `${minutes} ${inc ?? 0}` : tc;
}

/**
 * The puzzle's real two-board position as a Bughouse Lab link. The Lab's
 * `team` is the colour our team holds on board A; partners hold opposite
 * colours, so a solver on board B is on the team that has the other colour on A.
 */
export function labLink(puzzle: Puzzle, solver: Colour): string {
  const team = puzzle.board === 'A' ? solver : other(solver);
  const session = {
    version: 1,
    line: { moves: [], upto: { A: 0, B: 0 }, focus: puzzle.board, root: puzzle.dual },
    settings: { team, required: 'none', budget: '10000', clock: 'even', flipped: false },
  };
  return `/bughouse#lab=${encodeURIComponent(JSON.stringify(session))}`;
}
