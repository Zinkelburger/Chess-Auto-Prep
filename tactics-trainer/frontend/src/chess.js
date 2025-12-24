/**
 * Minimal chess logic library (module version)
 */

const PIECE_TYPES = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };
const FILES = 'abcdefgh';
const RANKS = '12345678';

class ChessGame {
  constructor(fen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1') {
    this.reset(fen);
  }

  reset(fen) {
    this.board = Array(64).fill(null);
    this.turn = 'w';
    this.castling = { K: true, Q: true, k: true, q: true };
    this.enPassant = null;
    this.halfmoves = 0;
    this.fullmoves = 1;
    this.loadFen(fen);
  }

  loadFen(fen) {
    const parts = fen.split(' ');
    const position = parts[0];
    
    // Parse position
    let square = 0;
    for (const char of position) {
      if (char === '/') continue;
      if (/[1-8]/.test(char)) {
        square += parseInt(char);
      } else {
        const color = char === char.toUpperCase() ? 'w' : 'b';
        const type = char.toLowerCase();
        this.board[square] = { color, type };
        square++;
      }
    }

    // Parse other FEN parts
    if (parts[1]) this.turn = parts[1];
    if (parts[2]) {
      this.castling = { K: false, Q: false, k: false, q: false };
      if (parts[2] !== '-') {
        for (const c of parts[2]) {
          this.castling[c] = true;
        }
      }
    }
    if (parts[3]) this.enPassant = parts[3] === '-' ? null : parts[3];
    if (parts[4]) this.halfmoves = parseInt(parts[4]);
    if (parts[5]) this.fullmoves = parseInt(parts[5]);
  }

  getFen() {
    let fen = '';
    
    // Position
    for (let rank = 0; rank < 8; rank++) {
      let empty = 0;
      for (let file = 0; file < 8; file++) {
        const piece = this.board[rank * 8 + file];
        if (piece) {
          if (empty > 0) {
            fen += empty;
            empty = 0;
          }
          const char = piece.type;
          fen += piece.color === 'w' ? char.toUpperCase() : char;
        } else {
          empty++;
        }
      }
      if (empty > 0) fen += empty;
      if (rank < 7) fen += '/';
    }

    fen += ` ${this.turn}`;
    
    let castling = '';
    if (this.castling.K) castling += 'K';
    if (this.castling.Q) castling += 'Q';
    if (this.castling.k) castling += 'k';
    if (this.castling.q) castling += 'q';
    fen += ` ${castling || '-'}`;
    
    fen += ` ${this.enPassant || '-'}`;
    fen += ` ${this.halfmoves}`;
    fen += ` ${this.fullmoves}`;

    return fen;
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
    const piece = this.board[index];
    if (!piece || piece.color !== this.turn) return [];

    const moves = [];
    const file = index % 8;
    const rank = Math.floor(index / 8);

    const addMove = (toIndex, promotion = null) => {
      if (toIndex >= 0 && toIndex < 64) {
        const to = this.board[toIndex];
        if (!to || to.color !== piece.color) {
          moves.push({
            from: index,
            to: toIndex,
            fromAlg: this.indexToAlgebraic(index),
            toAlg: this.indexToAlgebraic(toIndex),
            promotion
          });
        }
      }
    };

    const slideMove = (dFile, dRank) => {
      let f = file + dFile;
      let r = rank + dRank;
      while (f >= 0 && f < 8 && r >= 0 && r < 8) {
        const toIndex = r * 8 + f;
        const target = this.board[toIndex];
        if (target) {
          if (target.color !== piece.color) addMove(toIndex);
          break;
        }
        addMove(toIndex);
        f += dFile;
        r += dRank;
      }
    };

    switch (piece.type) {
      case 'p': {
        const direction = piece.color === 'w' ? -1 : 1;
        const startRank = piece.color === 'w' ? 6 : 1;
        const promotionRank = piece.color === 'w' ? 0 : 7;
        
        const forwardIndex = (rank + direction) * 8 + file;
        if (!this.board[forwardIndex]) {
          if (rank + direction === promotionRank) {
            ['q', 'r', 'b', 'n'].forEach(p => addMove(forwardIndex, p));
          } else {
            addMove(forwardIndex);
          }
          
          if (rank === startRank) {
            const doubleIndex = (rank + 2 * direction) * 8 + file;
            if (!this.board[doubleIndex]) {
              addMove(doubleIndex);
            }
          }
        }
        
        for (const df of [-1, 1]) {
          if (file + df >= 0 && file + df < 8) {
            const captureIndex = (rank + direction) * 8 + (file + df);
            const target = this.board[captureIndex];
            if (target && target.color !== piece.color) {
              if (rank + direction === promotionRank) {
                ['q', 'r', 'b', 'n'].forEach(p => addMove(captureIndex, p));
              } else {
                addMove(captureIndex);
              }
            }
            if (this.enPassant === this.indexToAlgebraic(captureIndex)) {
              addMove(captureIndex);
            }
          }
        }
        break;
      }
      
      case 'n': {
        const knightMoves = [
          [-2, -1], [-2, 1], [-1, -2], [-1, 2],
          [1, -2], [1, 2], [2, -1], [2, 1]
        ];
        for (const [dr, df] of knightMoves) {
          const newRank = rank + dr;
          const newFile = file + df;
          if (newRank >= 0 && newRank < 8 && newFile >= 0 && newFile < 8) {
            addMove(newRank * 8 + newFile);
          }
        }
        break;
      }
      
      case 'b':
        slideMove(-1, -1); slideMove(-1, 1);
        slideMove(1, -1); slideMove(1, 1);
        break;
      
      case 'r':
        slideMove(-1, 0); slideMove(1, 0);
        slideMove(0, -1); slideMove(0, 1);
        break;
      
      case 'q':
        slideMove(-1, -1); slideMove(-1, 1);
        slideMove(1, -1); slideMove(1, 1);
        slideMove(-1, 0); slideMove(1, 0);
        slideMove(0, -1); slideMove(0, 1);
        break;
      
      case 'k': {
        for (let dr = -1; dr <= 1; dr++) {
          for (let df = -1; df <= 1; df++) {
            if (dr === 0 && df === 0) continue;
            const newRank = rank + dr;
            const newFile = file + df;
            if (newRank >= 0 && newRank < 8 && newFile >= 0 && newFile < 8) {
              addMove(newRank * 8 + newFile);
            }
          }
        }
        
        if (piece.color === 'w' && rank === 7) {
          if (this.castling.K && !this.board[61] && !this.board[62]) {
            moves.push({ from: index, to: 62, fromAlg: 'e1', toAlg: 'g1', castling: 'K' });
          }
          if (this.castling.Q && !this.board[57] && !this.board[58] && !this.board[59]) {
            moves.push({ from: index, to: 58, fromAlg: 'e1', toAlg: 'c1', castling: 'Q' });
          }
        } else if (piece.color === 'b' && rank === 0) {
          if (this.castling.k && !this.board[5] && !this.board[6]) {
            moves.push({ from: index, to: 6, fromAlg: 'e8', toAlg: 'g8', castling: 'k' });
          }
          if (this.castling.q && !this.board[1] && !this.board[2] && !this.board[3]) {
            moves.push({ from: index, to: 2, fromAlg: 'e8', toAlg: 'c8', castling: 'q' });
          }
        }
        break;
      }
    }

    return moves;
  }

  move(from, to, promotion = null) {
    const fromIndex = typeof from === 'string' ? this.algebraicToIndex(from) : from;
    const toIndex = typeof to === 'string' ? this.algebraicToIndex(to) : to;
    
    const piece = this.board[fromIndex];
    if (!piece || piece.color !== this.turn) return false;

    const legalMoves = this.getLegalMoves(fromIndex);
    const move = legalMoves.find(m => 
      m.to === toIndex && 
      (!promotion || m.promotion === promotion)
    );
    
    if (!move) return false;

    const captured = this.board[toIndex];
    this.board[toIndex] = piece;
    this.board[fromIndex] = null;

    if (piece.type === 'p') {
      if (move.promotion) {
        this.board[toIndex] = { color: piece.color, type: move.promotion };
      }
      if (this.enPassant === this.indexToAlgebraic(toIndex)) {
        const epCaptureIndex = piece.color === 'w' ? toIndex + 8 : toIndex - 8;
        this.board[epCaptureIndex] = null;
      }
      if (Math.abs(toIndex - fromIndex) === 16) {
        this.enPassant = this.indexToAlgebraic((fromIndex + toIndex) / 2);
      } else {
        this.enPassant = null;
      }
    } else {
      this.enPassant = null;
    }

    if (move.castling) {
      if (move.castling === 'K') {
        this.board[61] = this.board[63];
        this.board[63] = null;
      } else if (move.castling === 'Q') {
        this.board[59] = this.board[56];
        this.board[56] = null;
      } else if (move.castling === 'k') {
        this.board[5] = this.board[7];
        this.board[7] = null;
      } else if (move.castling === 'q') {
        this.board[3] = this.board[0];
        this.board[0] = null;
      }
    }

    if (piece.type === 'k') {
      if (piece.color === 'w') {
        this.castling.K = false;
        this.castling.Q = false;
      } else {
        this.castling.k = false;
        this.castling.q = false;
      }
    }
    if (fromIndex === 63 || toIndex === 63) this.castling.K = false;
    if (fromIndex === 56 || toIndex === 56) this.castling.Q = false;
    if (fromIndex === 7 || toIndex === 7) this.castling.k = false;
    if (fromIndex === 0 || toIndex === 0) this.castling.q = false;

    if (piece.type === 'p' || captured) {
      this.halfmoves = 0;
    } else {
      this.halfmoves++;
    }
    if (this.turn === 'b') {
      this.fullmoves++;
    }
    this.turn = this.turn === 'w' ? 'b' : 'w';

    return true;
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

  clone() {
    const clone = new ChessGame();
    clone.board = [...this.board.map(p => p ? {...p} : null)];
    clone.turn = this.turn;
    clone.castling = {...this.castling};
    clone.enPassant = this.enPassant;
    clone.halfmoves = this.halfmoves;
    clone.fullmoves = this.fullmoves;
    return clone;
  }
}

export const Chess = {
  Game: ChessGame,
  PIECE_TYPES,
  FILES,
  RANKS
};

