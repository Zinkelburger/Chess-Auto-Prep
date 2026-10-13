import assert from 'node:assert/strict';
import { Chess } from 'chess.js';
import { readPgn, writePgn } from '../src/prep/pgn';
import { maiaInput, maiaShares, mirrorMove } from '../src/prep/maia-input';
import { search, utility, type SearchOptions, type SearchDependencies } from '../src/prep/search';
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

const options: SearchOptions = { side: 'w', plies: 1, depth: 8, elo: 1600, maxNodes: 100, maxReplies: 2, replyMass: .9 };
let calls = 0;
const deps: SearchDependencies = { evaluate: async fen => { calls++; return fen.includes('4P3') ? -100 : 0; }, policy: async () => ({ e7e5: .6, c7c5: .3, e7e6: .1 }), stopped: () => false, progress: () => {} };
let result = await search(initial, options, deps);
assert.equal(result.nodes, 21); assert.equal(result.reason, 'complete'); assert.equal(result.root.children.length, 20);
assert.ok(Math.abs(result.root.value - utility(100)) < 1e-12, 'our move maximizes, engine score converted from side to move');
const e4 = new Chess(); e4.move('e4');
result = await search(e4.fen(), options, { ...deps, evaluate: async fen => fen.includes('4p3') ? 100 : 0 });
assert.equal(result.root.children.length, 2);
assert.ok(Math.abs(result.root.children[0].probability - 2/3) < 1e-12);
assert.ok(Math.abs(result.root.value - (2/3 * utility(100) + 1/3 * .5)) < 1e-12, 'opponent turn uses renormalized weighted expectation');
const budget = await search(initial, { ...options, maxNodes: 10 }, deps);
assert.equal(budget.reason, 'budget'); assert.equal(budget.nodes, 1); assert.equal(budget.root.children.length, 0);
result = await search(initial, options, deps, budget);
assert.equal(result.nodes, 21); assert.equal(result.reason, 'complete');
await assert.rejects(search(initial, { ...options, elo: 2000 }, deps, budget), /settings/);
await assert.rejects(search(initial, { ...options, maxNodes: 5 }, deps, budget), /increase/);
let stop = false;
result = await search(initial, options, { ...deps, evaluate: async () => { stop = true; return 0; }, stopped: () => stop });
assert.equal(result.reason, 'stopped'); assert.equal(result.root.children.length, 0);
const checkmate = '7k/6Q1/6K1/8/8/8/8/8 b - - 0 1';
calls = 0; result = await search(checkmate, options, deps); assert.equal(result.root.value, 1); assert.equal(calls, 0);
result = await search('7k/5Q2/6K1/8/8/8/8/8 b - - 0 1', options, deps); assert.equal(result.root.value, .5);
await assert.rejects(search(initial, options, { ...deps, evaluate: async () => { throw new Error('engine unavailable'); } }), /engine unavailable/);
console.log('Expectimax perspective, max/average recurrence, truncation, terminal positions, atomic budget, stop and resume passed.');

// A custom PGN start reaches the engine as that position, not the initial board.
const seen: string[] = [];
const fen = '7k/8/8/8/8/8/6Q1/6K1 w - - 0 12';
await mineGame({ headers: { FEN: fen }, moves: [{ san: 'Qf2', evalAfter: null }] }, { source: 'pgn', id: 'fixture', url: '', white: 'White', black: 'Black', whiteElo: null, blackElo: null, result: '*', date: '', timeClass: '', moves: ['Qf2'] }, 'w', {
  pool: { evaluate: async (position: string) => { seen.push(position); return { cp: 100, mate: null, depth: 8, bestMove: 'g2f2', pv: ['g2f2'] }; } } as unknown as EnginePool,
  store: { getEval: async () => null, putEval: () => {} } as unknown as TacticsStore, depth: 8, signal: new AbortController().signal, minSeverity: 'mistake',
});
assert.equal(seen[0], fen);
console.log('Imported tactics honor custom FEN starts.');
