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
 * infinite analysis, the position is searched again without a limit once the
 * background evaluations are done; that search is shown once it has looked
 * at more positions than the first.
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
  /** "1,234 positions · 380/s", under the engine name. */
  info: string;
}

export interface SearchSettings {
  multiPv: number;
  infinite: boolean;
  /** Stop after this many positions instead of the time limit (practice). */
  nodes?: number;
}

export type EngineStatus =
  | { kind: 'off' }
  | { kind: 'loading'; text: string }
  | { kind: 'ready'; backend: string }
  | { kind: 'failed'; text: string };

/** Without infinite analysis a position is searched this long. */
export const SEARCH_MS = 10_000;
const INFINITE_MS = 3_600_000;
const REPORT_MS = 400;
const MAX_NODES = 1_000_000;
/** Tests can force the CPU path: localStorage `bughouse-engine-backend` = `cpu`. */
const BACKEND_KEY = 'bughouse-engine-backend';

/** A frozen-board search report from the worker; values from the side to move, mate in plies. */
export interface FrozenSearch {
  q: number; mate: number | null; nodes: number; depth: number; elapsed_ms: number; done: boolean;
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
export function toResult(fen: string, report: FrozenSearch, done: boolean): EngineResult {
  const sign = fen.split(' ')[1] === 'b' ? -1 : 1;
  const lines: EngineLine[] = report.lines.map((line, i) => ({
    multipv: i + 1,
    depth: report.depth,
    pv: line.pv,
    ...(line.mate !== null ? { mate: sign * mateMoves(line.mate) } : { cp: sign * centipawns(line.q) }),
  }));
  const seconds = report.elapsed_ms / 1000;
  const rate = seconds > 0.2 ? Math.round(report.nodes / seconds) : 0;
  return {
    fen, depth: report.depth, nodes: report.nodes, millis: report.elapsed_ms, lines, done,
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
  /** Reports are shown from this many positions on (the unlimited search repeats the first one's work). */
  shownFrom?: number;
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
  /** `superseded`: stopped for other work; `dropped`: its evaluation was cancelled. */
  private running: { job: Job; id: number; superseded: boolean; dropped: boolean } | null = null;
  private serial = 0;

  constructor(
    private readonly onStatus: (status: EngineStatus) => void,
    private readonly onResult: (result: EngineResult) => void,
  ) {}

  get current(): EngineStatus { return this.status; }

  private setStatus(status: EngineStatus) {
    this.status = status;
    this.onStatus(status);
  }

  /** Starts the worker and loads the network; later calls share the same start. */
  load(): Promise<void> {
    this.loading ??= new Promise<void>((resolve, reject) => {
      this.setStatus({ kind: 'loading', text: 'Starting Hivemind…' });
      const worker = new Worker(new URL('./hivemind.worker.ts', import.meta.url), { type: 'module' });
      this.worker = worker;
      worker.onmessage = ({ data }: MessageEvent<WorkerReply>) => {
        if (data.type === 'progress') { if (!this.backend) this.setStatus({ kind: 'loading', text: data.text }); return; }
        if (data.type === 'ready') {
          this.backend = data.backend;
          this.setStatus({ kind: 'ready', backend: data.backend.kind === 'gpu' ? 'GPU' : `CPU × ${data.backend.threads}` });
          resolve();
          this.next();
          return;
        }
        if (data.type === 'failed' && data.id === undefined) {
          this.loading = null;
          this.worker?.terminate();
          this.worker = null;
          this.setStatus({ kind: 'failed', text: data.error });
          reject(new Error(data.error));
          return;
        }
        this.reply(data);
      };
      worker.onerror = () => {
        this.loading = null;
        this.worker = null;
        this.setStatus({ kind: 'failed', text: 'The engine stopped. Reload to try again.' });
        reject(new Error('worker error'));
      };
      let prefer: 'auto' | 'cpu' = 'auto';
      try { if (localStorage.getItem(BACKEND_KEY) === 'cpu') prefer = 'cpu'; } catch { /* Auto. */ }
      this.post({ type: 'load', prefer });
    });
    this.loading.catch(() => undefined);
    return this.loading;
  }

  /** Searches `fen` from now on, before any background evaluation; a search in progress is stopped first. */
  analyse(fen: string, settings: SearchSettings) {
    this.main = {
      fen, main: true, lines: settings.multiPv,
      nodes: settings.nodes ?? MAX_NODES,
      millis: settings.nodes ? 120_000 : SEARCH_MS,
      infinite: settings.infinite && !settings.nodes,
    };
    this.continuation = null;
    if (this.running) this.supersede();
    else this.next();
  }

  /** Stops the analysis and forgets it; background evaluations carry on. */
  stop() {
    this.main = null;
    this.continuation = null;
    if (this.running?.job.main) this.supersede();
  }

  /** Searches `fen` for `nodes` positions once the analysis is done; null when cancelled or failed. */
  evaluate(fen: string, nodes: number): Promise<EngineResult | null> {
    return new Promise((settle) => {
      this.background.push({ fen, nodes, millis: 120_000, lines: 1, main: false, settle });
      if (!this.running) this.next();
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
    this.post({ type: 'search', id, fen: job.fen, nodes: job.nodes, millis: job.millis, lines: job.lines, reportMs: job.main ? REPORT_MS : 0 });
  }

  private reply(data: WorkerReply) {
    const running = this.running;
    if (!running || !('id' in data) || data.id !== running.id) return;
    const { job } = running;
    if (data.type === 'report') {
      const report = data.data as FrozenSearch;
      if (job.main && !running.superseded && report.lines?.length && report.nodes >= (job.shownFrom ?? 0))
        this.onResult(toResult(job.fen, report, false));
      return;
    }
    this.running = null;
    if (data.type === 'done') {
      const final = data.data as FrozenSearch;
      const result = final.lines.length ? toResult(job.fen, final, !running.superseded) : null;
      if (job.main) {
        if (result && !running.superseded && final.nodes >= (job.shownFrom ?? 0)) this.onResult(result);
        if (job.infinite && !running.superseded && !this.main)
          this.continuation = { ...job, millis: INFINITE_MS, infinite: false, shownFrom: final.nodes };
      } else if (running.dropped) { /* Settled when it was cancelled. */ }
      else if (running.superseded) this.background.unshift(job); // stopped for the analysis: run it again later
      else job.settle?.(result);
    } else if (data.type === 'failed') {
      if (job.main && !running.superseded) this.setStatus({ kind: 'failed', text: data.error });
      if (!running.dropped) job.settle?.(null);
    }
    this.next();
  }
}
