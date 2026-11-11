/**
 * The position being set up in the board editor, apart from the pieces on
 * the board, which chessground holds: the side to move, castling, en
 * passant, both hands and the move number.
 */
import { makePockets, parseFen } from 'chessops/fen';
import { Material } from 'chessops/setup';
import type { Color, Role, SquareName } from 'chessops/types';
import { makeSquare } from 'chessops/util';
import type { Brush } from './board';
import { castlingPossible, enPassantOptions, positionOf } from './tree';

export interface Draft {
  turn: Color;
  castling: { K: boolean; Q: boolean; k: boolean; q: boolean };
  /** The en passant square asked for; it counts only while the board allows it. */
  ep: string | null;
  /** After Clear board, castling follows the board (a king and rook put home tick it) until a box is touched. */
  guessCastling: boolean;
  hands: Material;
  fullmoves: number;
  brush: Brush;
}

/** What stands on a square of the board being edited. */
export type PieceAt = (square: SquareName) => { role: Role; color: Color } | undefined;

/** The draft the editor opens on for [fen]. */
export function draftOf(fen: string): Draft {
  const pos = positionOf(fen);
  const castling = fen.split(' ')[2] ?? '-';
  return {
    turn: pos.turn,
    castling: { K: castling.includes('K'), Q: castling.includes('Q'), k: castling.includes('k'), q: castling.includes('q') },
    ep: pos.epSquare === undefined ? null : makeSquare(pos.epSquare),
    guessCastling: false,
    hands: pos.pockets ? pos.pockets.clone() : Material.empty(),
    fullmoves: pos.fullmoves,
    brush: 'pointer',
  };
}

/** The draft's FEN over [boardFen]; a castling right or en passant square the board does not allow is left out. */
export function fenOfDraft(d: Draft, boardFen: string, pieceAt: PieceAt): string {
  const castling = (['K', 'Q', 'k', 'q'] as const).filter((right) => d.castling[right] && castlingPossible(right, pieceAt)).join('') || '-';
  const ep = d.ep && enPassantOptions(d.turn, pieceAt).includes(d.ep as SquareName) ? d.ep : '-';
  return `${boardFen}[${makePockets(d.hands)}] ${d.turn === 'white' ? 'w' : 'b'} ${castling} ${ep} 0 ${d.fullmoves}`;
}

/** Reads [fen] into [d]: the board placement to show, or why it cannot be read. */
export function readDraftFen(d: Draft, fen: string): { board: string } | { error: string } {
  const setupFen = fen.trim();
  // The editor takes positions the analysis board would refuse too; only the FEN itself must parse.
  if (parseFen(setupFen).isErr) return { error: 'That is not a FEN.' };
  const parts = setupFen.split(/\s+/);
  // The hand is in brackets or, as Lichess writes it, a ninth rank.
  const ranks = parts[0].replace(/\[.*$/, '').split('/');
  const board = ranks.slice(0, 8).join('/');
  const hand = /\[([^\]]*)\]/.exec(parts[0])?.[1] ?? ranks[8] ?? '';
  d.hands = Material.empty();
  for (const ch of hand) {
    const role = (({ p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen' }) as Record<string, Role>)[ch.toLowerCase()];
    if (role) d.hands[ch === ch.toUpperCase() ? 'white' : 'black'][role]++;
  }
  d.turn = parts[1] === 'b' ? 'black' : 'white';
  const castling = parts[2] ?? '-';
  d.castling = { K: castling.includes('K'), Q: castling.includes('Q'), k: castling.includes('k'), q: castling.includes('q') };
  d.ep = /^[a-h][36]$/.test(parts[3] ?? '') ? parts[3] : null;
  d.guessCastling = false;
  d.fullmoves = Math.max(1, Number(parts[5]) || 1);
  return { board };
}
