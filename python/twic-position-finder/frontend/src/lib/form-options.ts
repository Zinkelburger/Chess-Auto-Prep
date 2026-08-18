/** Time-control and result checkbox groups. */

const TIME_CONTROLS = ['classical', 'rapid', 'blitz'] as const;

const RESULTS: { suffix: string; value: string }[] = [
  { suffix: 'res-white', value: '1-0' },
  { suffix: 'res-black', value: '0-1' },
  { suffix: 'res-draw', value: '1/2-1/2' },
];

function box(id: string): HTMLInputElement | null {
  return document.getElementById(id) as HTMLInputElement | null;
}

export function readTimeControl(prefix: string): string | undefined {
  const parts = TIME_CONTROLS.filter((tc) => box(`${prefix}-tc-${tc}`)?.checked);
  return parts.length > 0 && parts.length < TIME_CONTROLS.length ? parts.join(',') : undefined;
}

export function writeTimeControl(prefix: string, value?: string | null): void {
  const set = new Set((value || '').split(',').map((s) => s.trim()).filter(Boolean));
  const all = set.size === 0;
  for (const tc of TIME_CONTROLS) {
    const el = box(`${prefix}-tc-${tc}`);
    if (el) el.checked = all || set.has(tc);
  }
}

export function readResult(prefix: string): string | undefined {
  const parts = RESULTS.filter((r) => box(`${prefix}-${r.suffix}`)?.checked).map((r) => r.value);
  return parts.length > 0 && parts.length < RESULTS.length ? parts.join(',') : undefined;
}

export function writeResult(prefix: string, value?: string | null): void {
  const set = new Set((value || '').split(',').map((s) => s.trim()).filter(Boolean));
  const all = set.size === 0;
  for (const r of RESULTS) {
    const el = box(`${prefix}-${r.suffix}`);
    if (el) el.checked = all || set.has(r.value);
  }
}

export function readExcludeOnline(id: string): string | undefined {
  return box(id)?.checked ? 'chess.com' : undefined;
}

export function writeExcludeOnline(id: string, site?: string | null): void {
  const el = box(id);
  if (el) el.checked = Boolean(site);
}
