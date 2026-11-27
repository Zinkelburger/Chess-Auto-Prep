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
 *
 * The board is also one Tab stop, as the puzzle board is: the arrows move a
 * square cursor (drawn only once a key is pressed on the board), Enter or
 * Space presses the square as a click does (pick up, put down, drop a hand
 * piece, paint with the editor's brush), Escape puts back what is picked. A
 * polite live line says where the cursor is and what was picked.
 */
import { Chessground } from '@lichess-org/chessground';
import type { Api } from '@lichess-org/chessground/api';
import type { DrawShape } from '@lichess-org/chessground/draw';
import { write as writeBoard } from '@lichess-org/chessground/fen';
import type { Color, Key, Piece, Role } from '@lichess-org/chessground/types';
import { moveCursor, type CursorKey } from '../bughouse-puzzles/puzzle';

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
  swapBrushColor?: () => void;
}

export interface BoardOptions {
  /** Crazyhouse: Shift-click in the editor marks a piece promoted (it goes back as a pawn when taken). */
  promotedPieces?: boolean;
}

const SQUARE_ROLES: Role[] = ['queen', 'knight', 'rook', 'bishop'];
const SPARE_ROLES: Role[] = ['king', 'queen', 'rook', 'bishop', 'knight', 'pawn'];

/** Piece letters as SAN and drops write them. */
export const ROLE_LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };

/** A piece's cburnett image under /piece/. */
export const pieceSrc = (color: Color, role: Role) => `/piece/${color === 'white' ? 'w' : 'b'}${ROLE_LETTER[role]}.svg`;

/** The bin as a cursor: white strokes over a dark outline, readable on both square colours. */
const TRASH_PATH = 'M3 6h18M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2';
const TRASH_CURSOR = svgCursor(`<svg xmlns="http://www.w3.org/2000/svg" width="28" height="28" viewBox="-2 -2 28 28" fill="none" stroke-linecap="round" stroke-linejoin="round"><path d="${TRASH_PATH}" stroke="#000" stroke-width="4.5"/><path d="${TRASH_PATH}" stroke="#fff" stroke-width="2"/></svg>`, 14);
/** Piece cursors, made once per piece from the board's own piece images. */
const pieceCursors = new Map<string, Promise<string | null>>();

function svgCursor(svg: string, hotspot: number): string {
  return `url("data:image/svg+xml,${encodeURIComponent(svg)}") ${hotspot} ${hotspot}, crosshair`;
}

/** The piece as a cursor, as lila's editor shows it; null when the image cannot be read. */
function pieceCursor(piece: Piece): Promise<string | null> {
  const src = pieceSrc(piece.color, piece.role);
  let cursor = pieceCursors.get(src);
  if (!cursor) {
    // A cursor image needs its own size and cannot load other files, so the SVG is inlined with one.
    cursor = fetch(src)
      .then((r) => (r.ok ? r.text() : Promise.reject(new Error(String(r.status)))))
      .then((svg) => svgCursor(svg.replace('<svg ', '<svg width="44" height="44" '), 22))
      .catch(() => null);
    pieceCursors.set(src, cursor);
  }
  return cursor;
}

export class CrazyBoard {
  readonly cg: Api;
  private mode: 'analysis' | 'editor' = 'analysis';
  private brush: Brush = 'pointer';
  private painting: { last: Key | null; erase: boolean } | null = null;
  private promotion: HTMLElement | null = null;
  /** The keyboard cursor's square; null until a key places it. */
  private cursor: Key | null = null;
  private cursorShown = false;
  private readonly cursorEl: HTMLElement;
  private readonly live: HTMLElement;

  constructor(
    private readonly wrap: HTMLElement,
    private readonly el: HTMLElement,
    private readonly hooks: BoardHooks,
    private readonly options: BoardOptions = {},
  ) {
    this.cg = Chessground(el, {
      coordinates: true,
      autoCastle: true,
      highlight: { lastMove: true, check: true },
      // No sliding pieces for a reader who asked for less motion.
      animation: { enabled: !matchMedia('(prefers-reduced-motion: reduce)').matches, duration: 150 },
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
        change: () => { if (this.mode === 'editor') { this.markPromoted(); hooks.edited(); } },
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
    const swapBrushColor = hooks.swapBrushColor;
    if (swapBrushColor)
      wrap.addEventListener('contextmenu', (e) => {
        if (this.mode !== 'editor' || typeof this.brush === 'string') return;
        e.preventDefault();
        this.cg.cancelMove();
        swapBrushColor();
      });
    for (const type of ['mouseup', 'touchend', 'touchcancel'] as const)
      document.addEventListener(type, () => { this.painting = null; });

    // The keyboard: one Tab stop, a square cursor, a live line.
    el.tabIndex = 0;
    this.cursorEl = document.createElement('div');
    this.cursorEl.className = 'ch-cursor';
    this.cursorEl.hidden = true;
    this.cursorEl.setAttribute('aria-hidden', 'true');
    wrap.append(this.cursorEl);
    this.live = document.createElement('p');
    this.live.className = 'visually-hidden';
    this.live.setAttribute('aria-live', 'polite');
    wrap.append(this.live);
    el.addEventListener('keydown', (e) => this.keydown(e));
    el.addEventListener('blur', () => this.hideCursor());
    // A mouse or a finger on the board takes over from the keyboard.
    for (const type of ['mousedown', 'touchstart'] as const) el.addEventListener(type, () => this.hideCursor(), { capture: true, passive: true });
  }

  /** A hand piece picked from the keyboard: the board takes the focus, cursor showing. */
  focusForDrop(text: string) {
    this.el.focus({ preventScroll: true });
    this.showCursor();
    this.say(text);
  }

  private say(text: string) { this.live.textContent = text; }

  private keydown(e: KeyboardEvent) {
    if (e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === 'ArrowUp' || e.key === 'ArrowDown' || e.key === 'ArrowLeft' || e.key === 'ArrowRight') {
      // While the board has focus the arrows belong to the cursor, not to the moves.
      e.preventDefault();
      e.stopPropagation();
      if (this.cursorShown && this.cursor) this.cursor = moveCursor(this.cursor, e.key as CursorKey, this.cg.state.orientation) as Key;
      else this.showCursor();
      this.drawCursor();
      this.saySquare();
    } else if (e.key === 'Enter' || e.key === ' ') {
      e.preventDefault();
      e.stopPropagation();
      if (!this.cursorShown || !this.cursor) { this.showCursor(); this.saySquare(); return; }
      this.press(this.cursor);
    } else if (e.key === 'Escape' && this.cg.state.selected) {
      e.preventDefault();
      e.stopPropagation();
      this.cg.selectSquare(null);
      this.say('Put back');
    }
  }

  /** Enter or Space on a square: what a click there does. */
  private press(key: Key) {
    if (this.mode === 'editor' && this.brush !== 'pointer') {
      const here = this.cg.state.pieces.get(key);
      const brush = this.brush;
      this.painting = { last: null, erase: brush === 'trash' || (!!here && here.role === brush.role && here.color === brush.color) };
      this.paint(key);
      this.painting = null;
      this.saySquare();
      return;
    }
    const before = this.cg.state.selected;
    this.cg.selectSquare(key);
    const now = this.cg.state.selected;
    if (now && now !== before) {
      const piece = this.cg.state.pieces.get(now);
      const n = this.cg.state.movable.dests?.get(now)?.length ?? 0;
      if (piece) this.say(`${piece.color} ${piece.role} ${now} picked${this.mode === 'analysis' ? `, ${n} move${n === 1 ? '' : 's'}` : ''}`);
    }
  }

  /** The cursor starts on the last move's square, else the king of the side to move. */
  private showCursor() {
    if (!this.cursor) {
      const turn = this.cg.state.turnColor;
      const king = [...this.cg.state.pieces].find(([, p]) => p.role === 'king' && p.color === turn)?.[0];
      this.cursor = this.cg.state.lastMove?.at(-1) ?? king ?? 'e1';
    }
    this.cursorShown = true;
    this.drawCursor();
  }

  private hideCursor() {
    this.cursorShown = false;
    this.drawCursor();
  }

  private drawCursor() {
    const el = this.cursorEl;
    el.hidden = !this.cursorShown || !this.cursor;
    if (el.hidden) return;
    const file = this.cursor!.charCodeAt(0) - 97;
    const rank = Number(this.cursor![1]) - 1;
    const white = this.cg.state.orientation === 'white';
    el.dataset.square = this.cursor!;
    el.style.left = `${(white ? file : 7 - file) * 12.5}%`;
    el.style.top = `${(white ? 7 - rank : rank) * 12.5}%`;
  }

  private saySquare() {
    const key = this.cursor;
    if (!key) return;
    const piece = this.cg.state.pieces.get(key);
    this.say(piece ? `${key}, ${piece.color} ${piece.role}` : `${key}, empty`);
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
    });
    this.markPromoted(new Map(view.dropSquares.map((sq) => [sq, 'move-dest'])));
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
    });
    this.markPromoted();
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
    this.wrap.style.removeProperty('--ch-cursor');
    if (brush === 'trash') this.wrap.style.setProperty('--ch-cursor', TRASH_CURSOR);
    else if (brush !== 'pointer')
      void pieceCursor(brush).then((cursor) => {
        if (cursor && this.brush === brush) this.wrap.style.setProperty('--ch-cursor', cursor);
      });
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

  /**
   * Marks promoted pieces, which go back to the partner as pawns when taken. Chessground keeps
   * the flag (a ~ in the FEN) but draws nothing for it.
   */
  private markPromoted(custom = new Map<Key, string>()) {
    for (const [key, piece] of this.cg.state.pieces)
      if (piece.promoted) custom.set(key, `${custom.get(key) ?? ''} ch-promoted`.trim());
    this.cg.set({ highlight: { custom } });
  }

  /** Shift-click in the editor marks a queen, rook, bishop or knight promoted, or not. */
  private togglePromoted(e: MouseEvent | TouchEvent): boolean {
    if (!this.options.promotedPieces || this.mode !== 'editor' || !(e instanceof MouseEvent) || !e.shiftKey || e.button !== 0) return false;
    const key = this.keyAt(e);
    const here = key && this.cg.state.pieces.get(key);
    if (!key || !here || here.role === 'king' || here.role === 'pawn') return false;
    e.preventDefault();
    e.stopPropagation();
    this.cg.setPieces(new Map([[key, { ...here, promoted: !here.promoted }]]));
    this.markPromoted();
    this.hooks.edited();
    return true;
  }

  private pressed(e: MouseEvent | TouchEvent) {
    if (this.togglePromoted(e)) return;
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
    this.markPromoted();
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
      // From the keyboard the picker takes the focus, and gives it back to the board.
      const byKey = document.activeElement === this.el;
      const done = (role: Role | null) => { this.closePromotion(); if (byKey) this.el.focus({ preventScroll: true }); resolve(role); };
      overlay.addEventListener('keydown', (e) => { if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); done(null); } });
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
      if (byKey) overlay.querySelector<HTMLElement>('button')?.focus({ preventScroll: true });
    });
  }

  private closePromotion() {
    this.promotion?.remove();
    this.promotion = null;
  }
}

const POINTER_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 11V6a2 2 0 0 0-4 0v0M14 10V4a2 2 0 0 0-4 0v2M10 10.5V6a2 2 0 0 0-4 0v8"/><path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/></svg>';
const TRASH_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>';
