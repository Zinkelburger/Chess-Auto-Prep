/**
 * The analysis settings, kept in this browser. The display switches are
 * Lichess's analysis settings with Lichess's defaults; the engine ones are
 * its engine gear.
 */
import type { SearchSettings } from './engine';

const KEY = 'bughouse-analysis-v3';
/** Earlier keys, read when this one is missing. Their sit search meant something else then (Fairy-Stockfish nodes, then a fixed default), so it is dropped. */
const OLD_KEYS = ['bughouse-analysis-v2', 'bughouse-analysis-v1'];
/** The sit panel's default search per row: a GPU is fast enough for rows that agree with the analysis. */
const SIT_NODES = { gpu: 800, cpu: 200 };

export interface Settings extends SearchSettings {
  engineOn: boolean;
  /** The sit panel's search for each row, in positions; null for the backend's default. */
  sitNodes: number | null;
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
  engineOn: true, multiPv: 2, infinite: false, sitNodes: null,
  inline: false, disclosure: false, liveGlyphs: false, glyphsOnBoard: true,
  bestArrows: true, maneuverArrows: false, variationArrows: true,
};

export function clamp(value: unknown, lo: number, hi: number, fallback: number): number {
  const n = Math.round(Number(value));
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : fallback;
}

/** The sit panel's search per row: the setting, or the default for the engine's backend. */
export function sitNodesFor(settings: Settings, gpu: boolean): number {
  return settings.sitNodes ?? (gpu ? SIT_NODES.gpu : SIT_NODES.cpu);
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
    if (current && typeof saved.sitNodes === 'number') out.sitNodes = clamp(saved.sitNodes, 20, 5000, 200);
  } catch { /* Defaults. */ }
  return out;
}

export function saveSettings(settings: Settings, key = KEY) {
  try { localStorage.setItem(key, JSON.stringify(settings)); } catch { /* Settings stay for this visit. */ }
}
