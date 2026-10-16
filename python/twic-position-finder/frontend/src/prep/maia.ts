/** The page's side of the Maia worker: one promise per position and rating, remembered for the visit. */
import type { MaiaReply } from './maia.worker';

export class Maia {
  private worker: Worker | null = null;
  private nextId = 0;
  private waiting = new Map<number, { resolve: (s: Record<string, number>) => void; reject: (e: Error) => void }>();
  private memo = new Map<string, Promise<Record<string, number>>>();
  ready = false;

  constructor(private readonly onStatus: (text: string, fraction?: number) => void) {}

  private start(): Worker {
    if (this.worker) return this.worker;
    const worker = new Worker(new URL('./maia.worker.ts', import.meta.url), { type: 'module' });
    worker.onmessage = (e: MessageEvent<MaiaReply>) => {
      const reply = e.data;
      if ('status' in reply) { this.onStatus(reply.status, reply.fraction); return; }
      const waiter = this.waiting.get(reply.id);
      if (!waiter) return;
      this.waiting.delete(reply.id);
      if ('error' in reply) waiter.reject(new Error(reply.error));
      else { this.ready = true; waiter.resolve(reply.shares); }
    };
    worker.onerror = () => this.fail(new Error('Maia stopped. Try again.'));
    this.worker = worker;
    return worker;
  }

  private fail(error: Error) {
    for (const w of this.waiting.values()) w.reject(error);
    this.waiting.clear();
    this.memo.clear();
    this.worker?.terminate();
    this.worker = null;
  }

  /** Maia's share of every legal move at this rating. */
  shares(fen: string, elo: number): Promise<Record<string, number>> {
    const key = `${fen.split(' ').slice(0, 4).join(' ')}|${elo}`;
    const known = this.memo.get(key);
    if (known) return known;
    const worker = this.start();
    const id = ++this.nextId;
    const promise = new Promise<Record<string, number>>((resolve, reject) => this.waiting.set(id, { resolve, reject }));
    promise.catch(() => this.memo.delete(key));
    if (this.memo.size > 20_000) this.memo.clear();
    this.memo.set(key, promise);
    worker.postMessage({ id, fen, elo });
    return promise;
  }
}
