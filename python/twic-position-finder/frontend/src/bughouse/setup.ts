/**
 * Setting a position by hand: one ordinary FEN per board plus each player's
 * reserve written as pieces ("2N Q P"), checked here before the server sees
 * the dual FEN it builds.
 */

const ORDER = 'QRBNP';

/** "2N Q P" from a pocket's letters, in either case. */
export function formatReserve(pocket: string): string {
  return [...ORDER]
    .map((p) => [p, [...pocket.toUpperCase()].filter((c) => c === p).length] as const)
    .filter(([, n]) => n > 0)
    .map(([p, n]) => (n > 1 ? `${n}${p}` : p))
    .join(' ');
}

/** Upper-case pocket letters from "2N Q P", "NNQP" or "n, q"; or why not. */
export function parseReserve(text: string): { pieces: string } | { error: string } {
  let pieces = '';
  const rest = text.replace(/(\d*)\s*([a-z])/gi, (_, count: string, letter: string) => {
    const p = letter.toUpperCase();
    if (p === 'K') { pieces += '!K'; return ''; }
    if (!ORDER.includes(p)) { pieces += `!${letter}`; return ''; }
    const n = count ? Number(count) : 1;
    if (!Number.isSafeInteger(n) || n > 30 || pieces.length + n > 30) { pieces += '!overflow'; return ''; }
    pieces += p.repeat(n);
    return '';
  });
  if (pieces.includes('!overflow')) return { error: 'That is more pieces than a reserve can hold.' };
  if (pieces.includes('!K')) return { error: 'A king can’t be in reserve (N is the knight).' };
  const bad = pieces.match(/!(.)/);
  if (bad) return { error: `“${bad[1]}” isn’t a piece: use P, N, B, R or Q.` };
  if (rest.replace(/[\s,]/g, '')) return { error: `Can’t read “${rest.trim()}” in a reserve.` };
  if (pieces.length > 30) return { error: 'That is more pieces than a reserve can hold.' };
  return { pieces };
}

export interface BoardSetup { fen: string; white: string; black: string }

/** One board's FEN split into a plain FEN and its two reserves. */
export function splitBoard(fen: string): BoardSetup {
  const [field, ...rest] = fen.trim().split(/\s+/);
  const open = field.indexOf('[');
  const pocket = open >= 0 ? field.slice(open + 1, field.indexOf(']', open)) : '';
  const placement = open >= 0 ? field.slice(0, open) : field;  // keeps ~ on promoted pieces
  return {
    fen: [placement, ...rest].join(' '),
    white: formatReserve([...pocket].filter((c) => c === c.toUpperCase()).join('')),
    black: formatReserve([...pocket].filter((c) => c !== c.toUpperCase()).join('')),
  };
}

/**
 * A board's FEN checked for shape, with missing fields filled in: White to
 * move, and castling rights wherever king and rook still stand at home.
 * A pocket in brackets is allowed and returned separately.
 */
export function checkFen(text: string): { placement: string; rest: string; pocket: string } | { error: string } {
  const fields = text.trim().split(/\s+/);
  if (!fields[0]) return { error: 'Enter a FEN.' };
  let placement = fields[0];
  let pocket = '';
  const open = placement.indexOf('[');
  if (open >= 0) {
    const close = placement.indexOf(']', open);
    if (close < 0) return { error: 'The reserve in brackets isn’t closed.' };
    pocket = placement.slice(open + 1, close);
    placement = placement.slice(0, open);
  }
  const ranks = placement.split('/');
  if (ranks.length !== 8) return { error: `A FEN has 8 ranks; this has ${ranks.length}.` };
  const squares: Record<string, string> = {};
  for (const [r, rank] of ranks.entries()) {
    let file = 0;
    for (const ch of rank) {
      if (/[1-8]/.test(ch)) file += Number(ch);
      else if (/[pnbrqk]/i.test(ch)) { squares['abcdefgh'[file] + String(8 - r)] = ch; file += 1; }
      else if (ch !== '~') return { error: `“${ch}” isn’t a piece or a number of empty squares.` };
    }
    if (file !== 8) return { error: `Rank ${8 - r} covers ${file} squares, not 8.` };
  }
  const pieces = Object.values(squares).join('');
  for (const [king, side] of [['K', 'White'], ['k', 'Black']]) {
    const n = [...pieces].filter((c) => c === king).length;
    if (n !== 1) return { error: `${side} needs exactly one king; there ${n === 1 ? 'is' : 'are'} ${n}.` };
  }
  const turn = fields[1] ?? 'w';
  if (turn !== 'w' && turn !== 'b') return { error: 'The side to move is w or b.' };
  const castling = fields[2] ?? ([
    squares.e1 === 'K' && squares.h1 === 'R' ? 'K' : '', squares.e1 === 'K' && squares.a1 === 'R' ? 'Q' : '',
    squares.e8 === 'k' && squares.h8 === 'r' ? 'k' : '', squares.e8 === 'k' && squares.a8 === 'r' ? 'q' : '',
  ].join('') || '-');
  if (!/^(-|K?Q?k?q?)$/.test(castling)) return { error: `“${castling}” isn’t castling rights (like KQkq or -).` };
  const rest = [turn, castling, fields[3] ?? '-', fields[4] ?? '0', fields[5] ?? '1'].join(' ');
  return { placement, rest, pocket };
}

const FULL: Record<string, number> = { P: 16, N: 4, B: 4, R: 4, Q: 2, K: 2 };

/**
 * Bughouse keeps every piece: all 64 are on a board or in a reserve. Given
 * both boards' FENs and the reserves (White upper case, Black lower case),
 * the pieces still to place and any extras, as "1P 2R" per colour, or null
 * when a FEN can't be read yet. A promoted piece (Q~) counts as a pawn.
 */
export function balance(fens: string[], reserves: string): { missing: Record<'white' | 'black', string>; extra: Record<'white' | 'black', string> } | null {
  const have: Record<string, number> = {};
  const add = (c: string) => { have[c] = (have[c] ?? 0) + 1; };
  for (const fen of fens) {
    const shape = checkFen(fen);
    if ('error' in shape) return null;
    const cells = shape.placement;
    for (let i = 0; i < cells.length; i++) {
      const c = cells[i];
      if (!/[pnbrqk]/i.test(c)) continue;
      add(cells[i + 1] === '~' ? (c === c.toUpperCase() ? 'P' : 'p') : c);
    }
    [...shape.pocket].forEach(add);
  }
  [...reserves].forEach(add);
  const side = (upper: boolean, sign: 1 | -1) => Object.entries(FULL)
    .map(([p, n]) => [p, sign * (n - (have[upper ? p : p.toLowerCase()] ?? 0))] as const)
    .filter(([, d]) => d > 0)
    .map(([p, d]) => `${d}${p}`)
    .join(' ');
  return {
    missing: { white: side(true, 1), black: side(false, 1) },
    extra: { white: side(true, -1), black: side(false, -1) },
  };
}
