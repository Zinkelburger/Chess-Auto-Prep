/**
 * The engine panel's Stockfish: the shown position is searched for the gear's
 * search time (or until the player moves on, with ∞), reporting a few times a
 * second, as on lichess.org/analysis. A new position stops the old search.
 */
import { Stockfish, type EngineLine } from './stockfish';

export interface EngineResult {
  fen: string;
  depth: number;
  nodes: number;
  millis: number;
  lines: EngineLine[];
  /** The search reached its time limit (or was searched before). */
  done: boolean;
  /** The time limit it ran to, 0 for infinite. */
  budget: number;
  /** "Depth 21 · 640 kn/s", under the engine name. */
  info: string;
}

export type EngineStatus =
  | { kind: 'loading' }
  | { kind: 'ready' }
  | { kind: 'failed'; text: string };

export interface SearchSettings { multiPv: number; searchMs: number; infinite: boolean }

const REPORT_MS = 150;

function info(depth: number, nps: number, infinite: boolean): string {
  const speed = nps >= 1e6 ? `${(nps / 1e6).toFixed(1)} Mn/s` : `${Math.round(nps / 1000)} kn/s`;
  return `Depth ${depth}${infinite ? '/∞' : ''} · ${speed}`;
}

export class LiveEngine {
  private engine: Stockfish | null = null;
  private token = 0;
  private status: EngineStatus = { kind: 'loading' };

  constructor(private readonly onStatus: (s: EngineStatus) => void, private readonly onResult: (r: EngineResult) => void) {}

  private start(): Stockfish {
    if (this.engine) return this.engine;
    const engine = new Stockfish(64);
    this.engine = engine;
    this.setStatus({ kind: 'loading' });
    engine.started().then(
      () => { if (this.engine === engine) this.setStatus({ kind: 'ready' }); },
      (e: Error) => { if (this.engine === engine) { this.engine = null; this.setStatus({ kind: 'failed', text: e.message }); } },
    );
    return engine;
  }

  private setStatus(status: EngineStatus) {
    this.status = status;
    this.onStatus(status);
  }

  get current(): EngineStatus { return this.status; }

  analyse(fen: string, settings: SearchSettings) {
    const engine = this.start();
    const token = ++this.token;
    engine.stop();
    let last = 0;
    const budget = settings.infinite ? 0 : settings.searchMs;
    const publish = (r: { depth: number; nodes: number; nps: number; millis: number; lines: EngineLine[] }, done: boolean) => {
      if (token !== this.token || !r.lines.length) return;
      this.onResult({ fen, depth: r.depth, nodes: r.nodes, millis: r.millis, lines: r.lines, done, budget, info: info(r.depth, r.nps, settings.infinite) });
    };
    engine.search(fen, settings.infinite ? { multiPv: settings.multiPv, infinite: true } : { multiPv: settings.multiPv, movetime: settings.searchMs }, (r) => {
      const now = performance.now();
      if (now - last < REPORT_MS) return;
      last = now;
      publish(r, false);
    }).then((r) => publish(r, true), (e: Error) => {
      if (token !== this.token) return;
      this.engine?.terminate();
      this.engine = null;
      this.setStatus({ kind: 'failed', text: e.message });
    });
  }

  stop() {
    this.token++;
    this.engine?.stop();
  }
}
