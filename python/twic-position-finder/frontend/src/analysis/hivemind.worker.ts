/**
 * Hivemind in a browser worker: the engine compiled to WebAssembly
 * (tools/bughouse_web) and its network run by ONNX Runtime Web.
 *
 * The network runs on the GPU through WebGPU when the browser has it, with
 * leaves evaluated in batches (a GPU is fast only on batches). Otherwise it
 * runs on the CPU, one leaf at a time, on up to four threads when the page is
 * cross-origin isolated. The network (about 32 MB) downloads once and is kept
 * in the browser's cache.
 *
 * Messages in: `load`, `search` (one frozen-board search), `cancel`.
 * Out: `progress`, `ready` (with the backend), `report` (while searching),
 * `done` and `failed`.
 */
import * as ort from 'onnxruntime-web/webgpu';

interface Wasm {
  HEAPF32: Float32Array;
  cancelled: boolean;
  onFrozenReport?: (json: string) => void;
  inferenceError?: string;
  infer: (...args: number[]) => Promise<void>;
  ccall: (name: string, result: string | null, types: string[], args: unknown[], options?: { async: boolean }) => string | Promise<string>;
}
interface Chunk { file: string; sha256: string; bytes: number }
interface Manifest { model_sha256: string; chunks: Chunk[]; input: string; outputs: Record<string, string> }
export interface Backend { kind: 'gpu' | 'cpu'; threads: number; batch: number }
export type WorkerRequest =
  | { type: 'load'; prefer: 'auto' | 'cpu' }
  | { type: 'search'; id: number; fen: string; nodes: number; millis: number; lines: number; reportMs: number }
  | { type: 'cancel' };
export type WorkerReply =
  | { type: 'progress'; text: string }
  | { type: 'ready'; backend: Backend }
  | { type: 'report' | 'done'; id: number; data: unknown }
  | { type: 'failed'; id?: number; error: string };

const DIRECTORY = '/bughouse-engine/';
/** Leaves per GPU evaluation: 32 runs about twelve times as many positions a second as one at a time. */
const GPU_BATCH = 32;
const send = (reply: WorkerReply) => postMessage(reply);

let engine: Wasm | null = null;
let backend: Backend | null = null;
let loading: Promise<Backend> | null = null;

async function sha256(buffer: ArrayBuffer): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', buffer))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

async function fetchBytes(url: string, millis = 120_000): Promise<ArrayBuffer> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), millis);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error('The engine download failed. Check your connection and reload.');
    return await response.arrayBuffer();
  } catch (error) {
    if (controller.signal.aborted) throw new Error('The engine download timed out. Reload to try again.');
    throw error;
  } finally { clearTimeout(timer); }
}

/** The network, from this browser's cache or downloaded once in parts. */
async function network(): Promise<{ manifest: Manifest; model: ArrayBuffer }> {
  const manifest: Manifest = JSON.parse(new TextDecoder().decode(await fetchBytes(DIRECTORY + 'model.json', 30_000)));
  let cache: Cache | null = null;
  try { cache = await caches.open('hivemind-model-v1'); } catch { /* The cache is optional. */ }
  const buffers: ArrayBuffer[] = [];
  for (const [i, chunk] of manifest.chunks.entries()) {
    const url = DIRECTORY + chunk.file;
    let buffer: ArrayBuffer | null = null;
    try {
      const kept = await cache?.match(url);
      if (kept) buffer = await kept.arrayBuffer();
      if (buffer && (buffer.byteLength !== chunk.bytes || await sha256(buffer) !== chunk.sha256)) { buffer = null; await cache?.delete(url); }
    } catch { cache = null; }
    if (!buffer) {
      send({ type: 'progress', text: `Downloading Hivemind’s network · part ${i + 1} of ${manifest.chunks.length} (about 32 MB, once)` });
      buffer = await fetchBytes(url);
      if (buffer.byteLength !== chunk.bytes || await sha256(buffer) !== chunk.sha256)
        throw new Error('The engine download was incomplete. Reload to try again.');
      try { await cache?.put(url, new Response(buffer)); } catch { /* Private mode or quota: run from memory. */ }
    }
    buffers.push(buffer);
  }
  const model = await new Response(new Blob(buffers).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
  if (await sha256(model) !== manifest.model_sha256) throw new Error('The network checksum did not match. Reload to try again.');
  return { manifest, model };
}

async function gpuAvailable(): Promise<boolean> {
  try {
    const gpu = (navigator as Navigator & { gpu?: { requestAdapter(): Promise<unknown> } }).gpu;
    return !!gpu && !!(await gpu.requestAdapter());
  } catch { return false; }
}

async function load(prefer: 'auto' | 'cpu'): Promise<Backend> {
  send({ type: 'progress', text: 'Starting Hivemind…' });
  const url = new URL(DIRECTORY + 'hivemind.mjs', self.location.href).href;
  const { default: createHivemind } = await import(/* @vite-ignore */ url);
  const wasm: Wasm = await createHivemind();
  wasm.ccall('bh_init', null, [], []);
  const { manifest, model } = await network();
  send({ type: 'progress', text: 'Starting Hivemind…' });
  // A full URL: the dev server rejects a root-relative import of a /public file.
  ort.env.wasm.wasmPaths = new URL(DIRECTORY, self.location.origin).href;
  // ORT notes that shape operations stay on the CPU under WebGPU, as an error-level console line.
  ort.env.logLevel = 'error';
  const options = { graphOptimizationLevel: 'all', logSeverityLevel: 3 } as const;
  const cores = navigator.hardwareConcurrency || 2;
  ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.max(1, Math.min(4, cores - 1)) : 1;
  let session: ort.InferenceSession | null = null;
  let chosen: Backend = { kind: 'cpu', threads: ort.env.wasm.numThreads, batch: 1 };
  if (prefer === 'auto' && await gpuAvailable()) {
    try {
      session = await ort.InferenceSession.create(model, { ...options, executionProviders: ['webgpu'] });
      chosen = { kind: 'gpu', threads: 1, batch: GPU_BATCH };
    } catch { session = null; }
  }
  session ??= await ort.InferenceSession.create(model, { ...options, executionProviders: ['wasm'] });
  const net = session;
  wasm.infer = async (input, batch, value, policyA, policyB, wdl, movesLeft) => {
    // ORT's promise can settle in the same microtask turn. Yield a real task
    // so a cancel message arrives between evaluations.
    await new Promise((resolve) => setTimeout(resolve, 0));
    const tensor = new ort.Tensor('float32', wasm.HEAPF32.slice(input / 4, input / 4 + batch * 74 * 64), [batch, 74, 8, 8]);
    let result: Record<string, ort.Tensor> = {};
    try {
      result = await net.run({ [manifest.input]: tensor });
      const destinations: Record<string, [number, number]> = {
        value: [value, batch], policyA: [policyA, batch * 4672], policyB: [policyB, batch * 4672],
        wdl: [wdl, batch * 3], movesLeft: [movesLeft, batch],
      };
      for (const [name, [pointer, length]] of Object.entries(destinations)) {
        const output = result[manifest.outputs[name]];
        if (!output || output.type !== 'float32' || output.data.length !== length) throw new Error(`Unexpected network output: ${name}`);
        wasm.HEAPF32.set(output.data as Float32Array, pointer / 4);
      }
    } finally {
      tensor.dispose();
      for (const t of Object.values(result)) t.dispose();
    }
  };
  engine = wasm;
  return chosen;
}

/** One search to its end; a cancelled search still answers with what it found. */
async function search(request: Extract<WorkerRequest, { type: 'search' }>) {
  const wasm = engine!;
  wasm.cancelled = false;
  wasm.onFrozenReport = (json) => send({ type: 'report', id: request.id, data: JSON.parse(json) });
  try {
    const text = await wasm.ccall('bh_frozen_search', 'string', ['string', 'number', 'number', 'number', 'number', 'number'],
      [request.fen, request.nodes, request.millis, request.lines, request.reportMs, backend!.batch], { async: true });
    if (wasm.inferenceError) { const error = wasm.inferenceError; wasm.inferenceError = undefined; throw new Error(error); }
    const answer = JSON.parse(text as string);
    if (answer.error) throw new Error(answer.error);
    send({ type: 'done', id: request.id, data: answer });
  } catch (error) {
    send({ type: 'failed', id: request.id, error: error instanceof Error ? error.message : String(error) });
  } finally { wasm.onFrozenReport = undefined; }
}

let queue: Promise<void> = Promise.resolve();

self.onmessage = ({ data }: MessageEvent<WorkerRequest>) => {
  if (data.type === 'cancel') { if (engine) engine.cancelled = true; return; }
  if (data.type === 'load') {
    loading ??= load(data.prefer);
    loading.then((b) => { backend = b; send({ type: 'ready', backend: b }); },
      (error) => { loading = null; send({ type: 'failed', error: error instanceof Error ? error.message : String(error) }); });
    return;
  }
  // Searches run one after another; the page sends the next only after the last answered.
  queue = queue.then(() => search(data));
};
