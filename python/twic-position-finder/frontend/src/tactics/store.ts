/**
 * Persistent caches in IndexedDB, so re-running the trainer for the same
 * account is nearly free:
 *
 *  - `games`: the puzzles mined from each game at a given depth. A game that
 *    has already been analysed is never sent to the engine again (the Dart
 *    app's "skip analysed games").
 *  - `evals`: engine results by FEN+depth. Only opening positions (fullmove
 *    ≤ OPENING_FULLMOVE) are persisted — those repeat across games; middlegame
 *    positions never do and would only bloat the store.
 *
 * Everything degrades to in-memory when IndexedDB is unavailable.
 */
import type { EvalResult } from './engine/uci-worker';
import type { MinSeverity, Puzzle } from './miner';

const DB_NAME = 'cap-tactics';
const DB_VERSION = 1;
export const OPENING_FULLMOVE = 12;

export interface GameRecord {
  key: string;
  puzzles: Puzzle[];
  analysedAt: number;
  /** Number of user moves that were evaluated. */
  sites: number;
  /**
   * The threshold this game was mined at. A record is only reusable for a
   * run whose threshold is the same or stricter — mining at 'mistake' never
   * recorded the inaccuracies a later 'inaccuracy' run wants, so that run
   * has to analyse the game again. Absent on records written before this
   * field existed; those are re-mined rather than guessed at.
   */
  minSeverity?: MinSeverity;
}

/** Loosest first: a record mined at [0] satisfies any run below it. */
const SEVERITY_ORDER: MinSeverity[] = ['inaccuracy', 'mistake'];

/**
 * Can [record] answer a run that wants [want]? Only when it was mined at
 * least as loosely — otherwise the puzzles it is missing were never found.
 */
export function recordSatisfies(record: GameRecord, want: MinSeverity): boolean {
  if (!record.minSeverity) return false;
  return SEVERITY_ORDER.indexOf(record.minSeverity) <= SEVERITY_ORDER.indexOf(want);
}

/** The subset of [record]'s puzzles a run at [want] should actually show. */
export function puzzlesAtSeverity(record: GameRecord, want: MinSeverity): Puzzle[] {
  if (want === 'inaccuracy') return record.puzzles;
  return record.puzzles.filter((p) => p.severity !== 'inaccuracy');
}

function openDb(): Promise<IDBDatabase | null> {
  if (typeof indexedDB === 'undefined') return Promise.resolve(null);
  return new Promise((resolve) => {
    let req: IDBOpenDBRequest;
    try {
      req = indexedDB.open(DB_NAME, DB_VERSION);
    } catch {
      resolve(null);
      return;
    }
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains('games')) db.createObjectStore('games', { keyPath: 'key' });
      if (!db.objectStoreNames.contains('evals')) db.createObjectStore('evals');
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => resolve(null);
    req.onblocked = () => resolve(null);
  });
}

function idbGet<T>(db: IDBDatabase, store: string, key: string): Promise<T | undefined> {
  return new Promise((resolve) => {
    try {
      const req = db.transaction(store, 'readonly').objectStore(store).get(key);
      req.onsuccess = () => resolve(req.result as T | undefined);
      req.onerror = () => resolve(undefined);
    } catch {
      resolve(undefined);
    }
  });
}

function idbPut(db: IDBDatabase, store: string, value: unknown, key?: string): void {
  try {
    const os = db.transaction(store, 'readwrite').objectStore(store);
    if (key === undefined) os.put(value);
    else os.put(value, key);
  } catch {
    /* quota or closed db: the in-memory layer still has it */
  }
}

function idbClear(db: IDBDatabase, store: string): Promise<void> {
  return new Promise((resolve) => {
    try {
      const req = db.transaction(store, 'readwrite').objectStore(store).clear();
      req.onsuccess = () => resolve();
      req.onerror = () => resolve();
    } catch {
      resolve();
    }
  });
}

export function isOpeningFen(fen: string): boolean {
  const fullmove = Number(fen.split(' ')[5]);
  return Number.isFinite(fullmove) && fullmove <= OPENING_FULLMOVE;
}

export class TacticsStore {
  private db: Promise<IDBDatabase | null>;
  private readonly evals = new Map<string, EvalResult>();
  private readonly games = new Map<string, GameRecord>();

  constructor() {
    this.db = openDb();
  }

  private static evalKey(fen: string, depth: number): string {
    return `${depth}:${fen}`;
  }

  async getEval(fen: string, depth: number): Promise<EvalResult | undefined> {
    const key = TacticsStore.evalKey(fen, depth);
    const mem = this.evals.get(key);
    if (mem) return mem;
    if (!isOpeningFen(fen)) return undefined;
    const db = await this.db;
    if (!db) return undefined;
    const hit = await idbGet<EvalResult>(db, 'evals', key);
    if (hit) this.evals.set(key, hit);
    return hit;
  }

  putEval(fen: string, depth: number, result: EvalResult): void {
    const key = TacticsStore.evalKey(fen, depth);
    this.evals.set(key, result);
    if (!isOpeningFen(fen)) return;
    void this.db.then((db) => db && idbPut(db, 'evals', result, key));
  }

  static gameKey(source: string, gameId: string, username: string, depth: number): string {
    return `${source}:${gameId}:${username.toLowerCase()}:${depth}`;
  }

  async getGame(key: string): Promise<GameRecord | undefined> {
    const mem = this.games.get(key);
    if (mem) return mem;
    const db = await this.db;
    if (!db) return undefined;
    const hit = await idbGet<GameRecord>(db, 'games', key);
    if (hit) this.games.set(key, hit);
    return hit;
  }

  putGame(record: GameRecord): void {
    this.games.set(record.key, record);
    void this.db.then((db) => db && idbPut(db, 'games', record));
  }

  async clear(): Promise<void> {
    this.evals.clear();
    this.games.clear();
    const db = await this.db;
    if (!db) return;
    await Promise.all([idbClear(db, 'evals'), idbClear(db, 'games')]);
  }
}
