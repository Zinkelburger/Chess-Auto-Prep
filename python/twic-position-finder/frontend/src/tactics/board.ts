/**
 * Chessground wrapper for the trainer board: legal-move generation from
 * chess.js, promotion (auto-queen; a non-queen promotion is accepted if the
 * engine line wants one), and the arrows/highlights lila uses to show a
 * solution.
 */
import { Chess, type Square } from 'chess.js';
import { Chessground } from 'chessground';
import type { Api } from 'chessground/api';
import type { Key } from 'chessground/types';
import type { DrawShape } from 'chessground/draw';

export interface BoardOptions {
  onMove: (uci: string) => void;
}

export class TrainerBoard {
  private cg: Api;
  private chess = new Chess();
  private interactive = false;
  private orientation: 'white' | 'black' = 'white';

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
    const piece = this.chess.get(orig as Square);
    const promotion = piece?.type === 'p' && (dest[1] === '8' || dest[1] === '1') ? 'q' : undefined;
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
