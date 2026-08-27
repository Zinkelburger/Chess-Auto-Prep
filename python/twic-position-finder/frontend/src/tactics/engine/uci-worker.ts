/**
 * One Stockfish web worker speaking UCI, wrapped as a promise API.
 *
 * A worker runs one search at a time; the EnginePool owns several and hands
 * each search to an idle one. The single-threaded stockfish.js build is used
 * deliberately: it needs no SharedArrayBuffer (so no COOP/COEP headers, which
 * break third-party embeds), and at the shallow depths tactics mining uses,
 * N independent searches beat one N-thread search by a wide margin.
 */

export interface EvalResult {
  /** Score in centipawns from the side to move, or null when mate is set. */
  cp: number | null;
  /** Mate in N (negative = getting mated), or null. */
  mate: number | null;
  depth: number;
  bestMove: string | null;
  /** Principal variation in UCI. */
  pv: string[];
}

export class EngineAbortError extends Error {
  constructor() {
    super('Analysis cancelled');
    this.name = 'EngineAbortError';
  }
}

interface Waiter {
  test: (line: string) => boolean;
  resolve: (line: string) => void;
  reject: (err: Error) => void;
  timer: ReturnType<typeof setTimeout>;
}

const ENGINE_PATH = '/stockfish/stockfish.js';
const BOOT_TIMEOUT_MS = 20_000;
const SEARCH_TIMEOUT_MS = 30_000;

export class UciWorker {
  private worker: Worker | null = null;
  private waiters: Waiter[] = [];
  private searching = false;
  private info: { cp: number | null; mate: number | null; depth: number; pv: string[] } = emptyInfo();
  private dead: Error | null = null;

  static async spawn(hashMb = 16): Promise<UciWorker> {
    const w = new UciWorker();
    await w.boot(hashMb);
    return w;
  }

  private async boot(hashMb: number): Promise<void> {
    this.worker = new Worker(ENGINE_PATH);
    this.worker.onmessage = (e: MessageEvent<string>) => this.onLine(String(e.data));
    this.worker.onerror = (e) => {
      this.fail(new Error(`Stockfish worker failed: ${e.message || 'unknown error'}`));
    };
    try {
      this.send('uci');
      await this.waitFor((l) => l === 'uciok', BOOT_TIMEOUT_MS);
      this.send(`setoption name Hash value ${hashMb}`);
      this.send('setoption name MultiPV value 1');
      this.send('setoption name Threads value 1');
      await this.sync();
    } catch (err) {
      // The pool only counts the failure; nobody else holds this worker, so
      // without this the wasm stays resident for the life of the page — once
      // per configured worker on a slow or blocked engine load.
      this.terminate();
      throw err;
    }
  }

  get isBusy(): boolean {
    return this.searching;
  }

  get isDead(): boolean {
    return this.dead !== null;
  }

  private send(cmd: string): void {
    this.worker?.postMessage(cmd);
  }

  private waitFor(test: (line: string) => boolean, timeoutMs: number): Promise<string> {
    if (this.dead) return Promise.reject(this.dead);
    return new Promise((resolve, reject) => {
      const waiter: Waiter = {
        test,
        resolve,
        reject,
        timer: setTimeout(() => {
          this.waiters = this.waiters.filter((w) => w !== waiter);
          reject(new Error('Engine did not respond in time'));
        }, timeoutMs),
      };
      this.waiters.push(waiter);
    });
  }

  private onLine(line: string): void {
    if (line.startsWith('info ') && line.includes(' pv ')) this.parseInfo(line);
    for (const w of [...this.waiters]) {
      if (w.test(line)) {
        clearTimeout(w.timer);
        this.waiters = this.waiters.filter((x) => x !== w);
        w.resolve(line);
      }
    }
  }

  private parseInfo(line: string): void {
    // Only the main line: ignore "multipv 2+" if an engine ever emits it.
    const mpv = /\bmultipv (\d+)/.exec(line);
    if (mpv && mpv[1] !== '1') return;
    const depth = /\bdepth (\d+)/.exec(line);
    const cp = /\bscore cp (-?\d+)/.exec(line);
    const mate = /\bscore mate (-?\d+)/.exec(line);
    const pv = / pv (.+)$/.exec(line);
    if (!depth || !pv) return;
    const d = Number(depth[1]);
    // Keep the deepest info seen; equal depth = later refinement, so overwrite.
    if (d < this.info.depth) return;
    this.info = {
      depth: d,
      cp: cp ? Number(cp[1]) : null,
      mate: mate ? Number(mate[1]) : null,
      pv: pv[1].trim().split(/\s+/),
    };
  }

  private async sync(): Promise<void> {
    this.send('isready');
    await this.waitFor((l) => l === 'readyok', BOOT_TIMEOUT_MS);
  }

  /** Reset engine state between games (clears the hash of a previous game's lines). */
  async newGame(): Promise<void> {
    this.send('ucinewgame');
    await this.sync();
  }

  /**
   * Search [fen] to [depth]. Rejects with EngineAbortError if [signal] fires
   * first; the engine is told to stop and its bestmove is awaited so the
   * worker is clean for the next search.
   */
  async evaluate(fen: string, depth: number, signal?: AbortSignal): Promise<EvalResult> {
    if (this.dead) throw this.dead;
    if (this.searching) throw new Error('UciWorker is already searching');
    if (signal?.aborted) throw new EngineAbortError();

    this.searching = true;
    this.info = emptyInfo();
    const onAbort = () => this.send('stop');
    signal?.addEventListener('abort', onAbort, { once: true });
    try {
      this.send(`position fen ${fen}`);
      this.send(`go depth ${depth}`);
      let line: string;
      try {
        line = await this.waitFor((l) => l.startsWith('bestmove'), SEARCH_TIMEOUT_MS);
      } catch (err) {
        // Timed out: stop and drain the bestmove so the next search is clean.
        this.send('stop');
        const drained = await this.waitFor((l) => l.startsWith('bestmove'), 5_000).catch(() => null);
        if (drained === null) {
          // The engine owes us a `bestmove` it has not sent. Reusing this
          // worker would let that line arrive during the *next* search and
          // satisfy its waiter — returning one position's move for another,
          // silently. Retire it instead; the pool spreads the work over the
          // workers that are still answering.
          this.fail(new Error('Engine stopped responding'));
          // Kill the process too: a wedged search left running would keep a
          // core busy for the rest of the session.
          try { this.worker?.terminate(); } catch { /* already gone */ }
          this.worker = null;
          if (this.info.depth === 0) throw err;
          line = 'bestmove (none)';
        } else {
          line = drained;
          if (this.info.depth === 0) throw err;
        }
      }
      if (signal?.aborted) throw new EngineAbortError();
      const best = /^bestmove (\S+)/.exec(line)?.[1] ?? null;
      return {
        cp: this.info.cp,
        mate: this.info.mate,
        depth: this.info.depth,
        bestMove: best && best !== '(none)' ? best : null,
        pv: this.info.pv.length ? this.info.pv : best && best !== '(none)' ? [best] : [],
      };
    } finally {
      signal?.removeEventListener('abort', onAbort);
      this.searching = false;
    }
  }

  private fail(err: Error): void {
    this.dead = err;
    for (const w of this.waiters) {
      clearTimeout(w.timer);
      w.reject(err);
    }
    this.waiters = [];
  }

  terminate(): void {
    this.fail(new Error('Engine terminated'));
    try {
      this.send('quit');
      this.worker?.terminate();
    } catch {
      /* already gone */
    }
    this.worker = null;
  }
}

function emptyInfo() {
  return { cp: null, mate: null, depth: 0, pv: [] as string[] };
}
