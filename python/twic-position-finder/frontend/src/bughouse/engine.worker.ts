import type { Analysis, EngineAction, EnginePayload, JointMove } from './types';
import * as ort from 'onnxruntime-web/wasm';

interface Wasm {
  HEAPF32: Float32Array;
  cancelled: boolean;
  inferenceError?: string;
  infer: (...args: number[]) => Promise<void>;
  ccall: (name: string, result: string | null, types: string[], args: unknown[], options?: { async: boolean }) => string | Promise<string>;
}
interface Chunk { file: string; sha256: string; bytes: number }
interface Manifest { model_sha256: string; chunks: Chunk[]; input: string; outputs: Record<string, string> }
interface Search {
  q: number; mate: number | null; nodes: number; elapsed_ms?: number; best: JointMove | null; pv?: string[]; lines: { best: JointMove | null }[]; error?: string;
}
let modulePromise: Promise<Wasm> | null = null;
let sessionPromise: Promise<ort.InferenceSession> | null = null;
let active = false;
let cancelled = false;
let downloadController: AbortController | null = null;
const analysisCache = new Map<string, Analysis>();
const directory = '/bughouse-engine/';
const progress = (message: string) => postMessage({ progress: message });

async function module(): Promise<Wasm> {
  if (!modulePromise) {
    modulePromise = (async () => {
      progress('Loading the browser engine…');
      const url = directory + 'hivemind.mjs';
      const { default: createHivemind } = await import(/* @vite-ignore */ url);
      const engine: Wasm = await createHivemind();
      engine.ccall('bh_init', null, [], []);
      return engine;
    })().catch((error) => { modulePromise = null; throw error; });
  }
  return modulePromise;
}

async function sha256(buffer: ArrayBuffer): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', buffer))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** The chunk kept in this browser, or null when it has to be downloaded. */
async function cachedChunk(chunk: Chunk, cache: Cache | null): Promise<ArrayBuffer | null> {
  const url = directory + chunk.file;
  const response = await cache?.match(url);
  if (!response) return null;
  const buffer = await response.arrayBuffer();
  if (buffer.byteLength === chunk.bytes && await sha256(buffer) === chunk.sha256) return buffer;
  await cache?.delete(url);
  return null;
}

/** Abort includes the response body; a stalled transfer cannot lock the page forever. */
async function fetchBytes(url: string, millis = 120_000): Promise<ArrayBuffer> {
  const controller = new AbortController();
  downloadController = controller;
  const timer = setTimeout(() => controller.abort(), millis);
  try {
    if (cancelled) throw new Error('Analysis cancelled.');
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error('The engine download failed. Check your connection and retry.');
    return await response.arrayBuffer();
  } catch (error) {
    if (cancelled) throw new Error('Analysis cancelled. Downloaded parts are kept for next time.');
    if (controller.signal.aborted) throw new Error('The engine download timed out. Please retry.');
    throw error;
  } finally {
    clearTimeout(timer);
    if (downloadController === controller) downloadController = null;
  }
}

async function downloadChunk(chunk: Chunk, cache: Cache | null): Promise<ArrayBuffer> {
  const url = directory + chunk.file;
  const buffer = await fetchBytes(url);
  if (buffer.byteLength !== chunk.bytes || await sha256(buffer) !== chunk.sha256)
    throw new Error('The engine download was incomplete. Please retry.');
  try { await cache?.put(url, new Response(buffer)); } catch { /* Private mode/quota: still run in memory. */ }
  return buffer;
}

async function session(engine: Wasm): Promise<ort.InferenceSession> {
  if (!sessionPromise) {
    sessionPromise = (async () => {
      const manifest: Manifest = JSON.parse(new TextDecoder().decode(await fetchBytes(directory + 'model.json', 30_000)));
      let cache: Cache | null = null;
      try { cache = await caches.open('hivemind-model-v1'); } catch { /* Cache is optional. */ }
      // Only a part missing from this browser's cache is downloaded, and only
      // then does the message speak of a download: once kept, it never repeats.
      progress('Starting Hivemind…');
      const buffers: ArrayBuffer[] = [];
      for (let i = 0; i < manifest.chunks.length; i++) {
        let buffer: ArrayBuffer | null = null;
        try { buffer = await cachedChunk(manifest.chunks[i], cache); } catch { cache = null; }
        if (!buffer) {
          progress(`Downloading Hivemind’s network · part ${i + 1} of ${manifest.chunks.length} (about 32 MB, once)`);
          buffer = await downloadChunk(manifest.chunks[i], cache);
        }
        buffers.push(buffer);
        if (cancelled) throw new Error('Analysis cancelled. Downloaded parts are kept for next time.');
      }
      if (cancelled) throw new Error('Analysis cancelled.');
      progress('Starting Hivemind…');
      const stream = new Blob(buffers).stream().pipeThrough(new DecompressionStream('gzip'));
      const model = await new Response(stream).arrayBuffer();
      if (await sha256(model) !== manifest.model_sha256) throw new Error('The network checksum did not match. Please reload.');
      // A single WASM inference thread works on ordinary Cloudflare Pages:
      // no SharedArrayBuffer, COOP/COEP, GPU, server or remote model required.
      if (cancelled) throw new Error('Analysis cancelled.');
      ort.env.wasm.numThreads = 1;
      ort.env.wasm.wasmPaths = directory;
      const network = await ort.InferenceSession.create(model, { executionProviders: ['wasm'], graphOptimizationLevel: 'all' });
      engine.infer = async (input, batch, value, policyA, policyB, wdl, movesLeft) => {
        // ORT's CPU promise can settle in the same microtask turn. Yield a
        // real event-loop task so Stop messages arrive between evaluations.
        await new Promise((resolve) => setTimeout(resolve, 0));
        const data = engine.HEAPF32.slice(input / 4, input / 4 + batch * 74 * 64);
        const tensor = new ort.Tensor('float32', data, [batch, 74, 8, 8]);
        let result: Record<string, ort.Tensor> = {};
        try {
          result = await network.run({ [manifest.input]: tensor });
          const destinations: Record<string, [number, number]> = {
            value: [value, batch], policyA: [policyA, batch * 4672], policyB: [policyB, batch * 4672],
            wdl: [wdl, batch * 3], movesLeft: [movesLeft, batch],
          };
          for (const [name, [pointer, length]] of Object.entries(destinations)) {
            const output = result[manifest.outputs[name]];
            if (!output || output.type !== 'float32' || output.data.length !== length)
              throw new Error(`Unexpected network output: ${name}`);
            engine.HEAPF32.set(output.data as Float32Array, pointer / 4);
          }
        } finally {
          tensor.dispose();
          for (const tensor of Object.values(result)) tensor.dispose();
        }
      };
      return network;
    })().catch((error) => { sessionPromise = null; throw error; });
  }
  return sessionPromise;
}

async function request(id: number, action: EngineAction, payload: EnginePayload) {
  const engine = await module();
  engine.cancelled = false;
  const team = payload.team === 'black' ? 1 : 0;
  if (action === 'position') {
    const text = engine.ccall('bh_position', 'string', ['string', 'string', 'number'],
      [payload.dual_fen ?? '', (payload.moves ?? []).join(' '), team]);
    const position = JSON.parse(text as string);
    if (position.error) throw new Error(position.error);
    return position;
  }
  const cacheKey = JSON.stringify(payload);
  const cached = action === 'analyse' ? analysisCache.get(cacheKey) : undefined;
  if (cached) { progress('Using analysis saved in this tab.'); return { ...cached, cached: true }; }
  await session(engine);
  if (cancelled) throw new Error('Analysis cancelled.');
  if (action === 'search') {
    // Exactly one node-budgeted search for `team`; raw result including pv.
    const text = await engine.ccall('bh_search_nodes', 'string',
      ['string', 'number', 'number', 'number', 'number', 'number'],
      [payload.dual_fen ?? '', team, Number(payload.time_advantage ?? false), 0,
        payload.nodes ?? 1000, payload.movetime_ms ?? 60000], { async: true });
    const answer: Search = JSON.parse(text as string);
    if (engine.inferenceError) { const error = engine.inferenceError; engine.inferenceError = undefined; throw new Error(error); }
    if (answer.error) throw new Error(answer.error);
    if (cancelled) throw new Error('Analysis cancelled.');
    return answer;
  }
  const search = async (side: number, ahead: boolean, required: number): Promise<Search> => {
    const text = await engine.ccall('bh_search', 'string', ['string', 'number', 'number', 'number', 'number'],
      [payload.dual_fen ?? '', side, Number(ahead), required, payload.movetime_ms ?? 1500], { async: true });
    const answer: Search = JSON.parse(text);
    if (engine.inferenceError) { const error = engine.inferenceError; engine.inferenceError = undefined; throw new Error(error); }
    return answer;
  };
  progress('Hivemind is searching for our team, on your device…');
  const ours = await search(team, payload.time_advantage ?? false, { A: 1, B: 2 }[payload.require_move_on ?? ''] ?? 0);
  if (ours.error) throw new Error(ours.error);
  if (cancelled) throw new Error('Analysis cancelled.');
  const preliminary: Analysis = { ...ours, advantage: null, calibration: { source: 'pending' } };
  postMessage({ id, partial: preliminary });
  progress('Moves ready · comparing the other team for the score…');
  // Hivemind's clock input is one bit per team: "ahead". Equal clocks are
  // both bits off; behind is theirs on. The calibration searches them with it.
  const theirs = ours.mate === null ? await search(1 - team, payload.their_time_advantage ?? false, 0) : null;
  if (cancelled) throw new Error('Analysis cancelled.');
  const measured = theirs && !theirs.error && ours.mate === null && theirs.mate === null;
  const result: Analysis = { ...ours, advantage: measured ? (ours.q - theirs.q) / 2 : null,
    total_nodes: ours.nodes + (theirs?.nodes ?? 0),
    elapsed_ms: (ours.elapsed_ms ?? 0) + (theirs?.elapsed_ms ?? 0),
    calibration: { source: measured ? 'measured' : 'unavailable' } };
  if (analysisCache.size >= 32) analysisCache.delete(analysisCache.keys().next().value!);
  analysisCache.set(cacheKey, result);
  return result;
}

self.onmessage = async ({ data }) => {
  if (data.action === 'cancel') {
    cancelled = true;
    downloadController?.abort();
    if (modulePromise) (await modulePromise).cancelled = true;
    return;
  }
  if (active) { postMessage({ id: data.id, error: 'A browser search is already running.' }); return; }
  active = true; cancelled = false;
  try { postMessage({ id: data.id, result: await request(data.id, data.action, data.payload) }); }
  catch (error) { postMessage({ id: data.id, error: error instanceof Error ? error.message : String(error) }); }
  finally { active = false; }
};
