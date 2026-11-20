/**
 * What the page says about the data: waits, scores, clocks, seats and
 * results in plain words. Pure, so tests/games.ts covers it.
 */
import type { BoardName } from '../bughouse/types';
import type { Game, IndexEntry, Move, Seat, Waited } from './games';

export function seatLabel(seat: Seat): string {
  return `${seat[0]}-${seat.slice(1, 2).toUpperCase()}${seat.slice(2)}`;
}

export function sideName(colour: 'white' | 'black'): string { return colour === 'white' ? 'White' : 'Black'; }

/** `14.` for White's move, `14…` for Black's. */
export function moveNumber(num: number, white: boolean): string { return white ? `${num}.` : `${num}…`; }

/** `B 14. h3+`: how a game move is named in sentences. */
export function moveName(move: Move): string {
  return `${moveNumber(move.num, move.seat.endsWith('white'))} ${move.san}`;
}

/**
 * `waited.why` codes with a phrase; anything else reads "waited". These are
 * the builder's four codes (HypeBeast `scripts/collection/README.md`).
 */
const WAITS: Record<string, (s: string) => string> = {
  partner_mate: (s) => `sat ${s} while the partner mates, so no new piece reaches the other board`,
  mated: (s) => `sat ${s} rather than move into mate, while the partner plays on`,
  deny_feed: (s) => `sat ${s} so the opponent cannot capture the piece their partner needs`,
  wait_delivery: (s) => `sat ${s} for a piece the partner is about to capture`,
};
export const WAIT_CODES = Object.keys(WAITS);

export function seconds(s: number): string {
  const r = Math.round(s * 10) / 10;
  return `${Number.isInteger(r) ? r.toFixed(0) : r.toFixed(1)} s`;
}

export function waitPhrase(waited: Waited): string {
  const s = seconds(waited.seconds);
  return WAITS[waited.why]?.(s) ?? `waited ${s}`;
}

/**
 * Scores past this many centipawns show as `>+20` / `<−20`: near the end the
 * engines report thousands, which say "won" and nothing more. The exact
 * number stays on hover (`formatEval` without the cap).
 */
export const EVAL_CAP = 2000;

/** A score as Lichess writes it: `+1.8`, `−0.4`, `#3`, `#-2`; `–` when there is none. With `cap`, `>+20` beyond ±20. */
export function formatEval(cp: number | null, mate: number | null, cap = false): string {
  if (mate !== null) return `#${mate}`;
  if (cp === null) return '–';
  if (cap && Math.abs(cp) > EVAL_CAP) return cp > 0 ? `>+${EVAL_CAP / 100}` : `<−${EVAL_CAP / 100}`;
  const p = cp / 100;
  const text = Math.abs(p).toFixed(1);
  return p > 0 ? `+${text}` : p < 0 && text !== '0.0' ? `−${text}` : '0.0';
}

/** A forced mate in words, from the sign rule (positive: that board's White mates): `White mates in 3`. */
export function mateWords(mate: number): string {
  const n = Math.abs(mate);
  if (n === 0) return 'Mate on the board';
  return `${mate > 0 ? 'White' : 'Black'} mates in ${n}`;
}

/** A clock as `1:41`; under twenty seconds with tenths, `0:09.4`. */
export function formatClock(s: number): string {
  const t = Math.max(0, s);
  const m = Math.floor(t / 60);
  const rest = t - m * 60;
  if (t < 20) return `${m}:${rest.toFixed(1).padStart(4, '0')}`;
  return `${m}:${String(Math.floor(rest)).padStart(2, '0')}`;
}

/** Game time when a move was made, `0:36`. */
export function formatGameTime(t: number): string {
  const m = Math.floor(t / 60);
  return `${m}:${String(Math.floor(t - m * 60)).padStart(2, '0')}`;
}

/** The engines on each side: "X against Y", or "X and Y against Z" when a team mixes engines. */
export function playersLine(seats: Record<Seat, string>, teams: [[Seat, Seat], [Seat, Seat]] = [['Awhite', 'Bblack'], ['Ablack', 'Bwhite']]): string {
  const side = (team: [Seat, Seat]) => [...new Set(team.map((s) => seats[s]))].join(' and ');
  return `${side(teams[0])} against ${side(teams[1])}`;
}

const DEFAULT_TEAMS: [[Seat, Seat], [Seat, Seat]] = [['Awhite', 'Bblack'], ['Ablack', 'Bwhite']];

/** "A-Black and B-White win by checkmate", "Draw by repetition". */
export function resultLine(winner: 0 | 1 | null, how: string, teams: [[Seat, Seat], [Seat, Seat]] = DEFAULT_TEAMS): string {
  const by = how ? ` by ${how.replace(/_/g, ' ')}` : '';
  if (winner === null) return `Draw${by}`;
  const team = teams[winner];
  return `${seatLabel(team[0])} and ${seatLabel(team[1])} win${by}`;
}

export function entryResult(entry: IndexEntry): string { return resultLine(entry.winner, entry.how); }

export function gameResult(game: Game): string { return game.result.text || resultLine(game.result.winner, game.result.how, game.teams); }

/** "57 moves". */
export function lengthLine(moves: number): string {
  return `${moves} move${moves === 1 ? '' : 's'}`;
}

export function boardTitle(board: BoardName): string { return `Board ${board}`; }
