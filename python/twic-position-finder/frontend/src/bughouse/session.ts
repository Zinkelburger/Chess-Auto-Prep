import { Lines, type LineMove } from './lines';
import type { Colour } from './types';

export const START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
export const START_DUAL = `${START}|${START}`;
export const SESSION_KEY = 'bughouse-lab-session-v1';
export interface Settings { team: Colour; required: string; budget: string; clock: string; flipped: boolean }
export interface SavedSession { version: 1; line: ReturnType<Lines['snapshot']>; settings: Settings }

/** Treat local storage and shared links as untrusted input; legality is checked by WASM. */
export function parseSession(text: string): SavedSession {
  if (text.length > 1_000_000) throw new Error('This saved line is too large.');
  const s = JSON.parse(text) as SavedSession;
  if (s?.version !== 1 || !s.line || !s.settings) throw new Error('Unsupported saved line.');
  const { line, settings } = s;
  if (typeof line.root !== 'string' || line.root.length > 1025 || line.root.split('|').length !== 2 ||
      !Array.isArray(line.moves) || line.moves.length > 4096 || !line.upto || !['A', 'B'].includes(line.focus))
    throw new Error('Invalid saved position.');
  for (const m of line.moves) {
    if (!m || !['A', 'B'].includes(m.board) || !['white', 'black'].includes(m.colour) ||
        !Number.isSafeInteger(m.num) || m.num < 1 || m.num > 99999 ||
        typeof m.uci !== 'string' || !/^([a-h][1-8][a-h][1-8][qrbn]?|[PNBRQ]@[a-h][1-8])$/.test(m.uci) ||
        typeof m.san !== 'string' || !/^[a-zA-Z0-9@=+#-]{1,20}$/.test(m.san))
      throw new Error('Invalid move in saved line.');
  }
  for (const board of ['A', 'B'] as const) {
    if (!Number.isSafeInteger(line.upto[board]) || line.upto[board] < 0 ||
        line.upto[board] > line.moves.filter((m) => m.board === board).length)
      throw new Error('Invalid saved move cursor.');
  }
  if (!['white', 'black'].includes(settings.team) || !['none', 'A', 'B'].includes(settings.required) ||
      !['3000', '10000', '30000'].includes(settings.budget) || !['even', 'AB', 'CD'].includes(settings.clock) ||
      typeof settings.flipped !== 'boolean') throw new Error('Invalid saved settings.');
  return s;
}

/** FICS-style BPGN preserves cross-board chronology, drops and underpromotions. */
export function exportBpgn(line: Lines): string {
  const tag = (key: string, value: string) => `[${key} "${value.replace(/\\/g, '\\\\').replace(/"/g, '\\"').replace(/[\r\n]/g, ' ')}"]`;
  const tags = [tag('Event', 'Bughouse Lab analysis'), tag('Site', 'Chess Auto Prep'), tag('Variant', 'Bughouse'),
    tag('WhiteA', 'Player A'), tag('BlackA', 'Player C'), tag('WhiteB', 'Player D'), tag('BlackB', 'Player B'), tag('Result', '*')];
  if (line.root !== START_DUAL) tags.push(tag('SetUp', '1'), tag('FEN', line.root));
  const moves = line.applied().map((m: LineMove) => `${m.num}${m.colour === 'white' ? m.board : m.board.toLowerCase()}. ${m.san}`);
  const rows: string[] = [];
  for (let i = 0; i < moves.length; i += 6) rows.push(moves.slice(i, i + 6).join(' '));
  return `${tags.join('\n')}\n\n{Boards A/B are boards 1/2. Uppercase board letter = White; lowercase = Black.}\n${rows.join('\n')}${rows.length ? '\n' : ''}*\n`;
}

export function sessionHash(session: SavedSession): string {
  return `#lab=${encodeURIComponent(JSON.stringify(session))}`;
}
