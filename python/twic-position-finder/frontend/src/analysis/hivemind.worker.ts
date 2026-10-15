/**
 * Hivemind in a browser worker: the engine compiled to WebAssembly
 * (tools/bughouse_web) and its network run by ONNX Runtime Web.
 *
 * The network runs on the GPU through WebGPU when the browser has it, with
 * leaves evaluated in batches (a GPU is fast only on batches). Otherwise it
 * runs on the CPU, one leaf at a time, on the threads the page asks for (the
 * gear's Threads) when the page is cross-origin isolated. A GPU that fails while searching is dropped for the
 * CPU and the search runs again there. The network (about 32 MB) and ONNX
 * Runtime's WebGPU build (about 22 MB) download once, with their progress,
 * and are kept in the browser's cache.
 *
 * Messages in: `load`, `search` (one frozen-board search), `cancel`.
 * Out: `progress`, `ready` (with the backend, again after a switch to the
 * CPU), `report` (while searching), `done` and `failed`.
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
interface Manifest { model_sha256: string; chunks: Chunk[]; runtime?: Chunk; input: string; outputs: Record<string, string> }
/** `gpuAvailable`: the browser offers WebGPU, whichever backend was chosen. */
export interface Backend { kind: 'gpu' | 'cpu'; threads: number; batch: number; gpuAvailable: boolean }
export type WorkerRequest =
  | { type: 'load'; prefer: 'auto' | 'cpu'; threads: number }
  /** `keep`: keep the search tree, and carry on from the kept one for the same position. */
  | { type: 'search'; id: number; fen: string; nodes: number; millis: number; lines: number; reportMs: number; keep: boolean }
  | { type: 'cancel' };
export type WorkerReply =
  /** `done` of `total` bytes while downloading. */
  | { type: 'progress'; text: string; done?: number; total?: number }
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

/** Downloads a file; `onBytes` hears each part as it arrives. A stalled download gives up after `millis` without data. */
async function fetchBytes(url: string, millis = 60_000, onBytes?: (n: number) => void): Promise<ArrayBuffer> {
  const controller = new AbortController();
  let timer = setTimeout(() => controller.abort(), millis);
  try {
    const response = await fetch(url, { signal: controller.signal });
    if (!response.ok) throw new Error('The engine download failed. Check your connection.');
    if (!response.body || !onBytes) return await response.arrayBuffer();
    const parts: Uint8Array<ArrayBuffer>[] = [];
    const reader = response.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      clearTimeout(timer);
      timer = setTimeout(() => controller.abort(), millis);
      parts.push(value);
      onBytes(value.byteLength);
    }
    return await new Blob(parts).arrayBuffer();
  } catch (error) {
    if (controller.signal.aborted) throw new Error('The engine download stalled. Check your connection.');
    if (error instanceof TypeError) throw new Error('The engine download failed. Check your connection.');
    throw error;
  } finally { clearTimeout(timer); }
}

/**
 * The network and ONNX Runtime's WebGPU build, from this browser's cache or
 * downloaded once, each part checked against the manifest's checksum.
 */
async function download(): Promise<{ manifest: Manifest; model: ArrayBuffer; runtime: ArrayBuffer | null }> {
  const manifest: Manifest = JSON.parse(new TextDecoder().decode(await fetchBytes(DIRECTORY + 'model.json', 30_000)));
  let cache: Cache | null = null;
  try { cache = await caches.open('hivemind-model-v1'); } catch { /* The cache is optional. */ }
  const parts = [...manifest.chunks, ...(manifest.runtime ? [manifest.runtime] : [])];
  // A cached copy is keyed by its checksum, so a new runtime under the same name downloads again.
  const keyOf = (part: Chunk) => `${DIRECTORY}${part.file}?sha256=${part.sha256}`;
  const buffers = new Map<Chunk, ArrayBuffer>();
  for (const part of parts) {
    try {
      const kept = await cache?.match(keyOf(part));
      const buffer = kept ? await kept.arrayBuffer() : null;
      if (buffer && buffer.byteLength === part.bytes && await sha256(buffer) === part.sha256) buffers.set(part, buffer);
      else if (kept) await cache?.delete(keyOf(part));
    } catch { cache = null; }
  }
  const missing = parts.filter((part) => !buffers.has(part));
  const total = missing.reduce((sum, part) => sum + part.bytes, 0);
  let done = 0;
  const megabytes = (n: number) => Math.round(n / 1_048_576);
  const progress = () => send({ type: 'progress', text: `Downloading the engine · ${megabytes(done)} of ${megabytes(total)} MB, once`, done, total });
  if (missing.length) progress();
  for (const part of missing) {
    let last = 0;
    const buffer = await fetchBytes(DIRECTORY + part.file, 60_000, (n) => {
      done += n;
      const now = performance.now();
      if (now - last > 250) { last = now; progress(); }
    });
    if (buffer.byteLength !== part.bytes || await sha256(buffer) !== part.sha256)
      throw new Error('The engine download was incomplete. Try again.');
    try { await cache?.put(keyOf(part), new Response(buffer)); } catch { /* Private mode or quota: run from memory. */ }
    buffers.set(part, buffer);
  }
  const model = await new Response(new Blob(manifest.chunks.map((c) => buffers.get(c)!)).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
  if (await sha256(model) !== manifest.model_sha256) throw new Error('The network checksum did not match. Try again.');
  return { manifest, model, runtime: manifest.runtime ? buffers.get(manifest.runtime)! : null };
}

async function gpuAvailable(): Promise<boolean> {
  try {
    const gpu = (navigator as Navigator & { gpu?: { requestAdapter(): Promise<unknown> } }).gpu;
    return !!gpu && !!(await gpu.requestAdapter());
  } catch { return false; }
}

/** A real task between evaluations, so a cancel message is read; a timer would be clamped to 4 ms. */
const tick = (() => {
  const channel = new MessageChannel();
  const waiting: (() => void)[] = [];
  channel.port1.onmessage = () => waiting.shift()?.();
  return () => new Promise<void>((resolve) => { waiting.push(resolve); channel.port2.postMessage(null); });
})();

let model: ArrayBuffer | null = null;
let webgpu = false;
let manifest: Manifest | null = null;
let net: ort.InferenceSession | null = null;
const SESSION_OPTIONS = { graphOptimizationLevel: 'all', logSeverityLevel: 3 } as const;

/** One evaluation of a batch of zeros: a GPU that cannot run the network fails here, at load. */
async function warmUp(session: ort.InferenceSession, batch: number) {
  const tensor = new ort.Tensor('float32', new Float32Array(batch * 74 * 64), [batch, 74, 8, 8]);
  const result = await session.run({ [manifest!.input]: tensor });
  tensor.dispose();
  for (const t of Object.values(result)) t.dispose();
}

/** The network on the CPU, on the threads set at load. */
async function cpuSession(): Promise<Backend> {
  net = await ort.InferenceSession.create(model!, { ...SESSION_OPTIONS, executionProviders: ['wasm'] });
  return { kind: 'cpu', threads: ort.env.wasm.numThreads ?? 1, batch: 1, gpuAvailable: webgpu };
}

async function load(prefer: 'auto' | 'cpu', threads: number): Promise<Backend> {
  send({ type: 'progress', text: 'Starting Hivemind…' });
  const url = new URL(DIRECTORY + 'hivemind.mjs', self.location.href).href;
  const { default: createHivemind } = await import(/* @vite-ignore */ url);
  const wasm: Wasm = await createHivemind();
  wasm.ccall('bh_init', null, [], []);
  const files = await download();
  manifest = files.manifest;
  model = files.model;
  send({ type: 'progress', text: 'Starting Hivemind…' });
  // A full URL: the dev server rejects a root-relative import of a /public file.
  ort.env.wasm.wasmPaths = new URL(DIRECTORY, self.location.origin).href;
  if (files.runtime) ort.env.wasm.wasmBinary = files.runtime;
  // ORT notes that shape operations stay on the CPU under WebGPU, as an error-level console line.
  ort.env.logLevel = 'error';
  // Threads need SharedArrayBuffer, so a page that is not isolated runs one.
  const cores = navigator.hardwareConcurrency || 1;
  ort.env.wasm.numThreads = self.crossOriginIsolated ? Math.max(1, Math.min(cores, Math.round(threads) || 1)) : 1;
  webgpu = await gpuAvailable();
  let chosen: Backend | null = null;
  if (prefer === 'auto' && webgpu) {
    try {
      net = await ort.InferenceSession.create(model, { ...SESSION_OPTIONS, executionProviders: ['webgpu'] });
      await warmUp(net, GPU_BATCH);
      chosen = { kind: 'gpu', threads: 1, batch: GPU_BATCH, gpuAvailable: true };
    } catch {
      try { await net?.release(); } catch { /* Already gone. */ }
      net = null;
    }
  }
  chosen ??= await cpuSession();
  wasm.infer = async (input, batch, value, policyA, policyB, wdl, movesLeft) => {
    await tick();
    const tensor = new ort.Tensor('float32', wasm.HEAPF32.slice(input / 4, input / 4 + batch * 74 * 64), [batch, 74, 8, 8]);
    let result: Record<string, ort.Tensor> = {};
    try {
      result = await net!.run({ [manifest!.input]: tensor });
      const destinations: Record<string, [number, number]> = {
        value: [value, batch], policyA: [policyA, batch * 4672], policyB: [policyB, batch * 4672],
        wdl: [wdl, batch * 3], movesLeft: [movesLeft, batch],
      };
      for (const [name, [pointer, length]] of Object.entries(destinations)) {
        const output = result[manifest!.outputs[name]];
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
    const answer = await frozenSearch(wasm, request);
    send({ type: 'done', id: request.id, data: answer });
  } catch (error) {
    // The GPU failed while searching (a lost device, a driver error): carry on on the CPU.
    if (backend?.kind === 'gpu' && !wasm.cancelled && wasm.inferenceError !== undefined) {
      wasm.inferenceError = undefined;
      try {
        try { await net?.release(); } catch { /* Already gone. */ }
        backend = await cpuSession();
        send({ type: 'ready', backend });
        send({ type: 'done', id: request.id, data: await frozenSearch(wasm, request) });
        return;
      } catch (retry) { error = retry; }
    }
    wasm.inferenceError = undefined;
    send({ type: 'failed', id: request.id, error: error instanceof Error ? error.message : String(error) });
  } finally { wasm.onFrozenReport = undefined; }
}

async function frozenSearch(wasm: Wasm, request: Extract<WorkerRequest, { type: 'search' }>): Promise<unknown> {
  const text = await wasm.ccall('bh_frozen_search', 'string', ['string', 'number', 'number', 'number', 'number', 'number', 'number'],
    [request.fen, request.nodes, request.millis, request.lines, request.reportMs, backend!.batch, request.keep ? 1 : 0], { async: true });
  if (wasm.inferenceError !== undefined) throw new Error(wasm.inferenceError);
  const answer = JSON.parse(text as string);
  if (answer.error) throw new Error(answer.error);
  return answer;
}

let queue: Promise<void> = Promise.resolve();

self.onmessage = ({ data }: MessageEvent<WorkerRequest>) => {
  if (data.type === 'cancel') { if (engine) engine.cancelled = true; return; }
  if (data.type === 'load') {
    loading ??= load(data.prefer, data.threads);
    loading.then((b) => { backend = b; send({ type: 'ready', backend: b }); },
      (error) => { loading = null; send({ type: 'failed', error: error instanceof Error ? error.message : String(error) }); });
    return;
  }
  // Searches run one after another; the page sends the next only after the last answered.
  queue = queue.then(() => search(data));
};
