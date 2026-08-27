/** Trainer settings, persisted in localStorage under one key. */
import { defaultPoolSize } from './engine/engine-pool';
import type { MinSeverity } from './miner';
import type { TimeClass } from './sources';

export interface Settings {
  lichessUser: string;
  chesscomUser: string;
  numGames: number;
  depth: number;
  workers: number;
  timeClasses: TimeClass[];
  minSeverity: MinSeverity;
  autoNext: boolean;
}

const KEY = 'cap-tactics-settings';
export const ALL_TIME_CLASSES: { id: TimeClass; label: string }[] = [
  { id: 'bullet', label: 'Bullet' },
  { id: 'blitz', label: 'Blitz' },
  { id: 'rapid', label: 'Rapid' },
  { id: 'classical', label: 'Classical' },
  { id: 'correspondence', label: 'Daily' },
];

export const LIMITS = {
  numGames: { min: 1, max: 200 },
  depth: { min: 8, max: 22 },
  workers: { min: 1, max: Math.max(1, navigator.hardwareConcurrency || 2) },
};

export function defaultSettings(): Settings {
  return {
    lichessUser: '',
    chesscomUser: '',
    numGames: 20,
    depth: 14,
    workers: defaultPoolSize(),
    timeClasses: ['blitz', 'rapid', 'classical', 'correspondence'],
    minSeverity: 'mistake',
    autoNext: true,
  };
}

function clamp(v: unknown, lo: number, hi: number, dflt: number): number {
  const n = typeof v === 'number' ? v : Number.parseInt(String(v ?? ''), 10);
  if (!Number.isFinite(n)) return dflt;
  return Math.max(lo, Math.min(hi, Math.round(n)));
}

export function loadSettings(): Settings {
  const d = defaultSettings();
  let raw: Partial<Settings> = {};
  try {
    raw = JSON.parse(localStorage.getItem(KEY) ?? '{}') as Partial<Settings>;
  } catch {
    /* corrupt or unavailable */
  }
  // Migrate the pre-refactor keys once, so returning users keep their names.
  try {
    if (!raw.lichessUser && localStorage.getItem('lichessUser')) raw.lichessUser = localStorage.getItem('lichessUser')!;
    if (!raw.chesscomUser && localStorage.getItem('chesscomUser')) raw.chesscomUser = localStorage.getItem('chesscomUser')!;
  } catch { /* ignore */ }
  const valid = new Set(ALL_TIME_CLASSES.map((t) => t.id));
  const classes = Array.isArray(raw.timeClasses)
    ? raw.timeClasses.filter((t): t is TimeClass => valid.has(t as TimeClass))
    : d.timeClasses;
  return {
    lichessUser: typeof raw.lichessUser === 'string' ? raw.lichessUser.trim() : d.lichessUser,
    chesscomUser: typeof raw.chesscomUser === 'string' ? raw.chesscomUser.trim() : d.chesscomUser,
    numGames: clamp(raw.numGames, LIMITS.numGames.min, LIMITS.numGames.max, d.numGames),
    depth: clamp(raw.depth, LIMITS.depth.min, LIMITS.depth.max, d.depth),
    workers: clamp(raw.workers, LIMITS.workers.min, LIMITS.workers.max, d.workers),
    timeClasses: classes.length ? classes : d.timeClasses,
    minSeverity: raw.minSeverity === 'inaccuracy' ? 'inaccuracy' : 'mistake',
    autoNext: typeof raw.autoNext === 'boolean' ? raw.autoNext : d.autoNext,
  };
}

export function saveSettings(s: Settings): void {
  try {
    localStorage.setItem(KEY, JSON.stringify(s));
  } catch {
    /* private mode */
  }
}
