/**
 * Fairy-Stockfish 14 with Lichess's crazyhouse NNUE, the engine behind
 * lichess.org/analysis/crazyhouse, from @lichess-org/stockfish-web. It plays
 * crazyhouse: a capture goes to the capturer's hand, and the hands are
 * whatever the page set, so a piece added with + is searched as if the
 * partner had sent it.
 *
 * The module runs on this page's main thread and searches in its own pthread
 * workers, so the page must be cross-origin isolated (COOP/COEP in
 * public/_headers and the dev server). The net (about 30 MB gzipped) comes in
 * parts prepared by tools/prepare_crazyhouse_web.py and is kept in the Cache
 * API, so it downloads once; on a phone or a data-saving connection the
 * engine waits for the player before that download. Positions are always
 * sent as a bare FEN: a hand edited between moves has no move list that
 * leads to it.
 *
 * One engine serves two kinds of search. The analysis of the shown position
 * comes first and stops at its time limit, as Lichess's does. Background
 * evaluations (the sit panel's rows) run after it, one at a time. A new
 * position stops whatever is running. With infinite analysis, the position
 * is searched again without a limit once the background evaluations are
 * done; the hash table keeps what the first search found.
 */
import type StockfishWeb from '@lichess-org/stockfish-web';

const DIRECTORY = '/crazyhouse-engine/';
const CACHE = 'crazyhouse-nnue-v1';
/** Set once the engine has loaded in this browser: its net is then in the cache. */
const LOADED_KEY = 'crazyhouse-engine-loaded';
/** The first download: the gzipped net and the engine's WebAssembly. */
const DOWNLOAD_MB = 30;
/** Lichess sizes the hash by the device's memory; a phone gets less. */
const HASH_MB = ((navigator as Navigator & { deviceMemory?: number }).deviceMemory ?? 8) >= 8 ? 256 : 64;

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
  nodes: number;
  /** Time since the search started. */
  millis: number;
  lines: EngineLine[];
  /** The search ended by itself (its time or node limit). */
  done: boolean;
  /** Searched to the analysis's own limit, not practice's short search. */
  complete: boolean;
  /** The search's time limit. */
  budget: number;
  /** "Depth 21 · 1.4 Mn/s", under the engine name. */
  info: string;
}

export interface SearchSettings {
  multiPv: number;
  infinite: boolean;
  /** Search time; infinite analysis carries on after it. */
  searchMs: number;
  /** Stop after this many nodes instead of the time limit (practice). */
  nodes?: number;
}

export type EngineStatus =
  | { kind: 'off' }
  /** Waits for the player before downloading `megabytes` (phones and data saving). */
  | { kind: 'ask'; megabytes: number }
  /** `fraction` of the download, while downloading. */
  | { kind: 'loading'; text: string; fraction?: number }
  | { kind: 'ready'; threads: number }
  | { kind: 'failed'; text: string };

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

const DOWNLOAD_FAILED = 'The engine download failed. Check your connection and try again.';

/** A fetch whose network errors read as a failed download. */
async function download(url: string): Promise<Response> {
  const response = await fetch(url).catch(() => null);
  if (!response?.ok || !response.body) throw new Error(DOWNLOAD_FAILED);
  return response;
}

async function fetchChunk(chunk: Chunk, cache: Cache | null, progress: (bytes: number) => void): Promise<ArrayBuffer> {
  const url = DIRECTORY + chunk.file;
  const kept = await cache?.match(url).catch(() => undefined);
  if (kept) {
    const buffer = await kept.arrayBuffer();
    if (buffer.byteLength === chunk.bytes && await sha256(buffer) === chunk.sha256) { progress(chunk.bytes); return buffer; }
    await cache?.delete(url).catch(() => undefined);
  }
  const reader = (await download(url)).body!.getReader();
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
    throw new Error('The engine download was incomplete. Try again.');
  try { await cache?.put(url, new Response(buffer)); } catch { /* Private mode or quota: run from memory. */ }
  return buffer;
}

function speed(nps: number): string {
  return nps >= 1e6 ? `${(nps / 1e6).toFixed(1)} Mn/s` : `${Math.round(nps / 1000)} kn/s`;
}

interface Job {
  fen: string;
  /** Stop after this many nodes (practice, background evaluations). */
  nodes?: number;
  /** The time limit; 0 searches until stopped. */
  millis: number;
  lines: number;
  /** The shown position's analysis; otherwise a background evaluation. */
  main: boolean;
  /** Infinite analysis: search on without a limit after the background evaluations. */
  infinite?: boolean;
  /** Practice's short search: its result is not the analysis's. */
  short?: boolean;
  /** Infinite analysis's unlimited search, which gives way to background evaluations. */
  continued?: boolean;
  settle?: (result: EngineResult | null) => void;
}

interface Running {
  job: Job;
  started: number;
  lines: Map<number, EngineLine>;
  nodes: number;
  nps: number;
  /**
   * `superseded`: stopped for other work; `dropped`: its evaluation was
   * cancelled; `paused`: the unlimited search gave way to an evaluation and
   * carries on after it; `requeue`: stopped to change the threads, and runs
   * again.
   */
  superseded: boolean;
  dropped: boolean;
  paused?: boolean;
  requeue?: boolean;
}

export class Engine {
  private module: StockfishWeb | null = null;
  private loading: Promise<void> | null = null;
  private status: EngineStatus = { kind: 'off' };
  private main: Job | null = null;
  private background: Job[] = [];
  /** Infinite analysis's unlimited search, waiting for the background evaluations. */
  private continuation: Job | null = null;
  private running: Running | null = null;
  private sent = new Map<string, string>();
  /** The player agreed to the first download (or it is not asked for). */
  private allowed = false;
  private threads = 1;

  constructor(
    private readonly onStatus: (status: EngineStatus) => void,
    private readonly onResult: (result: EngineResult) => void,
  ) {}

  get current(): EngineStatus { return this.status; }

  private setStatus(status: EngineStatus) {
    this.status = status;
    this.onStatus(status);
  }

  /** Sets the search threads; a running search starts again with them. */
  configure(threads: number) {
    this.threads = threads;
    if (this.status.kind === 'ready' && this.status.threads !== threads) this.setStatus({ kind: 'ready', threads });
    const running = this.running;
    if (running && !running.superseded && this.sent.get('Threads') !== String(threads)) {
      running.requeue = true;
      this.supersede();
    }
  }

  /** Whether the first download waits for the player: a phone, a tablet or a data-saving connection, before the net is cached. */
  private mustAsk(): boolean {
    if (this.allowed) return false;
    try { if (localStorage.getItem(LOADED_KEY)) return false; } catch { /* Ask. */ }
    const connection = (navigator as Navigator & { connection?: { saveData?: boolean; type?: string } }).connection;
    return !!connection?.saveData || connection?.type === 'cellular' || matchMedia('(pointer: coarse)').matches;
  }

  /** The player asked for the engine: download it now. */
  allow() {
    this.allowed = true;
    void this.load().catch(() => undefined);
  }

  /** Downloads (once) and starts the engine; later calls share the same start. */
  load(): Promise<void> {
    if (!this.loading && this.mustAsk()) {
      if (this.status.kind !== 'ask') this.setStatus({ kind: 'ask', megabytes: DOWNLOAD_MB });
      return Promise.reject(new Error('waiting for the player'));
    }
    this.loading ??= this.boot().catch((e: unknown) => {
      this.loading = null;
      this.setStatus({ kind: 'failed', text: e instanceof Error ? e.message : String(e) });
      throw e;
    });
    this.loading.catch(() => undefined);
    return this.loading;
  }

  private async boot() {
    if (!crossOriginReady()) throw new Error('This browser blocks the shared memory the engine needs. Reload the page, or try another browser.');
    this.setStatus({ kind: 'loading', text: 'Loading Fairy-Stockfish…' });
    const manifest: Manifest = await (await download(DIRECTORY + 'net.json')).json();
    let cache: Cache | null = null;
    try { cache = await caches.open(CACHE); } catch { /* Optional download cache. */ }
    const total = manifest.chunks.reduce((sum, c) => sum + c.bytes, 0);
    const done: number[] = manifest.chunks.map(() => 0);
    const buffers = await Promise.all(manifest.chunks.map((chunk, i) => fetchChunk(chunk, cache, (bytes) => {
      done[i] = bytes;
      const got = done.reduce((a, b) => a + b, 0);
      if (got < total) this.setStatus({ kind: 'loading', text: `Downloading the crazyhouse net · ${Math.round(got / 1e6)} of ${Math.round(total / 1e6)} MB, once`, fraction: got / total });
    })));
    this.setStatus({ kind: 'loading', text: 'Starting Fairy-Stockfish…' });
    const net = new Uint8Array(await new Response(new Blob(buffers).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
    if (await sha256(net.buffer as ArrayBuffer) !== manifest.sha256) {
      for (const c of manifest.chunks) await cache?.delete(DIRECTORY + c.file).catch(() => undefined);
      throw new Error('The engine net did not check out. Try again to download it again.');
    }
    const scriptUrl = new URL(DIRECTORY + 'fsf_14.js', location.href).href;
    const makeModule = await import(/* @vite-ignore */ scriptUrl);
    const module: StockfishWeb = await makeModule.default({
      wasmMemory: sharedMemory(),
      locateFile: (file: string) => new URL(DIRECTORY + file, location.href).href,
      mainScriptUrlOrBlob: scriptUrl,
    });
    module.onError = (msg: string) => this.reset(msg.startsWith('BAD_NNUE') ? 'The engine net did not load. Try again.' : msg);
    module.listen = (line: string) => this.received(line);
    module.uci('setoption name UCI_Variant value crazyhouse');
    module.setNnueBuffer(net, 0);
    this.module = module;
    this.sent = new Map();
    try { localStorage.setItem(LOADED_KEY, '1'); } catch { /* Asked again next visit. */ }
    this.setStatus({ kind: 'ready', threads: this.threads });
    this.next();
  }

  /** Drops the engine after an error: the running search is lost, and the next load starts a new one. */
  private reset(text: string) {
    this.module = null;
    this.loading = null;
    const running = this.running;
    this.running = null;
    if (running && !running.job.main && !running.dropped) running.job.settle?.(null);
    this.continuation = null;
    this.setStatus({ kind: 'failed', text });
  }

  /** Searches `fen` from now on, before any background evaluation; a search in progress is stopped first. */
  analyse(fen: string, settings: SearchSettings) {
    this.main = {
      fen, main: true, lines: settings.multiPv,
      nodes: settings.nodes,
      millis: settings.nodes ? 0 : settings.searchMs,
      infinite: settings.infinite && !settings.nodes,
      short: !!settings.nodes,
    };
    this.continuation = null;
    if (this.running) { this.running.paused = false; this.supersede(); }
    else this.next();
  }

  /** Stops the analysis and forgets it; background evaluations carry on. */
  stop() {
    this.main = null;
    this.continuation = null;
    if (this.running?.job.main) { this.running.paused = false; this.supersede(); }
  }

  /** Searches `fen` for `nodes` nodes once the analysis is done; null when cancelled or failed. */
  evaluate(fen: string, nodes: number): Promise<EngineResult | null> {
    return new Promise((settle) => {
      this.background.push({ fen, nodes, millis: 0, lines: 1, main: false, settle });
      if (!this.running) this.next();
      // The unlimited search gives way, and carries on afterwards.
      else if (this.running.job.continued && !this.running.superseded) { this.running.paused = true; this.supersede(); }
    });
  }

  /** Drops every background evaluation, the running one included. */
  cancelEvaluations() {
    for (const job of this.background) job.settle?.(null);
    this.background = [];
    if (this.running && !this.running.job.main && !this.running.dropped) {
      this.running.dropped = true;
      this.running.job.settle?.(null);
      this.supersede();
    }
  }

  /** Stops the running search; the next job starts on its `bestmove`. */
  private supersede() {
    if (!this.running || this.running.superseded) return;
    this.running.superseded = true;
    this.module?.uci('stop');
  }

  private setOption(name: string, value: string) {
    if (this.sent.get(name) === value) return;
    this.sent.set(name, value);
    this.module!.uci(`setoption name ${name} value ${value}`);
  }

  private next() {
    if (this.running || !this.module) return;
    const job = this.main ?? this.background.shift() ?? this.continuation;
    if (!job) return;
    if (job === this.main) this.main = null;
    if (job === this.continuation) this.continuation = null;
    this.running = { job, started: performance.now(), lines: new Map(), nodes: 0, nps: 0, superseded: false, dropped: false };
    this.setOption('Threads', String(this.threads));
    this.setOption('Hash', String(HASH_MB));
    this.setOption('MultiPV', String(job.lines));
    this.setOption('UCI_AnalyseMode', 'true');
    this.module.uci(`position fen ${job.fen}`);
    this.module.uci(job.nodes ? `go nodes ${job.nodes}` : job.millis ? `go movetime ${job.millis}` : 'go infinite');
  }

  private received(line: string) {
    const running = this.running;
    if (line.startsWith('bestmove')) { if (running) this.finish(running); return; }
    if (!running || running.superseded || !line.startsWith('info ') || !line.includes(' pv ')) return;
    const parts = line.split(' ');
    let depth = 0, multipv = 1, cp: number | undefined, mate: number | undefined, bound = false, nps = 0, nodes = 0;
    let i = 1;
    for (; i < parts.length; i++) {
      const key = parts[i];
      if (key === 'depth') depth = Number(parts[++i]);
      else if (key === 'multipv') multipv = Number(parts[++i]);
      else if (key === 'nps') nps = Number(parts[++i]);
      else if (key === 'nodes') nodes = Number(parts[++i]);
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
    const sign = running.job.fen.split(' ')[1] === 'b' ? -1 : 1;
    if (multipv === 1) running.lines = new Map([...running.lines].filter(([, l]) => l.depth >= depth - 1));
    running.lines.set(multipv, { multipv, depth, pv, cp: cp === undefined ? undefined : cp * sign, mate: mate === undefined ? undefined : mate * sign });
    if (nps) running.nps = nps;
    if (nodes) running.nodes = nodes;
    if (running.job.main) {
      const result = this.result(running, false);
      if (result) this.onResult(result);
    }
  }

  private result(running: Running, done: boolean): EngineResult | null {
    const { job } = running;
    const lines = [...running.lines.values()].sort((a, b) => a.multipv - b.multipv).slice(0, job.lines);
    if (!lines.length) return null;
    const depth = lines[0].depth;
    return {
      fen: job.fen, depth, nodes: running.nodes, millis: performance.now() - running.started, lines, done,
      complete: done && !job.short, budget: job.millis,
      info: `Depth ${depth}${job.continued ? '/∞' : ''} · ${speed(running.nps)}`,
    };
  }

  private finish(running: Running) {
    this.running = null;
    const { job } = running;
    if (running.requeue) {
      if (job.continued) this.continuation ??= job;
      else if (job.main) this.main ??= job;
      else if (!running.dropped) this.background.unshift(job);
    } else if (job.main) {
      if (!running.superseded) {
        const result = this.result(running, true);
        if (result) this.onResult(result);
        if (job.infinite && !this.main) this.continuation = { ...job, millis: 0, infinite: false, continued: true };
      }
      if (running.paused && !this.main) this.continuation = job;
    } else if (running.dropped) { /* Settled when it was cancelled. */ }
    else if (running.superseded) this.background.unshift(job); // stopped for the analysis: run it again later
    else job.settle?.(this.result(running, true));
    this.next();
  }
}
