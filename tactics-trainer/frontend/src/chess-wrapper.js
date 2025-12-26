/**
 * Chess.js wrapper for tactics trainer
 * Uses the chess.js npm package for proper move validation and SAN parsing
 */

import { Chess } from 'chess.js';

export class ChessGame {
  constructor(fen) {
    this.chess = fen ? new Chess(fen) : new Chess();
  }

  // Get current FEN
  getFen() {
    return this.chess.fen();
  }

  // Get current turn ('w' or 'b')
  get turn() {
    return this.chess.turn();
  }

  // Load a FEN position
  loadFen(fen) {
    this.chess.load(fen);
  }

  // Make a move using SAN (e.g., "Nf3", "e4", "O-O", "exd8=Q")
  // Returns the move object if successful, null if invalid
  moveSan(san) {
    try {
      return this.chess.move(san);
    } catch (e) {
      return null;
    }
  }

  // Make a move using UCI (e.g., "g1f3", "e2e4", "e7e8q")
  // Returns the move object if successful, null if invalid
  moveUci(uci) {
    if (!uci || uci.length < 4) return null;
    
    const from = uci.substring(0, 2);
    const to = uci.substring(2, 4);
    const promotion = uci.length > 4 ? uci[4] : undefined;
    
    try {
      return this.chess.move({ from, to, promotion });
    } catch (e) {
      return null;
    }
  }

  // Convert SAN to UCI
  // Returns UCI string if valid, null if invalid
  sanToUci(san) {
    // Clone the current position to test the move
    const testChess = new Chess(this.chess.fen());
    try {
      const move = testChess.move(san);
      if (move) {
        return move.from + move.to + (move.promotion || '');
      }
    } catch (e) {
      // Invalid move
    }
    return null;
  }

  // Convert UCI to SAN
  // Returns SAN string if valid, null if invalid
  uciToSan(uci) {
    if (!uci || uci.length < 4) return null;
    
    const from = uci.substring(0, 2);
    const to = uci.substring(2, 4);
    const promotion = uci.length > 4 ? uci[4] : undefined;
    
    // Clone the current position to test the move
    const testChess = new Chess(this.chess.fen());
    try {
      const move = testChess.move({ from, to, promotion });
      if (move) {
        return move.san;
      }
    } catch (e) {
      // Invalid move
    }
    return null;
  }

  // Get all legal moves as SAN strings
  getMoves() {
    return this.chess.moves();
  }

  // Get all legal moves with details (from, to, san, etc.)
  getMovesVerbose() {
    return this.chess.moves({ verbose: true });
  }

  // Get legal destinations for a square (for chessground)
  getDestinations() {
    const dests = new Map();
    const moves = this.chess.moves({ verbose: true });
    
    for (const move of moves) {
      if (!dests.has(move.from)) {
        dests.set(move.from, []);
      }
      dests.get(move.from).push(move.to);
    }
    
    return dests;
  }

  // Check if a move is legal (accepts SAN or UCI)
  isLegalMove(move) {
    const testChess = new Chess(this.chess.fen());
    try {
      // chess.js permissive parser handles both SAN and UCI
      return testChess.move(move) !== null;
    } catch (e) {
      return false;
    }
  }

  // Get piece at a square
  getPiece(square) {
    return this.chess.get(square);
  }

  // Check if in check
  isCheck() {
    return this.chess.isCheck();
  }

  // Check if game is over
  isGameOver() {
    return this.chess.isGameOver();
  }

  // Clone the game
  clone() {
    return new ChessGame(this.chess.fen());
  }
}

// Export for compatibility
export const ChessWrapper = {
  Game: ChessGame
};


