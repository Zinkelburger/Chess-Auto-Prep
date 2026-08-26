/**
 * Static board rendering from a FEN — no interaction, no dependencies.
 *
 * Used for the FEN filter preview and ECO picker on the alerts page, and for
 * the hover preview of solution moves in the tactics trainer. Pieces are the
 * cburnett SVGs in /public/piece so the two boards on the site look alike.
 */

const PIECE_URLS: Record<string, string> = {
  K: '/piece/wK.svg', Q: '/piece/wQ.svg', R: '/piece/wR.svg',
  B: '/piece/wB.svg', N: '/piece/wN.svg', P: '/piece/wP.svg',
  k: '/piece/bK.svg', q: '/piece/bQ.svg', r: '/piece/bR.svg',
  b: '/piece/bB.svg', n: '/piece/bN.svg', p: '/piece/bP.svg',
};

export type BoardCell = string | null;

/** Parse the placement field of a FEN into 64 cells (a8 … h1), or an error. */
export function parsePlacement(fen: string): { cells: BoardCell[] } | { error: string } {
  const placement = fen.trim().split(/\s+/)[0] ?? '';
  const ranks = placement.split('/');
  if (ranks.length !== 8) return { error: 'Invalid FEN — need 8 ranks separated by /' };
  const cells: BoardCell[] = [];
  for (let r = 0; r < 8; r++) {
    let file = 0;
    for (const ch of ranks[r]) {
      if (ch >= '1' && ch <= '8') {
        const n = Number(ch);
        for (let i = 0; i < n; i++) cells.push(null);
        file += n;
      } else if (PIECE_URLS[ch]) {
        cells.push(ch);
        file++;
      } else {
        return { error: `Invalid FEN — unexpected character “${ch}”` };
      }
      if (file > 8) break;
    }
    if (file !== 8) return { error: `Invalid FEN — rank ${8 - r} has ${file} squares (need 8)` };
  }
  return { cells };
}

export interface RenderOptions {
  /** Orientation; black puts h1 top-left. */
  flipped?: boolean;
  /** Squares to tint (e.g. the last move). Algebraic, like "e4". */
  highlight?: string[];
}

/**
 * Render [fen] into [el] as an 8×8 grid. Returns null on success or the
 * validation message on failure (the element is emptied either way).
 */
export function renderBoard(fen: string, el: HTMLElement, opts: RenderOptions = {}): string | null {
  const parsed = parsePlacement(fen);
  el.replaceChildren();
  if ('error' in parsed) return parsed.error;
  const highlight = new Set(opts.highlight ?? []);
  const frag = document.createDocumentFragment();
  for (let i = 0; i < 64; i++) {
    const idx = opts.flipped ? 63 - i : i;
    const rank = Math.floor(idx / 8);
    const file = idx % 8;
    const sq = document.createElement('div');
    const alg = 'abcdefgh'[file] + String(8 - rank);
    sq.className = `board-sq ${(rank + file) % 2 === 0 ? 'light' : 'dark'}`;
    if (highlight.has(alg)) sq.classList.add('hl');
    const piece = parsed.cells[idx];
    if (piece) {
      const img = document.createElement('img');
      img.src = PIECE_URLS[piece];
      img.alt = '';
      img.draggable = false;
      img.loading = 'lazy';
      sq.appendChild(img);
    }
    frag.appendChild(sq);
  }
  el.appendChild(frag);
  return null;
}

/**
 * Wire a FEN input to a preview element and an error line: the board shows
 * while the FEN is valid, the message while it is not, nothing while empty.
 */
export function bindFenPreview(input: HTMLInputElement, board: HTMLElement, error: HTMLElement): void {
  const update = () => {
    const fen = input.value.trim();
    if (!fen) {
      board.hidden = true;
      error.hidden = true;
      return;
    }
    const msg = renderBoard(fen, board);
    board.hidden = msg !== null;
    error.hidden = msg === null;
    error.textContent = msg ?? '';
  };
  input.addEventListener('input', update);
  update();
}

/**
 * A single floating board that follows the pointer near whichever element is
 * being hovered. One per page; call [show] on pointerenter and [hide] on
 * pointerleave. Positioned so it never leaves the viewport.
 *
 * `pointerleave` alone is not enough to take a preview down. The hovered
 * element can be *destroyed* while the pointer is still over it — a new
 * puzzle re-renders the move list, an alert list reloads — and a removed node
 * never fires it, leaving a board from the previous puzzle pinned over
 * unrelated content. So the preview does not trust its caller: while it is
 * up, it re-checks every frame that its anchor is still a real, visible
 * element and takes itself down when it isn't.
 */
export class HoverBoard {
  private readonly el: HTMLElement;
  private readonly board: HTMLElement;
  private readonly caption: HTMLElement;

  /** The element the preview is pinned to; null whenever it is hidden. */
  private anchor: Element | null = null;
  private frame = 0;

  constructor() {
    this.el = document.createElement('div');
    this.el.className = 'hover-board';
    this.el.hidden = true;
    this.el.setAttribute('aria-hidden', 'true');
    this.board = document.createElement('div');
    this.board.className = 'board-preview board-preview-sm';
    this.caption = document.createElement('div');
    this.caption.className = 'hover-board-caption mono';
    this.el.append(this.board, this.caption);
    document.body.appendChild(this.el);

    // A pointer that leaves via a route the anchor cannot see — tabbing away,
    // a resize reflow, the window losing focus — must not strand the preview.
    const hide = () => this.hide();
    window.addEventListener('resize', hide, { passive: true });
    window.addEventListener('blur', hide);
    document.addEventListener('visibilitychange', hide);
  }

  show(anchor: Element, fen: string, opts: RenderOptions & { caption?: string } = {}): void {
    // Nothing sensible to pin to: refuse rather than place a floating board
    // at whatever coordinates a detached node reports (0, 0).
    if (!anchor.isConnected) {
      this.hide();
      return;
    }
    if (renderBoard(fen, this.board, opts) !== null) return;
    this.caption.textContent = opts.caption ?? '';
    this.caption.hidden = !opts.caption;
    this.anchor = anchor;
    this.el.hidden = false;
    this.place(anchor.getBoundingClientRect());
    this.watch();
  }

  hide(): void {
    cancelAnimationFrame(this.frame);
    this.frame = 0;
    this.anchor = null;
    this.el.hidden = true;
  }

  /** Sit above the anchor, or below it when there is no room, never off-screen. */
  private place(a: DOMRect): void {
    const w = this.el.offsetWidth;
    const h = this.el.offsetHeight;
    const margin = 8;
    let left = a.left + a.width / 2 - w / 2;
    left = Math.max(margin, Math.min(left, window.innerWidth - w - margin));
    let top = a.top - h - margin;
    if (top < margin) top = a.bottom + margin;
    this.el.style.left = `${Math.round(left)}px`;
    this.el.style.top = `${Math.round(top)}px`;
  }

  /**
   * Runs only while a preview is up: one rect read per frame, which both
   * follows the anchor (scrolling, reflow) and catches the anchor being
   * removed or hidden underneath us.
   */
  private watch(): void {
    cancelAnimationFrame(this.frame);
    this.frame = requestAnimationFrame(() => {
      const a = this.anchor;
      if (!a || !a.isConnected) return this.hide();
      const r = a.getBoundingClientRect();
      // Zero-sized means an ancestor went `display:none` or `[hidden]`.
      if (r.width === 0 && r.height === 0) return this.hide();
      this.place(r);
      this.watch();
    });
  }
}
