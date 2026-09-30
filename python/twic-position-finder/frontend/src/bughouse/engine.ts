import type { Analysis, EngineAction, EngineReply, JointMove } from './types';
export type { JointMove } from './types';

/** Payload of the worker's `search` action: one node-budgeted Hivemind search. */
export interface NodeSearchPayload {
  dual_fen: string;
  /** Our colour on board A (partner plays the other colour on board B). */
  team: 'white' | 'black';
  time_advantage: boolean;
  /** Node budget, 1..100000. */
  nodes: number;
  /** Time cap in ms, 1..120000 (default 60000). */
  movetime_ms?: number;
}

/** Raw `search` result. q is in [-1, 1] from `team`'s side; mate is in plies. */
export interface NodeSearchResult {
  q: number;
  mate: number | null;
  nodes: number;
  elapsed_ms: number;
  best: JointMove | null;
  /** Native UCI pv tokens, e.g. "(d2d4,pass)", "(P@f7,e2e4)". */
  pv: string[];
  lines: { best: JointMove }[];
  /** Each board's moves the search expanded, most visited first; sitting left out. */
  moves: { board: 'A' | 'B'; uci: string; prior: number; visits: number }[];
}

/** One browser worker owns both Hivemind WASM and ONNX inference. No API. */
export class BrowserEngine {
  private worker: Worker | null = null;
  private serial = 0;
  private pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void; partial?: (analysis: Analysis) => void }>();

  constructor(private progress: (message: string) => void) {}

  request<T>(action: EngineAction, payload: object, partial?: (analysis: Analysis) => void): Promise<T> {
    if (!this.worker) {
      this.worker = new Worker(new URL('./engine.worker.ts', import.meta.url), { type: 'module' });
      this.worker.onmessage = ({ data }: MessageEvent<EngineReply>) => {
        if (data.progress) { this.progress(data.progress); return; }
        const pending = data.id === undefined ? undefined : this.pending.get(data.id);
        if (!pending) return;
        if (data.partial) { pending.partial?.(data.partial); return; }
        this.pending.delete(data.id!);
        if (data.error) pending.reject(new Error(data.error));
        else pending.resolve(data.result);
      };
      this.worker.onerror = () => {
        for (const request of this.pending.values()) request.reject(new Error('The browser engine stopped. Please retry, or use a shorter search.'));
        this.pending.clear(); this.worker?.terminate(); this.worker = null;
      };
    }
    const id = ++this.serial;
    return new Promise<T>((resolve, reject) => {
      this.pending.set(id, { resolve: (value) => resolve(value as T), reject, partial });
      this.worker!.postMessage({ id, action, payload });
    });
  }

  cancel() { this.worker?.postMessage({ action: 'cancel' }); }
}

/**
 * Several engines, one per core: each worker runs its own WASM and network
 * on one thread, so independent searches run side by side without
 * SharedArrayBuffer or special headers. Workers stay loaded between batches.
 */
export class EnginePool {
  private engines: BrowserEngine[] = [];
  private stopped = false;

  constructor(private progress: (message: string) => void) {}

  /** Available logical cores, and the default of half of them. */
  static cores(): number { return Math.max(1, navigator.hardwareConcurrency || 2); }
  static defaultSize(): number { return Math.max(1, Math.floor(EnginePool.cores() / 2)); }

  private engine(i: number): BrowserEngine {
    // Only the first worker reports loading progress; the rest would repeat it.
    while (this.engines.length <= i) this.engines.push(new BrowserEngine(this.engines.length ? () => {} : this.progress));
    return this.engines[i];
  }

  /**
   * `run` for every item on up to `size` workers, results in item order. The
   * first item runs alone so one worker downloads and caches the network
   * before the others read it from the cache.
   */
  async map<T, R>(size: number, items: T[], run: (engine: BrowserEngine, item: T) => Promise<R>): Promise<R[]> {
    this.stopped = false;
    const out: R[] = new Array(items.length);
    if (!items.length) return out;
    out[0] = await run(this.engine(0), items[0]);
    let next = 1;
    const lane = async (i: number) => {
      while (next < items.length && !this.stopped) {
        const index = next++;
        out[index] = await run(this.engine(i), items[index]);
      }
    };
    // One failed search stops the other workers too.
    await Promise.all(Array.from({ length: Math.max(1, size) }, (_, i) => lane(i)))
      .catch((error) => { this.cancel(); throw error; });
    if (this.stopped) throw new Error('Analysis cancelled.');
    return out;
  }

  cancel() {
    this.stopped = true;
    for (const engine of this.engines) engine.cancel();
  }
}
