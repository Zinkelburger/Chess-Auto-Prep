/**
 * A pool of UciWorkers behind one `evaluate(fen, depth)` queue.
 *
 * Same idea as the Dart app's StockfishPool: the miner submits every
 * position of a game at once and the pool keeps all workers busy, instead of
 * one engine grinding through a game move by move. Workers boot lazily and
 * concurrently; the first search starts as soon as the first worker is up.
 */
import { EngineAbortError, UciWorker, type EvalResult } from './uci-worker';

interface Task {
  fen: string;
  depth: number;
  signal?: AbortSignal;
  resolve: (r: EvalResult) => void;
  reject: (e: Error) => void;
}

export interface PoolStatus {
  size: number;
  ready: number;
  busy: number;
  queued: number;
}

export class EnginePool {
  private workers: UciWorker[] = [];
  private booting: Promise<void> | null = null;
  private queue: Task[] = [];
  private bootError: Error | null = null;
  private disposed = false;
  private readonly listeners = new Set<(s: PoolStatus) => void>();

  constructor(public readonly size: number, private readonly hashMb = 16) {}

  /** Start booting workers. Safe to call repeatedly; returns when the first is ready. */
  start(): Promise<void> {
    if (!this.booting) {
      this.booting = new Promise<void>((resolveFirst, rejectFirst) => {
        let settled = false;
        let failures = 0;
        for (let i = 0; i < this.size; i++) {
          void UciWorker.spawn(this.hashMb).then(
            (w) => {
              if (this.disposed) {
                w.terminate();
                return;
              }
              this.workers.push(w);
              this.emit();
              this.pump();
              if (!settled) {
                settled = true;
                resolveFirst();
              }
            },
            (err: Error) => {
              failures++;
              if (failures === this.size && !settled) {
                settled = true;
                this.bootError = err;
                this.failQueue(err);
                rejectFirst(err);
              }
            },
          );
        }
      });
    }
    return this.booting;
  }

  status(): PoolStatus {
    return {
      size: this.size,
      ready: this.workers.length,
      busy: this.workers.filter((w) => w.isBusy).length,
      queued: this.queue.length,
    };
  }

  onStatus(fn: (s: PoolStatus) => void): () => void {
    this.listeners.add(fn);
    return () => this.listeners.delete(fn);
  }

  private emit(): void {
    const s = this.status();
    for (const fn of this.listeners) fn(s);
  }

  evaluate(fen: string, depth: number, signal?: AbortSignal): Promise<EvalResult> {
    if (this.bootError) return Promise.reject(this.bootError);
    if (signal?.aborted) return Promise.reject(new EngineAbortError());
    void this.start().catch(() => { /* surfaced through the task */ });
    return new Promise<EvalResult>((resolve, reject) => {
      const task: Task = { fen, depth, signal, resolve, reject };
      this.queue.push(task);
      signal?.addEventListener('abort', () => {
        const i = this.queue.indexOf(task);
        if (i >= 0) {
          this.queue.splice(i, 1);
          reject(new EngineAbortError());
          this.emit();
        }
      }, { once: true });
      this.emit();
      this.pump();
    });
  }

  /** Clear engine hash on every worker — between users, not between games. */
  async newGame(): Promise<void> {
    await Promise.all(this.workers.map((w) => w.newGame().catch(() => undefined)));
  }

  private pump(): void {
    for (const w of this.workers) {
      if (w.isBusy || w.isDead) continue;
      const task = this.queue.shift();
      if (!task) break;
      this.run(w, task);
    }
  }

  private run(w: UciWorker, task: Task): void {
    this.emit();
    w.evaluate(task.fen, task.depth, task.signal).then(
      (r) => {
        task.resolve(r);
        this.emit();
        this.pump();
      },
      (err: Error) => {
        if (w.isDead) {
          // Drop the dead worker; retry the task elsewhere unless cancelled.
          this.workers = this.workers.filter((x) => x !== w);
          if (this.workers.length === 0 && !this.disposed) {
            this.failQueue(err);
            task.reject(err);
          } else if (!(err instanceof EngineAbortError)) {
            this.queue.unshift(task);
          } else {
            task.reject(err);
          }
        } else {
          task.reject(err);
        }
        this.emit();
        this.pump();
      },
    );
  }

  private failQueue(err: Error): void {
    const pending = this.queue;
    this.queue = [];
    for (const t of pending) t.reject(err);
  }

  dispose(): void {
    this.disposed = true;
    this.failQueue(new EngineAbortError());
    for (const w of this.workers) w.terminate();
    this.workers = [];
    this.emit();
  }
}

/** Sensible worker count for this machine: leave a core for the UI. */
export function defaultPoolSize(): number {
  const cores = navigator.hardwareConcurrency || 2;
  return Math.max(1, Math.min(8, cores - 1));
}
