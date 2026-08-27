/**
 * Chessground wrapper for the trainer board: legal-move generation from
 * chess.js, promotion, and the arrows/highlights lila uses to show a
 * solution.
 *
 * There is no promotion picker. The board queens by default and asks
 * [BoardOptions.promotionFor] first, so a puzzle whose solution underpromotes
 * gets the piece the line actually wants — otherwise the position would
 * diverge from the line after the very move that solved it.
 */
import { Chess, type Square } from 'chess.js';
import { Chessground } from 'chessground';
import type { Api } from 'chessground/api';
import type { Key } from 'chessground/types';
import type { DrawShape } from 'chessground/draw';

export type PromotionPiece = 'q' | 'r' | 'b' | 'n';

export interface BoardOptions {
  onMove: (uci: string) => void;
  /** Promotion piece for this from→to, when something knows better than a queen. */
  promotionFor?: (orig: Key, dest: Key) => PromotionPiece | undefined;
}

export class TrainerBoard {
  private cg: Api;
  private chess = new Chess();
  private interactive = false;
  private orientation: 'white' | 'black' = 'white';
  /**
   * Set while we drive the board ourselves. `cg.move()` fires chessground's
   * own `events.move`, which is wired to [onUserMove] — without this the
   * auto-played engine reply re-enters as though the user had made it, the
   * nested `chess.move` throws on an already-advanced position, and the catch
   * resets the board mid-animation, wiping the solution arrows.
   */
  private applying = false;

  constructor(el: HTMLElement, private readonly opts: BoardOptions) {
    this.cg = Chessground(el, {
      coordinates: true,
      movable: { free: false, color: undefined, dests: new Map(), showDests: true },
      draggable: { enabled: true, showGhost: true },
      selectable: { enabled: true },
      highlight: { lastMove: true, check: true },
      animation: { enabled: true, duration: 180 },
      premovable: { enabled: false },
      drawable: { enabled: false, visible: true },
      events: { move: (orig, dest) => this.onUserMove(orig, dest) },
    });
    // Only redraw while the board has a size: a hidden board (display:none)
    // reports 0×0 and chessground would place any arrows at NaN.
    new ResizeObserver((entries) => {
      if (entries.some((e) => e.contentRect.width > 0)) this.cg.redrawAll();
    }).observe(el);
  }

  private turn(): 'white' | 'black' {
    return this.chess.turn() === 'w' ? 'white' : 'black';
  }

  private dests(): Map<Key, Key[]> {
    const map = new Map<Key, Key[]>();
    for (const m of this.chess.moves({ verbose: true })) {
      const list = map.get(m.from as Key) ?? [];
      list.push(m.to as Key);
      map.set(m.from as Key, list);
    }
    return map;
  }

  /** Show [fen]; optional [lastMove] highlight. */
  setPosition(fen: string, lastMove?: [Key, Key]): void {
    this.chess.load(fen);
    this.cg.set({
      fen,
      turnColor: this.turn(),
      lastMove,
      check: this.chess.inCheck(),
      movable: this.movableConfig(),
      drawable: { shapes: [] },
    });
  }

  setOrientation(color: 'white' | 'black'): void {
    if (this.orientation === color) return;
    this.orientation = color;
    this.cg.set({ orientation: color });
  }

  setInteractive(on: boolean): void {
    this.interactive = on;
    this.cg.set({ movable: this.movableConfig() });
  }

  private movableConfig() {
    return {
      color: this.interactive ? this.turn() : undefined,
      dests: this.interactive ? this.dests() : new Map<Key, Key[]>(),
    };
  }

  private onUserMove(orig: Key, dest: Key): void {
    if (this.applying) return;
    const piece = this.chess.get(orig as Square);
    const promotion = piece?.type === 'p' && (dest[1] === '8' || dest[1] === '1')
      ? this.opts.promotionFor?.(orig, dest) ?? 'q'
      : undefined;
    let uci = orig + dest;
    try {
      this.chess.move({ from: orig, to: dest, promotion });
      if (promotion) uci += promotion;
    } catch {
      this.setPosition(this.chess.fen());
      return;
    }
    // Reflect the move (chessground already animated it; sync check/turn).
    this.cg.set({
      fen: this.chess.fen(),
      turnColor: this.turn(),
      check: this.chess.inCheck(),
      movable: { color: undefined, dests: new Map() },
    });
    this.opts.onMove(uci);
  }

  /** Play [uci] with animation from the current position. Returns false if illegal. */
  playUci(uci: string): boolean {
    this.applying = true;
    try {
      const mv = this.chess.move({ from: uci.slice(0, 2), to: uci.slice(2, 4), promotion: uci[4] });
      this.cg.move(mv.from as Key, mv.to as Key);
      this.cg.set({
        fen: this.chess.fen(),
        turnColor: this.turn(),
        check: this.chess.inCheck(),
        lastMove: [mv.from as Key, mv.to as Key],
        movable: this.movableConfig(),
      });
      return true;
    } catch {
      return false;
    } finally {
      this.applying = false;
    }
  }

  fen(): string {
    return this.chess.fen();
  }

  setShapes(shapes: DrawShape[]): void {
    this.cg.setShapes(shapes);
  }

  /** A single arrow for a UCI move, in lila's solution green. */
  arrow(uci: string, brush: 'green' | 'red' | 'blue' | 'yellow' = 'green'): DrawShape {
    return { orig: uci.slice(0, 2) as Key, dest: uci.slice(2, 4) as Key, brush };
  }

  redraw(): void {
    this.cg.redrawAll();
  }
}
