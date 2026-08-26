/**
 * Turn one of the user's games into puzzles.
 *
 * Mirrors the Dart app's `_analyzeGameParallel`:
 *  1. Replay the game synchronously, collecting every position where the
 *     user was to move ("sites").
 *  2. Submit all sites to the engine pool at once so every worker stays busy.
 *  3. Per site: search the position before the move. If the user played the
 *     engine's own choice, stop — no winning chances were lost. Otherwise
 *     search the position after and compare winning chances.
 *
 * Two shortcuts on top of that:
 *  - Lichess `[%eval]` annotations (server analysis) settle most sites with
 *    no engine at all; only candidates that lost ≥ inaccuracy threshold are
 *    searched, and only to obtain the best line.
 *  - Opening positions are memoised across games (TacticsStore).
 */
import { Chess } from 'chess.js';
import type { EnginePool } from './engine/engine-pool';
import { EngineAbortError, type EvalResult } from './engine/uci-worker';
import type { ParsedPgn, PgnEval } from './pgn';
import type { TacticsStore } from './store';
import { effectiveCp, severityOf, winPercent, winningChances, type Severity } from './win-chances';

export type Source = 'lichess' | 'chesscom';

/** Max user moves the trainer will ask for in one puzzle (Flutter: 5). */
const MAX_TRAINABLE_USER_MOVES = 5;

/** Captures, checks and mates are the only replies safe to assume forced. */
const isTacticalSan = (san: string) => san.includes('x') || san.includes('+') || san.includes('#');

/**
 * How many plies of the engine line the puzzle should actually train.
 *
 * A port of the Dart `TacticsEngine._buildTrainableLineFallback` heuristic:
 * start with the one move that was scored, then extend by an opponent reply +
 * user move only while both the current and the next user move are forcing.
 * Anything quieter is the engine's opinion, not a tactic, so a second "right
 * answer" there would be unfair. Always odd — the line ends on a user move.
 */
export function trainablePlyCount(pvSan: string[]): number {
  if (pvSan.length === 0) return 0;
  let plies = 1;
  let userMoves = 1;
  let i = 0;
  while (userMoves < MAX_TRAINABLE_USER_MOVES) {
    if (!isTacticalSan(pvSan[i])) break;
    if (i + 2 >= pvSan.length) break;
    if (!isTacticalSan(pvSan[i + 2])) break;
    plies += 2;
    userMoves++;
    i += 2;
  }
  return plies;
}

export interface GameMeta {
  source: Source;
  id: string;
  url: string;
  white: string;
  black: string;
  whiteElo: number | null;
  blackElo: number | null;
  result: string;
  date: string;
  timeClass: string;
  /** SAN mainline of the whole game. */
  moves: string[];
}

export interface Puzzle {
  /** Stable id: `${source}:${gameId}:${ply}`. */
  id: string;
  fen: string;
  /** 0-based ply index of the user's move in the game. */
  ply: number;
  moveNumber: number;
  color: 'white' | 'black';
  userMoveSan: string;
  userMoveUci: string;
  /** Engine line from [fen], UCI and SAN. */
  bestLineUci: string[];
  bestLineSan: string[];
  severity: Exclude<Severity, null>;
  /** Win % for the user before and after the move. */
  winBefore: number;
  winAfter: number;
  /** Centipawns from White's perspective before and after (±1000 = mate). */
  cpBeforeWhite: number;
  cpAfterWhite: number;
  game: GameMeta;
}

interface Site {
  ply: number;
  moveNumber: number;
  fenBefore: string;
  fenAfter: string;
  san: string;
  uci: string;
  endsGame: boolean;
  /** White-perspective annotations from the PGN, if any. */
  evalBefore: PgnEval | null;
  evalAfter: PgnEval | null;
}

export interface MineOptions {
  pool: EnginePool;
  store: TacticsStore;
  depth: number;
  signal?: AbortSignal;
  /** Which severities become puzzles. */
  minSeverity: 'mistake' | 'inaccuracy';
  onSite?: (done: number, total: number) => void;
}

export interface MineResult {
  puzzles: Puzzle[];
  sites: number;
  /** How many sites needed no engine search. */
  shortcuts: number;
}

export function userColorOf(headers: Record<string, string>, username: string): 'w' | 'b' | null {
  const u = username.trim().toLowerCase();
  if (!u) return null;
  if ((headers.White ?? '').trim().toLowerCase() === u) return 'w';
  if ((headers.Black ?? '').trim().toLowerCase() === u) return 'b';
  return null;
}

function toUserPerspective(score: PgnEval, userIsWhite: boolean): number {
  const cp = effectiveCp(score);
  return userIsWhite ? cp : -cp;
}

/** Winning-chances delta of a move from the user's perspective. */
function lostChances(cpBefore: number, cpAfter: number): number {
  return winningChances(cpBefore) - winningChances(cpAfter);
}

function severityPasses(s: Severity, min: MineOptions['minSeverity']): s is Exclude<Severity, null> {
  if (s === null) return false;
  if (min === 'inaccuracy') return true;
  return s !== 'inaccuracy';
}

/** UCI → SAN along a line from [fen]; stops at the first illegal move. */
export function lineToSan(fen: string, uci: string[]): string[] {
  const out: string[] = [];
  let chess: Chess;
  try {
    chess = new Chess(fen);
  } catch {
    return out;
  }
  for (const m of uci) {
    try {
      const mv = chess.move({ from: m.slice(0, 2), to: m.slice(2, 4), promotion: m[4] });
      out.push(mv.san);
    } catch {
      break;
    }
  }
  return out;
}

/** FEN after [uci] from [fen], or null if illegal. */
function fenAfter(fen: string, uci: string): string | null {
  try {
    const chess = new Chess(fen);
    chess.move({ from: uci.slice(0, 2), to: uci.slice(2, 4), promotion: uci[4] });
    return chess.fen();
  } catch {
    return null;
  }
}

function collectSites(game: ParsedPgn, userColor: 'w' | 'b'): { sites: Site[]; sans: string[] } {
  const chess = new Chess();
  const sites: Site[] = [];
  const sans: string[] = [];
  let prevEval: PgnEval | null = null;
  for (let ply = 0; ply < game.moves.length; ply++) {
    const { san, evalAfter } = game.moves[ply];
    const fenBefore = chess.fen();
    const moveNumber = chess.moveNumber();
    const isUser = chess.turn() === userColor;
    let mv;
    try {
      mv = chess.move(san);
    } catch {
      break; // unparsable move: keep what we have
    }
    sans.push(mv.san);
    if (isUser) {
      sites.push({
        ply,
        moveNumber,
        fenBefore,
        fenAfter: chess.fen(),
        san: mv.san,
        uci: mv.from + mv.to + (mv.promotion ?? ''),
        endsGame: chess.isGameOver(),
        evalBefore: prevEval,
        evalAfter,
      });
    }
    prevEval = evalAfter;
  }
  return { sites, sans };
}

export async function mineGame(
  game: ParsedPgn, meta: GameMeta, userColor: 'w' | 'b', opts: MineOptions,
): Promise<MineResult> {
  const { pool, store, depth, signal } = opts;
  const userIsWhite = userColor === 'w';
  const { sites } = collectSites(game, userColor);
  let done = 0;
  let shortcuts = 0;
  const report = () => opts.onSite?.(++done, sites.length);

  async function search(fen: string): Promise<EvalResult> {
    const cached = await store.getEval(fen, depth);
    if (cached) return cached;
    const r = await pool.evaluate(fen, depth, signal);
    store.putEval(fen, depth, r);
    return r;
  }

  /** Side-to-move score → user's perspective. */
  const userCp = (r: EvalResult, sideToMoveIsUser: boolean) =>
    sideToMoveIsUser ? effectiveCp(r) : -effectiveCp(r);

  async function evaluateSite(site: Site): Promise<Puzzle | null> {
    if (signal?.aborted) throw new EngineAbortError();
    if (site.endsGame) {
      shortcuts++;
      return null;
    }

    // Shortcut 1: PGN annotations settle the verdict without an engine.
    // (Only when both sides of the move are annotated; the start position
    // of an unannotated ply 0 has no "before" eval.)
    let cpBefore: number | null = null;
    let cpAfter: number | null = null;
    let engineBefore: EvalResult | null = null;
    if (site.evalBefore && site.evalAfter) {
      const b = toUserPerspective(site.evalBefore, userIsWhite);
      const a = toUserPerspective(site.evalAfter, userIsWhite);
      if (!severityPasses(severityOf(lostChances(b, a)), opts.minSeverity)) {
        shortcuts++;
        return null;
      }
      // A candidate: the engine still has to supply the best line.
      engineBefore = await search(site.fenBefore);
      cpBefore = userCp(engineBefore, true);
      cpAfter = a;
    } else if (site.ply === 0 && site.evalAfter) {
      // Opening move with an annotation after it: treat the start as equal.
      const a = toUserPerspective(site.evalAfter, userIsWhite);
      if (!severityPasses(severityOf(lostChances(15, a)), opts.minSeverity)) {
        shortcuts++;
        return null;
      }
    }

    engineBefore ??= await search(site.fenBefore);
    cpBefore ??= userCp(engineBefore, true);

    // Shortcut 2: the user played the engine's own move — nothing lost.
    const best = engineBefore.pv[0] ?? engineBefore.bestMove;
    if (best && (best === site.uci || fenAfter(site.fenBefore, best) === site.fenAfter)) {
      shortcuts++;
      return null;
    }
    if (!best) return null;

    if (cpAfter === null) {
      const engineAfter = await search(site.fenAfter);
      cpAfter = userCp(engineAfter, false);
    }

    const severity = severityOf(lostChances(cpBefore, cpAfter));
    if (!severityPasses(severity, opts.minSeverity)) return null;

    const bestLineUci = engineBefore.pv.slice(0, 8);
    const bestLineSan = lineToSan(site.fenBefore, bestLineUci);
    if (bestLineSan.length === 0) return null;
    return {
      id: `${meta.source}:${meta.id}:${site.ply}`,
      fen: site.fenBefore,
      ply: site.ply,
      moveNumber: site.moveNumber,
      color: userIsWhite ? 'white' : 'black',
      userMoveSan: site.san,
      userMoveUci: site.uci,
      bestLineUci: bestLineUci.slice(0, bestLineSan.length),
      bestLineSan,
      severity,
      winBefore: winPercent(cpBefore),
      winAfter: winPercent(cpAfter),
      cpBeforeWhite: userIsWhite ? cpBefore : -cpBefore,
      cpAfterWhite: userIsWhite ? cpAfter : -cpAfter,
      game: meta,
    };
  }

  const results = await Promise.all(sites.map(async (site) => {
    try {
      return await evaluateSite(site);
    } finally {
      report();
    }
  }));

  return {
    puzzles: results.filter((p): p is Puzzle => p !== null),
    sites: sites.length,
    shortcuts,
  };
}
