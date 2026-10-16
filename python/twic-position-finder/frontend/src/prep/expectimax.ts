/**
 * Practical expectimax, as the desktop app's interactive search
 * (docs/ALGORITHM.md, "V2 interactive Expectimax"): the prepared side plays
 * its best moves, the other side replies the way players at a rating do.
 *
 * - Our turn: Stockfish's MultiPV shortlist (Root moves for the first move,
 *   Candidates after it); a move is worth the best of what follows it.
 * - Their turn: Maia's likeliest replies until they cover the reply share,
 *   at most Max replies, renormalised to sum to one; a move is worth the
 *   average of its replies, weighted by those shares.
 * - A path met less than once in `rareOnceIn` games keeps its engine value.
 * - Leaves score U(cp) = 1 / (1 + e^(−0.00368208·cp)) from the prepared
 *   side; checkmate is 1 or 0 and every draw ½.
 *
 * The search runs breadth first, one ply at a time, so a stopped search
 * still holds every complete ply. An expansion is attached only once all its
 * moves are scored. Positions are searched once: a reply the next ply will
 * expand is searched with the shortlist's width straight away.
 *
 * Every value here is an expected score for the prepared side, a model
 * estimate rather than a measured win probability.
 */
import { makeSan } from 'chessops/san';
import type { EngineLine } from './stockfish';
import { fenOf, outcomeOf, positionOf, readMove } from './tree';

export type Side = 'white' | 'black';

export interface ExpectimaxOptions {
  /** Maia's rating for the replies. */
  elo: number;
  /** Half-moves past the position. */
  plies: number;
  /** Stockfish's depth for every position. */
  engineDepth: number;
  /** Our moves kept for the first move. */
  rootMoves: number;
  /** Our moves kept at every later move. */
  candidates: number;
  /** Replies kept until they cover this share of Maia's distribution. */
  replyMass: number;
  maxReplies: number;
  /** A path met less than once in this many games is not searched further; 0 searches every path. */
  rareOnceIn: number;
}

export const DEFAULT_OPTIONS: ExpectimaxOptions = {
  elo: 1600, plies: 4, engineDepth: 12, rootMoves: 4, candidates: 4, replyMass: 0.9, maxReplies: 5, rareOnceIn: 100,
};

/** Positions one side's search may hold, so a deep setting cannot run away. */
export const MAX_POSITIONS = 8000;

export interface XNode {
  fen: string;
  /** The move from the parent, standard UCI; empty at the root. */
  uci: string;
  san: string;
  /** Plies from the search's root. */
  ply: number;
  /** Stockfish's score of this position from White's side, in centipawns; mate is ±(10000 − moves). */
  cp: number;
  /** The expected score for the prepared side. */
  value: number;
  /** This reply's share among the kept replies, where the opponent plays it. */
  share?: number;
  /** The chance of reaching this position from the root, the product of the replies' shares. */
  reach: number;
  /** Maia's shares of the likeliest moves here, where the opponent is to move and the position was expanded. */
  policy?: Record<string, number>;
  terminal?: 'Checkmate' | 'Stalemate' | 'Draw';
  /** Undefined while the position is a leaf of the search. */
  children?: XNode[];
}

export interface XSearch {
  id: string;
  side: Side;
  options: ExpectimaxOptions;
  root: XNode;
  /** Plies searched completely. */
  reached: number;
  positions: number;
  state: 'running' | 'complete' | 'stopped' | 'failed';
  error?: string;
  millis: number;
  /** When the search started, for "most recent first". */
  at: number;
}

export interface XDeps {
  /** Stockfish's best `multiPv` lines at `depth`, scored from White's side; empty when there is no legal move. */
  lines(fen: string, multiPv: number, depth: number): Promise<EngineLine[]>;
  /** Maia's share of every legal move. */
  policy(fen: string, elo: number): Promise<Record<string, number>>;
  readonly signal: AbortSignal;
  /** A ply or an expansion finished; the trees changed. */
  progress(): void;
}

const SLOPE = 0.00368208;

export function utility(cp: number): number {
  if (Math.abs(cp) > 9000) return cp > 0 ? 1 : 0;
  return 1 / (1 + Math.exp(-SLOPE * cp));
}

/** An expected score written as the engine score it stands for, `+0.85`, so it reads beside Stockfish's. */
export function valueText(value: number): string {
  const v = Math.min(0.995, Math.max(0.005, value));
  const cp = -Math.log(1 / v - 1) / SLOPE;
  const pawns = (cp / 100).toFixed(2);
  if (pawns === '0.00' || pawns === '-0.00') return '0.00';
  return cp < 0 ? pawns : `+${pawns}`;
}

/** A line's score as packed centipawns from White's side. */
export function lineCp(line: Pick<EngineLine, 'cp' | 'mate'>): number {
  if (line.mate !== undefined) return Math.sign(line.mate || 1) * (10000 - Math.min(99, Math.abs(line.mate)));
  return line.cp ?? 0;
}

const turnOf = (fen: string): Side => (fen.split(' ')[1] === 'b' ? 'black' : 'white');
const forSide = (cp: number, side: Side) => (side === 'white' ? cp : -cp);

/** The exact value and score of a finished game, from the prepared side and from White's. */
function terminalOf(fen: string, side: Side): Pick<XNode, 'terminal' | 'value' | 'cp'> | null {
  const outcome = outcomeOf(fen);
  if (!outcome) return null;
  if (outcome !== 'Checkmate') return { terminal: outcome, value: 0.5, cp: 0 };
  const mated = turnOf(fen);
  return { terminal: outcome, value: mated === side ? 0 : 1, cp: mated === 'white' ? -10000 : 10000 };
}

/** The node a move leads to, scored by `cp` (White's side) unless the game ends there. */
function child(parent: XNode, uci: string, cp: number, side: Side, reach: number, share?: number): XNode | null {
  const pos = positionOf(parent.fen);
  const move = readMove(pos, uci);
  if (!move) return null;
  const san = makeSan(pos, move);
  pos.play(move);
  const fen = fenOf(pos);
  const end = terminalOf(fen, side);
  const node: XNode = { fen, uci, san, ply: parent.ply + 1, cp, value: utility(forSide(cp, side)), reach, ...(share !== undefined ? { share } : {}) };
  return end ? { ...node, ...end, children: [] } : node;
}

/** Recomputes values from the leaves up: the best of ours, the weighted average of theirs. */
export function backup(node: XNode, side: Side): number {
  if (!node.children?.length) return node.value;
  const values = node.children.map((c) => backup(c, side));
  node.value = turnOf(node.fen) === side
    ? Math.max(...values)
    : node.children.reduce((sum, c, i) => sum + (c.share ?? 0) * values[i], 0);
  return node.value;
}

/** The replies kept from Maia's shares: likeliest first, until they cover the share or reach the count, renormalised. */
export function keptReplies(shares: Record<string, number>, mass: number, max: number): [string, number][] {
  const sorted = Object.entries(shares).filter(([, s]) => s > 0).sort((a, b) => b[1] - a[1]);
  const kept: [string, number][] = [];
  let covered = 0;
  for (const [uci, share] of sorted) {
    if (kept.length >= max || covered >= mass) break;
    kept.push([uci, share]);
    covered += share;
  }
  return covered > 0 ? kept.map(([uci, s]) => [uci, s / covered]) : [];
}

/** Maia's likeliest moves as kept on a node for the table: those above half a percent, at most twelve. */
function topShares(shares: Record<string, number>): Record<string, number> {
  return Object.fromEntries(Object.entries(shares).filter(([, s]) => s >= 0.005).sort((a, b) => b[1] - a[1]).slice(0, 12));
}

let searchId = 0;

/** A new search for one side from a position; `run` fills it in. */
export function newSearch(fen: string, side: Side, options: ExpectimaxOptions): XSearch {
  const end = terminalOf(fen, side);
  const root: XNode = { fen, uci: '', san: '', ply: 0, cp: 0, value: 0.5, reach: 1, ...(end ? { ...end, children: [] } : {}) };
  return { id: `x${Date.now().toString(36)}${++searchId}`, side, options, root, reached: 0, positions: 1, state: 'running', millis: 0, at: Date.now() };
}

/** Searches one side ply by ply until its depth, a stop, or the position cap. Never throws: a failure is the search's state. */
export async function run(search: XSearch, deps: XDeps): Promise<XSearch> {
  const { side, options } = search;
  const started = performance.now();
  const floor = options.rareOnceIn > 0 ? 1 / options.rareOnceIn : 0;
  const ours = (fen: string) => turnOf(fen) === side;

  /** The engine's lines for a position, at the width its expansion will need. */
  const linesFor = (fen: string, width: number) => deps.lines(fen, Math.max(1, width), options.engineDepth);

  const expand = async (node: XNode) => {
    const level = node.ply;
    const deeper = (reach: number) => level + 1 < options.plies && reach >= floor;
    let children: XNode[];
    if (ours(node.fen)) {
      const lines = await linesFor(node.fen, level === 0 ? options.rootMoves : options.candidates);
      if (lines[0]) node.cp = lineCp(lines[0]);
      const seen = new Set<string>();
      children = [];
      for (const line of lines) {
        const uci = line.pv[0];
        if (!uci || seen.has(uci)) continue;
        seen.add(uci);
        const next = child(node, uci, lineCp(line), side, node.reach);
        if (next) children.push(next);
      }
    } else {
      const shares = await deps.policy(node.fen, options.elo);
      node.policy = topShares(shares);
      const kept = keptReplies(shares, options.replyMass, options.maxReplies);
      children = (await Promise.all(kept.map(async ([uci, share]) => {
        const next = child(node, uci, 0, side, node.reach * share, share);
        if (!next || next.terminal) return next;
        // A reply the next ply expands is searched with the shortlist's width now, so it is searched once.
        const lines = await linesFor(next.fen, deeper(next.reach) ? options.candidates : 1);
        if (!lines[0]) return next;
        next.cp = lineCp(lines[0]);
        next.value = utility(forSide(next.cp, side));
        return next;
      }))).filter((c): c is XNode => !!c);
    }
    if (deps.signal.aborted) return;
    node.children = children;
    search.positions += children.length;
    backup(search.root, side);
    search.millis = performance.now() - started;
    deps.progress();
  };

  try {
    const root = search.root;
    if (!root.terminal && !ours(root.fen)) {
      const lines = await linesFor(root.fen, 1);
      if (lines[0]) { root.cp = lineCp(lines[0]); root.value = utility(forSide(root.cp, side)); }
    }
    for (let level = search.reached; level < options.plies; level++) {
      const frontier: XNode[] = [];
      const walk = (n: XNode) => {
        if (n.ply === level) { if (!n.children && !n.terminal && (level === 0 || n.reach >= floor)) frontier.push(n); return; }
        n.children?.forEach(walk);
      };
      walk(root);
      if (!frontier.length) break;
      if (search.positions + frontier.length * options.maxReplies > MAX_POSITIONS) { search.error = `Stopped at ${MAX_POSITIONS.toLocaleString()} positions.`; break; }
      await Promise.all(frontier.map(expand));
      if (deps.signal.aborted) break;
      search.reached = level + 1;
      deps.progress();
    }
    search.state = deps.signal.aborted ? 'stopped' : 'complete';
  } catch (e) {
    search.state = deps.signal.aborted ? 'stopped' : 'failed';
    if (!deps.signal.aborted) search.error = (e as Error).message;
  }
  backup(search.root, side);
  search.millis = performance.now() - started;
  deps.progress();
  return search;
}
