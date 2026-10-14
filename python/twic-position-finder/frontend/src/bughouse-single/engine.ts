/**
 * Hivemind on one board, as the analysis board's engine. Each search runs in
 * the Bughouse Lab's browser worker (`frozen`): board A is the position on
 * the board, and the partner board is the starting position held still, so
 * nothing arrives and every capture leaves for the partner. The worker reports
 * twice a second; values from the side to move become Lichess-style scores
 * from White's side, so the gauge, arrows and move marks read them as usual.
 */
import { BrowserEngine } from '../bughouse/engine';
import type { FrozenSearch } from '../bughouse/types';
import type { AnalysisEngine, EngineLine, EngineResult, EngineStatus, SearchSettings } from '../crazyhouse/engine';

/** Without infinite analysis a position is searched this long. */
export const SEARCH_MS = 30_000;
const INFINITE_MS = 3_600_000;
const REPORT_MS = 500;

/**
 * Lichess's centipawns for a winning chance, the inverse of
 * lila's winningChances (judge.ts): Hivemind's value is a winning chance.
 */
export function centipawns(q: number): number {
  const w = Math.max(-0.999, Math.min(0.999, q));
  return Math.round(Math.log((1 + w) / (1 - w)) / 0.00368208);
}

/** Mate in moves from a mate in plies (Hivemind), with the sign of who mates. */
export function mateMoves(plies: number): number {
  return Math.sign(plies) * Math.max(1, Math.ceil(Math.abs(plies) / 2));
}

/** One search report as the analysis board's result, scored from White's side. */
export function toResult(fen: string, report: FrozenSearch, done: boolean, limitMs: number): EngineResult {
  const sign = fen.split(' ')[1] === 'b' ? -1 : 1;
  const lines: EngineLine[] = report.lines.map((line, i) => ({
    multipv: i + 1,
    depth: report.depth,
    pv: line.pv,
    ...(line.mate !== null ? { mate: sign * mateMoves(line.mate) } : { cp: sign * centipawns(line.q) }),
  }));
  const seconds = report.elapsed_ms / 1000;
  const rate = seconds > 0 ? Math.round(report.nodes / seconds) : 0;
  return {
    fen, depth: report.depth, knps: 0, nodes: report.nodes, millis: report.elapsed_ms, lines, done,
    info: `${report.nodes.toLocaleString()} positions${rate ? ` · ${rate}/s` : ''}`,
    progress: report.elapsed_ms / limitMs,
  };
}

interface Job { fen: string; settings: SearchSettings; generation: number }

export class HivemindEngine implements AnalysisEngine {
  private readonly worker: BrowserEngine;
  private running: Job | null = null;
  private next: Job | null = null;
  private generation = 0;
  private ready = false;

  constructor(
    private readonly onStatus: (status: EngineStatus) => void,
    private readonly onResult: (result: EngineResult) => void,
  ) {
    this.worker = new BrowserEngine((text) => { if (!this.ready) this.onStatus({ kind: 'loading', text }); });
  }

  /** The worker loads Hivemind with its first search; the panel shows its progress meanwhile. */
  load(): Promise<void> { return Promise.resolve(); }

  analyse(fen: string, settings: SearchSettings) {
    this.next = { fen, settings: { ...settings }, generation: ++this.generation };
    if (this.running) this.worker.cancel();
    else this.start();
  }

  stop() {
    this.generation++;
    this.next = null;
    if (this.running) this.worker.cancel();
  }

  private start() {
    const job = this.next;
    if (!job) return;
    this.next = null;
    this.running = job;
    const { settings } = job;
    // Practice asks for a node count; analysis searches for a time, as on Lichess.
    const limitMs = settings.nodes ? 120_000 : settings.infinite ? INFINITE_MS : SEARCH_MS;
    const live = () => job.generation === this.generation;
    this.worker.request<FrozenSearch, FrozenSearch>('frozen', {
      fen: job.fen, nodes: settings.nodes ?? 1_000_000, movetime_ms: limitMs,
      lines: settings.multiPv, report_ms: REPORT_MS,
    }, (report) => {
      if (!report.lines?.length || !live()) return;
      this.markReady();
      this.onResult(toResult(job.fen, report, false, limitMs));
    }).then((final) => {
      if (!final.lines.length) return;
      this.markReady();
      // A stopped search keeps its last lines; only one that ran out by itself is finished.
      this.onResult(toResult(job.fen, final, live(), limitMs));
    }, (error: unknown) => {
      if (!live()) return;
      this.ready = false;
      this.onStatus({ kind: 'failed', text: error instanceof Error ? error.message : String(error) });
    }).finally(() => {
      this.running = null;
      this.start();
    });
  }

  private markReady() {
    if (this.ready) return;
    this.ready = true;
    this.onStatus({ kind: 'ready' });
  }
}
