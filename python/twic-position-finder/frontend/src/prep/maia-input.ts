import { Chess } from 'chess.js';
export const mirrorMove = (uci: string) => uci[0] + (9 - Number(uci[1])) + uci[2] + (9 - Number(uci[3])) + uci.slice(4);
export function maiaInput(fen: string) {
  const chess = new Chess(fen), black = chess.turn() === 'b';
  const tokens = new Float32Array(768);
  for (const row of chess.board()) for (const piece of row) if (piece) {
    const rank = Number(piece.square[1]) - 1, file = piece.square.charCodeAt(0) - 97;
    const color = black ? (piece.color === 'w' ? 'b' : 'w') : piece.color;
    const letter = color === 'w' ? piece.type.toUpperCase() : piece.type;
    tokens[((black ? 7 - rank : rank) * 8 + file) * 12 + 'PNBRQKpnbrqk'.indexOf(letter)] = 1;
  }
  const moves = chess.moves({ verbose: true }).map(m => m.from + m.to + (m.promotion || ''));
  return { tokens, moves, black };
}
export function maiaShares(logits: Float32Array, moves: string[], black: boolean, vocabulary: Record<string, number>): Record<string, number> {
  const values = moves.map(m => logits[vocabulary[black ? mirrorMove(m) : m]]);
  if (values.some(v => !Number.isFinite(v))) throw new Error('Maia returned an invalid move distribution.');
  const max = Math.max(...values), weights = values.map(v => Math.exp(v - max)), sum = weights.reduce((a, b) => a + b, 0);
  return Object.fromEntries(moves.map((m, i) => [m, weights[i] / sum]));
}
