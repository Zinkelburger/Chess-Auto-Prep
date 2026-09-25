import assert from 'node:assert/strict';
import { Lines } from '../src/bughouse/lines';
import { exportBpgn, parseSession, sessionHash, START_DUAL, type SavedSession } from '../src/bughouse/session';
import { parseReserve } from '../src/bughouse/setup';
import { BrowserEngine } from '../src/bughouse/engine';

const line = new Lines(START_DUAL);
line.play({ board: 'A', colour: 'white', num: 1, uci: 'e2e4', san: 'e4' });
line.play({ board: 'A', colour: 'black', num: 1, uci: 'd7d5', san: 'd5' });
line.play({ board: 'A', colour: 'white', num: 2, uci: 'e4d5', san: 'exd5' });
line.play({ board: 'B', colour: 'white', num: 1, uci: 'e2e4', san: 'e4' });
line.play({ board: 'B', colour: 'black', num: 1, uci: 'P@e6', san: 'P@e6' });
const accepted = line.snapshot();
for (let i = 0; i < 3; i++) {
  line.go('A', 2); line.restore(accepted);
  assert.equal(line.upto.A, 3);
  assert.equal(accepted.upto.A, 3, 'rejected undo must not mutate its rollback point');
}
line.moves[0].san = 'changed';
assert.equal(accepted.moves[0].san, 'e4');
line.restore(accepted);
const bpgn = exportBpgn(line);
assert.match(bpgn, /1A\. e4 1a\. d5 2A\. exd5 1B\. e4 1b\. P@e6/);
line.go('B', 1);
assert.ok(!exportBpgn(line).includes('1b. P@e6'), 'export only the played prefix visible on each board');
assert.equal(line.moves.length, 5, 'export/navigation retain the forward line');
const custom = new Lines('7k/P7/8/8/8/8/8/7K[] w - - 0 1|' + START_DUAL.split('|')[1]);
custom.play({ board: 'A', colour: 'white', num: 1, uci: 'a7a8n', san: 'a8=N' });
assert.match(exportBpgn(custom), /\[SetUp "1"\]/);
assert.match(exportBpgn(custom), /\[FEN "7k\/P7/);
assert.match(exportBpgn(custom), /1A\. a8=N/);
const saved: SavedSession = { version: 1, line: line.snapshot(), settings: { team: 'black', required: 'A', budget: '10000', clock: 'CD', flipped: true } };
assert.deepEqual(parseSession(decodeURIComponent(sessionHash(saved).slice(5))), saved);
for (const mutate of [
  (s: SavedSession) => { s.line.upto.A = 999; },
  (s: SavedSession) => { s.line.moves[0].san = '\n[Event "injected"]'; },
  (s: SavedSession) => { s.line.moves[0].uci = 'bad'; },
  (s: SavedSession) => { s.line.moves[0].num = -1; },
]) {
  const s = structuredClone(saved); mutate(s);
  assert.throws(() => parseSession(JSON.stringify(s)));
}
assert.ok('error' in parseReserve('999999999999999999999999999999N'));
assert.deepEqual(parseReserve('2N Q P'), { pieces: 'NNQP' });

// The client must reuse its worker for position edits, searches and Stop.
class FakeWorker {
  static all: FakeWorker[] = [];
  onmessage?: (event: { data: object }) => void;
  onerror?: () => void;
  messages: { id?: number; action: string }[] = [];
  terminated = false;
  constructor() { FakeWorker.all.push(this); }
  postMessage(message: { id?: number; action: string }) { this.messages.push(message); }
  terminate() { this.terminated = true; }
}
Object.assign(globalThis, { Worker: FakeWorker });
const client = new BrowserEngine(() => {});
const first = client.request('position', {});
const worker = FakeWorker.all[0];
worker.onmessage!({ data: { id: 1, result: 'position' } });
assert.equal(await first, 'position');
let partial = false;
const second = client.request('analyse', {}, () => { partial = true; });
worker.onmessage!({ data: { id: 2, partial: {} } });
assert.ok(partial);
client.cancel();
assert.equal(worker.messages.at(-1)?.action, 'cancel');
assert.equal(worker.terminated, false);
worker.onmessage!({ data: { id: 2, error: 'Analysis cancelled.' } });
await assert.rejects(second, /cancelled/);
const third = client.request('analyse', {});
worker.onmessage!({ data: { id: 3, result: 'reused' } });
assert.equal(await third, 'reused');
assert.equal(FakeWorker.all.length, 1);
console.log('Bughouse state, BPGN export, saved links, reserve validation and worker reuse passed.');
