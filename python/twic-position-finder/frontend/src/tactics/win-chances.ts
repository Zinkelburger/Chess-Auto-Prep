/**
 * Lichess winning-chances model (scalachess `Eval.WinningChances`), also
 * used by the Dart app so the two miners agree on what a mistake is.
 * Thresholds are lila's `Advice.scala`: blunder ≥ 0.3, mistake ≥ 0.2,
 * inaccuracy ≥ 0.1 of winning chances lost.
 */

export const LICHESS_MULTIPLIER = -0.00368208;

/** [-1, 1] from the perspective of whoever [cp] is for. */
export function winningChances(cp: number): number {
  const capped = Math.max(-1000, Math.min(1000, cp));
  return 2 / (1 + Math.exp(LICHESS_MULTIPLIER * capped)) - 1;
}

export function winPercent(cp: number): number {
  return 50 + 50 * winningChances(cp);
}

/** Collapse a (cp | mate) score to a centipawn figure the model can eat. */
export function effectiveCp(score: { cp: number | null; mate: number | null }): number {
  if (score.mate !== null) return score.mate > 0 ? 1000 : -1000;
  return score.cp ?? 0;
}

export type Severity = 'blunder' | 'mistake' | 'inaccuracy' | null;

export function severityOf(delta: number): Severity {
  if (delta >= 0.3) return 'blunder';
  if (delta >= 0.2) return 'mistake';
  if (delta >= 0.1) return 'inaccuracy';
  return null;
}

export const SEVERITY_GLYPH: Record<Exclude<Severity, null>, string> = {
  blunder: '??',
  mistake: '?',
  inaccuracy: '?!',
};
