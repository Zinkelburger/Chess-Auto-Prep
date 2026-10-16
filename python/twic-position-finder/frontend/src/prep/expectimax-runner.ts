/**
 * Runs the Expectimax tab's searches and keeps their results. One press
 * searches both sides from the position, as the desktop app does: once with
 * White as the prepared side and once with Black, so every move has its
 * value for each side beside Stockfish's.
 *
 * The searches share a pool of Stockfish workers, one Maia worker, and the
 * engine's lines for each position at each depth, so a position the two
 * searches both reach is searched once. Finished and stopped searches are
 * kept in this browser (IndexedDB) and found again by position, so going
 * back to a searched position, or reloading, shows its table without
 * searching again. Nothing searches until the player presses Search.
 */
import { newSearch, run, type ExpectimaxOptions, type Side, type XNode, type XSearch } from './expectimax';
import { Maia } from './maia';
import { StockfishPool, type EngineLine } from './stockfish';
import { workspaceStore } from './storage';
import { positionKey } from './tree';

const STORE_KEY = 'expectimax-v1';
/** Searches kept between visits, newest first. */
const KEEP = 16;

export interface Found { node: XNode; search: XSearch }
export interface FoundAt { white?: Found; black?: Found }

export class ExpectimaxRunner {
  searches: XSearch[] = [];
  running: { white: XSearch; black: XSearch; abort: AbortController } | null = null;
  /** Maia's download or start-up, while it is under way. */
  loading: { text: string; fraction?: number } | null = null;
  saveError: string | null = null;
  private pool: StockfishPool | null = null;
  private readonly maia: Maia;
  private lineCache = new Map<string, { width: number; lines: Promise<EngineLine[]> }>();
  private index: Map<string, FoundAt> | null = null;

  constructor(private readonly changed: () => void) {
    this.maia = new Maia((text, fraction) => {
      this.loading = fraction === 1 && text.startsWith('Starting') ? { text } : { text, fraction };
      this.changed();
    });
  }

  async restore() {
    try {
      const saved = await workspaceStore('read', undefined, STORE_KEY) as { version: number; searches: XSearch[] } | undefined;
      if (saved?.version === 1 && Array.isArray(saved.searches)) {
        this.searches = saved.searches.filter((s) => s?.root?.fen && (s.side === 'white' || s.side === 'black'));
        // A search the page closed on keeps its complete plies.
        for (const s of this.searches) if (s.state === 'running') s.state = 'stopped';
      }
    } catch { /* A search saved badly is dropped; the page runs without it. */ }
    this.index = null;
    this.changed();
  }

  private async save() {
    const kept = this.searches.slice(0, KEEP);
    try {
      await workspaceStore('write', { version: 1, searches: kept }, STORE_KEY);
      this.saveError = null;
    } catch (e) { this.saveError = (e as Error).message; }
    this.changed();
  }

  /** The searches holding this position, the newest that expanded it first. */
  at(fen: string): FoundAt {
    if (!this.index) {
      const index = new Map<string, FoundAt>();
      // Oldest first, so a newer search replaces an older one; an expanded node beats a leaf.
      for (const search of [...this.searches].reverse()) {
        const stack = [search.root];
        while (stack.length) {
          const node = stack.pop()!;
          const key = positionKey(node.fen);
          const entry = index.get(key) ?? {};
          const held = entry[search.side];
          if (!held || node.children?.length || !held.node.children?.length) entry[search.side] = { node, search };
          index.set(key, entry);
          if (node.children) stack.push(...node.children);
        }
      }
      this.index = index;
    }
    return this.index.get(positionKey(fen)) ?? {};
  }

  /** Searches both sides from a position; a running search stops first and keeps what it found. */
  start(fen: string, options: ExpectimaxOptions) {
    this.stop();
    const abort = new AbortController();
    const white = newSearch(fen, 'white', options), black = newSearch(fen, 'black', options);
    this.running = { white, black, abort };
    this.searches = [white, black, ...this.searches.filter((s) => !(positionKey(s.root.fen) === positionKey(fen) && sameOptions(s.options, options)))];
    this.index = null;
    this.changed();
    let plies = 0;
    const deps = {
      signal: abort.signal,
      lines: (f: string, width: number, depth: number) => this.lines(f, width, depth, abort.signal),
      policy: (f: string, elo: number) => this.maia.shares(f, elo).then((s) => { this.loading = null; return s; }),
      progress: () => {
        this.index = null;
        this.changed();
        // Each complete ply is kept, so closing the page loses at most the ply under way.
        if (white.reached + black.reached > plies) { plies = white.reached + black.reached; void this.save(); }
      },
    };
    void Promise.all([run(white, deps), run(black, deps)]).then(() => {
      if (this.running?.white === white) this.running = null;
      this.loading = null;
      this.index = null;
      void this.save();
    });
  }

  stop() {
    this.running?.abort.abort();
  }

  isRunning(side?: Side): boolean {
    return !!this.running && (!side || this.running[side].state === 'running');
  }

  /** The engine's lines for a position, at least `width` of them; a wider search already made serves a narrower one. */
  private lines(fen: string, width: number, depth: number, signal: AbortSignal): Promise<EngineLine[]> {
    const key = `${positionKey(fen)}|${depth}`;
    const held = this.lineCache.get(key);
    if (held && held.width >= width) return held.lines;
    this.pool ??= new StockfishPool();
    const lines = this.pool.search(fen, { multiPv: width, depth }, signal).then((r) => r.lines);
    if (this.lineCache.size > 50_000) this.lineCache.clear();
    this.lineCache.set(key, { width, lines });
    lines.catch(() => { if (this.lineCache.get(key)?.lines === lines) this.lineCache.delete(key); });
    return lines;
  }

  /** Forgets every kept search. */
  clear() {
    this.stop();
    this.searches = [];
    this.index = null;
    void this.save();
  }
}

function sameOptions(a: ExpectimaxOptions, b: ExpectimaxOptions): boolean {
  return (Object.keys(a) as (keyof ExpectimaxOptions)[]).every((k) => a[k] === b[k]);
}
