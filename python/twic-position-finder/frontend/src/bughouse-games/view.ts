/**
 * Where the reader is in a game, and what the two boards show there, with
 * no DOM. The cursor is a move of the game (-1 is the start) and, inside a
 * variation, one of that move's lines and a ply in it. A variation moves only
 * its own board; the other board stays as it stood where the line begins
 * (before or after the move, as the line says).
 */
import type { BoardName } from '../bughouse/types';
import { SEATS, type Game, type Line, type Seat } from './games';

export interface Cursor {
  /** Index into game.moves; -1 is the starting position. */
  move: number;
  /** Inside a variation: which of the move's lines, and how many of its moves are on the board (0 is the first). */
  line: { index: number; ply: number } | null;
}

export const START: Cursor = { move: -1, line: null };

export interface Shown {
  fen: Record<BoardName, string>;
  /** The last move on each board as UCI (a drop is `N@f3`), or null. */
  last: Record<BoardName, string | null>;
  /** Whether the side to move on each board is in check (from the last move's SAN). */
  check: Record<BoardName, boolean>;
  /** The board a variation is shown on, or null on the game itself. */
  variation: BoardName | null;
}

const checks = (san: string | undefined) => !!san && /[+#]$/.test(san);

/** The line the cursor is in, if any. */
export function lineAt(game: Game, cursor: Cursor): Line | null {
  if (!cursor.line) return null;
  return game.moves[cursor.move]?.lines[cursor.line.index] ?? null;
}

/** Both boards after move `at` (-1: the start). */
export function fensAt(game: Game, at: number): Record<BoardName, string> {
  return at >= 0 ? game.moves[at].fen : game.start;
}

/** The index of the last move made on `board` at or before `at`, or -1. */
export function lastMoveOn(game: Game, at: number, board: BoardName): number {
  for (let k = Math.min(at, game.moves.length - 1); k >= 0; k--) if (game.moves[k].board === board) return k;
  return -1;
}

/** Where a line begins in the game: the move before it, or the move itself. */
export function anchorOf(cursor: Cursor, line: Line): number {
  return line.from === 'before' ? cursor.move - 1 : cursor.move;
}

/** The game moment the clocks and the still board show: in a variation, where the line begins. */
export function momentOf(game: Game, cursor: Cursor): number {
  const line = lineAt(game, cursor);
  return line ? anchorOf(cursor, line) : cursor.move;
}

export function shown(game: Game, cursor: Cursor): Shown {
  const line = lineAt(game, cursor);
  const at = line ? anchorOf(cursor, line) : cursor.move;
  const fen = { ...fensAt(game, at) };
  const last = { A: null, B: null } as Shown['last'];
  const check = { A: false, B: false } as Shown['check'];
  for (const b of ['A', 'B'] as BoardName[]) {
    const k = lastMoveOn(game, at, b);
    if (k >= 0) { last[b] = game.moves[k].uci; check[b] = checks(game.moves[k].san); }
  }
  if (!line || !cursor.line) return { fen, last, check, variation: null };
  const b = line.board;
  const ply = Math.min(cursor.line.ply, line.moves.length - 1);
  if (ply < 0) {
    fen[b] = line.start;
    // At the line's start the board stands as the line found it.
    if (line.start !== fensAt(game, at)[b]) { last[b] = null; check[b] = false; }
  } else {
    fen[b] = line.moves[ply].fen;
    last[b] = line.moves[ply].uci;
    check[b] = checks(line.moves[ply].san);
  }
  return { fen, last, check, variation: b };
}

/** Each seat's clock at the cursor: the last recorded clocks at or before that moment, else the starting time. */
export function clocksAt(game: Game, cursor: Cursor): Record<Seat, number> {
  for (let k = Math.min(momentOf(game, cursor), game.moves.length - 1); k >= 0; k--) {
    const c = game.moves[k].clocks;
    if (c) return c;
  }
  return Object.fromEntries(SEATS.map((s) => [s, game.initial_clock])) as Record<Seat, number>;
}

export interface BoardEval { eval: number | null; mate: number | null; move: number }

/** The last score given on `board` at or before the cursor's moment, or null. */
export function evalOn(game: Game, cursor: Cursor, board: BoardName): BoardEval | null {
  for (let k = Math.min(momentOf(game, cursor), game.moves.length - 1); k >= 0; k--) {
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

/** One step forward (+1) or back (-1). In a variation it walks the line; back from its first move leaves it. */
export function step(game: Game, cursor: Cursor, delta: 1 | -1): Cursor {
  const line = lineAt(game, cursor);
  if (line && cursor.line) {
    const ply = cursor.line.ply + delta;
    if (ply < 0) return { move: cursor.move, line: null };
    return { move: cursor.move, line: { index: cursor.line.index, ply: Math.min(ply, line.moves.length - 1) } };
  }
  return { move: Math.max(-1, Math.min(game.moves.length - 1, cursor.move + delta)), line: null };
}

export function goTo(game: Game, move: number): Cursor {
  return { move: Math.max(-1, Math.min(game.moves.length - 1, move)), line: null };
}

export function home(): Cursor { return START; }
export function end(game: Game): Cursor { return goTo(game, game.moves.length - 1); }

/** Into a line of the current move, at one of its moves. */
export function enterLine(game: Game, cursor: Cursor, index: number, ply: number): Cursor {
  const line = game.moves[cursor.move]?.lines[index];
  if (!line) return cursor;
  return { move: cursor.move, line: { index, ply: Math.max(0, Math.min(ply, line.moves.length - 1)) } };
}

export function leaveLine(cursor: Cursor): Cursor { return { move: cursor.move, line: null }; }

/** The moves that carry a note, in order. */
export function notedMoves(game: Game): number[] {
  return game.moves.filter((m) => m.note).map((m) => m.i);
}

/** The next (+1) or previous (-1) move with a note from the cursor, or null when there is none that way. */
export function noteStep(game: Game, cursor: Cursor, delta: 1 | -1): Cursor | null {
  const noted = notedMoves(game);
  const at = delta > 0 ? noted.find((i) => i > cursor.move) : [...noted].reverse().find((i) => i < cursor.move);
  return at === undefined ? null : { move: at, line: null };
}

export function sameCursor(a: Cursor, b: Cursor): boolean {
  return a.move === b.move && a.line?.index === b.line?.index && a.line?.ply === b.line?.ply;
}

/** The board in focus: a variation's board, else the current move's board (A at the start). */
export function focusBoard(game: Game, cursor: Cursor): BoardName {
  return lineAt(game, cursor)?.board ?? game.moves[cursor.move]?.board ?? 'A';
}

/** Both boards on the bughouse analysis board, the focused one first (it opens large there). */
export function analysisLink(game: Game, cursor: Cursor): string {
  const { fen } = shown(game, cursor);
  const first = focusBoard(game, cursor);
  const second: BoardName = first === 'A' ? 'B' : 'A';
  return `/bughouse?fen=${encodeURIComponent(fen[first])}&fen2=${encodeURIComponent(fen[second])}`;
}
