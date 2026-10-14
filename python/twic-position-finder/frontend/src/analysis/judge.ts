/**
 * Lichess's winning chances (lila ui/lib/src/ceval/winningChances.ts) and the
 * two judgements built on them: live move marks (?!, ?, ??) and the verdicts
 * of "Practice with computer". Scores are from White's side.
 */
import type { Color } from 'chessops/types';

export interface Score { cp?: number; mate?: number }

export interface Glyph { symbol: '?!' | '?' | '??'; name: string }

export type Verdict = 'goodMove' | 'inaccuracy' | 'mistake' | 'blunder';

const raw = (cp: number) => 2 / (1 + Math.exp(-0.00368208 * cp)) - 1;

/** White's winning chances, from −1 (lost) to 1 (won). */
export function winningChances(score: Score): number {
  if (score.mate !== undefined) {
    const cp = (21 - Math.min(10, Math.abs(score.mate))) * 100;
    return raw(score.mate > 0 ? cp : -cp);
  }
  return raw(Math.min(1000, Math.max(-1000, score.cp ?? 0)));
}

export const povChances = (color: Color, score: Score) => (color === 'white' ? 1 : -1) * winningChances(score);

/** How much better `a` is than `b` for `color`, from −1 to 1. */
export const povDiff = (color: Color, a: Score, b: Score) => (povChances(color, a) - povChances(color, b)) / 2;

const GLYPHS: Record<Glyph['symbol'], Glyph> = {
  '?!': { symbol: '?!', name: 'Inaccuracy' },
  '?': { symbol: '?', name: 'Mistake' },
  '??': { symbol: '??', name: 'Blunder' },
};

/**
 * Lichess's live annotation of a move by `mover`: what it lost against the
 * engine's best score before it.
 */
export function liveGlyph(mover: Color, before: Score, after: Score): Glyph | undefined {
  const loss = povChances(mover, before) - povChances(mover, after);
  if (loss > 0.3) return GLYPHS['??'];
  if (loss > 0.2) return GLYPHS['?'];
  if (loss > 0.1) return GLYPHS['?!'];
  return undefined;
}

/** Lichess practice's verdict on the player's move. */
export function verdict(player: Color, before: Score, after: Score): Verdict {
  const shift = -povDiff(player, after, before);
  if (shift < 0.025) return 'goodMove';
  if (shift < 0.06) return 'inaccuracy';
  if (shift < 0.14) return 'mistake';
  return 'blunder';
}

export const VERDICT_TEXT: Record<Verdict, string> = {
  goodMove: 'Good move',
  inaccuracy: 'Inaccuracy',
  mistake: 'Mistake',
  blunder: 'Blunder',
};
