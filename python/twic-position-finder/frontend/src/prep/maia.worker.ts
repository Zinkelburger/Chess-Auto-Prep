/**
 * Maia 3, the human-move model, in a worker with ONNX Runtime Web on one WASM
 * thread (the page is not cross-origin isolated). The model is served in
 * checksum-pinned gzip parts (tools/prepare_prep_web.py) and kept in the Cache
 * API once verified. Each request is one position at one rating; the answer is
 * the share of every legal move.
 */
import * as ort from 'onnxruntime-web/wasm';
import { maiaInput, maiaShares } from './maia-input';

export type MaiaRequest = { id: number; fen: string; elo: number };
export type MaiaReply =
  | { id: number; shares: Record<string, number> }
  | { id: number; error: string }
  | { status: string; fraction?: number };

let session: Promise<ort.InferenceSession> | null = null;
let vocabulary: Record<string, number> = {};
const status = (text: string, fraction?: number) => postMessage({ status: text, fraction } satisfies MaiaReply);
const sha = async (data: ArrayBuffer) => [...new Uint8Array(await crypto.subtle.digest('SHA-256', data))].map((b) => b.toString(16).padStart(2, '0')).join('');

async function bytes(url: string): Promise<ArrayBuffer> {
  const response = await fetch(url, { signal: AbortSignal.timeout(180_000) });
  if (!response.ok) throw new Error('Could not download Maia. Check your connection and try again.');
  return response.arrayBuffer();
}

async function load(): Promise<ort.InferenceSession> {
  const manifest = JSON.parse(new TextDecoder().decode(await bytes('/prep-engine/model.json'))) as {
    sha256: string; vocabulary: string; chunks: { file: string; bytes: number; sha256: string }[];
  };
  let cache: Cache | null = null;
  try { cache = await caches.open('cap-maia-v1'); } catch { /* Downloads every visit without the cache. */ }
  const total = manifest.chunks.reduce((n, c) => n + c.bytes, 0);
  let have = 0;
  const parts: ArrayBuffer[] = [];
  for (const chunk of manifest.chunks) {
    const url = '/prep-engine/' + chunk.file;
    let data: ArrayBuffer | undefined;
    try { data = await (await cache?.match(url))?.arrayBuffer(); } catch { cache = null; }
    if (!data || data.byteLength !== chunk.bytes || await sha(data) !== chunk.sha256) {
      status(`Downloading Maia · ${Math.round(have / 1048576)} of ${Math.round(total / 1048576)} MB`, have / total);
      data = await bytes(url);
      if (data.byteLength !== chunk.bytes || await sha(data) !== chunk.sha256) throw new Error('Maia’s download was incomplete. Try again.');
      try { await cache?.put(url, new Response(data)); } catch { /* Runs without the cache. */ }
    }
    have += chunk.bytes;
    parts.push(data);
  }
  status('Starting Maia…', 1);
  const model = await new Response(new Blob(parts).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer();
  if (await sha(model) !== manifest.sha256) throw new Error('Maia’s checksum did not match. Try again.');
  vocabulary = JSON.parse(new TextDecoder().decode(await bytes('/prep-engine/' + manifest.vocabulary)));
  ort.env.wasm.numThreads = 1;
  ort.env.wasm.wasmPaths = new URL('/bughouse-engine/', self.location.origin).href;
  return ort.InferenceSession.create(model, { executionProviders: ['wasm'], graphOptimizationLevel: 'all', enableMemPattern: false });
}

async function shares(fen: string, elo: number): Promise<Record<string, number>> {
  session ??= load();
  let model: ort.InferenceSession;
  try { model = await session; } catch (e) { session = null; throw e; }
  const input = maiaInput(fen);
  const feeds = {
    tokens: new ort.Tensor('float32', input.tokens, [1, 64, 12]),
    elo_self: new ort.Tensor('float32', [elo], [1]),
    elo_oppo: new ort.Tensor('float32', [elo], [1]),
  };
  let outputs: Record<string, ort.Tensor> = {};
  try {
    outputs = await model.run(feeds);
    return maiaShares(outputs[model.outputNames[0]].data as Float32Array, input.moves, input.black, vocabulary);
  } finally {
    Object.values(feeds).forEach((t) => t.dispose());
    Object.values(outputs).forEach((t) => t.dispose());
  }
}

// One inference at a time, in the order asked.
let queue = Promise.resolve();
onmessage = (event: MessageEvent<MaiaRequest>) => {
  const { id, fen, elo } = event.data;
  queue = queue.then(async () => {
    try { postMessage({ id, shares: await shares(fen, elo) } satisfies MaiaReply); }
    catch (e) { postMessage({ id, error: (e as Error).message } satisfies MaiaReply); }
  });
};
