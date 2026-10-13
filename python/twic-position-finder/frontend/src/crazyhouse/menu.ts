/**
 * Lichess's analysis menu (☰, or H): board tools, replay mode and the
 * analysis settings, shown in place of the engine and moves; and the
 * keyboard help (?).
 */
import { el } from './moves';
import { TOGGLES, type Settings, type Toggle } from './settings';

export interface MenuHost {
  readonly settings: Settings;
  readonly practising: boolean;
  /** Replay mode's delay between moves, or null when it is not running. */
  readonly autoplay: number | null;
  /** The main line is long enough to replay. */
  readonly canReplay: boolean;
  readonly hasMoves: boolean;
  flip(): void;
  editor(): void;
  practice(): void;
  help(): void;
  clearMoves(): void;
  replay(delay: number | null): void;
  toggle(key: Toggle): void;
}

const ICONS = {
  flip: 'M7 4v16M7 4l-3 3M7 4l3 3M17 20V4M17 20l-3-3M17 20l3-3',
  edit: 'M12 20h9M16.5 3.5a2.12 2.12 0 0 1 3 3L7 19l-4 1 1-4z',
  practice: 'M12 22a10 10 0 1 0 0-20 10 10 0 0 0 0 20zM12 18a6 6 0 1 0 0-12 6 6 0 0 0 0 12zM12 14a2 2 0 1 0 0-4 2 2 0 0 0 0 4z',
  keys: 'M3 6h18v12H3zM7 10h.01M11 10h.01M15 10h.01M7 14h10',
  trash: 'M3 6h18M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2',
};

function icon(path: string): string {
  return `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${path}"/></svg>`;
}

export function renderMenu(box: HTMLElement, host: MenuHost) {
  const tool = (path: string, text: string, title: string, onClick: () => void, pressed?: boolean) => {
    const b = el('button', 'ch-menu-tool') as HTMLButtonElement;
    b.type = 'button';
    b.innerHTML = icon(path);
    b.append(el('span', '', text));
    b.title = title;
    if (pressed !== undefined) b.setAttribute('aria-pressed', String(pressed));
    b.onclick = onClick;
    return b;
  };
  const tools = el('div', 'ch-menu-tools');
  tools.append(
    tool(ICONS.flip, 'Flip board', 'Flip board (F)', () => host.flip()),
    tool(ICONS.edit, 'Board editor', 'Board editor (B)', () => host.editor()),
    tool(ICONS.practice, host.practising ? 'Stop practice' : 'Practice with computer', 'Play the side at the bottom against the engine', () => host.practice(), host.practising),
    tool(ICONS.keys, 'Keyboard shortcuts', 'Keyboard shortcuts (?)', () => host.help()),
  );
  if (host.hasMoves) tools.append(tool(ICONS.trash, 'Clear moves', 'Remove every move and start again from the first position', () => host.clearMoves()));
  const parts: HTMLElement[] = [tools];

  if (host.canReplay) {
    parts.push(el('h3', 'ch-menu-heading', 'Replay mode'));
    const row = el('div', 'ch-menu-replay');
    for (const [label, delay] of [['Fast', 1000], ['Slow', 5000]] as const) {
      const b = el('button', 'ch-menu-choice', label) as HTMLButtonElement;
      b.type = 'button';
      const on = host.autoplay === delay;
      b.setAttribute('aria-pressed', String(on));
      b.title = on ? 'Stop the replay' : `Play the main line from here, one move every ${delay / 1000} s`;
      b.onclick = () => host.replay(on ? null : delay);
      row.append(b);
    }
    parts.push(row);
  }

  for (const group of ['Move list', 'Board'] as const) {
    parts.push(el('h3', 'ch-menu-heading', group));
    for (const t of TOGGLES.filter((x) => x.group === group)) {
      const row = el('label', 'ch-menu-switch');
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.checked = host.settings[t.key];
      input.onchange = () => host.toggle(t.key);
      const track = el('span', 'ch-switch-track');
      track.setAttribute('aria-hidden', 'true');
      row.append(el('span', 'ch-menu-switch-label', t.label));
      if (t.hotkey) row.append(el('kbd', '', t.hotkey));
      row.append(input, track);
      parts.push(row);
    }
  }
  box.replaceChildren(...parts);
}

const KEYS: [string, string][] = [
  ['← → or K J', 'Previous / next move'],
  ['↑ ↓', 'Choose among the moves played from here; first / last move otherwise'],
  ['Home End, 0 $', 'First / last move'],
  ['Shift ← →', 'Previous / next fork'],
  ['Shift ↑ ↓', 'Previous / next line at the fork'],
  ['Mouse wheel', 'Step through the moves'],
  ['Space', 'Play the engine’s best move'],
  ['L', 'Engine on or off'],
  ['X', 'Show threat'],
  ['A', 'Best move arrows'],
  ['V', 'Variation arrows'],
  ['F', 'Flip board'],
  ['B', 'Board editor'],
  ['H', 'Menu'],
  ['Shift I', 'Inline notation'],
  ['Esc', 'Close menus, drop a picked piece, leave the editor'],
  ['?', 'This help'],
];

export function openHelp() {
  const dialog = document.createElement('dialog');
  dialog.className = 'ch-help';
  dialog.setAttribute('aria-label', 'Keyboard shortcuts');
  const close = el('button', 'ch-icon ch-help-close', '×') as HTMLButtonElement;
  close.type = 'button';
  close.setAttribute('aria-label', 'Close');
  close.onclick = () => dialog.close();
  const table = el('dl', 'ch-help-keys');
  for (const [keys, what] of KEYS) table.append(el('dt', '', keys), el('dd', '', what));
  const note = el('p', 'ch-help-note', 'Right-click a move for Promote variation, Make main line, Force variation, Copy PGN and Delete from here.');
  dialog.append(el('h2', '', 'Keyboard shortcuts'), close, table, note);
  dialog.addEventListener('click', (e) => { if (e.target === dialog) dialog.close(); });
  dialog.addEventListener('close', () => dialog.remove());
  document.body.append(dialog);
  dialog.showModal();
}
