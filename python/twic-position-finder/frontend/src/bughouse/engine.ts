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

export interface JointMove { A: string; B: string; uci: string }

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
}

/** One browser worker owns both Hivemind WASM and ONNX inference. No API. */
export class BrowserEngine {
  private worker: Worker | null = null;
  private serial = 0;
  private pending = new Map<number, { resolve: (value: unknown) => void; reject: (error: Error) => void }>();

  constructor(private progress: (message: string) => void) {}

  request<T>(action: string, payload: object): Promise<T> {
    if (!this.worker) {
      this.worker = new Worker(new URL('./engine.worker.ts', import.meta.url), { type: 'module' });
      this.worker.onmessage = ({ data }) => {
        if (data.progress) { this.progress(data.progress); return; }
        const pending = this.pending.get(data.id);
        if (!pending) return;
        this.pending.delete(data.id);
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
      this.pending.set(id, { resolve: (value) => resolve(value as T), reject });
      this.worker!.postMessage({ id, action, payload });
    });
  }

  cancel() { this.worker?.postMessage({ action: 'cancel' }); }
}
