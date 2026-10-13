import { Chess, DEFAULT_POSITION } from 'chess.js';

export interface MoveNode { id: number; parent: number | null; fen: string; san: string; uci: string; comments: string[]; nags: string[]; children: number[] }
export interface Game { headers: Record<string, string>; nodes: MoveNode[]; result: string }
export const MAX_PGN_BYTES = 10 * 1024 * 1024;
const results = new Set(['1-0', '0-1', '1/2-1/2', '*']);

/** A bounded, variation-aware reader. Rejects a damaged import atomically. */
export function readPgn(text: string): Game[] {
  if (text.length > MAX_PGN_BYTES) throw new Error('Open a PGN smaller than 10 MB.');
  const tokens = text.replace(/^\uFEFF/, '').match(/\[(?:[^"\]]|"(?:\\.|[^"\\])*")*\]|\{[^}]*\}|;[^\r\n]*|\(|\)|\$\d+|[^\s(){};\[\]]+/g) ?? [];
  const games: Game[] = [];
  let game: Game | null = null;
  let headers: Record<string, string> = Object.create(null);
  let cursor = 0;
  let stack: number[] = [];
  let total = 0;
  const begin = () => {
    const chess = new Chess(headers.FEN || DEFAULT_POSITION);
    game = { headers, result: headers.Result || '*', nodes: [{ id: 0, parent: null, fen: chess.fen(), san: '', uci: '', comments: [], nags: [], children: [] }] };
    cursor = 0;
  };
  const finish = () => {
    if (stack.length) throw new Error('A PGN variation is missing its closing parenthesis.');
    if (game) { game.headers.Result = game.result; games.push(game); }
    game = null; headers = Object.create(null); cursor = 0;
  };
  for (const token of tokens) {
    if (token.startsWith('[')) {
      if (game) finish();
      const tag = /^\[(\w+)\s+"((?:\\.|[^"\\])*)"\s*\]$/.exec(token);
      if (!tag) throw new Error('A PGN header is malformed.');
      headers[tag[1]] = tag[2].replace(/\\(["\\])/g, '$1');
      continue;
    }
    if (!game) begin();
    const g = game! as Game;
    if (token.startsWith('{') || token.startsWith(';')) {
      g.nodes[cursor].comments.push(token.startsWith('{') ? token.slice(1, -1).trim() : token.slice(1).trim());
      continue;
    }
    if (token === '(') {
      if (cursor === 0 || stack.length >= 100) throw new Error('Invalid or excessively nested PGN variation.');
      stack.push(cursor); cursor = g.nodes[cursor].parent!; continue;
    }
    if (token === ')') {
      const previous = stack.pop();
      if (previous === undefined) throw new Error('A PGN variation has an extra closing parenthesis.');
      cursor = previous; continue;
    }
    if (token.startsWith('$') || /^[!?]+$/.test(token)) { g.nodes[cursor].nags.push(token); continue; }
    const san = token.replace(/^\d+\.(?:\.\.)?/, '').replace(/^\.\.\./, '');
    if (!san) continue;
    if (results.has(san)) {
      if (stack.length) continue;
      g.result = san; finish(); continue;
    }
    const chess = new Chess(g.nodes[cursor].fen);
    try {
      const move = chess.move(san);
      const id = g.nodes.length;
      const suffix = /[!?]+$/.exec(san)?.[0];
      g.nodes.push({ id, parent: cursor, fen: chess.fen(), san: move.san, uci: move.from + move.to + (move.promotion || ''), comments: [], nags: suffix ? [suffix] : [], children: [] });
      g.nodes[cursor].children.push(id); cursor = id;
    } catch { throw new Error(`Game ${games.length + 1}: cannot read “${san}”. Check the move or starting FEN.`); }
    if (++total > 40000) throw new Error('This PGN has more than 40,000 moves. Split it into smaller files.');
  }
  if (!game && Object.keys(headers).length) begin();
  finish();
  if (!games.length) throw new Error('No games found. Paste PGN moves or open a .pgn file.');
  return games;
}

export function moveLabel(node: MoveNode, game: Game): string {
  const before = game.nodes[node.parent ?? 0].fen.split(' ');
  return `${before[5]}${before[1] === 'w' ? '.' : '…'} ${node.san}`;
}

export function writePgn(games: Game[]): string {
  return games.map(g => {
    const headers = { ...g.headers, Result: g.result };
    const quote = (s: string) => s.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/[\r\n]/g, ' ');
    const comment = (s: string) => `{${s.replace(/[{}]/g, '')}}`;
    // Iterative traversal keeps long mainlines off the JS call stack.
    const out = g.nodes[0].comments.map(comment);
    const pending: (number | string)[] = g.nodes[0].children.length ? [g.nodes[0].children[0]] : [];
    while (pending.length) {
      const item = pending.pop()!;
      if (typeof item === 'string') { out.push(item); continue; }
      const n = g.nodes[item]; out.push(moveLabel(n, g).replace('…', '...'), ...n.nags, ...n.comments.map(comment));
      const children = n.children;
      if (children.length) pending.push(children[0]);
      // Variations are alternatives to the move just printed, before continuing.
      const siblings = g.nodes[n.parent!].children;
      if (siblings[0] === item) for (let i = siblings.length - 1; i >= 1; i--) pending.push(')', siblings[i], '(');
    }
    return Object.entries(headers).map(([k, v]) => `[${k} "${quote(v)}"]`).join('\n') + '\n\n' + out.join(' ') + ` ${g.result}`;
  }).join('\n\n');
}
