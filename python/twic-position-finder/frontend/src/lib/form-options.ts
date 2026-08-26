/**
 * Time-control and result chip groups. The server stores "all" as an absent
 * field, so a read returns `undefined` when every chip is on, a comma list
 * when some are, and `null` when none are (a validation error).
 */

const TIME_CONTROLS = ['classical', 'rapid', 'blitz'] as const;

const RESULTS: { suffix: string; value: string }[] = [
  { suffix: 'res-white', value: '1-0' },
  { suffix: 'res-black', value: '0-1' },
  { suffix: 'res-draw', value: '1/2-1/2' },
];

function box(id: string): HTMLInputElement | null {
  return document.getElementById(id) as HTMLInputElement | null;
}

function encode(parts: string[], total: number): string | null | undefined {
  if (parts.length === 0) return null;
  if (parts.length === total) return undefined;
  return parts.join(',');
}

export function readTimeControl(prefix: string): string | null | undefined {
  const parts = TIME_CONTROLS.filter((tc) => box(`${prefix}-tc-${tc}`)?.checked);
  return encode([...parts], TIME_CONTROLS.length);
}

export function writeTimeControl(prefix: string, value?: string | null): void {
  const set = new Set((value || '').split(',').map((s) => s.trim()).filter(Boolean));
  const all = set.size === 0;
  for (const tc of TIME_CONTROLS) {
    const el = box(`${prefix}-tc-${tc}`);
    if (el) el.checked = all || set.has(tc);
  }
}

export function readResult(prefix: string): string | null | undefined {
  const parts = RESULTS.filter((r) => box(`${prefix}-${r.suffix}`)?.checked).map((r) => r.value);
  return encode(parts, RESULTS.length);
}

export function writeResult(prefix: string, value?: string | null): void {
  const set = new Set((value || '').split(',').map((s) => s.trim()).filter(Boolean));
  const all = set.size === 0;
  for (const r of RESULTS) {
    const el = box(`${prefix}-${r.suffix}`);
    if (el) el.checked = all || set.has(r.value);
  }
}

/** What the checkbox means when the alert had no `exclude_site` of its own. */
export const DEFAULT_EXCLUDE_SITE = 'chess.com';

/**
 * The checkbox is a boolean over a free-text column, so a ticked box has to
 * report back whatever the alert already excluded — [current] — rather than
 * flattening every value to chess.com on the next save.
 */
export function readExcludeOnline(id: string, current?: string | null): string | undefined {
  if (!box(id)?.checked) return undefined;
  return current || DEFAULT_EXCLUDE_SITE;
}

export function writeExcludeOnline(id: string, site?: string | null): void {
  const el = box(id);
  if (el) el.checked = Boolean(site);
}
