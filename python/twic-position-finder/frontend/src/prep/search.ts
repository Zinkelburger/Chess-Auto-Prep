import { Chess } from 'chess.js';
export interface SearchOptions { side: 'w' | 'b'; plies: number; depth: number; elo: number; maxNodes: number; maxReplies: number; replyMass: number }
export interface SearchNode { fen: string; san: string; uci: string; value: number; cp: number; probability: number; children: SearchNode[]; expanded: boolean; terminal: boolean; ply: number }
export interface SearchResult { root: SearchNode; nodes: number; expanded: number; reason: 'complete' | 'budget' | 'stopped'; options: SearchOptions }
export interface SearchDependencies { evaluate: (fen: string) => Promise<number>; policy: (fen: string) => Promise<Record<string, number>>; stopped: () => boolean; progress: (result: SearchResult) => void }
export function utility(cp: number): number { return Math.abs(cp) > 9000 ? (cp > 0 ? 1 : 0) : 1 / (1 + Math.exp(-0.00368208 * cp)); }
export function backup(node: SearchNode, side: 'w' | 'b'): number {
  if (!node.children.length) return node.value;
  node.value = node.fen.split(' ')[1] === side ? Math.max(...node.children.map(c => c.value)) : node.children.reduce((sum, c) => sum + c.value * c.probability, 0);
  return node.value;
}
/** Breadth-first, atomic expansions; our turns maximize, opponent turns average Maia replies. */
export async function search(fen: string, options: SearchOptions, deps: SearchDependencies, seed?: SearchResult): Promise<SearchResult> {
  const evaluate = async (position: string, san = '', uci = '', ply = 0, probability = 1): Promise<SearchNode> => {
    const chess = new Chess(position);
    const sign = chess.turn() === options.side ? 1 : -1;
    const terminal = chess.isCheckmate() || chess.isDraw();
    const cp = chess.isCheckmate() ? -10000 * sign : chess.isDraw() ? 0 : await deps.evaluate(position) * sign;
    return { fen: position, san, uci, ply, probability, cp, value: utility(cp), children: [], expanded: terminal, terminal };
  };
  const result: SearchResult = seed ? structuredClone(seed) : { root: await evaluate(fen), nodes: 1, expanded: 0, reason: 'complete', options };
  if (seed && options.maxNodes < seed.options.maxNodes) throw new Error('Keep or increase the saved position budget to resume.');
  if (seed && (seed.root.fen !== fen || JSON.stringify({ ...seed.options, maxNodes: options.maxNodes }) !== JSON.stringify(options))) throw new Error('Saved search settings do not match. Start a new search.');
  const queue: { node: SearchNode; ancestors: SearchNode[] }[] = [{ node: result.root, ancestors: [] }];
  result.reason = 'complete'; result.options = options;
  for (let at = 0; at < queue.length; at++) {
    await new Promise(resolve => setTimeout(resolve, 0));
    const { node, ancestors } = queue[at];
    if (deps.stopped()) { result.reason = 'stopped'; break; }
    if (node.ply >= options.plies || node.terminal) continue;
    if (node.expanded) { for (const child of node.children) queue.push({ node: child, ancestors: [...ancestors, node] }); continue; }
    const chess = new Chess(node.fen), ours = chess.turn() === options.side;
    let moves = chess.moves({ verbose: true }).map(m => ({ san: m.san, uci: m.from + m.to + (m.promotion || ''), fen: m.after, share: 1 }));
    if (!ours) {
      const shares = await deps.policy(node.fen);
      if (deps.stopped()) { result.reason = 'stopped'; break; }
      moves = moves.map(m => ({ ...m, share: shares[m.uci] ?? 0 })).sort((a, b) => b.share - a.share);
      let mass = 0;
      moves = moves.filter((m, i) => { const keep = i < options.maxReplies && mass < options.replyMass && m.share > 0; if (keep) mass += m.share; return keep; });
      if (!mass) throw new Error('Maia did not return legal replies. Retry the search.');
      moves = moves.map(m => ({ ...m, share: m.share / mass }));
    }
    if (result.nodes + moves.length > options.maxNodes) { result.reason = 'budget'; break; }
    const children: SearchNode[] = [];
    for (const m of moves) {
      if (deps.stopped()) break;
      children.push(await evaluate(m.fen, m.san, m.uci, node.ply + 1, m.share));
    }
    if (deps.stopped()) { result.reason = 'stopped'; break; }
    node.children = children; node.expanded = true; result.nodes += children.length; result.expanded++;
    backup(node, options.side);
    for (let i = ancestors.length - 1; i >= 0; i--) backup(ancestors[i], options.side);
    for (const child of children) queue.push({ node: child, ancestors: [...ancestors, node] });
    deps.progress(structuredClone(result));
  }
  return result;
}
