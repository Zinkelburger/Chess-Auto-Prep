/**
 * HypeBeast, a bughouse engine on Fairy-Stockfish that plays one board
 * knowing the other (https://github.com/Zinkelburger/HypeBeast), compiled to
 * WebAssembly with Fairy-Stockfish's bughouse net. It is always given both
 * boards (`position fen A|B`) and the seat it plays: the board searched and
 * the side to move there. Before searching that board it searches the other
 * one, reads off what is likely to arrive, and measures what one more piece
 * in hand is worth there; its report of that is kept, so the page shows it
 * without searching again.
 *
 * The module runs on this page's main thread and searches in its own pthread
 * workers, so the page must be cross-origin isolated (COOP/COEP in
 * public/_headers and the dev server). The net (about 28 MB gzipped) comes in
 * parts prepared by tools/prepare_hypebeast_web.py and is kept in the Cache
 * API, so it downloads once; on a phone or a data-saving connection the
 * engine waits for the player before that download.
 *
 * Jobs run one at a time. The shown board's analysis comes first; then, in
 * order, the background jobs the page asks for (the partner board's analysis,
 * a deeper measure of piece values). A new analysis stops whatever is
 * running. Every job ends with the engine's `bestmove`.
 */
import type { Color, Role } from 'chessops/types';

const DIRECTORY = '/hypebeast-engine/';
const CACHE = 'hypebeast-nnue-v1';
/** Set once the engine has loaded in this browser: its net is then in the cache. */
const LOADED_KEY = 'hypebeast-engine-loaded';
/** The first download: the gzipped net and the engine's WebAssembly. */
const DOWNLOAD_MB = 29;
/** Sized by the device's memory, as Lichess does; a phone gets less. */
const HASH_MB = ((navigator as Navigator & { deviceMemory?: number }).deviceMemory ?? 8) >= 8 ? 256 : 64;

interface Chunk { file: string; bytes: number; sha256: string }
interface Manifest { name: string; sha256: string; chunks: Chunk[] }

interface EngineModule {
  uci(command: string): void;
  setNnueBuffer(buffer: Uint8Array, index?: number): void;
  listen: (line: string) => void;
  onError: (line: string) => void;
}

/** One principal variation, scored from White's side of the board searched. */
export interface EngineLine {
  multipv: number;
  depth: number;
  cp?: number;
  mate?: number;
  pv: string[];
}

/** Both boards, board 1's FEN first, and the board searched (0 or 1); the side to move there plays. */
export interface Seat {
  fens: [string, string];
  board: 0 | 1;
  /** The other board is not in play (one board shown): HypeBeast searches this one alone, without looking across. */
  solo?: boolean;
}

export const seatKey = (seat: Seat) => `${seat.fens[0]} | ${seat.fens[1]} # ${seat.board}${seat.solo ? ' solo' : ''}`;

export type HandRole = Exclude<Role, 'king'>;
/** A receiver's gain in centipawns from its own side, "mate" when the piece makes a mate possible, null when not measured. */
export type PieceGain = number | 'mate' | null;

/** What one more piece in hand is worth on one board, to each colour. */
export interface PieceValues {
  board: 0 | 1;
  /** `partner`: read from the other board's search; `board`: measured on this board. */
  source: 'partner' | 'board';
  depth: number;
  turn: Color;
  /** The board as it is, from White's side; null when not measured. */
  base: number | null;
  gains: Record<Color, Record<HandRole, PieceGain>>;
}

/** A likely line on the partner board and what its captures would send. */
export interface ForecastLine {
  move: string;
  weight: number;
  /** `none`, or `+P` (for the searching side) and `-B` (for its opponent), joined: `+P-B`. */
  arrival: string;
  pv: string[];
}

export interface Forecast {
  lines: ForecastLine[];
  /** Packages of arrivals with their chance, `none` first. */
  worlds: { arrival: string; p: number }[];
}

export interface Candidate {
  move: string;
  source: string;
  /** The piece this move sends the partner (a capture), or empty. */
  delivery: string;
  /** Score from the searching side: on this board alone (L) and with what it sends (S). */
  L: number | null;
  S: number | null;
  mating?: boolean;
}

export interface Coordination {
  reason: string;
  candidates: Candidate[];
}

export interface EngineResult {
  key: string;
  seat: Seat;
  /** The board searched. */
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
  /** "Depth 21 · 140 kn/s", under the engine name. */
  info: string;
  /** The move HypeBeast chose, or `pass` when it sits; set once done. */
  decision?: string;
  /** Why (the coordinator's reason). */
  reason?: string;
  coordination?: Coordination;
  forecast?: Forecast;
}

export interface SearchSettings {
  multiPv: number;
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

const turnOf = (fen: string): Color => (fen.split(' ')[1] === 'b' ? 'black' : 'white');
const ROLE_OF: Record<string, HandRole> = { P: 'pawn', N: 'knight', B: 'bishop', R: 'rook', Q: 'queen' };

/** The engine's `hb_values` JSON, as the page keeps it. */
export function readValues(json: string): PieceValues | null {
  try {
    const v = JSON.parse(json) as {
      board: string; source: string; stm: string; depth: number; base: number | null;
      white: Record<string, PieceGain>; black: Record<string, PieceGain>;
    };
    const side = (raw: Record<string, PieceGain>) => Object.fromEntries(
      Object.entries(ROLE_OF).map(([letter, role]) => [role, raw[letter] ?? null])) as Record<HandRole, PieceGain>;
    return {
      board: v.board === 'B' ? 1 : 0, source: v.source === 'partner' ? 'partner' : 'board', depth: v.depth,
      turn: v.stm === 'b' ? 'black' : 'white', base: v.base, gains: { white: side(v.white), black: side(v.black) },
    };
  } catch { return null; }
}

/** `key=value` pairs of a `hb_summary` line. */
function summaryFields(text: string): Record<string, string> {
  const out: Record<string, string> = {};
  for (const pair of text.split(' ')) {
    const at = pair.indexOf('=');
    if (at > 0) out[pair.slice(0, at)] = pair.slice(at + 1);
  }
  return out;
}

/** The engine's seat options for searching `seat`'s board for its side to move. */
function seatOptions(seat: Seat): { Seat: string; Team: string } {
  const turn = turnOf(seat.fens[seat.board]);
  // Team white is White on board A and Black on board B.
  const team = (seat.board === 0) === (turn === 'white') ? 'white' : 'black';
  return { Seat: `${seat.board === 0 ? 'A' : 'B'}${turn}`, Team: team };
}

type Job =
  | {
    kind: 'go'; seat: Seat;
    /** Stop after this many nodes (practice). */
    nodes?: number;
    millis: number; lines: number;
    /** The shown board's analysis; otherwise a background job. */
    main: boolean;
    /** Practice's short search: its result is not the analysis's. */
    short?: boolean;
    settle?: (result: EngineResult | null) => void;
  }
  | { kind: 'values'; seat: Seat; millis: number; main: false; settle?: (values: PieceValues | null) => void };

interface Running {
  job: Job;
  started: number;
  main: EngineLine | null;
  /** Every line of the main search by multipv (one board: HypeBeast searches it alone, with several lines). */
  multi: Map<number, EngineLine>;
  nodes: number;
  nps: number;
  coordination?: Coordination;
  forecast?: Forecast;
  summary?: Record<string, string>;
  values: PieceValues | null;
  /** `superseded`: stopped for other work; `dropped`: its job was cancelled; `requeue`: stopped to change the threads, and runs again. */
  superseded: boolean;
  dropped: boolean;
  requeue?: boolean;
}

export class Engine {
  private module: EngineModule | null = null;
  private loading: Promise<void> | null = null;
  private status: EngineStatus = { kind: 'off' };
  private main: Job | null = null;
  private background: Job[] = [];
  private running: Running | null = null;
  private sent = new Map<string, string>();
  /** The player agreed to the first download (or it is not asked for). */
  private allowed = false;
  private threads = 1;

  constructor(
    private readonly onStatus: (status: EngineStatus) => void,
    /** Every go's report: the analysis while it runs, background searches when they end. */
    private readonly onResult: (result: EngineResult) => void,
    /** Piece values for one board of a pair of positions, keyed by seatKey with that board. */
    private readonly onValues: (key: string, values: PieceValues) => void,
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
    this.setStatus({ kind: 'loading', text: 'Loading HypeBeast…' });
    const manifest: Manifest = await (await download(DIRECTORY + 'net.json')).json();
    let cache: Cache | null = null;
    try { cache = await caches.open(CACHE); } catch { /* Optional download cache. */ }
    const total = manifest.chunks.reduce((sum, c) => sum + c.bytes, 0);
    const done: number[] = manifest.chunks.map(() => 0);
    const buffers = await Promise.all(manifest.chunks.map((chunk, i) => fetchChunk(chunk, cache, (bytes) => {
      done[i] = bytes;
      const got = done.reduce((a, b) => a + b, 0);
      if (got < total) this.setStatus({ kind: 'loading', text: `Downloading the bughouse net · ${Math.round(got / 1e6)} of ${Math.round(total / 1e6)} MB, once`, fraction: got / total });
    })));
    this.setStatus({ kind: 'loading', text: 'Starting HypeBeast…' });
    const net = new Uint8Array(await new Response(new Blob(buffers).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer());
    if (await sha256(net.buffer as ArrayBuffer) !== manifest.sha256) {
      for (const c of manifest.chunks) await cache?.delete(DIRECTORY + c.file).catch(() => undefined);
      throw new Error('The engine net did not check out. Try again to download it again.');
    }
    const scriptUrl = new URL(DIRECTORY + 'hypebeast.js', location.href).href;
    const makeModule = await import(/* @vite-ignore */ scriptUrl);
    const module: EngineModule = await makeModule.default({
      wasmMemory: sharedMemory(),
      locateFile: (file: string) => new URL(DIRECTORY + file, location.href).href,
      mainScriptUrlOrBlob: scriptUrl,
    });
    module.onError = (msg: string) => { if (msg.startsWith('BAD_NNUE')) this.reset('The engine net did not load. Try again.'); };
    module.listen = (line: string) => this.received(line);
    // HypeBeast mode switches the variant to bughouse; the net is read for that variant.
    module.uci('setoption name HypeBeast value true');
    module.setNnueBuffer(net, 0);
    this.module = module;
    this.sent = new Map();
    try { localStorage.setItem(LOADED_KEY, '1'); } catch { /* Asked again next visit. */ }
    this.setStatus({ kind: 'ready', threads: this.threads });
    this.next();
  }

  /** Drops the engine after an error: the running job is lost, and the next load starts a new one. */
  private reset(text: string) {
    this.module = null;
    this.loading = null;
    const running = this.running;
    this.running = null;
    if (running && !running.dropped) this.settle(running.job, null);
    this.setStatus({ kind: 'failed', text });
  }

  /** Searches `seat` from now on, before any background job; a search in progress is stopped first. */
  analyse(seat: Seat, settings: SearchSettings) {
    this.main = {
      kind: 'go', seat, main: true, lines: settings.multiPv,
      nodes: settings.nodes, millis: settings.nodes ? 0 : settings.searchMs, short: !!settings.nodes,
    };
    if (this.running) this.supersede();
    else this.next();
  }

  /** Stops the analysis and forgets it; background jobs carry on. */
  stop() {
    this.main = null;
    if (this.running?.job.main) this.supersede();
  }

  /** Searches `seat` after the analysis, for `millis`; null when cancelled or failed. */
  search(seat: Seat, millis: number, lines: number): Promise<EngineResult | null> {
    return new Promise((settle) => {
      this.background.push({ kind: 'go', seat, millis, lines, main: false, settle });
      if (!this.running) this.next();
    });
  }

  /** Measures what one more piece is worth on `seat`'s board, deepening for `millis`; each depth is reported through onValues. */
  values(seat: Seat, millis: number): Promise<PieceValues | null> {
    return new Promise((settle) => {
      this.background.push({ kind: 'values', seat, millis, main: false, settle });
      if (!this.running) this.next();
    });
  }

  /** Drops every background job, the running one included. */
  cancelBackground() {
    for (const job of this.background) this.settle(job, null);
    this.background = [];
    if (this.running && !this.running.job.main && !this.running.dropped) {
      this.running.dropped = true;
      this.settle(this.running.job, null);
      this.supersede();
    }
  }

  private settle(job: Job, value: EngineResult | PieceValues | null) {
    if (job.kind === 'go') job.settle?.(value as EngineResult | null);
    else job.settle?.(value as PieceValues | null);
  }

  /** Stops the running job; the next one starts on its `bestmove`. */
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
    const job = this.main ?? this.background.shift();
    if (!job) return;
    if (job === this.main) this.main = null;
    this.running = { job, started: performance.now(), main: null, multi: new Map(), nodes: 0, nps: 0, values: null, superseded: false, dropped: false };
    this.setOption('Threads', String(this.threads));
    this.setOption('Hash', String(HASH_MB));
    const { Seat, Team } = seatOptions(job.seat);
    this.setOption('Seat', Seat);
    this.setOption('Team', Team);
    this.setOption('Coordination', job.seat.solo ? 'false' : 'true');
    // Alone, the main search is the whole answer and gives every line; across boards the lines are the moves HypeBeast compared.
    this.setOption('MultiPV', String(job.kind === 'go' && job.seat.solo ? job.lines : 1));
    this.module.uci(`position fen ${job.seat.fens[0]}|${job.seat.fens[1]}`);
    if (job.kind === 'values') this.module.uci(`hbvalues board ${job.seat.board === 0 ? 'A' : 'B'} movetime ${job.millis}`);
    else this.module.uci(job.nodes ? `go nodes ${job.nodes}` : `go movetime ${job.millis}`);
  }

  private received(line: string) {
    const running = this.running;
    if (line.startsWith('bestmove')) { if (running) this.finish(running, line); return; }
    if (!running || running.superseded) return;
    if (line.startsWith('info string ')) { this.report(running, line.slice(12)); return; }
    if (running.job.kind !== 'go' || !line.startsWith('info ') || !line.includes(' pv ')) return;
    // Only the main search prints lines; HypeBeast's searches of other positions are silent.
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
    }
    // Only the first line's bounds are noise; later lines may only ever have bounds.
    if (bound && multipv === 1) return;
    const pv = parts.slice(i + 1).filter(Boolean);
    if (!pv.length) return;
    const sign = turnOf(running.job.seat.fens[running.job.seat.board]) === 'black' ? -1 : 1;
    const parsed: EngineLine = { multipv, depth, pv, cp: cp === undefined ? undefined : cp * sign, mate: mate === undefined ? undefined : mate * sign };
    if (multipv === 1) {
      running.main = parsed;
      running.multi = new Map([...running.multi].filter(([, l]) => l.depth >= depth - 1));
    }
    running.multi.set(multipv, parsed);
    if (nps) running.nps = nps;
    if (nodes) running.nodes = nodes;
    if (running.job.main) {
      const result = this.result(running, false);
      if (result) this.onResult(result);
    }
  }

  /** HypeBeast's own reports: piece values, the forecast, its reasons and its summary. */
  private report(running: Running, text: string) {
    const space = text.indexOf(' ');
    const kind = space < 0 ? text : text.slice(0, space), body = space < 0 ? '' : text.slice(space + 1);
    if (kind === 'hb_values') {
      const values = readValues(body);
      if (!values) return;
      if (running.job.kind === 'values') running.values = values;
      this.onValues(seatKey({ fens: running.job.seat.fens, board: values.board, solo: running.job.seat.solo }), values);
    } else if (kind === 'hb_forecast') {
      try {
        const f = JSON.parse(body) as { lines?: ForecastLine[]; worlds?: { arrival: string; p: number }[] };
        running.forecast = { lines: f.lines ?? [], worlds: f.worlds ?? [] };
      } catch { /* Not shown. */ }
    } else if (kind === 'hb_coord') {
      try {
        const c = JSON.parse(body) as { reason: string; candidates?: Candidate[] };
        running.coordination = { reason: c.reason, candidates: c.candidates ?? [] };
      } catch { /* Not shown. */ }
    } else if (kind === 'hb_summary') running.summary = summaryFields(body);
  }

  /** The lines shown: the main search's while it runs; once done, the move chosen first, then the other moves it compared. */
  private lines(running: Running, decision: string | undefined): EngineLine[] {
    const { job, main, coordination } = running;
    if (job.kind !== 'go') return [];
    const out: EngineLine[] = [];
    if (job.seat.solo) return [...running.multi.values()].sort((a, b) => a.multipv - b.multipv).slice(0, job.lines);
    if (!decision || decision === 'pass') return main ? [main] : [];
    const sign = turnOf(job.seat.fens[job.seat.board]) === 'black' ? -1 : 1;
    const depth = main?.depth ?? 0;
    const scored = (coordination?.candidates ?? [])
      .map((c) => ({ c, score: c.S ?? c.L }))
      .filter((x): x is { c: Candidate; score: number } => x.score !== null && x.score !== undefined)
      .sort((a, b) => b.score - a.score);
    const lineOf = (move: string, score: number | undefined): EngineLine => {
      if (main && main.pv[0] === move) return main;
      return { multipv: 0, depth, pv: [move], cp: score === undefined ? main?.cp : score * sign, mate: score === undefined ? main?.mate : undefined };
    };
    out.push(lineOf(decision, scored.find((x) => x.c.move === decision)?.score));
    for (const { c, score } of scored)
      if (!out.some((l) => l.pv[0] === c.move)) out.push(lineOf(c.move, score));
    return out.slice(0, job.lines).map((l, i) => ({ ...l, multipv: i + 1 }));
  }

  private result(running: Running, done: boolean, decision?: string): EngineResult | null {
    const { job } = running;
    if (job.kind !== 'go') return null;
    const lines = this.lines(running, decision);
    if (!lines.length) return null;
    const depth = Number(running.summary?.main_depth) || lines[0].depth;
    return {
      key: seatKey(job.seat), seat: job.seat, fen: job.seat.fens[job.seat.board],
      depth, nodes: Number(running.summary?.total_nodes) || running.nodes, millis: performance.now() - running.started,
      lines, done, complete: done && !job.short, budget: job.millis,
      info: `Depth ${depth} · ${speed(running.nps)}`,
      decision, reason: running.summary?.reason ?? running.coordination?.reason,
      coordination: running.coordination, forecast: running.forecast,
    };
  }

  private finish(running: Running, line: string) {
    this.running = null;
    const { job } = running;
    if (running.requeue) {
      if (job.main) this.main ??= job;
      else if (!running.dropped) this.background.unshift(job);
    } else if (running.dropped) { /* Settled when it was cancelled. */ }
    else if (running.superseded) {
      // Stopped for the analysis: a background job runs again later.
      if (!job.main) this.background.unshift(job);
    } else if (job.kind === 'values') job.settle?.(running.values);
    else {
      const joint = /^bestmove \(([^,]*),([^)]*)\)/.exec(line);
      const decision = joint ? joint[job.seat.board + 1] : undefined;
      const result = this.result(running, true, decision);
      if (result) this.onResult(result);
      job.settle?.(result);
    }
    this.next();
  }
}
