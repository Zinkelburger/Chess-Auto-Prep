/** Reading one bughouse board's FEN (pieces and both reserves). */

import type { Colour } from './types';

/** Pieces by square and the two reserves, from one board's FEN. */
export function readBoard(fen: string): { pieces: Record<string, string>; pockets: Record<Colour, string> } {
  const field = fen.split(' ')[0];
  const open = field.indexOf('[');
  const placement = (open >= 0 ? field.slice(0, open) : field).replace(/~/g, '');
  const pocket = open >= 0 ? field.slice(open + 1, field.indexOf(']', open)) : '';
  const pieces: Record<string, string> = {};
  placement.split('/').forEach((rank, r) => {
    let file = 0;
    for (const ch of rank) {
      if (/\d/.test(ch)) { file += Number(ch); continue; }
      pieces['abcdefgh'[file] + String(8 - r)] = ch;
      file += 1;
    }
  });
  return { pieces, pockets: { white: [...pocket].filter((c) => c === c.toUpperCase()).join(''), black: [...pocket].filter((c) => c !== c.toUpperCase()).join('') } };
}
