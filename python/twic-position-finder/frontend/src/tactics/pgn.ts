/**
 * Minimal PGN reading: split an export into games, read headers, and walk
 * the mainline collecting SAN plus any `[%eval]` annotation on each move.
 * Variations, NAGs and comments are skipped; `[%eval]` inside a comment is
 * the one thing we keep, because Lichess ships server analysis that way and
 * it lets the miner skip most engine work.
 */

export interface PgnEval {
  cp: number | null;
  mate: number | null;
}

export interface PgnMove {
  san: string;
  /** Evaluation after this move, White's perspective, if annotated. */
  evalAfter: PgnEval | null;
}

export interface ParsedPgn {
  headers: Record<string, string>;
  moves: PgnMove[];
}

/** Split a multi-game PGN export on `[Event` header boundaries. */
export function splitPgn(text: string): string[] {
  if (!text?.trim()) return [];
  const games: string[] = [];
  let current: string[] = [];
  let inMovetext = false;
  for (const line of text.split(/\r?\n/)) {
    const isHeader = line.startsWith('[') && /^\[\w+\s+"/.test(line);
    if (isHeader && inMovetext) {
      games.push(current.join('\n'));
      current = [];
      inMovetext = false;
    }
    if (!isHeader && line.trim() !== '') inMovetext = true;
    current.push(line);
  }
  if (current.some((l) => l.trim() !== '')) games.push(current.join('\n'));
  return games;
}

const RESULTS = new Set(['1-0', '0-1', '1/2-1/2', '*']);

export function parsePgn(pgn: string): ParsedPgn {
  const headers: Record<string, string> = {};
  let i = 0;
  const lines = pgn.split(/\r?\n/);
  for (; i < lines.length; i++) {
    const m = /^\[(\w+)\s+"((?:[^"\\]|\\.)*)"\]\s*$/.exec(lines[i]);
    if (!m) {
      if (lines[i].trim() === '') continue;
      break;
    }
    headers[m[1]] = m[2].replace(/\\"/g, '"');
  }
  const movetext = lines.slice(i).join(' ');
  return { headers, moves: parseMovetext(movetext) };
}

function parseEvalComment(comment: string): PgnEval | null {
  const m = /\[%eval\s+(#?-?\d+(?:\.\d+)?)\]/.exec(comment);
  if (!m) return null;
  const v = m[1];
  if (v.startsWith('#')) return { cp: null, mate: Number(v.slice(1)) };
  const cp = Math.round(Number(v) * 100);
  return Number.isFinite(cp) ? { cp, mate: null } : null;
}

export function parseMovetext(text: string): PgnMove[] {
  const moves: PgnMove[] = [];
  let depth = 0; // variation nesting
  let pos = 0;
  const n = text.length;

  while (pos < n) {
    const ch = text[pos];
    if (ch === '{') {
      const end = text.indexOf('}', pos + 1);
      const comment = text.slice(pos + 1, end === -1 ? n : end);
      if (depth === 0 && moves.length > 0) {
        const ev = parseEvalComment(comment);
        if (ev) moves[moves.length - 1].evalAfter = ev;
      }
      pos = end === -1 ? n : end + 1;
      continue;
    }
    if (ch === ';') {
      const end = text.indexOf('\n', pos);
      pos = end === -1 ? n : end + 1;
      continue;
    }
    if (ch === '(') { depth++; pos++; continue; }
    if (ch === ')') { depth = Math.max(0, depth - 1); pos++; continue; }
    if (/\s/.test(ch)) { pos++; continue; }

    // token
    let end = pos;
    while (end < n && !/[\s{}();]/.test(text[end])) end++;
    if (end === pos) {
      pos++; // a stray delimiter (e.g. an unmatched '}'): skip it
      continue;
    }
    const tok = text.slice(pos, end);
    pos = end;
    if (depth > 0) continue;
    if (tok.startsWith('$')) continue;
    if (RESULTS.has(tok)) break;
    // "12." / "12..." / "12.e4" (number glued to the move)
    const numbered = /^\d+\.+(.*)$/.exec(tok);
    const san = numbered ? numbered[1] : tok;
    if (!san) continue;
    const clean = san.replace(/[?!]+$/g, '');
    if (!clean) continue;
    moves.push({ san: clean, evalAfter: null });
  }
  return moves;
}

/** Best-effort time class from PGN headers (Lichess: Event; else TimeControl). */
export function timeClassOf(headers: Record<string, string>): string {
  const event = (headers.Event ?? '').toLowerCase();
  for (const k of ['ultrabullet', 'bullet', 'blitz', 'rapid', 'classical', 'correspondence']) {
    if (event.includes(k)) return k === 'ultrabullet' ? 'bullet' : k;
  }
  const tc = headers.TimeControl ?? '';
  if (!tc || tc === '-') return tc === '-' ? 'correspondence' : 'unknown';
  if (/^\d+\/\d+/.test(tc)) return 'correspondence';
  const [base, inc] = tc.split('+').map((x) => Number.parseInt(x, 10) || 0);
  const total = base + 40 * inc;
  if (total < 180) return 'bullet';
  if (total < 600) return 'blitz';
  if (total < 1800) return 'rapid';
  return 'classical';
}
