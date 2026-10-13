import * as ort from 'onnxruntime-web/wasm';
import { EnginePool } from '../tactics/engine/engine-pool';
import { maiaInput, maiaShares } from './maia-input';
import { search, type SearchOptions, type SearchResult } from './search';
let pool: EnginePool | null = null;
let session: ort.InferenceSession | null = null;
let vocabulary: Record<string, number> = {};
let running = false;
let abort = new AbortController();
let activeId = 0;
const evaluations = new Map<string, number>();
const policies = new Map<string, Record<string, number>>();
const send = (data: object) => postMessage({ id: activeId, ...data });
const sha = async (data: ArrayBuffer) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', data))].map(b => b.toString(16).padStart(2, '0')).join('');
async function bytes(url: string): Promise<ArrayBuffer> {
  const response = await fetch(url, { signal: AbortSignal.any([abort.signal, AbortSignal.timeout(120000)]) });
  if (!response.ok) throw new Error('Could not download Maia. Check your connection and retry.');
  return response.arrayBuffer();
}
async function loadMaia() {
  if (session) return;
  send({ status: 'Loading Maia’s human-move model…' });
  const manifest = JSON.parse(new TextDecoder().decode(await bytes('/prep-engine/model.json')));
  let cache: Cache | null = null;
  try { cache = await caches.open('cap-maia-v1'); } catch { /* Optional download cache. */ }
  const buffers: ArrayBuffer[] = [];
  for (const [i, chunk] of manifest.chunks.entries()) {
    const url = '/prep-engine/' + chunk.file;
    let data: ArrayBuffer | undefined;
    try { data = await (await cache?.match(url))?.arrayBuffer(); } catch { cache = null; }
    if (!data || data.byteLength !== chunk.bytes || await sha(data) !== chunk.sha256) {
      send({ status: `Downloading Maia · part ${i + 1} of ${manifest.chunks.length}…` });
      data = await bytes(url);
      if (data.byteLength !== chunk.bytes || await sha(data) !== chunk.sha256) throw new Error('Maia download was incomplete. Retry the search.');
      try { await cache?.put(url, new Response(data)); } catch { /* Can run without cache. */ }
    }
    abort.signal.throwIfAborted(); buffers.push(data);
  }
  const model = await new Response(new Blob(buffers).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
  if (await sha(model) !== manifest.sha256) throw new Error('Maia’s checksum did not match. Retry the search.');
  vocabulary = JSON.parse(new TextDecoder().decode(await bytes('/prep-engine/' + manifest.vocabulary)));
  ort.env.wasm.numThreads = 1;
  ort.env.wasm.wasmPaths = '/bughouse-engine/';
  send({ status: 'Starting Maia…' });
  session = await ort.InferenceSession.create(model, { executionProviders: ['wasm'], graphOptimizationLevel: 'all', enableMemPattern: false });
}
async function policy(fen: string, elo: number): Promise<Record<string, number>> {
  const key = `${fen}|${elo}`;
  const cached = policies.get(key); if (cached) return cached;
  await loadMaia(); abort.signal.throwIfAborted();
  const input = maiaInput(fen);
  const feeds = { tokens: new ort.Tensor('float32', input.tokens, [1, 64, 12]), elo_self: new ort.Tensor('float32', [elo], [1]), elo_oppo: new ort.Tensor('float32', [elo], [1]) };
  let outputs: Record<string, ort.Tensor> = {};
  try {
    outputs = await session!.run(feeds);
    const shares = maiaShares(outputs[session!.outputNames[0]].data as Float32Array, input.moves, input.black, vocabulary);
    if (policies.size > 3000) policies.clear(); policies.set(key, shares); return shares;
  } finally { Object.values(feeds).forEach(t => t.dispose()); Object.values(outputs).forEach(t => t.dispose()); }
}
async function evaluate(fen: string, depth: number) {
  const key = `${fen}|${depth}`;
  const cached = evaluations.get(key); if (cached !== undefined) return cached;
  pool ??= new EnginePool(1, 32);
  const result = await pool.evaluate(fen, depth, abort.signal);
  if (result.depth < depth && result.mate === null) throw new Error(`Stockfish reached depth ${result.depth}, below the requested ${depth}. Reduce depth and retry.`);
  if (result.cp === null && result.mate === null) throw new Error('Stockfish returned no evaluation. Retry.');
  const cp = result.mate !== null ? (result.mate > 0 ? 1 : -1) * (10000 - Math.min(99, Math.abs(result.mate))) : result.cp!;
  if (evaluations.size > 10000) evaluations.clear(); evaluations.set(key, cp); return cp;
}
onmessage = async (event: MessageEvent<{ action: string; id: number; fen: string; options: SearchOptions; seed?: SearchResult }>) => {
  const { action, id, fen, options, seed } = event.data;
  if (action === 'stop') { abort.abort(); return; }
  if (running) return;
  running = true; abort = new AbortController(); activeId = id;
  let latest: SearchResult | undefined = seed;
  try {
    if (action === 'evaluate') {
      send({ status: 'Stockfish is analysing this position…' });
      const cp = await evaluate(fen, options.depth);
      send({ evaluation: { fen, cp, depth: options.depth } });
    } else {
      send({ status: 'Starting Stockfish…' });
      const result = await search(fen, options, {
        evaluate: position => evaluate(position, options.depth),
        policy: position => policy(position, options.elo),
        stopped: () => abort.signal.aborted,
        progress: result => { latest = result; send({ progress: result }); },
      }, seed);
      send({ result });
    }
  } catch (error) {
    if (abort.signal.aborted && latest) send({ result: { ...latest, reason: 'stopped' } });
    else send({ error: abort.signal.aborted ? 'Stopped. Ready for another search.' : (error as Error).message });
    if (!abort.signal.aborted) { pool?.dispose(); pool = null; }
  } finally { running = false; send({ done: true }); }
};
