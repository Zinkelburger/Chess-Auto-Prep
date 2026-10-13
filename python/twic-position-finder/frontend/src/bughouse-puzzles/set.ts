/**
 * The puzzle set as served from /bughouse-puzzles/: a small index with one
 * row per puzzle (enough to filter and count) and immutable, content-hashed
 * shards of 50 full records that load on demand. The filtering, labels and
 * deep-link parsing are pure so tests/bughouse-state.ts covers them.
 */
import type { Difficulty, Puzzle, PuzzleKind } from './puzzle';

export interface IndexEntry {
  id: string;
  kind: PuzzleKind;
  /** Solver moves to mate; 0 for an advantage puzzle. */
  mate: number;
  /** Solver moves in the line. */
  moves: number;
  themes: string[];
  difficulty: Difficulty;
  side: 'w' | 'b';
  board: 'A' | 'B';
  /** Whether the player found the line in the game. */
  found: boolean;
  shard: number;
}

export interface PuzzleIndex {
  version: 2;
  source: string;
  generated: string;
  count: number;
  shards: string[];
  puzzles: IndexEntry[];
}

export interface Shard { puzzles: Puzzle[] }

export type KindFilter = 'all' | PuzzleKind;
/** Solver moves in the line: '4' means four or more. */
export type LengthFilter = 'all' | '1' | '2' | '3' | '4';
export type DifficultyFilter = 'all' | Difficulty;

export interface Filter {
  kind: KindFilter;
  length: LengthFilter;
  difficulty: DifficultyFilter;
  theme: string | null;
  /** Only puzzles the player missed in the game. */
  missed: boolean;
}

export const DEFAULT_FILTER: Filter = { kind: 'all', length: 'all', difficulty: 'all', theme: null, missed: false };
export const LENGTHS: LengthFilter[] = ['1', '2', '3', '4'];
export const DIFFICULTIES: Difficulty[] = [1, 2, 3];
export const DIFFICULTY_LABELS: Record<Difficulty, string> = { 1: 'Easy', 2: 'Medium', 3: 'Hard' };
export const KIND_LABELS: Record<PuzzleKind, string> = { mate: 'Mate', advantage: 'Tactic' };

export function matches(entry: IndexEntry, f: Filter): boolean {
  if (f.kind !== 'all' && entry.kind !== f.kind) return false;
  if (f.length !== 'all' && (f.length === '4' ? entry.moves < 4 : entry.moves !== Number(f.length))) return false;
  if (f.difficulty !== 'all' && entry.difficulty !== f.difficulty) return false;
  if (f.theme && !entry.themes.includes(f.theme)) return false;
  if (f.missed && entry.found) return false;
  return true;
}

export function applyFilter(entries: IndexEntry[], f: Filter): IndexEntry[] {
  return entries.filter((e) => matches(e, f));
}

/** How many entries each value of one facet would leave, with the other facets as set. */
export function facetCounts<K extends keyof Filter>(entries: IndexEntry[], f: Filter, facet: K, values: Filter[K][]): Map<Filter[K], number> {
  const out = new Map<Filter[K], number>();
  for (const value of values) out.set(value, applyFilter(entries, { ...f, [facet]: value }).length);
  return out;
}

/** Every theme in the entries that pass the other facets, most common first. */
export function themeCounts(entries: IndexEntry[], f: Filter): [string, number][] {
  const counts = new Map<string, number>();
  for (const e of applyFilter(entries, { ...f, theme: null })) for (const t of e.themes) counts.set(t, (counts.get(t) ?? 0) + 1);
  return [...counts].sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]));
}

/** The length chip's wording depends on which kinds are in view. */
export function lengthLabel(length: LengthFilter, kind: KindFilter): string {
  const n = length === '4' ? '4+' : length;
  if (kind === 'mate') return `Mate in ${n}`;
  return length === '1' ? '1 move' : `${n} moves`;
}

const THEME_LABELS: Record<string, string> = {
  mate: 'Mate',
  drop: 'Drop',
  dropMate: 'Drop mate',
  backRankMate: 'Back-rank mate',
  smotheredMate: 'Smothered mate',
  anastasiaMate: 'Anastasia’s mate',
  arabianMate: 'Arabian mate',
  bodenMate: 'Boden’s mate',
  doubleBishopMate: 'Double-bishop mate',
  hookMate: 'Hook mate',
  dovetailMate: 'Dovetail mate',
  killBoxMate: 'Kill-box mate',
  vukovicMate: 'Vukovic mate',
  queenRookEndgame: 'Queen and rook endgame',
  xRayAttack: 'X-ray attack',
  enPassant: 'En passant',
  hangingPiece: 'Hanging piece',
  trappedPiece: 'Trapped piece',
  doubleCheck: 'Double check',
  discoveredAttack: 'Discovered attack',
  queensideAttack: 'Queenside attack',
  kingsideAttack: 'Kingside attack',
  exposedKing: 'Exposed king',
  advancedPawn: 'Advanced pawn',
  oneMove: 'One move',
  veryLong: 'Very long',
  crushing: 'Crushing',
};

/** "backRankMate" → "Back rank mate", "mateIn3" → "Mate in 3"; overrides keep hyphens and apostrophes. */
export function themeLabel(theme: string): string {
  if (THEME_LABELS[theme]) return THEME_LABELS[theme];
  const m = /^mateIn(\d+)$/.exec(theme);
  if (m) return `Mate in ${m[1]}`;
  const words = theme.replace(/([a-z])([A-Z0-9])/g, '$1 $2').replace(/([0-9])([A-Za-z])/g, '$1 $2').toLowerCase();
  return words.charAt(0).toUpperCase() + words.slice(1);
}

const ID = /^[A-Za-z0-9][\w-]{0,63}$/;

/** `#3675501-B-113` → the puzzle id; null for anything else. */
export function parseHash(hash: string): string | null {
  const id = decodeURIComponent(hash.replace(/^#/, ''));
  return ID.test(id) ? id : null;
}

export function puzzleHash(id: string): string { return `#${encodeURIComponent(id)}`; }

/** A saved filter from storage or an older version, made safe. */
export function normalizeFilter(raw: unknown): Filter {
  const f = { ...DEFAULT_FILTER };
  if (!raw || typeof raw !== 'object') return f;
  const r = raw as Record<string, unknown>;
  if (r.kind === 'mate' || r.kind === 'advantage') f.kind = r.kind;
  if (typeof r.length === 'string' && (LENGTHS as string[]).includes(r.length)) f.length = r.length as LengthFilter;
  if (r.difficulty === 1 || r.difficulty === 2 || r.difficulty === 3) f.difficulty = r.difficulty;
  if (typeof r.theme === 'string' && ID.test(r.theme)) f.theme = r.theme;
  if (r.missed === true) f.missed = true;
  return f;
}

export function isIndex(value: unknown): value is PuzzleIndex {
  const v = value as PuzzleIndex;
  return !!v && v.version === 2 && Array.isArray(v.shards) && Array.isArray(v.puzzles);
}

/** Loads the index once and shards on demand; a shard fetched once is kept. */
export class PuzzleStore {
  private readonly shards = new Map<number, Promise<Shard>>();
  index: PuzzleIndex | null = null;

  constructor(private readonly base = '/bughouse-puzzles', private readonly fetchJson: (url: string) => Promise<unknown> = defaultFetch) {}

  async loadIndex(): Promise<PuzzleIndex> {
    const data = await this.fetchJson(`${this.base}/index.json`);
    if (!isIndex(data)) throw new Error('Unexpected puzzle index');
    this.index = data;
    return data;
  }

  shard(n: number): Promise<Shard> {
    const name = this.index?.shards[n];
    if (!name) return Promise.reject(new Error(`No shard ${n}`));
    let pending = this.shards.get(n);
    if (!pending) {
      pending = this.fetchJson(`${this.base}/${name}`).then((data) => {
        const s = data as Shard;
        if (!s || !Array.isArray(s.puzzles)) throw new Error(`Bad shard ${name}`);
        return s;
      });
      // A failed load must not poison the cache; the next call retries.
      pending.catch(() => { if (this.shards.get(n) === pending) this.shards.delete(n); });
      this.shards.set(n, pending);
    }
    return pending;
  }

  async get(entry: IndexEntry): Promise<Puzzle> {
    const shard = await this.shard(entry.shard);
    const puzzle = shard.puzzles.find((p) => p.id === entry.id);
    if (!puzzle) throw new Error(`Puzzle ${entry.id} missing from its shard`);
    return puzzle;
  }

  /** Warm the shard a puzzle lives in; errors are ignored here and surface on `get`. */
  prefetch(entry: IndexEntry | undefined) {
    if (entry) this.shard(entry.shard).catch(() => {});
  }
}

async function defaultFetch(url: string): Promise<unknown> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${res.status} for ${url}`);
  return res.json();
}
