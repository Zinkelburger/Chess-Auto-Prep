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
}

const SQUARE_ROLES: Role[] = ['queen', 'knight', 'rook', 'bishop'];
const SPARE_ROLES: Role[] = ['king', 'queen', 'rook', 'bishop', 'knight', 'pawn'];

/** Piece letters as SAN and drops write them. */
export const ROLE_LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };

/** A piece's cburnett image under /piece/. */
export const pieceSrc = (color: Color, role: Role) => `/piece/${color === 'white' ? 'w' : 'b'}${ROLE_LETTER[role]}.svg`;

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
      draggable: { deleteOnDropOff: false },
      selectable: { enabled: true },
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
    this.cg.set({ selectable: { enabled: !painting }, draggable: { enabled: !painting } });
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

  /**
   * One of lila's spare-piece strips beside the editor: the hand cursor, one
   * colour's six pieces and the bin. Choosing one makes it the brush; pressing
   * a piece also drags a new one onto the board.
   */
  spareStrip(color: Color, brush: Brush, choose: (brush: Brush) => void): HTMLElement[] {
    const items: HTMLElement[] = [];
    const tool = (name: 'pointer' | 'trash', label: string, svg: string) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.className = `ch-spare-tool ch-${name}`;
      b.title = label;
      b.setAttribute('aria-label', label);
      b.setAttribute('aria-pressed', String(brush === name));
      b.innerHTML = svg;
      b.onclick = () => choose(name);
      return b;
    };
    items.push(tool('pointer', 'Move pieces: drag one off the board to remove it', POINTER_SVG));
    for (const role of SPARE_ROLES) {
      const piece: Piece = { role, color };
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'ch-spare-piece';
      const selected = typeof brush !== 'string' && brush.role === role && brush.color === color;
      b.setAttribute('aria-pressed', String(selected));
      const name = `${color} ${role}`;
      b.title = `Place ${name}s: click or drag across squares`;
      b.setAttribute('aria-label', `Place ${name}s`);
      const img = document.createElement('img');
      img.src = pieceSrc(color, role);
      img.alt = '';
      img.draggable = false;
      b.append(img);
      const press = (e: MouseEvent | TouchEvent) => {
        if (e instanceof MouseEvent && e.button !== 0) return;
        e.preventDefault();
        choose(piece);
        this.dragNew({ ...piece }, e, true);
      };
      b.addEventListener('mousedown', press);
      b.addEventListener('touchstart', press, { passive: false });
      b.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); choose(piece); } };
      items.push(b);
    }
    items.push(tool('trash', 'Remove pieces: click or drag across squares', TRASH_SVG));
    return items;
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
        img.src = pieceSrc(color, role);
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

const POINTER_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 11V6a2 2 0 0 0-4 0v0M14 10V4a2 2 0 0 0-4 0v2M10 10.5V6a2 2 0 0 0-4 0v8"/><path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/></svg>';
const TRASH_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>';
