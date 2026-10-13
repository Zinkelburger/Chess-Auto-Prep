/**
 * Fairy-Stockfish 14 with Lichess's crazyhouse NNUE, the engine behind
 * lichess.org/analysis/crazyhouse, from @lichess-org/stockfish-web. The
 * module runs on this page's main thread and searches in its own pthread
 * workers, so the page must be cross-origin isolated (COOP/COEP in
 * public/_headers and the dev server).
 *
 * The net (about 30 MB gzipped) comes in parts prepared by
 * tools/prepare_crazyhouse_web.py and is kept in the browser's cache, so it
 * downloads once. Positions are always sent as a bare FEN: a hand edited
 * between moves has no move list that leads to it.
 */
import type StockfishWeb from '@lichess-org/stockfish-web';

const DIRECTORY = '/crazyhouse-engine/';
const CACHE = 'crazyhouse-nnue-v1';

interface Chunk { file: string; bytes: number; sha256: string }
interface Manifest { name: string; sha256: string; chunks: Chunk[] }

/** One principal variation, scored from White's side. */
export interface EngineLine {
  multipv: number;
  depth: number;
  cp?: number;
  mate?: number;
  pv: string[];
}

export interface EngineResult {
  fen: string;
  depth: number;
  knps: number;
  lines: EngineLine[];
  /** The search ended by itself (time or depth limit). */
  done: boolean;
}

export interface SearchSettings {
  multiPv: number;
  threads: number;
  hashMb: number;
  infinite: boolean;
}

export type EngineStatus =
  | { kind: 'off' }
  | { kind: 'loading'; text: string }
  | { kind: 'ready' }
  | { kind: 'failed'; text: string };

export const MAX_THREADS = Math.max(1, Math.min(32, navigator.hardwareConcurrency || 1));
/** Like Lichess: about all cores but one, leaving the page responsive. */
export const DEFAULT_THREADS = Math.max(1, MAX_THREADS - (MAX_THREADS % 2 ? 0 : 1));
/** Without infinite analysis a position is searched this long, as on Lichess. */
const SEARCH_MS = 30_000;

export function crossOriginReady(): boolean {
  return typeof SharedArrayBuffer !== 'undefined' && globalThis.crossOriginIsolated === true;
}

async function sha256(buffer: ArrayBuffer): Promise<string> {
  return [...new Uint8Array(await crypto.subtle.digest('SHA-256', buffer))].map((b) => b.toString(16).padStart(2, '0')).join('');
}

/** The largest shared memory the browser grants, shrinking the maximum as lila does. */
function sharedMemory(lo = 1024, hi = 32768): WebAssembly.Memory {
  let shrink = 4;
  for (;;) {
    try {
      return new WebAssembly.Memory({ shared: true, initial: lo, maximum: hi });
    } catch (e) {
      if (hi <= lo || !(e instanceof RangeError)) throw e;
      hi = Math.max(lo, Math.ceil(hi - hi / shrink));
      shrink = shrink === 4 ? 3 : 4;
    }
  }
}

async function fetchChunk(chunk: Chunk, cache: Cache | null, progress: (bytes: number) => void): Promise<ArrayBuffer> {
  const url = DIRECTORY + chunk.file;
  const kept = await cache?.match(url).catch(() => undefined);
  if (kept) {
    const buffer = await kept.arrayBuffer();
    if (buffer.byteLength === chunk.bytes && await sha256(buffer) === chunk.sha256) { progress(chunk.bytes); return buffer; }
    await cache?.delete(url).catch(() => undefined);
  }
  const response = await fetch(url);
  if (!response.ok || !response.body) throw new Error('The engine download failed. Check your connection and reload.');
  const reader = response.body.getReader();
  const parts: Uint8Array[] = [];
  let received = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    parts.push(value);
    received += value.byteLength;
    progress(received);
  }
  const buffer = await new Blob(parts as BlobPart[]).arrayBuffer();
  if (buffer.byteLength !== chunk.bytes || await sha256(buffer) !== chunk.sha256)
    throw new Error('The engine download was incomplete. Reload to try again.');
  try { await cache?.put(url, new Response(buffer)); } catch { /* Private mode or quota: run from memory. */ }
  return buffer;
}

interface Job { fen: string; settings: SearchSettings; generation: number }

export class Engine {
  private module: StockfishWeb | null = null;
  private loading: Promise<void> | null = null;
  private status: EngineStatus = { kind: 'off' };
  /** The search the engine is running; its output is shown until it is replaced. */
  private running: Job | null = null;
  /** Sent `stop`; the next search starts on `bestmove`. */
  private stopping = false;
  private next: Job | null = null;
  private generation = 0;
  private lines = new Map<number, EngineLine>();
  private knps = 0;
  private sent = new Map<string, string>();

  constructor(
    private readonly onStatus: (status: EngineStatus) => void,
    private readonly onResult: (result: EngineResult) => void,
  ) {}

  get current(): EngineStatus { return this.status; }

  private setStatus(status: EngineStatus) {
    this.status = status;
    this.onStatus(status);
  }

  /** Downloads (once) and starts the engine; later calls share the same start. */
  load(): Promise<void> {
    this.loading ??= this.boot().catch((e: unknown) => {
      this.loading = null;
      this.setStatus({ kind: 'failed', text: e instanceof Error ? e.message : String(e) });
      throw e;
    });
    return this.loading;
  }

  private async boot() {
    if (!crossOriginReady()) throw new Error('This browser blocks the shared memory the engine needs. Reload the page, or try another browser.');
    this.setStatus({ kind: 'loading', text: 'Loading engine…' });
    const manifestResponse = await fetch(DIRECTORY + 'net.json');
    if (!manifestResponse.ok) throw new Error('The engine files are missing from this site.');
    const manifest: Manifest = await manifestResponse.json();
    let cache: Cache | null = null;
    try { cache = await caches.open(CACHE); } catch { /* Optional download cache. */ }
    const total = manifest.chunks.reduce((sum, c) => sum + c.bytes, 0);
    const done: number[] = manifest.chunks.map(() => 0);
    const buffers = await Promise.all(manifest.chunks.map((chunk, i) => fetchChunk(chunk, cache, (bytes) => {
      done[i] = bytes;
      const got = done.reduce((a, b) => a + b, 0);
      if (got < total) this.setStatus({ kind: 'loading', text: `Downloading the crazyhouse net · ${Math.round(got / 1e6)} of ${Math.round(total / 1e6)} MB (once)` });
    })));
    this.setStatus({ kind: 'loading', text: 'Starting engine…' });
    const net = new Uint8Array(await new Response(new Blob(buffers).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
    if (await sha256(net.buffer as ArrayBuffer) !== manifest.sha256) {
      for (const c of manifest.chunks) await cache?.delete(DIRECTORY + c.file).catch(() => undefined);
      throw new Error('The engine net did not check out. Reload to download it again.');
    }
    const scriptUrl = new URL(DIRECTORY + 'fsf_14.js', location.href).href;
    const makeModule = await import(/* @vite-ignore */ scriptUrl);
    const module: StockfishWeb = await makeModule.default({
      wasmMemory: sharedMemory(),
      locateFile: (file: string) => new URL(DIRECTORY + file, location.href).href,
      mainScriptUrlOrBlob: scriptUrl,
    });
    module.onError = (msg: string) => this.setStatus({ kind: 'failed', text: msg.startsWith('BAD_NNUE') ? 'The engine net did not load. Reload to try again.' : msg });
    module.listen = (line: string) => this.received(line);
    module.uci('setoption name UCI_Variant value crazyhouse');
    module.setNnueBuffer(net, 0);
    this.module = module;
    this.setStatus({ kind: 'ready' });
    if (this.next && !this.running) this.start();
  }

  /** Searches `fen` from now on; any search in progress is stopped first. */
  analyse(fen: string, settings: SearchSettings) {
    this.next = { fen, settings: { ...settings }, generation: ++this.generation };
    if (!this.module) return;
    if (this.running) this.halt();
    else this.start();
  }

  /** Stops searching and forgets the queued position. */
  stop() {
    this.generation++;
    this.next = null;
    if (this.running) this.halt();
  }

  private halt() {
    if (this.stopping) return;
    this.stopping = true;
    this.module?.uci('stop');
  }

  private setOption(name: string, value: string) {
    if (this.sent.get(name) === value) return;
    this.sent.set(name, value);
    this.module!.uci(`setoption name ${name} value ${value}`);
  }

  private start() {
    const job = this.next;
    if (!job || !this.module) return;
    this.next = null;
    this.running = job;
    this.lines = new Map();
    this.knps = 0;
    this.setOption('Threads', String(job.settings.threads));
    this.setOption('Hash', String(job.settings.hashMb));
    this.setOption('MultiPV', String(job.settings.multiPv));
    this.setOption('UCI_AnalyseMode', 'true');
    this.module.uci(`position fen ${job.fen}`);
    this.module.uci(job.settings.infinite ? 'go infinite' : `go depth 99 movetime ${SEARCH_MS}`);
  }

  private received(line: string) {
    if (line.startsWith('bestmove')) {
      const finished = this.running;
      this.running = null;
      const natural = !this.stopping;
      this.stopping = false;
      if (finished && natural && finished.generation === this.generation) this.publish(finished, true);
      this.start();
      return;
    }
    const job = this.running;
    if (!job || this.stopping || !line.startsWith('info ') || !line.includes(' pv ')) return;
    const parts = line.split(' ');
    let depth = 0, multipv = 1, cp: number | undefined, mate: number | undefined, bound = false, nps = 0;
    let i = 1;
    for (; i < parts.length; i++) {
      const key = parts[i];
      if (key === 'depth') depth = Number(parts[++i]);
      else if (key === 'multipv') multipv = Number(parts[++i]);
      else if (key === 'nps') nps = Number(parts[++i]);
      else if (key === 'score') {
        const kind = parts[++i], value = Number(parts[++i]);
        if (kind === 'cp') cp = value; else mate = value;
        if (parts[i + 1] === 'lowerbound' || parts[i + 1] === 'upperbound') { bound = true; i++; }
      } else if (key === 'pv') break;
      else if (key === 'string') return;
    }
    // Only the first line's bounds are noise; later lines may only ever have bounds.
    if (bound && multipv === 1) return;
    const pv = parts.slice(i + 1).filter(Boolean);
    if (!pv.length) return;
    const blackToMove = job.fen.split(' ')[1] === 'b';
    const sign = blackToMove ? -1 : 1;
    if (multipv === 1) this.lines = new Map([...this.lines].filter(([, l]) => l.depth >= depth - 1));
    this.lines.set(multipv, { multipv, depth, pv, cp: cp === undefined ? undefined : cp * sign, mate: mate === undefined ? undefined : mate * sign });
    if (nps) this.knps = Math.round(nps / 1000);
    this.publish(job, false);
  }

  private publish(job: Job, done: boolean) {
    const lines = [...this.lines.values()].sort((a, b) => a.multipv - b.multipv).slice(0, job.settings.multiPv);
    if (!lines.length) return;
    this.onResult({ fen: job.fen, depth: lines[0].depth, knps: this.knps, lines, done });
  }
}
