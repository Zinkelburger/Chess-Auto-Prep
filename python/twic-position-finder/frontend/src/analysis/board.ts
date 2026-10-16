/**
 * The one bughouse board, in two modes that share the chessground instance:
 *
 * - analysis: legal moves and drops of the side to move (drag a hand piece on,
 *   or click it and then a square), the promotion picker, engine arrows, and
 *   the wheel stepping through moves, as on lichess.org/analysis;
 * - editor: lila's board editor. A spare piece or the bin chosen as a brush
 *   paints on press and while the button is held; the hand cursor drags
 *   pieces freely and off the board to remove them. Dragging a spare piece
 *   onto the board places it too.
 */
import { Chessground } from '@lichess-org/chessground';
import type { Api } from '@lichess-org/chessground/api';
import type { DrawShape } from '@lichess-org/chessground/draw';
import { write as writeBoard } from '@lichess-org/chessground/fen';
import type { Color, Key, Piece, Role } from '@lichess-org/chessground/types';

export type Brush = 'pointer' | 'trash' | Piece;

export interface AnalysisView {
  fen: string;
  orientation: Color;
  turn: Color;
  dests: Map<Key, Key[]>;
  lastMove: Key[];
  check: boolean;
  shapes: DrawShape[];
  /** The hand piece picked up by a click, waiting for a square. */
  dropping: Role | null;
  dropSquares: Key[];
}

export interface BoardHooks {
  move: (orig: Key, dest: Key) => void;
  drop: (role: Role, key: Key) => void;
  /** A click on a square while a hand piece is picked up (or any click, to cancel). */
  clickSquare: (key: Key) => void;
  wheel: (forward: boolean) => void;
  /** The editor's pieces changed. */
  edited: () => void;
  /** A right-click in the editor with a piece in hand: the same piece in the other colour. */
  swapBrushColor: () => void;
}

const SQUARE_ROLES: Role[] = ['queen', 'knight', 'rook', 'bishop'];

export class CrazyBoard {
  readonly cg: Api;
  private mode: 'analysis' | 'editor' = 'analysis';
  private brush: Brush = 'pointer';
  private painting: { last: Key | null; erase: boolean } | null = null;
  private promotion: HTMLElement | null = null;

  constructor(private readonly wrap: HTMLElement, el: HTMLElement, private readonly hooks: BoardHooks) {
    this.cg = Chessground(el, {
      coordinates: true,
      autoCastle: true,
      highlight: { lastMove: true, check: true },
      animation: { enabled: true, duration: 150 },
      premovable: { enabled: false },
      predroppable: { enabled: false },
      draggable: { showGhost: true },
      drawable: { enabled: true, eraseOnMovablePieceClick: false },
      movable: {
        free: false,
        showDests: true,
        events: {
          after: (orig, dest) => { if (this.mode === 'analysis') hooks.move(orig, dest); },
          afterNewPiece: (role, key) => { if (this.mode === 'analysis') hooks.drop(role, key); },
        },
      },
      events: {
        select: (key) => { if (this.mode === 'analysis') hooks.clickSquare(key); },
        change: () => { if (this.mode === 'editor') hooks.edited(); },
      },
    });
    // A board with no size (a window shrunk to nothing) has no coordinates for arrows: wait for one.
    new ResizeObserver(() => { if (this.sized()) this.cg.redrawAll(); }).observe(el);
    el.addEventListener('wheel', (e) => {
      if (this.mode !== 'analysis' || e.ctrlKey) return;
      e.preventDefault();
      hooks.wheel(e.deltaY > 0);
    }, { passive: false });
    // Capture before chessground: with a brush in hand the board paints instead of moving.
    for (const type of ['mousedown', 'touchstart'] as const)
      wrap.addEventListener(type, (e) => this.pressed(e), { capture: true, passive: false });
    for (const type of ['mousemove', 'touchmove'] as const)
      document.addEventListener(type, (e) => this.dragged(e), { passive: false });
    // As on lila: with a piece in hand, right-click takes the other colour (shapes need the hand).
    wrap.addEventListener('contextmenu', (e) => {
      if (this.mode !== 'editor' || typeof this.brush === 'string') return;
      e.preventDefault();
      this.cg.cancelMove();
      hooks.swapBrushColor();
    });
    for (const type of ['mouseup', 'touchend', 'touchcancel'] as const)
      document.addEventListener(type, () => { this.painting = null; });
  }

  showAnalysis(view: AnalysisView) {
    this.mode = 'analysis';
    this.cg.set({
      fen: view.fen,
      orientation: view.orientation,
      turnColor: view.turn,
      lastMove: view.lastMove,
      check: view.check ? view.turn : false,
      movable: { free: false, color: view.turn, dests: view.dests, showDests: true },
      // The editor's brush turns these off; analysis always has them.
      draggable: { enabled: true, deleteOnDropOff: false },
      selectable: { enabled: true },
      drawable: { enabled: true },
      highlight: { custom: new Map(view.dropSquares.map((sq) => [sq, 'move-dest'])) },
    });
    this.setShapes(view.shapes);
    this.wrap.classList.remove('ch-editing');
  }

  /** Engine arrows; drawn now, or when the board has a size again. */
  setShapes(shapes: DrawShape[]) {
    if (this.sized()) this.cg.setAutoShapes(shapes);
    else this.cg.state.drawable.autoShapes = shapes;
  }

  private sized(): boolean {
    return this.wrap.clientWidth > 0 && this.wrap.clientHeight > 0;
  }

  showEditor(fen: string, orientation: Color, brush: Brush) {
    this.mode = 'editor';
    this.closePromotion();
    this.cg.set({
      fen,
      orientation,
      lastMove: undefined,
      check: false,
      movable: { free: true, color: 'both', dests: new Map() },
      draggable: { deleteOnDropOff: true },
      highlight: { custom: new Map() },
    });
    this.cg.setAutoShapes([]);
    this.cg.selectSquare(null);
    this.setBrush(brush);
    this.wrap.classList.add('ch-editing');
  }

  setBrush(brush: Brush) {
    this.brush = brush;
    const painting = brush !== 'pointer';
    this.cg.set({ selectable: { enabled: !painting }, draggable: { enabled: !painting }, drawable: { enabled: !painting } });
    this.wrap.dataset.brush = typeof brush === 'string' ? brush : 'piece';
  }

  /** The editor's board as a FEN board field. */
  boardFen(): string {
    return writeBoard(this.cg.state.pieces);
  }

  /** Starts dragging a spare or hand piece onto the board. */
  dragNew(piece: Piece, e: MouseEvent | TouchEvent, force = false) {
    this.cg.state.dom.bounds.clear();
    this.cg.dragNewPiece(piece, e, force);
  }

  private keyAt(e: MouseEvent | TouchEvent): Key | undefined {
    const point = 'touches' in e ? e.touches[0] ?? e.changedTouches[0] : e;
    if (!point) return undefined;
    this.cg.state.dom.bounds.clear();
    return this.cg.getKeyAtDomPos([point.clientX, point.clientY]);
  }

  private pressed(e: MouseEvent | TouchEvent) {
    if (this.mode !== 'editor' || this.brush === 'pointer') return;
    if (e instanceof MouseEvent && e.button !== 0) return;
    const key = this.keyAt(e);
    if (!key) return;
    e.preventDefault();
    e.stopPropagation();
    const brush = this.brush;
    // As on lila: a click with the piece already there removes it.
    const here = this.cg.state.pieces.get(key);
    const erase = brush === 'trash' || (!!here && here.role === brush.role && here.color === brush.color);
    this.painting = { last: null, erase };
    this.paint(key);
  }

  private dragged(e: MouseEvent | TouchEvent) {
    if (!this.painting) return;
    const key = this.keyAt(e);
    if (key) { e.preventDefault(); this.paint(key); }
  }

  private paint(key: Key) {
    const painting = this.painting!;
    if (painting.last === key) return;
    painting.last = key;
    const piece = painting.erase || this.brush === 'pointer' || this.brush === 'trash' ? undefined : this.brush;
    const here = this.cg.state.pieces.get(key);
    if (!piece && !here) return;
    if (piece && here && here.role === piece.role && here.color === piece.color) return;
    this.cg.setPieces(new Map([[key, piece ? { ...piece } : undefined]]));
    this.hooks.edited();
  }

  /** Lichess's promotion picker on the promotion file; resolves null when dismissed. */
  pickPromotion(dest: Key, color: Color, orientation: Color): Promise<Role | null> {
    this.closePromotion();
    return new Promise((resolve) => {
      const overlay = document.createElement('div');
      overlay.className = 'ch-promotion';
      const file = dest.charCodeAt(0) - 97;
      const left = orientation === 'white' ? file : 7 - file;
      const top = color === orientation;
      const done = (role: Role | null) => { this.closePromotion(); resolve(role); };
      SQUARE_ROLES.forEach((role, i) => {
        const button = document.createElement('button');
        button.type = 'button';
        button.className = 'ch-promotion-piece';
        button.style.left = `${left * 12.5}%`;
        button.style.top = `${(top ? i : 7 - i) * 12.5}%`;
        button.setAttribute('aria-label', `Promote to ${role}`);
        const img = document.createElement('img');
        img.src = `/piece/${color === 'white' ? 'w' : 'b'}${role === 'knight' ? 'N' : role[0].toUpperCase()}.svg`;
        img.alt = '';
        button.append(img);
        button.onclick = (e) => { e.stopPropagation(); done(role); };
        overlay.append(button);
      });
      overlay.onclick = () => done(null);
      this.promotion = overlay;
      this.wrap.append(overlay);
    });
  }

  private closePromotion() {
    this.promotion?.remove();
    this.promotion = null;
  }
}
