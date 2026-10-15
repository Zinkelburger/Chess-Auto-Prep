/**
 * Hivemind, the bughouse engine, searching one board: the partner board is
 * held still behind it (tools/bughouse_web/patches/frozen-board.patch), so
 * every capture leaves for the partner and nothing arrives unless a hand is
 * edited. The search runs in one browser worker (hivemind.worker.ts), on the
 * GPU when the browser offers WebGPU and on the CPU otherwise.
 *
 * One worker serves two kinds of search. The analysis of the shown position
 * comes first: it reports a few times a second and stops at its time limit,
 * as Lichess's engine does. Background evaluations (the sit panel's rows) run
 * after it, one at a time. A new position stops whatever is running. With
 * infinite analysis, the position's search carries on without a limit once
 * the background evaluations are done: the worker keeps the analysis's tree,
 * so it goes on from where it stopped.
 *
 * A search that stops answering, or a worker that crashes, is stopped and
 * reported, and the next search starts a new worker (on the CPU after a hang).
 * On a phone or a data-saving connection the engine waits for the player
 * before its first download. Changing where the network runs (GPU or CPU) or
 * the CPU threads starts a new worker, which carries on with the same work.
 *
 * Hivemind's value is a winning chance from the side to move. Lines carry it
 * as Lichess's centipawns for that chance, from White's side, so the panel,
 * the arrows and the move marks read them as they would read Stockfish's.
 */
import type { Backend, WorkerReply, WorkerRequest } from './hivemind.worker';

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
  /** "1,234 positions · 380/s", under the engine name. */
  info: string;
}

export interface SearchSettings {
  multiPv: number;
  infinite: boolean;
  /** Search time; infinite analysis carries on after it. */
  searchMs: number;
  /** Stop after this many positions instead of the time limit (practice). */
  nodes?: number;
}

export type EngineStatus =
  | { kind: 'off' }
  /** Waits for the player before downloading `megabytes` (phones and data saving). */
  | { kind: 'ask'; megabytes: number }
  /** `fraction` of the download, while downloading. */
  | { kind: 'loading'; text: string; fraction?: number }
  /** `error`: the last analysis of `fen` failed; the engine still runs. */
  | { kind: 'ready'; backend: string; gpu: boolean; error?: { fen: string; text: string } }
  | { kind: 'failed'; text: string };

/** Where the network runs and on how many CPU threads. */
export interface Hardware { gpu: boolean; threads: number }
const INFINITE_MS = 3_600_000;
const REPORT_MS = 400;
const MAX_NODES = 1_000_000;
/** A search silent this long past its time limit has hung (a lost GPU device, a stuck inference). */
const HANG_MS = 30_000;
/** Tests can force the CPU path: localStorage `bughouse-engine-backend` = `cpu`. */
const BACKEND_KEY = 'bughouse-engine-backend';
/** Set once the engine has loaded in this browser: its files are then in the cache. */
const LOADED_KEY = 'bughouse-engine-loaded';
/** The first download: the network and ONNX Runtime's WebGPU build. */
export const DOWNLOAD_MB = 55;

/** A frozen-board search report from the worker; values from the side to move, mate in plies. */
export interface FrozenSearch {
  q: number; mate: number | null; nodes: number; depth: number; elapsed_ms: number; done: boolean;
  /** Nodes a resumed search had before this one started. */
  resumed_nodes?: number;
  lines: { q: number; mate: number | null; visits: number; pv: string[] }[];
}

/** Lichess's centipawns for a winning chance (the inverse of lila's winningChances). */
export function centipawns(q: number): number {
  const w = Math.max(-0.999, Math.min(0.999, q));
  return Math.round(Math.log((1 + w) / (1 - w)) / 0.00368208);
}

/** Mate in moves from a mate in plies, with the sign of who mates. */
export function mateMoves(plies: number): number {
  return Math.sign(plies) * Math.max(1, Math.ceil(Math.abs(plies) / 2));
}

/** One search report as an engine result, scored from White's side. */
export function toResult(fen: string, report: FrozenSearch, done: boolean, complete = done, budget = 0): EngineResult {
  const sign = fen.split(' ')[1] === 'b' ? -1 : 1;
  const lines: EngineLine[] = report.lines.map((line, i) => ({
    multipv: i + 1,
    depth: report.depth,
    pv: line.pv,
    ...(line.mate !== null ? { mate: sign * mateMoves(line.mate) } : { cp: sign * centipawns(line.q) }),
  }));
  const seconds = report.elapsed_ms / 1000;
  const rate = seconds > 0.2 ? Math.round((report.nodes - (report.resumed_nodes ?? 0)) / seconds) : 0;
  return {
    fen, depth: report.depth, nodes: report.nodes, millis: report.elapsed_ms, lines, done, complete, budget,
    info: `${report.nodes.toLocaleString()} positions${rate ? ` · ${rate.toLocaleString()}/s` : ''}`,
  };
}

interface Job {
  fen: string;
  nodes: number;
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

export class Engine {
  private worker: Worker | null = null;
  private loading: Promise<void> | null = null;
  private status: EngineStatus = { kind: 'off' };
  private backend: Backend | null = null;
  private main: Job | null = null;
  private background: Job[] = [];
  /** Infinite analysis's unlimited search, waiting for the background evaluations. */
  private continuation: Job | null = null;
  /**
   * `superseded`: stopped for other work; `dropped`: its evaluation was
   * cancelled; `paused`: the unlimited search gave way to an evaluation and
   * carries on after it.
   */
  private running: { job: Job; id: number; superseded: boolean; dropped: boolean; paused?: boolean } | null = null;
  private serial = 0;
  private watchdog = 0;
  /** After a hang the next worker runs on the CPU. */
  private preferCpu = false;
  /** The player agreed to the first download (or it is not asked for). */
  private allowed = false;
  private hardware: Hardware = { gpu: true, threads: 1 };
  /** The hardware the current worker was started with. */
  private started: Hardware | null = null;
  /** Whether the browser offers WebGPU; null until a worker has loaded. */
  private webgpu: boolean | null = null;

  constructor(
    private readonly onStatus: (status: EngineStatus) => void,
    private readonly onResult: (result: EngineResult) => void,
  ) {}

  get current(): EngineStatus { return this.status; }

  private setStatus(status: EngineStatus) {
    this.status = status;
    this.onStatus(status);
  }

  get gpu(): boolean { return this.backend?.kind === 'gpu'; }
  get gpuAvailable(): boolean | null { return this.webgpu; }

  /** Sets where the network runs; a worker started otherwise is replaced. */
  configure(hardware: Hardware) {
    this.hardware = { ...hardware };
    const started = this.started;
    if (!started || (started.gpu === hardware.gpu && started.threads === hardware.threads)) return;
    // Threads matter only to a worker on the CPU.
    if (started.gpu && hardware.gpu && this.backend?.kind === 'gpu') { this.started = { ...hardware }; return; }
    this.restart();
  }

  /** Replaces the worker; the running search is queued again for the new one. */
  private restart() {
    clearTimeout(this.watchdog);
    this.worker?.terminate();
    this.worker = null;
    this.loading = null;
    this.backend = null;
    this.started = null;
    const running = this.running;
    this.running = null;
    if (running && !running.superseded) {
      const { job } = running;
      if (job.continued) this.continuation ??= job;
      else if (job.main) this.main ??= job;
      else if (!running.dropped) this.background.unshift(job);
    }
    void this.load().catch(() => undefined);
  }

  /** Whether the first download waits for the player: a phone, a tablet or a data-saving connection, before the files are cached. */
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

  /** Starts the worker and loads the network; later calls share the same start. */
  load(): Promise<void> {
    if (!this.loading && this.mustAsk()) {
      if (this.status.kind !== 'ask') this.setStatus({ kind: 'ask', megabytes: DOWNLOAD_MB });
      return Promise.reject(new Error('waiting for the player'));
    }
    this.loading ??= new Promise<void>((resolve, reject) => {
      this.setStatus({ kind: 'loading', text: 'Starting Hivemind…' });
      const worker = new Worker(new URL('./hivemind.worker.ts', import.meta.url), { type: 'module' });
      this.worker = worker;
      worker.onmessage = ({ data }: MessageEvent<WorkerReply>) => {
        if (worker !== this.worker) return;
        if (data.type === 'progress') {
          if (!this.backend) this.setStatus({ kind: 'loading', text: data.text, fraction: data.total ? (data.done ?? 0) / data.total : undefined });
          return;
        }
        if (data.type === 'ready') {
          // Again after a GPU failure: the worker carries on on the CPU.
          this.backend = data.backend;
          this.webgpu = data.backend.gpuAvailable;
          const gpu = data.backend.kind === 'gpu';
          this.setStatus({ kind: 'ready', gpu, backend: gpu ? 'GPU' : `CPU × ${data.backend.threads}` });
          try { localStorage.setItem(LOADED_KEY, '1'); } catch { /* Asked again next visit. */ }
          resolve();
          this.next();
          return;
        }
        if (data.type === 'failed' && data.id === undefined) {
          this.reset(data.error);
          reject(new Error(data.error));
          return;
        }
        this.reply(data);
      };
      worker.onerror = (event) => {
        event.preventDefault();
        if (worker !== this.worker) return;
        this.reset('The engine stopped.');
        reject(new Error('worker error'));
      };
      let prefer: 'auto' | 'cpu' = this.preferCpu || !this.hardware.gpu ? 'cpu' : 'auto';
      try { if (localStorage.getItem(BACKEND_KEY) === 'cpu') prefer = 'cpu'; } catch { /* Auto. */ }
      this.started = { ...this.hardware };
      this.post({ type: 'load', prefer, threads: this.hardware.threads });
    });
    this.loading.catch(() => undefined);
    return this.loading;
  }

  /**
   * Drops the worker after a failure: the running search is lost (a
   * background one answers null), and the next load starts a new worker.
   */
  private reset(text: string) {
    clearTimeout(this.watchdog);
    this.worker?.terminate();
    this.worker = null;
    this.loading = null;
    this.backend = null;
    this.started = null;
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
      nodes: settings.nodes ?? MAX_NODES,
      millis: settings.nodes ? 120_000 : settings.searchMs,
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

  /** Searches `fen` for `nodes` positions once the analysis is done; null when cancelled or failed. */
  evaluate(fen: string, nodes: number): Promise<EngineResult | null> {
    return new Promise((settle) => {
      this.background.push({ fen, nodes, millis: 120_000, lines: 1, main: false, settle });
      if (!this.running) this.next();
      // The unlimited search gives way, and carries on from its tree afterwards.
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

  private post(message: WorkerRequest) { this.worker?.postMessage(message); }

  /** Stops the running search; its answer is then dropped and the next job starts. */
  private supersede() {
    if (!this.running || this.running.superseded) return;
    this.running.superseded = true;
    this.post({ type: 'cancel' });
  }

  private next() {
    if (this.running || !this.backend) return;
    const job = this.main ?? this.background.shift() ?? this.continuation;
    if (!job) return;
    if (job === this.main) this.main = null;
    if (job === this.continuation) this.continuation = null;
    const id = ++this.serial;
    this.running = { job, id, superseded: false, dropped: false };
    this.post({ type: 'search', id, fen: job.fen, nodes: job.nodes, millis: job.millis, lines: job.lines, reportMs: job.main ? REPORT_MS : 0, keep: job.main });
    // The analysis reports a few times a second; a background search answers once, at its end.
    this.guard(job.main ? REPORT_MS : job.millis);
  }

  /** Restarts the hang timer: a search silent for `millis` and HANG_MS more has hung. */
  private guard(millis: number) {
    clearTimeout(this.watchdog);
    this.watchdog = window.setTimeout(() => {
      this.preferCpu = true;
      this.reset('The engine stopped answering.');
    }, millis + HANG_MS);
  }

  private reply(data: WorkerReply) {
    const running = this.running;
    if (!running || !('id' in data) || data.id !== running.id) return;
    const { job } = running;
    if (data.type === 'report') {
      if (job.main) this.guard(REPORT_MS);
      const report = data.data as FrozenSearch;
      if (job.main && !running.superseded && report.lines?.length) this.onResult(toResult(job.fen, report, false));
      return;
    }
    clearTimeout(this.watchdog);
    this.running = null;
    if (data.type === 'done') {
      const final = data.data as FrozenSearch;
      const done = !running.superseded;
      const result = final.lines.length ? toResult(job.fen, final, done, done && !job.short, job.millis) : null;
      if (job.main) {
        if (result && !running.superseded) this.onResult(result);
        if (job.infinite && !running.superseded && !this.main)
          this.continuation = { ...job, millis: INFINITE_MS, infinite: false, continued: true };
        if (running.paused && !this.main) this.continuation = job;
        this.clearError(job.fen);
      } else if (running.dropped) { /* Settled when it was cancelled. */ }
      else if (running.superseded) this.background.unshift(job); // stopped for the analysis: run it again later
      else job.settle?.(result);
    } else if (data.type === 'failed') {
      // One position failing leaves the engine running: the next search may well succeed.
      if (job.main && !running.superseded && this.status.kind === 'ready')
        this.setStatus({ ...this.status, error: { fen: job.fen, text: data.error } });
      if (!job.main && !running.dropped) job.settle?.(null);
    }
    this.next();
  }

  private clearError(fen: string) {
    if (this.status.kind === 'ready' && this.status.error?.fen === fen) this.setStatus({ kind: 'ready', backend: this.status.backend, gpu: this.status.gpu });
  }
}
