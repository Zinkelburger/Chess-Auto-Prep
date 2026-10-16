/**
 * Stockfish 18 in this browser (public/stockfish/, the single-threaded
 * build with its small network inside), spoken to over UCI.
 *
 * `Stockfish` is one engine worker running one search at a time, reporting
 * its lines as it deepens. Lines are scored from White's side, as Lichess's
 * engine panel shows them. `StockfishPool` keeps several of them busy for the
 * expectimax search, which asks for many fixed-depth searches at once.
 */

/** One principal variation, scored from White's side. */
export interface EngineLine {
  multipv: number;
  depth: number;
  cp?: number;
  mate?: number;
  pv: string[];
}

export interface SearchReport {
  depth: number;
  nodes: number;
  nps: number;
  millis: number;
  lines: EngineLine[];
}

export interface Go {
  multiPv: number;
  depth?: number;
  movetime?: number;
  infinite?: boolean;
}

const ENGINE_PATH = '/stockfish/stockfish.js';
const BOOT_MS = 60_000;

export class Stockfish {
  private worker: Worker;
  private ready: Promise<void>;
  private listener: ((line: string) => void) | null = null;
  private bootWaiter: ((line: string) => void) | null = null;
  private multiPv = 1;
  private busy: Promise<void> = Promise.resolve();
  private failed: Error | null = null;
  private stopping = false;
  /** Raised by `stop()`: a search asked for before it and not yet started is dropped. */
  private generation = 0;

  constructor(hashMb = 32) {
    this.worker = new Worker(ENGINE_PATH);
    this.worker.onmessage = (e: MessageEvent) => {
      const line = String(e.data);
      this.bootWaiter?.(line);
      this.listener?.(line);
    };
    this.worker.onerror = (e) => { this.failed = new Error(e.message || 'Stockfish stopped.'); this.listener?.('bestmove (none)'); };
    this.ready = this.boot(hashMb);
  }

  private async boot(hashMb: number) {
    await this.until('uci', (l) => l === 'uciok');
    this.send(`setoption name Hash value ${hashMb}`);
    await this.until('isready', (l) => l === 'readyok');
  }

  private until(cmd: string, test: (line: string) => boolean): Promise<void> {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => { this.bootWaiter = null; reject(new Error('Stockfish did not start. Reload the page to try again.')); }, BOOT_MS);
      this.bootWaiter = (line) => { if (test(line)) { clearTimeout(timer); this.bootWaiter = null; resolve(); } };
      this.send(cmd);
    });
  }

  private send(cmd: string) { this.worker.postMessage(cmd); }

  /** Resolves once the engine answers, or with its start-up error. */
  started(): Promise<void> { return this.ready; }

  /**
   * Searches a position; `report` hears each deeper set of lines. Resolves with
   * the last report once Stockfish sends its best move, also after `stop()`.
   * Searches queue: a new one waits until the previous has ended.
   */
  search(fen: string, go: Go, report?: (r: SearchReport) => void): Promise<SearchReport> {
    const generation = this.generation;
    const run = this.busy.then(() => this.run(fen, go, generation, report));
    this.busy = run.then(() => undefined, () => undefined);
    return run;
  }

  private async run(fen: string, go: Go, generation: number, report?: (r: SearchReport) => void): Promise<SearchReport> {
    await this.ready;
    if (this.failed) throw this.failed;
    if (generation !== this.generation) return { depth: 0, nodes: 0, nps: 0, millis: 0, lines: [] };
    this.stopping = false;
    const black = fen.split(' ')[1] === 'b';
    const started = performance.now();
    const lines = new Map<number, EngineLine>();
    let depth = 0, nodes = 0, nps = 0;
    const snapshot = (): SearchReport => ({
      depth, nodes, nps, millis: performance.now() - started,
      lines: [...lines.values()].sort((a, b) => a.multipv - b.multipv),
    });
    if (go.multiPv !== this.multiPv) { this.send(`setoption name MultiPV value ${go.multiPv}`); this.multiPv = go.multiPv; }
    return new Promise<SearchReport>((resolve, reject) => {
      this.listener = (line) => {
        if (line.startsWith('bestmove')) {
          this.listener = null;
          if (this.failed) reject(this.failed); else resolve(snapshot());
          return;
        }
        if (!line.startsWith('info ') || !line.includes(' pv ') || line.includes('bound')) return;
        const at = parseInfo(line, black);
        if (!at) return;
        nodes = at.nodes ?? nodes;
        nps = at.nps ?? nps;
        // A deeper first line starts a new set; the others follow at that depth.
        if (at.line.multipv === 1 && at.line.depth > depth) depth = at.line.depth;
        lines.set(at.line.multipv, at.line);
        if (report && at.line.multipv === Math.min(go.multiPv, lines.size) && !this.stopping) report(snapshot());
      };
      this.send(`position fen ${fen}`);
      this.send(go.infinite ? 'go infinite' : go.depth ? `go depth ${go.depth}` : `go movetime ${go.movetime ?? 1000}`);
    });
  }

  /** Ends the running search, which resolves with what it found, and drops the ones waiting. */
  stop() {
    this.generation++;
    if (!this.listener) return;
    this.stopping = true;
    this.send('stop');
  }

  terminate() {
    this.failed ??= new Error('Stockfish was closed.');
    this.listener?.('bestmove (none)');
    this.worker.terminate();
  }
}

function parseInfo(line: string, black: boolean): { line: EngineLine; nodes?: number; nps?: number } | null {
  const num = (name: string) => {
    const m = new RegExp(`\\b${name} (-?\\d+)`).exec(line);
    return m ? Number(m[1]) : undefined;
  };
  const depth = num('depth'), cp = num('score cp'), mate = num('score mate');
  const pv = / pv (.+)$/.exec(line)?.[1].trim().split(/\s+/);
  if (depth === undefined || !pv?.length || (cp === undefined && mate === undefined)) return null;
  const sign = black ? -1 : 1;
  return {
    line: {
      multipv: num('multipv') ?? 1,
      depth,
      ...(mate !== undefined ? { mate: sign * mate } : { cp: sign * cp! }),
      pv,
    },
    nodes: num('nodes'),
    nps: num('nps'),
  };
}

/** Engine workers for many fixed-depth searches at once: leave a core for the page, and spare a phone's memory. */
export function poolSize(): number {
  const cores = navigator.hardwareConcurrency || 2;
  const memory = (navigator as Navigator & { deviceMemory?: number }).deviceMemory ?? 8;
  return Math.max(1, Math.min(memory <= 4 ? 2 : 6, cores - 1));
}

export class EngineStopped extends Error {
  constructor() { super('Stopped'); this.name = 'EngineStopped'; }
}

interface Job { fen: string; go: Go; resolve: (r: SearchReport) => void; reject: (e: Error) => void; signal: AbortSignal }

/**
 * Several Stockfish workers behind one queue of fixed-depth searches. Workers
 * start one at a time, while the queue has work no started worker can take,
 * so a slow machine is not asked to compile every engine at once; a job goes
 * only to a started worker. A worker that fails leaves the pool, and its job
 * goes back to the queue while another worker can run it.
 */
export class StockfishPool {
  private engines: Stockfish[] = [];
  private idle: Stockfish[] = [];
  private queue: Job[] = [];
  private running = new Map<Stockfish, Job>();
  private booting = false;

  constructor(private readonly size = poolSize()) {}

  search(fen: string, go: Go, signal: AbortSignal): Promise<SearchReport> {
    if (signal.aborted) return Promise.reject(new EngineStopped());
    return new Promise((resolve, reject) => {
      const job: Job = { fen, go, resolve, reject, signal };
      signal.addEventListener('abort', () => {
        const i = this.queue.indexOf(job);
        if (i >= 0) { this.queue.splice(i, 1); reject(new EngineStopped()); }
        for (const [engine, j] of this.running) if (j === job) engine.stop();
      }, { once: true });
      this.queue.push(job);
      this.pump();
    });
  }

  private pump() {
    while (this.queue.length && this.idle.length) this.run(this.idle.pop()!, this.queue.shift()!);
    if (this.queue.length && !this.booting && this.engines.length < this.size) this.boot();
  }

  private boot() {
    const engine = new Stockfish(16);
    this.engines.push(engine);
    this.booting = true;
    engine.started().then(
      () => { this.booting = false; this.idle.push(engine); this.pump(); },
      (e: Error) => {
        this.booting = false;
        this.drop(engine);
        // With no engine left to run them, the waiting jobs fail with the reason.
        if (!this.engines.length) { for (const job of this.queue) job.reject(e); this.queue = []; }
        else this.pump();
      },
    );
  }

  private run(engine: Stockfish, job: Job) {
    this.running.set(engine, job);
    engine.search(job.fen, job.go).then(
      (r) => {
        this.running.delete(engine);
        this.idle.push(engine);
        if (job.signal.aborted) job.reject(new EngineStopped()); else job.resolve(r);
        this.pump();
      },
      (e: Error) => {
        this.running.delete(engine);
        this.drop(engine);
        if (job.signal.aborted) job.reject(new EngineStopped());
        else if (this.engines.length) this.queue.unshift(job);
        else job.reject(e);
        this.pump();
      },
    );
  }

  private drop(engine: Stockfish) {
    this.engines = this.engines.filter((x) => x !== engine);
    this.idle = this.idle.filter((x) => x !== engine);
    engine.terminate();
  }

  dispose() {
    for (const job of this.queue) job.reject(new EngineStopped());
    this.queue = [];
    for (const e of this.engines) e.terminate();
    this.engines = [];
    this.idle = [];
  }
}
