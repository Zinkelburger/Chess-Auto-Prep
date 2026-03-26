import { Chessground } from 'chessground';
import { Chess } from './chess';

export class Board {
  constructor(containerId, options = {}) {
    this.containerId = containerId;
    this.container = null;
    this.options = {
      flipped: false,
      interactive: true,
      onMove: null,
      ...options
    };
    
    this.cg = null;
    this.game = null;
    this.fen = null;
    this.mounted = false;
  }

  // Call this when the container is visible and sized
  mount() {
    if (this.mounted) return Promise.resolve();
    
    return new Promise((resolve) => {
      const tryMount = () => {
        this.container = document.getElementById(this.containerId);
        
        if (!this.container) {
          requestAnimationFrame(tryMount);
          return;
        }
        
        const rect = this.container.getBoundingClientRect();
        if (rect.width < 50 || rect.height < 50) {
          requestAnimationFrame(tryMount);
          return;
        }
        
        this.initChessground();
        this.mounted = true;
        resolve();
      };
      
      tryMount();
    });
  }

  initChessground() {
    this.cg = Chessground(this.container, {
      orientation: this.options.flipped ? 'black' : 'white',
      coordinates: true,  // Enable coordinate display
      coordinatesOnSquares: false,  // Use edge coordinates, not on squares
      movable: {
        free: false,
        color: 'both',
        dests: new Map(),
        events: {
          after: (orig, dest) => this.handleMove(orig, dest)
        }
      },
      draggable: {
        enabled: true,
        showGhost: true
      },
      highlight: {
        lastMove: true,
        check: true
      },
      animation: {
        enabled: true,
        duration: 150
      },
      premovable: {
        enabled: false
      }
    });

    // Debounced resize observer
    let resizeTimeout;
    new ResizeObserver(() => {
      clearTimeout(resizeTimeout);
      resizeTimeout = setTimeout(() => {
        if (this.cg) this.cg.redrawAll();
      }, 50);
    }).observe(this.container);
  }

  setPosition(fen) {
    if (!this.cg) return;
    
    this.fen = fen;
    this.game = new Chess.Game(fen);
    
    const parts = fen.split(' ');
    const turn = parts[1] === 'w' ? 'white' : 'black';
    
    this.cg.set({
      fen: parts[0],
      turnColor: turn,
      lastMove: undefined,  // Clear last move highlighting for fresh position
      movable: {
        color: this.options.interactive ? turn : undefined,
        dests: this.options.interactive ? this.getDestinations() : new Map()
      },
      check: this.isInCheck()
    });
    
    // Force redraw after position set (double rAF ensures layout is stable)
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        if (this.cg) this.cg.redrawAll();
      });
    });
  }

  getDestinations() {
    if (!this.game) return new Map();
    
    const dests = new Map();
    
    for (let sq = 0; sq < 64; sq++) {
      const piece = this.game.board[sq];
      if (piece && piece.color === this.game.turn) {
        const from = this.game.indexToAlgebraic(sq);
        const moves = this.game.getLegalMoves(sq);
        const targets = moves.map(m => m.toAlg);
        if (targets.length > 0) {
          dests.set(from, targets);
        }
      }
    }
    
    return dests;
  }

  isInCheck() {
    return this.game ? this.game.inCheck() : false;
  }

  handleMove(orig, dest) {
    if (!this.game) return;
    
    const piece = this.game.getPiece(orig);
    const isPromotion = piece?.type === 'p' && (dest[1] === '8' || dest[1] === '1');
    const promotion = isPromotion ? 'q' : null;
    
    const success = this.game.move(orig, dest, promotion);
    
    if (success) {
      this.setPosition(this.game.getFen());
      
      if (this.options.onMove) {
        const uci = orig + dest + (promotion || '');
        this.options.onMove(uci, this.game.getFen());
      }
    } else {
      this.setPosition(this.fen);
    }
  }

  flip() {
    this.options.flipped = !this.options.flipped;
    if (this.cg) this.cg.set({ orientation: this.options.flipped ? 'black' : 'white' });
  }

  setFlipped(flipped) {
    if (this.options.flipped !== flipped) {
      this.options.flipped = flipped;
      if (this.cg) this.cg.set({ orientation: flipped ? 'black' : 'white' });
    }
  }

  setInteractive(interactive) {
    this.options.interactive = interactive;
    if (this.cg && this.game) {
      const turn = this.game.turn === 'w' ? 'white' : 'black';
      this.cg.set({
        movable: {
          color: interactive ? turn : undefined,
          dests: interactive ? this.getDestinations() : new Map()
        }
      });
    }
  }

  redraw() {
    if (this.cg) this.cg.redrawAll();
  }
}
