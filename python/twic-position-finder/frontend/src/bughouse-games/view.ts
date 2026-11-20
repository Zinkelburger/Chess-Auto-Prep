/**
 * Where the reader is in a game, and what the two boards show there, with
 * no DOM. The cursor is a move of the game (-1 is the start).
 */
import type { BoardName } from '../bughouse/types';
import { SEATS, type Game, type Seat } from './games';

export interface Cursor {
  /** Index into game.moves; -1 is the starting position. */
  move: number;
}

export const START: Cursor = { move: -1 };

export interface Shown {
  fen: Record<BoardName, string>;
  /** The last move on each board as UCI (a drop is `N@f3`), or null. */
  last: Record<BoardName, string | null>;
  /** Whether the side to move on each board is in check (from the last move's SAN). */
  check: Record<BoardName, boolean>;
}

const checks = (san: string | undefined) => !!san && /[+#]$/.test(san);

/** Both boards after move `at` (-1: the start). */
export function fensAt(game: Game, at: number): Record<BoardName, string> {
  return at >= 0 ? game.moves[at].fen : game.start;
}

/** The index of the last move made on `board` at or before `at`, or -1. */
export function lastMoveOn(game: Game, at: number, board: BoardName): number {
  for (let k = Math.min(at, game.moves.length - 1); k >= 0; k--) if (game.moves[k].board === board) return k;
  return -1;
}

export function shown(game: Game, cursor: Cursor): Shown {
  const fen = { ...fensAt(game, cursor.move) };
  const last = { A: null, B: null } as Shown['last'];
  const check = { A: false, B: false } as Shown['check'];
  for (const b of ['A', 'B'] as BoardName[]) {
    const k = lastMoveOn(game, cursor.move, b);
    if (k >= 0) { last[b] = game.moves[k].uci; check[b] = checks(game.moves[k].san); }
  }
  return { fen, last, check };
}

/** Each seat's clock at the cursor: the last recorded clocks at or before it, else the starting time. */
export function clocksAt(game: Game, cursor: Cursor): Record<Seat, number> {
  for (let k = Math.min(cursor.move, game.moves.length - 1); k >= 0; k--) {
    const c = game.moves[k].clocks;
    if (c) return c;
  }
  return Object.fromEntries(SEATS.map((s) => [s, game.initial_clock])) as Record<Seat, number>;
}

export interface BoardEval { eval: number | null; mate: number | null; move: number }

/** The last score given on `board` at or before the cursor, or null. */
export function evalOn(game: Game, cursor: Cursor, board: BoardName): BoardEval | null {
  for (let k = Math.min(cursor.move, game.moves.length - 1); k >= 0; k--) {
    const m = game.moves[k];
    if (m.board === board && (m.eval !== null || m.mate !== null)) return { eval: m.eval, mate: m.mate, move: k };
  }
  return null;
}

/** The side to move on a board, from its FEN. */
export function turnOf(fen: string): 'white' | 'black' {
  return fen.split(' ')[1] === 'b' ? 'black' : 'white';
}

// ── Moving the cursor ─────────────────────────────────────────────

/** One step forward (+1) or back (-1). */
export function step(game: Game, cursor: Cursor, delta: 1 | -1): Cursor {
  return goTo(game, cursor.move + delta);
}

export function goTo(game: Game, move: number): Cursor {
  return { move: Math.max(-1, Math.min(game.moves.length - 1, move)) };
}

export function home(): Cursor { return START; }
export function end(game: Game): Cursor { return goTo(game, game.moves.length - 1); }

export function sameCursor(a: Cursor, b: Cursor): boolean {
  return a.move === b.move;
}

/** The board in focus: the current move's board (A at the start). */
export function focusBoard(game: Game, cursor: Cursor): BoardName {
  return game.moves[cursor.move]?.board ?? 'A';
}
/** Both boards on the bughouse analysis board, the focused one first (it opens large there). */
export function analysisLink(game: Game, cursor: Cursor): string {
  const { fen } = shown(game, cursor);
  const first = focusBoard(game, cursor);
  const second: BoardName = first === 'A' ? 'B' : 'A';
  return `/bughouse?fen=${encodeURIComponent(fen[first])}&fen2=${encodeURIComponent(fen[second])}`;
}
