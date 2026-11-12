/**
 * The analysis settings, kept in this browser. The display switches are
 * Lichess's analysis settings with Lichess's defaults; the engine ones are
 * its engine gear.
 */
const KEY = 'bughouse-analysis-v5';
/** Earlier keys, read when this one is missing. v4 and before belonged to other engines; their display switches still apply. */
const OLD_KEYS = ['bughouse-analysis-v4', 'bughouse-analysis-v3', 'bughouse-analysis-v2', 'bughouse-analysis-v1'];
/** The default time to measure piece values on the board shown, in seconds. */
const VALUES_SECONDS = 3;
/** The gear's search times in seconds, as lila's; 0 is ∞ (infinite analysis). */
export const SEARCH_TICKS = [2, 4, 6, 8, 10, 12, 15, 20, 30, 60, 120, 300, 0];
/** The bughouse board's: HypeBeast decides within a time, so it has no ∞. */
export const BUGHOUSE_SEARCH_TICKS = SEARCH_TICKS.filter((s) => s > 0);
/** The gear's times for measuring piece values, in seconds. */
export const VALUES_TICKS = [1, 2, 3, 5, 10, 20, 30];

export interface Settings {
  engineOn: boolean;
  /** Engine lines, 1 to 5. */
  multiPv: number;
  /** Search time for each new position, one of SEARCH_TICKS; 0 is infinite. */
  searchSeconds: number;
  /** Search threads; null for the recommended count. */
  threads: number | null;
  /** Time to measure what one more piece is worth on the board shown, in seconds; null for the default. */
  valuesSeconds: number | null;
  /** Bughouse boards shown: one (the partner board stays out of play) or both. */
  boards: 1 | 2;
  inline: boolean;
  disclosure: boolean;
  liveGlyphs: boolean;
  glyphsOnBoard: boolean;
  bestArrows: boolean;
  maneuverArrows: boolean;
  variationArrows: boolean;
}

export type Toggle = 'inline' | 'disclosure' | 'liveGlyphs' | 'glyphsOnBoard' | 'bestArrows' | 'maneuverArrows' | 'variationArrows';

/** The switches in the ☰ menu, in Lichess's order, with their keys. */
export const TOGGLES: { key: Toggle; label: string; hotkey?: string; group: 'Move list' | 'Board' }[] = [
  { key: 'inline', label: 'Inline notation', hotkey: 'Shift+I', group: 'Move list' },
  { key: 'disclosure', label: 'Disclosure buttons', group: 'Move list' },
  { key: 'liveGlyphs', label: 'Live move annotations', group: 'Move list' },
  { key: 'bestArrows', label: 'Best move arrows', hotkey: 'A', group: 'Board' },
  { key: 'variationArrows', label: 'Variation arrows', hotkey: 'V', group: 'Board' },
  { key: 'maneuverArrows', label: 'Maneuver arrows', group: 'Board' },
  { key: 'glyphsOnBoard', label: 'Move annotations on board', group: 'Board' },
];

const DEFAULTS: Settings = {
  engineOn: true, multiPv: 2, searchSeconds: 10, threads: null, valuesSeconds: null, boards: 1,
  inline: false, disclosure: false, liveGlyphs: false, glyphsOnBoard: true,
  bestArrows: true, maneuverArrows: false, variationArrows: true,
};

function clamp(value: unknown, lo: number, hi: number, fallback: number): number {
  const n = Math.round(Number(value));
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : fallback;
}

/** Threads the engine may use: this computer's, up to 32, when the page is cross-origin isolated. */
export function maxThreads(): number {
  return globalThis.crossOriginIsolated ? Math.max(1, Math.min(32, navigator.hardwareConcurrency || 1)) : 1;
}

/** The recommended threads, as lila's: all but one, which keeps the page responsive. */
export function recommendedThreads(max = maxThreads()): number {
  return Math.max(1, max - 1);
}

export function threadsFor(settings: Settings): number {
  const max = maxThreads();
  return Math.min(max, settings.threads ?? recommendedThreads(max));
}

/** The time to measure piece values: the setting, or the default. */
export function valuesSecondsFor(settings: Settings): number {
  return settings.valuesSeconds ?? VALUES_SECONDS;
}

/** The settings kept in this browser, over the defaults. */
export function loadSettings(key = KEY, oldKeys = OLD_KEYS): Settings {
  const base = DEFAULTS;
  const out = { ...base };
  try {
    let text = localStorage.getItem(key);
    const current = text !== null;
    for (const old of oldKeys) text ??= localStorage.getItem(old);
    const saved = JSON.parse(text ?? '{}') as Record<string, unknown>;
    for (const name of Object.keys(base) as (keyof Settings)[])
      if (typeof saved[name] === 'boolean' && typeof base[name] === 'boolean') (out[name] as boolean) = saved[name] as boolean;
    out.multiPv = clamp(saved.multiPv, 1, 5, base.multiPv);
    if (typeof saved.searchSeconds === 'number' && SEARCH_TICKS.includes(saved.searchSeconds)) out.searchSeconds = saved.searchSeconds;
    else if (saved.infinite === true) out.searchSeconds = 0; // the old Infinite analysis switch
    if (typeof saved.threads === 'number') out.threads = clamp(saved.threads, 1, 32, 1);
    if (current && typeof saved.valuesSeconds === 'number' && VALUES_TICKS.includes(saved.valuesSeconds)) out.valuesSeconds = saved.valuesSeconds;
    if (saved.boards === 2) out.boards = 2;
  } catch { /* Defaults. */ }
  return out;
}

export function saveSettings(settings: Settings, key = KEY) {
  try { localStorage.setItem(key, JSON.stringify(settings)); } catch { /* Settings stay for this visit. */ }
}
