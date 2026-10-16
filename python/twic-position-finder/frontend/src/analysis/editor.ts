/**
 * The bughouse board editor: lichess.org/editor on its own page,
 * /bughouse/editor/?fen=…, with a + and − on every piece in both hands.
 * As on lila, the URL follows every edit, so a reload, Back and a copied
 * link all show this position, and "Analysis board" is a plain link to
 * /bughouse/?fen=…. Nothing else is kept: the URL is the editor's memory.
 *
 * The move counters are lila's too: the halfmove clock and move number come
 * from the FEN the editor opened (the analysis passes its current position,
 * so an editor opened at move 6 is at move 6), and only Starting position,
 * Clear board or a new FEN set them again. An en passant square is kept
 * while the board still allows it and dropped when the side to move changes.
 */
import type { Piece } from '@lichess-org/chessground/types';
import { makePockets } from 'chessops/fen';
import { Material } from 'chessops/setup';
import type { Color, Role } from 'chessops/types';
import { CrazyBoard, type Brush } from './board';
import { renderHand } from './hand';
import { analysisUrl, editorUrl, linkedOrientation } from './links';
import { HAND_ROLES, START_FEN, enPassantSquares, fenOf, readFen } from './tree';

const LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };
const SPARE_ROLES: Role[] = ['king', 'queen', 'rook', 'bishop', 'knight', 'pawn'];
const HAND_LETTER: Record<string, Role> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen' };
const EMPTY_BOARD = '8/8/8/8/8/8/8/8';

interface Castling { K: boolean; Q: boolean; k: boolean; q: boolean }

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;

export class BughouseEditor {
  private orientation: Color;
  private turn: Color = 'white';
  private castling: Castling = { K: true, Q: true, k: true, q: true };
  private hands = Material.empty();
  private enPassant = '-';
  private halfmoves = 0;
  private fullmoves = 1;
  private brush: Brush = 'pointer';
  private readonly board: CrazyBoard;

  constructor() {
    const params = new URLSearchParams(location.search);
    this.orientation = linkedOrientation(params) ?? 'white';
    const ignore = () => { /* The editor has no moves. */ };
    this.board = new CrazyBoard($('ch-board-wrap'), $('ch-board'), {
      move: ignore, drop: ignore, clickSquare: ignore, wheel: ignore,
      edited: () => this.changed(),
    });
    this.board.showEditor(START_FEN.split('[')[0], this.orientation, this.brush);
    const fen = params.get('fen');
    const error = fen ? this.setFen(fen) : null;
    if (error || !fen) this.setFen(START_FEN);
    if (error) this.fenError(`Could not open the linked position: ${error}`);
    this.bind();
    this.renderSpares();
  }

  /** The position as set, including ones the analysis board would refuse. */
  private fen(): string {
    const c = this.castling;
    const castling = `${c.K ? 'K' : ''}${c.Q ? 'Q' : ''}${c.k ? 'k' : ''}${c.q ? 'q' : ''}` || '-';
    const board = this.board.boardFen();
    const ep = (enPassantSquares(board, this.turn) as string[]).includes(this.enPassant) ? this.enPassant : '-';
    return `${board}[${makePockets(this.hands)}] ${this.turn === 'white' ? 'w' : 'b'} ${castling} ${ep} ${this.halfmoves} ${this.fullmoves}`;
  }

  private pieceCount(): number {
    return this.board.cg.state.pieces.size + this.hands.size();
  }

  /** Loads a FEN; the error when it is not one. */
  private setFen(text: string): string | null {
    const setupFen = text.trim();
    const read = readFen(setupFen);
    // Only the FEN itself must parse: the editor is where an impossible position gets fixed.
    const parts = setupFen.split(/\s+/);
    if (!read.ok && !/^[1-8pnbrqkPNBRQK~/]+(\[[pnbrqPNBRQ]*\])?$/.test(parts[0] ?? '')) return 'That is not a FEN.';
    this.hands = Material.empty();
    for (const ch of /\[([^\]]*)\]/.exec(parts[0])?.[1] ?? '') {
      const role = HAND_LETTER[ch.toLowerCase()];
      if (role) this.hands[ch === ch.toUpperCase() ? 'white' : 'black'][role]++;
    }
    this.turn = parts[1] === 'b' ? 'black' : 'white';
    const castling = parts[2] ?? '-';
    this.castling = { K: castling.includes('K'), Q: castling.includes('Q'), k: castling.includes('k'), q: castling.includes('q') };
    this.enPassant = /^[a-h][36]$/.test(parts[3] ?? '') ? parts[3] : '-';
    this.halfmoves = Math.max(0, Math.floor(Number(parts[4])) || 0);
    this.fullmoves = Math.max(1, Math.floor(Number(parts[5])) || 1);
    this.board.cg.set({ fen: parts[0].replace(/\[.*$/, '') });
    this.changed();
    return null;
  }

  private changed() {
    this.renderHands();
    this.renderPanel();
    this.renderUnder();
    history.replaceState(null, '', editorUrl(this.fen(), this.orientation));
    $<HTMLInputElement>('ch-url').value = location.href;
  }

  // ── Board tools ─────────────────────────────────────────────────
  private flip() {
    this.orientation = this.orientation === 'white' ? 'black' : 'white';
    this.board.cg.set({ orientation: this.orientation });
    this.renderSpares();
    this.changed();
  }

  /** lila's Clear board: an empty board at move 1, the side to move kept. */
  private clear() {
    this.board.cg.set({ fen: EMPTY_BOARD });
    this.hands = Material.empty();
    this.castling = { K: false, Q: false, k: false, q: false };
    this.enPassant = '-';
    this.halfmoves = 0;
    this.fullmoves = 1;
    this.changed();
  }

  private setBrush(brush: Brush) {
    this.brush = brush;
    this.board.setBrush(brush);
    this.renderSpares();
  }

  private adjust(color: Color, role: Role, delta: 1 | -1) {
    const next = this.hands[color][role] + delta;
    if (next < 0 || next > 16) return;
    if (delta > 0 && this.pieceCount() >= 64) return;
    this.hands[color][role] = next;
    this.changed();
  }

  // ── Rendering ───────────────────────────────────────────────────
  private renderHands() {
    const top: Color = this.orientation === 'white' ? 'black' : 'white';
    const total = this.pieceCount();
    for (const [boxId, color] of [['ch-hand-top', top], ['ch-hand-bottom', this.orientation]] as const) {
      const material = this.hands[color];
      const counts = Object.fromEntries(HAND_ROLES.map((r) => [r, material[r]])) as Record<Role, number>;
      renderHand($(boxId), { color, counts, roomForMore: total < 64, picked: null, usable: () => false }, {
        adjust: (c, role, delta) => this.adjust(c, role, delta),
        drag: (c, role, e) => this.board.dragNew({ role, color: c }, e),
        pick: () => { /* Hand pieces are dragged onto the board, not picked. */ },
      });
    }
  }

  /** lila's spare pieces above and below the board: pointer, six pieces, bin. */
  private renderSpares() {
    const top: Color = this.orientation === 'white' ? 'black' : 'white';
    for (const [id, color] of [['ch-spare-top', top], ['ch-spare-bottom', this.orientation]] as const) {
      const items: HTMLElement[] = [];
      const tool = (name: 'pointer' | 'trash', label: string, svg: string) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = `ch-spare-tool ch-${name}`;
        b.title = label;
        b.setAttribute('aria-label', label);
        b.setAttribute('aria-pressed', String(this.brush === name));
        b.innerHTML = svg;
        b.onclick = () => this.setBrush(name);
        return b;
      };
      items.push(tool('pointer', 'Move pieces: drag one off the board to remove it', POINTER_SVG));
      for (const role of SPARE_ROLES) {
        const piece: Piece = { role, color };
        const b = document.createElement('button');
        b.type = 'button';
        b.className = 'ch-spare-piece';
        const brush = this.brush;
        const selected = typeof brush !== 'string' && brush.role === role && brush.color === color;
        b.setAttribute('aria-pressed', String(selected));
        const name = `${color} ${role}`;
        b.title = `Place ${name}s: click or drag across squares`;
        b.setAttribute('aria-label', `Place ${name}s`);
        const img = document.createElement('img');
        img.src = `/piece/${color === 'white' ? 'w' : 'b'}${LETTER[role]}.svg`;
        img.alt = '';
        img.draggable = false;
        b.append(img);
        const press = (e: MouseEvent | TouchEvent) => {
          if (e instanceof MouseEvent && e.button !== 0) return;
          e.preventDefault();
          this.setBrush(piece);
          this.board.dragNew({ ...piece }, e, true);
        };
        b.addEventListener('mousedown', press);
        b.addEventListener('touchstart', press, { passive: false });
        b.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); this.setBrush(piece); } };
        items.push(b);
      }
      items.push(tool('trash', 'Remove pieces: click or drag across squares', TRASH_SVG));
      $(id).replaceChildren(...items);
    }
  }

  private renderPanel() {
    for (const b of document.querySelectorAll<HTMLButtonElement>('#ch-turn button'))
      b.setAttribute('aria-checked', String(b.dataset.turn === this.turn));
    for (const box of document.querySelectorAll<HTMLInputElement>('#ch-castling input'))
      box.checked = this.castling[box.dataset.right as keyof Castling];
    const read = readFen(this.fen());
    $('ch-editor-error').textContent = read.ok ? '' : read.error;
    const analyse = $<HTMLAnchorElement>('ch-editor-analyse');
    if (read.ok) {
      analyse.href = analysisUrl(fenOf(read.pos), this.orientation);
      analyse.removeAttribute('aria-disabled');
    } else {
      analyse.removeAttribute('href');
      analyse.setAttribute('aria-disabled', 'true');
    }
  }

  private renderUnder() {
    const fen = $<HTMLInputElement>('ch-fen');
    if (document.activeElement !== fen) fen.value = this.fen();
  }

  private fenError(error: string | null) {
    const input = $<HTMLInputElement>('ch-fen');
    if (error) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
    $('ch-fen-error').textContent = error ?? '';
  }

  private copy(id: string, value: string) {
    const button = $(id);
    void navigator.clipboard?.writeText(value).then(() => {
      button.textContent = 'Copied';
      setTimeout(() => { button.textContent = 'Copy'; }, 1200);
    });
  }

  // ── Wiring ──────────────────────────────────────────────────────
  private bind() {
    for (const b of document.querySelectorAll<HTMLButtonElement>('#ch-turn button'))
      b.onclick = () => { this.turn = b.dataset.turn as Color; this.enPassant = '-'; this.changed(); };
    for (const box of document.querySelectorAll<HTMLInputElement>('#ch-castling input'))
      box.onchange = () => { this.castling[box.dataset.right as keyof Castling] = box.checked; this.changed(); };
    $('ch-editor-start').onclick = () => { this.setFen(START_FEN); this.fenError(null); };
    $('ch-editor-clear').onclick = () => this.clear();
    $('ch-editor-flip').onclick = () => this.flip();

    const fen = $<HTMLInputElement>('ch-fen');
    const load = () => this.fenError(this.setFen(fen.value));
    fen.onchange = load;
    fen.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); load(); } };
    fen.onblur = () => { if (!fen.getAttribute('aria-invalid')) this.renderUnder(); };
    $('ch-fen-copy').onclick = () => this.copy('ch-fen-copy', this.fen());
    $('ch-url-copy').onclick = () => this.copy('ch-url-copy', location.href);

    document.addEventListener('keydown', (e) => {
      const target = e.target as HTMLElement;
      if (target.closest('input, textarea, [contenteditable], dialog') || e.ctrlKey || e.metaKey || e.altKey) return;
      if (e.key === 'f') this.flip();
      else if (e.key === 'a') { const href = $<HTMLAnchorElement>('ch-editor-analyse').href; if (href) location.assign(href); }
      else if (e.key === 'Escape' && this.brush !== 'pointer') this.setBrush('pointer');
      else return;
      e.preventDefault();
    });
  }
}

const POINTER_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 11V6a2 2 0 0 0-4 0v0M14 10V4a2 2 0 0 0-4 0v2M10 10.5V6a2 2 0 0 0-4 0v8"/><path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/></svg>';
const TRASH_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>';
