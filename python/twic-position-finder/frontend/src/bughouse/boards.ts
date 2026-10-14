/**
 * Small board helpers shared by the bughouse puzzle board, its pocket and
 * its promotion picker.
 */

export const PIECE_NAMES: Record<string, string> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };

export function pieceImage(piece: string): HTMLImageElement {
  const img = document.createElement('img');
  img.src = `/piece/${piece === piece.toUpperCase() ? 'w' : 'b'}${piece.toUpperCase()}.svg`;
  img.alt = '';
  img.draggable = false;
  return img;
}

/** The piece placement chessground reads, from pieces by square. */
export function placement(pieces: Record<string, string>): string {
  const rows: string[] = [];
  for (let rank = 8; rank >= 1; rank--) {
    let row = '';
    let empty = 0;
    for (const file of 'abcdefgh') {
      const piece = pieces[file + rank];
      if (!piece) { empty += 1; continue; }
      if (empty) { row += empty; empty = 0; }
      row += piece;
    }
    rows.push(empty ? row + empty : row);
  }
  return rows.join('/');
}
