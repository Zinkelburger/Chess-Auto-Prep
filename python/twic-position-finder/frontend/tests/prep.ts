import assert from 'node:assert/strict';
import { Chess } from 'chess.js';
import { readPgn, writePgn } from '../src/prep/pgn';
import { maiaInput, maiaShares, mirrorMove } from '../src/prep/maia-input';
import { DEFAULT_OPTIONS, keptReplies, lineCp, newSearch, run, utility, valueText } from '../src/prep/expectimax';
import { rows } from '../src/prep/expectimax-view';
import { START_FEN, Tree, commentText, outcomeOf, playLine, threatFen } from '../src/prep/tree';
import { mineGame } from '../src/tactics/miner';
import type { EnginePool } from '../src/tactics/engine/engine-pool';
import type { TacticsStore } from '../src/tactics/store';

const input = '[Event "A \\"quoted\\" event"]\n[White "<script>bad</script>"]\n\n{Root note} 1.e4! {Main} (1. d4 d5 (1... Nf6) 2.c4) 1...e5 2.Nf3 $1 Nc6 *\n\n[Event "Game two"]\n1.d4 d5 1/2-1/2';
const games = readPgn(input);
assert.equal(games.length, 2);
assert.equal(games[0].nodes[0].children.length, 2);
assert.deepEqual(readPgn(writePgn(games)), games, 'PGN round trip preserves variations, comments, NAGs, headers and results');
for (const pgn of ['1. e4 (1. d4', '1. e4 )', '1. e9', 'not pgn']) assert.throws(() => readPgn(pgn));
assert.throws(() => readPgn('a'.repeat(10 * 1024 * 1024 + 1)));
const promotion = readPgn('[SetUp "1"]\n[FEN "7k/P7/8/8/8/8/8/7K w - - 0 1"]\n1.a8=N *')[0];
assert.equal(promotion.nodes[1].uci, 'a7a8n');
const custom = readPgn('[FEN "7k/8/8/8/8/8/p7/7K b - - 0 37"]\n37...a1=Q+ *')[0];
assert.equal(custom.nodes[1].uci, 'a2a1q');
const long = readPgn(Array.from({length: 1000}, () => 'Nf3 Nf6 Ng1 Ng8').join(' ') + ' *');
assert.equal(readPgn(writePgn(long))[0].nodes.length, 4001);
console.log('PGN mainlines, nested variations, FEN, promotion, long games, errors and round trips passed.');

const initial = new Chess().fen();
const white = maiaInput(initial), black = maiaInput(initial.replace(' w ', ' b '));
assert.deepEqual(white.tokens, black.tokens);
assert.equal(white.tokens.reduce((a,b) => a+b), 32);
assert.equal(mirrorMove('e8g8'), 'e1g1'); assert.equal(mirrorMove('a2a1n'), 'a7a8n');
const distribution = maiaShares(new Float32Array([0, Math.log(3)]), ['e7e5', 'd7d5'], true, { e2e4: 0, d2d4: 1 });
assert.ok(Math.abs(distribution.e7e5 - .25) < 1e-7);
assert.throws(() => maiaShares(new Float32Array([NaN]), ['e2e4'], false, { e2e4: 0 }));
console.log('Maia encoding, colour mirroring, castling, promotions and legal softmax passed.');

// The analysis tree: PGN in and out with comments, glyphs and variations; standard UCI for castling.
const tree = Tree.fromPgn('[White "A"]\n[Black "B"]\n{Intro} 1.e4 $1 {Best by test} (1.d4 {Queen pawn} d5) 1...e5 2.Nf3 Nc6 3.Bc4 Nf6 4.O-O *')!.tree;
assert.equal(tree.root.comments?.[0], 'Intro');
const e4node = tree.root.children[0];
assert.deepEqual([e4node.san, e4node.nags, e4node.comments], ['e4', [1], ['Best by test']]);
assert.equal(tree.root.children[1].children[0].san, 'd5');
const castle = tree.lineEnd(tree.root.id);
assert.equal(castle.uci, 'e1g1', 'castling is kept as the king’s two-square step');
assert.equal(tree.play(tree.parent(castle.id)!.id, 'e1h1'), castle, 'both forms of castling find the same move');
const again = Tree.fromPgn(tree.pgn())!.tree;
assert.equal(again.pgn(), tree.pgn(), 'PGN round trip keeps comments, glyphs and variations');
assert.equal(again.headers.get('White'), 'A');
assert.deepEqual(tree.indexPath(castle.id), [0, 0, 0, 0, 0, 0, 0]);
assert.equal(tree.follow([1, 0]).san, 'd5');
const bad = Tree.fromPgn('1.e4 e5 2.Ke3 Nc6 *')!;
assert.equal(bad.skipped, 1);
assert.equal(bad.tree.lineEnd(bad.tree.root.id).san, 'e5', 'an illegal move ends the line it is on');
const custom960 = Tree.fromPgn('[FEN "7k/P7/8/8/8/8/8/7K w - - 0 1"]\n[SetUp "1"]\n1.a8=Q+ *')!.tree;
assert.equal(custom960.root.children[0].uci, 'a7a8q');
assert.match(custom960.pgn(), /\[FEN "7k\/P7/);
assert.equal(playLine(START_FEN, ['e2e4', 'e7e5', 'e1e2', 'zz'])[2].san, 'Ke2');
assert.equal(playLine(START_FEN, ['e2e4', 'e7e5', 'e1e2', 'zz']).length, 3);
assert.equal(threatFen('4k3/8/8/8/8/8/8/4K2r w - - 0 1'), null, 'no threat when the other side would be in check');
assert.equal(outcomeOf('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1'), 'Stalemate');
assert.equal(outcomeOf('8/8/8/8/8/8/8/K6k w - - 0 1'), 'Draw');
assert.equal(commentText('[%clk 0:03:00] Good [%eval 0.3]'), 'Good');
console.log('Analysis tree, PGN round trip, castling, illegal moves, custom starts and comments passed.');

// Expectimax: our turns take the best of the shortlist, theirs the renormalised average of Maia's likeliest replies.
assert.equal(utility(0), 0.5);
assert.equal(utility(9999), 1);
assert.equal(valueText(0.5), '0.00');
assert.equal(valueText(0.49999), '0.00', 'no minus sign on a level score');
assert.equal(lineCp({ mate: 3 }), 9997);
assert.equal(lineCp({ mate: -2 }), -9998);
assert.deepEqual(keptReplies({ a: 0.5, b: 0.3, c: 0.15, d: 0.05 }, 0.9, 5).map(([u]) => u), ['a', 'b', 'c']);
assert.deepEqual(keptReplies({ a: 0.5, b: 0.3, c: 0.15 }, 0.9, 2).map(([, s]) => Math.round(s * 1000)), [625, 375]);
const after = (fen: string, uci: string) => playLine(fen, [uci])[0].fen;
const scores = new Map<string, number>();
let engineCalls = 0;
const fakeLines = async (fen: string, width: number) => {
  engineCalls++;
  const pos = new Chess(fen);
  // A position in `scores` is worth that whatever is played; elsewhere White likes e4 (+50) and d4 (+30).
  const own = scores.get(fen);
  return pos.moves({ verbose: true }).map((m) => {
    const uci = m.from + m.to + (m.promotion ?? '');
    const cp = own ?? scores.get(after(fen, uci)) ?? (uci === 'e2e4' ? 50 : uci === 'd2d4' ? 30 : 0);
    return { multipv: 0, depth: 8, cp, pv: [uci] };
  }).sort((a, b) => (fen.includes(' w ') ? b.cp - a.cp : a.cp - b.cp)).slice(0, width).map((l, i) => ({ ...l, multipv: i + 1 }));
};
const xdeps = (signal = new AbortController().signal) => ({
  signal,
  lines: (fen: string, width: number) => fakeLines(fen, width),
  policy: async (fen: string) => (fen.includes(' w ') ? { e2e4: 0.6, d2d4: 0.3, c2c4: 0.1 } : { e7e5: 0.6, c7c5: 0.3, e7e6: 0.1 }) as Record<string, number>,
  progress: () => {},
});
const opts = { ...DEFAULT_OPTIONS, plies: 2, rootMoves: 2, candidates: 2, maxReplies: 2 };
const e4fen = after(START_FEN, 'e2e4');
scores.set(after(e4fen, 'e7e5'), 80);
scores.set(after(e4fen, 'c7c5'), -40);
const xw = await run(newSearch(START_FEN, 'white', opts), xdeps());
assert.equal(xw.state, 'complete');
assert.equal(xw.reached, 2);
const xe4 = xw.root.children!.find((c) => c.uci === 'e2e4')!;
assert.equal(xe4.children!.length, 2, 'two replies kept');
assert.ok(Math.abs(xe4.children![0].share! - 2 / 3) < 1e-12, 'kept shares renormalised');
assert.ok(Math.abs(xe4.value - (2 / 3 * utility(80) + 1 / 3 * utility(-40))) < 1e-12, 'their move is the weighted average');
assert.equal(xw.root.value, Math.max(...xw.root.children!.map((c) => c.value)), 'our move is the best of the shortlist');
assert.ok(xw.root.children!.every((c) => c.policy), 'their positions keep Maia’s shares for the table');
const xb = await run(newSearch(START_FEN, 'black', opts), xdeps());
assert.equal(xb.root.children!.length, 2, 'White’s first move is a Maia reply when Black is prepared');
const table = rows({ white: { node: xw.root, search: xw }, black: { node: xb.root, search: xb } }, 'white');
assert.equal(table[0].uci, xw.root.children!.slice().sort((a, b) => b.value - a.value)[0].uci, 'the board side’s best move leads the table');
assert.ok(table.some((r) => r.white !== undefined && r.black !== undefined), 'a move both searches hold has both values');
const mated = await run(newSearch('7k/6Q1/6K1/8/8/8/8/8 b - - 0 1', 'white', opts), xdeps());
assert.equal(mated.root.value, 1);
assert.equal(mated.root.terminal, 'Checkmate');
const stopper = new AbortController();
const stopped = await run(newSearch(START_FEN, 'white', opts), { ...xdeps(stopper.signal), lines: async (f: string, w: number) => { stopper.abort(); return fakeLines(f, w); } });
assert.equal(stopped.state, 'stopped');
assert.equal(stopped.root.children, undefined, 'an expansion is attached whole or not at all');
const failing = await run(newSearch(START_FEN, 'white', opts), { ...xdeps(), lines: async () => { throw new Error('engine unavailable'); } });
assert.equal(failing.state, 'failed');
assert.equal(failing.error, 'engine unavailable');
const rare = await run(newSearch(START_FEN, 'white', { ...opts, plies: 4, rareOnceIn: 2 }), xdeps());
const rareLeaf = rare.root.children![0].children!.find((c) => c.reach < 0.5)!;
assert.equal(rareLeaf.children, undefined, 'a rare line keeps its engine score');
console.log('Expectimax recurrence, reply cut, both sides, table rows, terminals, stop, failure and rare lines passed.');

// A custom PGN start reaches the engine as that position, not the initial board.
const seen: string[] = [];
const fen = '7k/8/8/8/8/8/6Q1/6K1 w - - 0 12';
await mineGame({ headers: { FEN: fen }, moves: [{ san: 'Qf2', evalAfter: null }] }, { source: 'pgn', id: 'fixture', url: '', white: 'White', black: 'Black', whiteElo: null, blackElo: null, result: '*', date: '', timeClass: '', moves: ['Qf2'] }, 'w', {
  pool: { evaluate: async (position: string) => { seen.push(position); return { cp: 100, mate: null, depth: 8, bestMove: 'g2f2', pv: ['g2f2'] }; } } as unknown as EnginePool,
  store: { getEval: async () => null, putEval: () => {} } as unknown as TacticsStore, depth: 8, signal: new AbortController().signal, minSeverity: 'mistake',
});
assert.equal(seen[0], fen);
console.log('Imported tactics honor custom FEN starts.');
