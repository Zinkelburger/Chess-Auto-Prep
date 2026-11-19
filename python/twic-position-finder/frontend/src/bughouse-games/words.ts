/**
 * What the page says about the data: line kinds, waits, scores, clocks,
 * seats and results in plain words. Pure, so tests/games.ts covers it.
 */
import type { BoardName } from '../bughouse/types';
import type { Game, IndexEntry, Line, Move, Seat, Waited } from './games';

const PIECE: Record<string, [string, string]> = {
  p: ['a pawn', 'pawns'], n: ['a knight', 'knights'], b: ['a bishop', 'bishops'], r: ['a rook', 'rooks'], q: ['a queen', 'queens'],
};
const COUNT = ['', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight'];

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

/** "a rook", "two knights and a pawn": pieces as words, from FEN letters of one colour. */
function piecesInWords(letters: string): string {
  const counts = new Map<string, number>();
  for (const c of letters.toLowerCase()) counts.set(c, (counts.get(c) ?? 0) + 1);
  const parts = ['q', 'r', 'b', 'n', 'p'].filter((p) => counts.has(p)).map((p) => {
    const n = counts.get(p)!;
    return n === 1 ? PIECE[p][0] : `${COUNT[n] ?? n} ${PIECE[p][1]}`;
  });
  return parts.length > 1 ? `${parts.slice(0, -1).join(', ')} and ${parts.at(-1)}` : parts[0] ?? '';
}

/**
 * What a line supposes the partner delivers, in a sentence:
 * `R` → "Supposes White's partner first delivers a rook." Empty for none.
 */
export function assumePhrase(assume: string): string {
  if (!assume) return '';
  const white = [...assume].filter((c) => c === c.toUpperCase()).join('');
  const black = [...assume].filter((c) => c !== c.toUpperCase()).join('');
  if (white && black) return `Supposes White first receives ${piecesInWords(white)} and Black ${piecesInWords(black)} from their partners.`;
  return `Supposes ${white ? 'White' : 'Black'}’s partner first delivers ${piecesInWords(white || black)}.`;
}

/** The heading of a line: its kind in plain words. */
export function kindTitle(line: Line, move: Move): string {
  switch (line.kind) {
    case 'played': return 'Expected continuation';
    case 'instead': return `Instead of ${move.san}`;
    case 'threat': return 'Threat';
    case 'arrives': return line.assume ? `If ${piecesInWords(line.assume)} arrives` : 'If a piece arrives';
    default: return 'Line';
  }
}

/** Where a line starts and what it shows, in one sentence. */
export function lineContext(line: Line, move: Move): string {
  const side = sideName(line.start.split(' ')[1] === 'b' ? 'black' : 'white');
  const where = `${line.from === 'before' ? 'Before' : 'After'} ${moveName(move)}, on board ${line.board}`;
  switch (line.kind) {
    case 'played': return `${where}: what the engine expected to follow.`;
    case 'instead': return `${where}: another first move, and the engine’s answer to it.`;
    case 'threat': return `${where}: what ${side} would play with a free move.`;
    case 'arrives': return `${where}: the engine’s plan if the piece reaches the hand.`;
    default: return `${where}.`;
  }
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

/** A score for reading: a mate in words, else the capped score. */
export function scoreWords(cp: number | null, mate: number | null): string {
  return mate !== null ? mateWords(mate) : formatEval(cp, null, true);
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

/** "57 moves · 13 notes". */
export function lengthLine(moves: number, notes: number): string {
  return `${moves} move${moves === 1 ? '' : 's'} · ${notes ? `${notes} note${notes === 1 ? '' : 's'}` : 'no notes'}`;
}

export function boardTitle(board: BoardName): string { return `Board ${board}`; }

/** Line moves with move numbers, from the line's starting FEN: number before White's moves and before the first. */
export function lineTokens(line: Line): { ply: number; number: string; san: string }[] {
  const parts = line.start.split(' ');
  let white = parts[1] !== 'b';
  let num = Number(parts[5]) || 1;
  return line.moves.map((m, ply) => {
    const number = white ? `${num}.` : ply === 0 ? `${num}…` : '';
    if (!white) num += 1;
    white = !white;
    return { ply, number, san: m.san };
  });
}
