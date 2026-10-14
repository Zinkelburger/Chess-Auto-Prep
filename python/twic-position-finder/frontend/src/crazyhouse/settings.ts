/**
 * The analysis settings, kept in this browser. The display switches are
 * Lichess's analysis settings with Lichess's defaults; the engine ones are
 * its engine gear.
 */
import { DEFAULT_THREADS, MAX_THREADS, type SearchSettings } from './engine';

const KEY = 'crazyhouse-analysis-v1';

export interface Settings extends SearchSettings {
  engineOn: boolean;
  /** Bughouse Single Board: positions searched for each row of the sit panel. */
  sitNodes: number;
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
  engineOn: true, multiPv: 2, threads: DEFAULT_THREADS, hashMb: 128, infinite: false, sitNodes: 200,
  inline: false, disclosure: false, liveGlyphs: false, glyphsOnBoard: true,
  bestArrows: true, maneuverArrows: false, variationArrows: true,
};

export function clamp(value: unknown, lo: number, hi: number, fallback: number): number {
  const n = Math.round(Number(value));
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : fallback;
}

/** The settings kept under `key`, with `defaults` over Lichess's for another page's engine. */
export function loadSettings(key = KEY, defaults: Partial<Settings> = {}): Settings {
  const base = { ...DEFAULTS, ...defaults };
  const out = { ...base };
  try {
    const saved = JSON.parse(localStorage.getItem(key) ?? '{}') as Record<string, unknown>;
    for (const name of Object.keys(base) as (keyof Settings)[])
      if (typeof saved[name] === 'boolean' && typeof base[name] === 'boolean') (out[name] as boolean) = saved[name] as boolean;
    out.multiPv = clamp(saved.multiPv, 1, 5, base.multiPv);
    out.threads = clamp(saved.threads, 1, MAX_THREADS, base.threads);
    out.hashMb = clamp(saved.hashMb, 16, 512, base.hashMb);
    out.sitNodes = clamp(saved.sitNodes, 20, 5000, base.sitNodes);
  } catch { /* Defaults. */ }
  return out;
}

export function saveSettings(settings: Settings, key = KEY) {
  try { localStorage.setItem(key, JSON.stringify(settings)); } catch { /* Settings stay for this visit. */ }
}
