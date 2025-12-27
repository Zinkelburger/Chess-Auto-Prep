/**
 * Chess logic wrapper using chess.js library
 */
import { Chess as ChessLib } from 'chess.js';

export const PIECE_TYPES = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };
export const FILES = 'abcdefgh';
export const RANKS = '12345678';

class ChessGame {
  constructor(fen) {
    this.chess = new ChessLib(fen);
    this.updateBoardCache();
  }

  reset(fen) {
    try {
      this.chess.load(fen || 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1');
    } catch (e) {
      console.error('Invalid FEN:', fen, e);
      this.chess.reset();
    }
    this.updateBoardCache();
  }

  updateBoardCache() {
    this.board = Array(64).fill(null);
    // chess.js board() returns 8x8 array, rank 8 (index 0) to rank 1 (index 7)
    const board2d = this.chess.board();
    
    for (let r = 0; r < 8; r++) {
      for (let f = 0; f < 8; f++) {
        const piece = board2d[r][f];
        if (piece) {
          this.board[r * 8 + f] = { type: piece.type, color: piece.color };
        }
      }
    }

    this.turn = this.chess.turn();
    
    // getCastlingRights returns { k: boolean, q: boolean } for kingside/queenside
    const whiteRights = this.chess.getCastlingRights('w');
    const blackRights = this.chess.getCastlingRights('b');
    this.castling = {
        K: whiteRights.k,
        Q: whiteRights.q,
        k: blackRights.k,
        q: blackRights.q,
    };
  }

  getFen() {
    return this.chess.fen();
  }

  algebraicToIndex(algebraic) {
    if (!algebraic || algebraic.length !== 2) return -1;
    const file = FILES.indexOf(algebraic[0]);
    const rank = 8 - parseInt(algebraic[1]);
    if (file === -1 || rank < 0 || rank > 7) return -1;
    return rank * 8 + file;
  }

  indexToAlgebraic(index) {
    const file = index % 8;
    const rank = 8 - Math.floor(index / 8);
    return FILES[file] + rank;
  }

  getPiece(square) {
    const index = typeof square === 'string' ? this.algebraicToIndex(square) : square;
    return this.board[index];
  }

  getLegalMoves(square) {
    const index = typeof square === 'string' ? this.algebraicToIndex(square) : square;
    const squareAlg = this.indexToAlgebraic(index);
    
    const moves = this.chess.moves({ square: squareAlg, verbose: true });
    
    return moves.map(m => {
      let castling = undefined;
      if (m.flags.includes('k')) castling = m.color === 'w' ? 'K' : 'k';
      if (m.flags.includes('q')) castling = m.color === 'w' ? 'Q' : 'q';
      
      return {
        from: this.algebraicToIndex(m.from),
        to: this.algebraicToIndex(m.to),
        fromAlg: m.from,
        toAlg: m.to,
        promotion: m.promotion,
        castling
      };
    });
  }

  move(from, to, promotion = null) {
    try {
      const moveObj = {
        from: typeof from === 'string' ? from : this.indexToAlgebraic(from),
        to: typeof to === 'string' ? to : this.indexToAlgebraic(to),
        promotion: promotion || undefined
      };

      const result = this.chess.move(moveObj);
      
      if (result) {
        this.updateBoardCache();
        return true;
      }
    } catch (e) {
      // chess.js throws on illegal moves sometimes
    }
    return false;
  }

  parseUci(uci) {
    if (!uci || uci.length < 4) return null;
    return {
      from: uci.substring(0, 2),
      to: uci.substring(2, 4),
      promotion: uci.length > 4 ? uci[4].toLowerCase() : null
    };
  }

  moveUci(uci) {
    const parsed = this.parseUci(uci);
    if (!parsed) return false;
    return this.move(parsed.from, parsed.to, parsed.promotion);
  }

  /**
   * Make a move using SAN notation (e.g., "Nf3", "e4", "O-O")
   * Returns the move object on success, null on failure
   * Move object contains: { from, to, san, lan, color, piece, flags, before, after, ... }
   */
  moveSan(san) {
    try {
      const result = this.chess.move(san);
      if (result) {
        this.updateBoardCache();
        return result;
      }
    } catch (e) {
      // chess.js throws on illegal/invalid moves
    }
    return null;
  }

  inCheck() {
    return this.chess.inCheck();
  }

  isGameOver() {
    return this.chess.isGameOver();
  }
  
  getSan(uci) {
    const parsed = this.parseUci(uci);
    if (!parsed) return null;
    
    const moves = this.chess.moves({ verbose: true });
    const match = moves.find(m => 
      m.from === parsed.from && 
      m.to === parsed.to && 
      (!parsed.promotion || m.promotion === parsed.promotion)
    );
    return match ? match.san : null;
  }
}

export const Chess = {
  Game: ChessGame,
  PIECE_TYPES,
  FILES,
  RANKS
};
