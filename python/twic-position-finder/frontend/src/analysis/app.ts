/**
 * Bughouse analysis: lichess.org/analysis/crazyhouse's board with a + above
 * and − below every piece in both hands and lila's board editor, searched by
 * HypeBeast. A captured piece leaves the board for the partner's hand, as in
 * bughouse. With one board (the default), what a partner sends you add
 * yourself. With two, the partner board stands beside it and a capture lands
 * in the partner's hand there; clicking it makes it the board you work on.
 * Each board keeps its own moves, as on the desktop app.
 *
 * HypeBeast always gets both boards. With two it searches the shown board
 * knowing the other one; while it does, it measures what one more piece is
 * worth across, and the partner panel (partner.ts) shows that without a
 * search of its own. Once the shown board is done, the engine searches the
 * partner board, then measures piece values on the shown board deeper.
 *
 * This file wires the parts together: the trees and the current positions,
 * the engine, the boards, the move list (moves.ts), the engine panel
 * (ceval.ts), practice (practice.ts), the ☰ menu (menu.ts) and the editor.
 */
import type { DrawShape } from '@lichess-org/chessground/draw';
import type { Key } from '@lichess-org/chessground/types';
import { Material } from 'chessops/setup';
import type { Color, Role, SquareName } from 'chessops/types';
import { CrazyBoard, ROLE_LETTER, type Brush } from './board';
import { CevalView, formatEval } from './ceval';
import { boardScore, Engine, seatKey, type EngineResult, type EngineStatus, type HandRole, type PieceValues, type SearchSettings, type Seat } from './engine';
import { renderHand } from './hand';
import { liveGlyph, type Glyph } from './judge';
import { openHelp, renderMenu } from './menu';
import { MoveList, el } from './moves';
import { PRACTICE_NODES, Practice } from './practice';
import { GearPanel } from './gear';
import { loadSettings, maxThreads, recommendedThreads, saveSettings, threadsFor, valuesSecondsFor, type Settings, type Toggle } from './settings';
import { PartnerPanel } from './partner';
import { Chessground } from '@lichess-org/chessground';
import type { Api as CgApi } from '@lichess-org/chessground/api';
import { engineShapes, glyphShape, moveShapes, threatShapes, variationShapes } from './shapes';
import {
  HAND_ROLES, START_FEN, Tree, boardDests, capturedBy, castlingPossible, dropSquares, enPassantOptions, fenOf, handEdit, lichessFen, outcomeOf, playLine,
  positionOf, readFen, readMove, sanLine, threatFen, type CastlingRight, type SavedTree, type TreeNode,
} from './tree';
import { makeUci } from 'chessops/util';
import { draftOf, fenOfDraft, readDraftFen, type Draft } from './editor-draft';
import { BOARDS_KEY, TREE_KEY, keepBoards, linkBoards, loadSaved, openBoard, type BoardState, type SavedBoards } from './saved-boards';

const HELP_NOTES = [
  'In the board editor, F flips the board, right-click with a piece in hand takes the other colour, and Shift-click marks a piece promoted (a dot in its top-left corner): taken, it goes back as a pawn.',
];

const BOARD_NAMES = ['board 1', 'board 2'] as const;

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;

function squaresOf(uci: string): Key[] {
  return (uci.includes('@') ? [uci.slice(2, 4)] : [uci.slice(0, 2), uci.slice(2, 4)]) as Key[];
}

/** A tree move as the arrow Lichess draws: castling to the king's square, not the rook's. */
function arrowUci(node: TreeNode): string {
  if (!node.san.startsWith('O-O')) return node.uci;
  return node.uci.slice(0, 2) + (node.san.startsWith('O-O-O') ? 'c' : 'g') + node.uci[1];
}

const opposite = (c: Color): Color => (c === 'white' ? 'black' : 'white');

export class BughouseApp {
  private boards: [BoardState, BoardState];
  /** The board shown large and worked on: 0 for board 1, 1 for board 2. */
  private active: 0 | 1 = 0;
  /** Board 1's orientation; board 2 faces the other way, as partners sit. */
  private teamOrientation: Color = 'white';
  private mode: 'analysis' | 'editor' = 'analysis';
  private dropping: Role | null = null;
  private settings: Settings;
  /** Engine reports by seatKey: both boards' positions and the board searched. */
  private evals = new Map<string, EngineResult>();
  /** Piece values by seatKey of the board they are for, the deepest kept. */
  private values = new Map<string, PieceValues>();
  /** The piece-value measure running or queued, by seatKey. */
  private measuring = new Set<string>();
  private partnerCg: CgApi | null = null;
  private engineStatus: EngineStatus = { kind: 'off' };
  private readonly engine: Engine;
  private readonly board: CrazyBoard;
  private readonly moves: MoveList<TreeNode>;
  private readonly ceval: CevalView;
  private draft: Draft | null = null;
  private pgnDirty = false;
  private threat = false;
  private practice: Practice | null = null;
  private forkIndex = 0;
  private hoverUci: string | null = null;
  /** Engine lines draw their hovered move pale, like the engine's own arrow; the sit panel draws it solid. */
  private hoverBrush = 'paleBlue';
  private menuOpen = false;
  private autoplay: { delay: number; timer: number } | null = null;
  private stepping = false;
  private saveTimer = 0;
  private editorSearchTimer = 0;
  private toastTimer = 0;
  private lastDepth = new Map<string, number>();
  private readonly partner: PartnerPanel;
  private gear!: GearPanel;

  private get tree(): Tree { return this.boards[this.active].tree; }
  private set tree(tree: Tree) { this.boards[this.active].tree = tree; }
  private get current(): TreeNode { return this.boards[this.active].current; }
  private set current(node: TreeNode) { this.boards[this.active].current = node; }
  private get orientation(): Color { return this.active === 0 ? this.teamOrientation : opposite(this.teamOrientation); }
  private set orientation(color: Color) { this.teamOrientation = this.active === 0 ? color : opposite(color); }
  private get twoBoards(): boolean { return this.settings.boards === 2; }
  private get engineStopped(): boolean { return this.engineStatus.kind === 'failed' || this.engineStatus.kind === 'ask'; }
  /** The board not shown large. */
  private get other(): BoardState { return this.boards[this.active === 0 ? 1 : 0]; }

  constructor() {
    this.settings = loadSettings();
    // HypeBeast decides within a time: an ∞ kept from the old engine searches the default 10 s.
    if (!this.settings.searchSeconds) this.settings.searchSeconds = 10;
    const params = new URLSearchParams(location.search);
    const fen = params.get('fen'), fen2 = params.get('fen2');
    if (fen2) this.settings.boards = 2;
    // A plain /bughouse comes back to the saved analysis; a linked position opens it unless it is the saved one.
    const saved = loadSaved<SavedBoards>(BOARDS_KEY);
    const flash = (text: string) => this.flash(text);
    this.boards = [
      openBoard(saved?.boards[0] ?? loadSaved<SavedTree>(TREE_KEY), fen, flash),
      openBoard(saved?.boards[1], fen2, flash),
    ];
    if (this.twoBoards && saved?.active === 1 && !fen) this.active = 1;
    if (!this.twoBoards && positionOf(this.boards[0].tree.root.fen).turn === 'black') this.teamOrientation = 'black';

    const onStatus = (status: EngineStatus) => { this.engineStatus = status; this.renderCeval(); this.renderGear(); this.partner?.update(); };
    const onResult = (result: EngineResult) => this.engineResult(result);
    const onValues = (key: string, values: PieceValues) => this.valuesResult(key, values);
    this.engine = new Engine(onStatus, onResult, onValues);
    this.engine.configure(threadsFor(this.settings));
    this.board = new CrazyBoard($('ch-board-wrap'), $('ch-board'), {
      move: (orig, dest) => void this.boardMove(orig, dest),
      drop: (role, key) => this.play(`${ROLE_LETTER[role]}@${key}`, 'user'),
      clickSquare: (key) => this.clickSquare(key),
      wheel: (forward) => forward ? this.next() : this.prev(),
      edited: () => this.draftChanged(),
      swapBrushColor: () => {
        const brush = this.draft?.brush;
        if (brush && typeof brush !== 'string') this.setBrush({ role: brush.role, color: brush.color === 'white' ? 'black' : 'white' });
      },
    }, { promotedPieces: true });

    // The host's getters read the app's current fields; a getter cannot be an arrow.
    // oxlint-disable-next-line typescript/no-this-alias
    const app = this;
    this.moves = new MoveList($('ch-moves'), $('ch-fork'), {
      get tree() { return app.tree; },
      get current() { return app.current; },
      get settings() { return app.settings; },
      get forkIndex() { return app.forkIndex; },
      glyph: (node) => this.glyph(node),
      goTo: (node) => this.goTo(node),
      treeChanged: () => { this.treeChanged(); this.renderMoves(); this.renderShapes(); },
      deleted: (parent, hadCurrent) => {
        this.treeChanged();
        if (hadCurrent) this.goTo(parent); else { this.renderMoves(); this.renderShapes(); }
      },
      copied: (text) => void navigator.clipboard?.writeText(text).then(() => this.toast('PGN copied'), () => this.toast('Copying was blocked by the browser')),
      intro: () => {
        const edit = handEdit(app.tree.loadedFen, app.tree.root.fen);
        return edit ? el('div', 'ch-root-edit', `Hands edited at the start: ${edit}`) : null;
      },
      chip: (node) => {
        const edit = handEdit(app.tree.expectedFen(node.id), node.fen);
        if (!edit) return null;
        const chip = el('span', 'ch-edit', edit);
        chip.title = 'Hands edited after this move';
        return chip;
      },
    });
    this.ceval = new CevalView({
      header: $('ch-ceval'), pearl: $('ch-pearl'), name: $('ch-engine-name'), info: $('ch-engine-info'), bar: $('ch-bar'),
      threat: $<HTMLButtonElement>('ch-threat'), pvs: $('ch-pvs'), board: $('ch-pv-board'), switch: $<HTMLInputElement>('ch-engine-on'),
      action: $<HTMLButtonElement>('ch-engine-action'), live: $('ch-eval-live'),
    }, {
      hover: (uci) => this.hover(uci, 'paleBlue'),
      play: (pv, upTo) => { if (this.mode === 'analysis') this.playLine(pv, upTo); },
      start: () => this.startEngine(),
    }, { engineName: 'HypeBeast', playLine, hands: (fen) => positionOf(fen).pockets });
    this.partner = new PartnerPanel({
      get active() { return app.mode === 'analysis' && !app.practice && app.settings.engineOn && !outcomeOf(app.current.fen); },
      get engineStopped() { return app.engineStopped; },
      get twoBoards() { return app.twoBoards; },
      get boardName() { return BOARD_NAMES[app.active]; },
      get partnerName() { return BOARD_NAMES[app.active === 0 ? 1 : 0]; },
      get turn() { return positionOf(app.current.fen).turn; },
      values: () => this.values.get(seatKey(this.seatFor(this.current.fen))),
      measuring: () => !this.engineStopped && (this.measuring.has(seatKey(this.seatFor(this.current.fen))) || !this.evalOf(this.current.fen)?.done),
      result: () => this.evalOf(this.current.fen),
      partnerSan: (uci) => sanLine(this.other.current.fen, [uci])[0] ?? uci,
      moveSan: (uci) => sanLine(this.current.fen, [uci])[0] ?? uci,
      give: (color: Color, role: HandRole) => this.adjust(color, role, 1),
    }, $('bs-partner'));

    this.bind();
    this.renderAll();
    this.analyse();
    this.updateUrl();
  }

  // ── Navigation and moves ─────────────────────────────────────────
  /** Shows a position. `browse` is the player moving through the tree (not a move or replay). */
  private goTo(node: TreeNode, browse = true) {
    const from = this.current;
    if (!this.stepping) this.stopAutoplay();
    this.moves.closeMenu();
    this.current = node;
    this.dropping = null;
    if (node !== from) { this.threat = false; this.forkIndex = 0; this.hoverUci = null; }
    this.renderAll();
    this.analyse();
    this.updateUrl();
    this.scheduleSave();
    this.practice?.jumped(browse, from, node);
  }

  private prev() { const p = this.tree.parent(this.current.id); if (p) this.goTo(p); }
  private next() { const c = this.current.children[this.forkIndex] ?? this.current.children[0]; if (c) this.goTo(c); }
  private first() { if (this.current !== this.tree.root) this.goTo(this.tree.root); }
  private last() { const end = this.tree.lineEnd(this.current.id); if (end !== this.current) this.goTo(end); }

  /** ↑/↓ choose among the moves already played from here, as Lichess's fork; otherwise first/last. */
  private forkStep(dir: 1 | -1): boolean {
    const n = this.current.children.length;
    if (n < 2) return false;
    this.forkIndex = (this.forkIndex + dir + n) % n;
    this.moves.render();
    this.renderShapes();
    return true;
  }

  private play(uci: string, by: 'user' | 'engine'): boolean {
    const node = this.playOn(this.current, uci);
    if (!node) { this.renderBoard(); return false; }
    if (by === 'user') this.practice?.userMoved();
    this.treeChanged();
    this.goTo(node, false);
    return true;
  }

  private async boardMove(orig: Key, dest: Key) {
    const pos = positionOf(this.current.fen);
    const piece = pos.board.get(squareIndex(orig));
    const rank = dest[1];
    if (piece?.role === 'pawn' && (rank === '1' || rank === '8')) {
      const role = await this.board.pickPromotion(dest, piece.color, this.orientation);
      if (!role) { this.renderBoard(); return; }
      this.play(orig + dest + (role === 'knight' ? 'n' : role[0]), 'user');
      return;
    }
    this.play(orig + dest, 'user');
  }

  private clickSquare(key: Key) {
    const role = this.dropping;
    if (!role) return;
    this.dropping = null;
    if (!this.play(`${ROLE_LETTER[role]}@${key}`, 'user')) this.renderAll();
  }

  private playBest() {
    const best = this.evalOf(this.current.fen)?.lines[0]?.pv[0];
    if (best) this.play(best, 'user');
  }

  /** Plays an engine line from the current position up to and including move `upTo`. */
  private playLine(pv: string[], upTo: number) {
    let node = this.current;
    for (const uci of pv.slice(0, upTo + 1)) {
      const next = this.playOn(node, uci);
      if (!next) break;
      node = next;
    }
    if (node !== this.current) { this.treeChanged(); this.goTo(node, false); }
  }

  /**
   * Plays a move after a node of the shown board. With two boards, a new
   * capture puts the piece in the partner's hand at the move the partner
   * board is at, as a hand edit there (stepping back here does not take it
   * back, as on the desktop app).
   */
  private playOn(parent: TreeNode, uci: string): TreeNode | null {
    const known = new Set(parent.children);
    const node = this.tree.play(parent.id, uci);
    if (!node || known.has(node) || !this.twoBoards) return node;
    const captured = capturedBy(parent.fen, node.uci);
    if (captured) {
      const other = this.other;
      if (other.tree.adjustHand(other.current.id, captured.color, captured.role, 1)) this.renderPartner();
    }
    return node;
  }

  private treeChanged() {
    this.renderPgn();
    this.scheduleSave();
  }

  // ── Replay mode ─────────────────────────────────────────────────
  private replay(delay: number | null) {
    this.stopAutoplay();
    if (delay === null) { this.renderActionMenu(); return; }
    if (!this.current.children.length) this.goTo(this.tree.root);
    this.closeActionMenu();
    const step = () => {
      const child = this.current.children[0];
      if (!child) { this.stopAutoplay(); return; }
      this.stepping = true;
      this.goTo(child, false);
      this.stepping = false;
      this.autoplay = { delay, timer: window.setTimeout(step, delay) };
    };
    this.autoplay = { delay, timer: window.setTimeout(step, delay) };
    this.renderControls();
  }

  private stopAutoplay() {
    if (!this.autoplay) return;
    clearTimeout(this.autoplay.timer);
    this.autoplay = null;
    this.renderControls();
    if (this.menuOpen) this.renderActionMenu();
  }

  // ── Hands ───────────────────────────────────────────────────────
  private adjust(color: Color, role: Role, delta: 1 | -1) {
    if (this.mode === 'editor') {
      const draft = this.draft!;
      const next = draft.hands[color][role] + delta;
      if (next < 0 || next > 16) return;
      if (delta > 0 && this.draftPieceCount() >= 64) return;
      draft.hands[color][role] = next;
      this.draftChanged();
      return;
    }
    if (!this.tree.adjustHand(this.current.id, color, role, delta)) return;
    this.dropping = null;
    this.treeChanged();
    this.renderAll();
    this.analyse();
    this.updateUrl();
    this.practice?.check();
  }

  private renderHands() {
    const top: Color = this.orientation === 'white' ? 'black' : 'white';
    const editing = this.mode === 'editor';
    const pos = editing ? null : positionOf(this.current.fen);
    const total = editing ? this.draftPieceCount() : pos!.board.occupied.size() + (pos!.pockets?.size() ?? 0);
    for (const [boxId, color] of [['ch-hand-top', top], ['ch-hand-bottom', this.orientation === 'white' ? 'white' : 'black']] as const) {
      const material = editing ? this.draft!.hands[color] : pos!.pockets![color];
      const counts = Object.fromEntries(HAND_ROLES.map((r) => [r, material[r]])) as Record<Role, number>;
      renderHand($(boxId), {
        color,
        counts,
        roomForMore: total < 64,
        picked: !editing && pos!.turn === color ? this.dropping : null,
        usable: (role) => !editing && pos!.turn === color && !outcomeOf(this.current.fen) && dropSquares(this.current.fen, role).length > 0,
      }, {
        adjust: (c, role, delta) => this.adjust(c, role, delta),
        drag: (c, role, e) => { this.dropping = null; this.board.dragNew({ role, color: c }, e); },
        pick: (role) => {
          this.board.cg.selectSquare(null);
          this.dropping = this.dropping === role ? null : role;
          this.renderBoard();
          this.renderHands();
        },
      });
    }
  }

  // ── Board ───────────────────────────────────────────────────────
  private renderBoard() {
    if (this.mode === 'editor') return;
    const node = this.current;
    const pos = positionOf(node.fen);
    const over = !!outcomeOf(node.fen);
    this.board.showAnalysis({
      fen: node.fen,
      orientation: this.orientation,
      turn: pos.turn,
      dests: over ? new Map() : boardDests(node.fen) as Map<Key, Key[]>,
      lastMove: node.uci ? squaresOf(node.uci) : [],
      check: pos.isCheck(),
      shapes: this.shapes(),
      dropping: this.dropping,
      dropSquares: this.dropping ? dropSquares(node.fen, this.dropping) as Key[] : [],
    });
  }

  /** Lichess's board shapes (autoShape.ts): practice hints, a hovered line, engine and threat arrows, the move's annotation, variations. */
  private shapes(): DrawShape[] {
    if (this.practice) return this.practice.shapes();
    const pos = positionOf(this.current.fen);
    const turn = pos.turn, other: Color = turn === 'white' ? 'black' : 'white';
    let shapes: DrawShape[] = [];
    const on = this.settings.engineOn && !outcomeOf(this.current.fen);
    if (on && this.hoverUci) shapes.push(...moveShapes(this.threat ? other : turn, this.hoverUci, this.hoverBrush));
    else if (on && this.settings.bestArrows) {
      const result = this.evalOf(this.current.fen);
      if (result) shapes.push(...engineShapes(turn, result.lines, this.settings.maneuverArrows));
    }
    if (on && this.threat) {
      const result = this.evalOf(threatFen(this.current.fen));
      if (result) shapes.push(...threatShapes(other, result.lines, this.settings.maneuverArrows));
    }
    const glyph = this.settings.glyphsOnBoard ? this.glyph(this.current) : undefined;
    if (glyph) shapes.push(glyphShape(this.current.uci, this.current.san, glyph));
    if (this.settings.variationArrows && this.current.children.length > 1)
      shapes = shapes.concat(variationShapes(turn, this.current.children.map(arrowUci), this.forkIndex, shapes));
    return shapes;
  }

  private hover(uci: string | null, brush: string) {
    if (uci === this.hoverUci && brush === this.hoverBrush) return;
    this.hoverUci = uci;
    this.hoverBrush = brush;
    this.renderShapes();
  }

  private renderShapes() {
    if (this.mode === 'analysis') this.board.setShapes(this.shapes());
  }

  private flip() {
    this.orientation = this.orientation === 'white' ? 'black' : 'white';
    if (this.mode === 'editor') {
      this.board.cg.set({ orientation: this.orientation });
      this.renderSpares();
      this.renderHands();
    } else this.renderAll();
  }

  // ── Engine ──────────────────────────────────────────────────────
  private analyse() {
    // Background work belongs to the positions it was asked for.
    this.engine.cancelBackground();
    this.measuring.clear();
    this.search();
    this.partner?.update();
    this.renderPartner();
  }

  /** Both boards for the engine, with `fen` on `board`; with one board shown, the other is out of play. */
  private seatFor(fen: string, board: 0 | 1 = this.active): Seat {
    if (!this.twoBoards) return { fens: [fen, START_FEN], board: 0, solo: true };
    const other = this.boards[board === 0 ? 1 : 0].current.fen;
    return { fens: board === 0 ? [fen, other] : [other, fen], board };
  }

  private evalOf(fen: string, board: 0 | 1 = this.active): EngineResult | undefined {
    return this.evals.get(seatKey(this.seatFor(fen, board)));
  }

  /** The position the engine looks at: the current move, or the editor's position while it is legal. */
  private enginePosition(): { fen: string; ply: number } | null {
    if (this.mode === 'analysis') return { fen: this.current.fen, ply: this.current.ply };
    const read = readFen(this.draftFen());
    if (!read.ok) return null;
    return { fen: fenOf(read.pos), ply: (read.pos.fullmoves - 1) * 2 + (read.pos.turn === 'black' ? 1 : 0) };
  }

  private search() {
    clearTimeout(this.editorSearchTimer);
    const at = this.enginePosition();
    if (!at || outcomeOf(at.fen)) { this.engine.stop(); this.renderCeval(); return; }
    if (this.practice) this.engine.analyse(this.seatFor(this.current.fen), { ...this.searchSettings(), multiPv: 1, nodes: PRACTICE_NODES });
    else if (!this.settings.engineOn) { this.engine.stop(); return; }
    else {
      const fen = this.threat ? threatFen(at.fen) : at.fen;
      // A position already searched to its limit is shown as it was, as Lichess keeps its evaluations;
      // the engine's time then goes to the partner board and the piece values.
      const kept = this.evalOf(fen);
      const search = this.searchSettings();
      if (kept?.complete && kept.budget >= search.searchMs && kept.lines.length >= Math.min(search.multiPv, 2)) { this.engine.stop(); this.background(); }
      else this.engine.analyse(this.seatFor(fen), search);
    }
    this.engine.load().catch(() => { /* Shown in the engine header. */ });
  }

  private searchSettings(): SearchSettings {
    return { multiPv: this.settings.multiPv, searchMs: (this.settings.searchSeconds || 10) * 1000 };
  }

  /**
   * Once the shown board is searched: with two boards, the partner board's
   * search (its own report, and this board's piece values from it), then a
   * deeper measure of piece values on this board.
   */
  private background() {
    if (this.practice || this.threat || this.mode !== 'analysis' || !this.settings.engineOn) return;
    const fen = this.current.fen;
    if (outcomeOf(fen)) return;
    this.engine.cancelBackground();
    this.measuring.clear();
    const here = this.seatFor(fen);
    if (this.twoBoards) {
      const partner = this.seatFor(this.other.current.fen, this.active === 0 ? 1 : 0);
      if (!outcomeOf(this.other.current.fen) && !this.evals.get(seatKey(partner))?.complete)
        void this.engine.search(partner, this.searchSettings().searchMs, 1);
    }
    const key = seatKey(here);
    if (this.values.get(key)?.source !== 'board') {
      this.measuring.add(key);
      void this.engine.values(here, valuesSecondsFor(this.settings) * 1000).then(() => {
        this.measuring.delete(key);
        this.partner.update();
      });
    }
    this.partner.update();
  }

  private valuesResult(key: string, values: PieceValues) {
    const kept = this.values.get(key);
    // A measure on the board itself beats one read across at the same depth.
    if (!kept || values.depth > kept.depth || (values.depth === kept.depth && values.source === 'board')) this.values.set(key, values);
    if (key === seatKey(this.seatFor(this.current.fen))) this.partner.update();
  }

  private engineResult(result: EngineResult) {
    const kept = this.evals.get(result.key);
    // A position searched again starts from depth 1: keep the deeper search until the new one reaches it.
    if (!kept || result.done || result.depth >= kept.depth || result.lines.length > kept.lines.length || kept.lines.length > this.settings.multiPv)
      this.evals.set(result.key, result);
    if (this.twoBoards && result.seat.board !== this.active) { this.renderPartner(); return; }
    const at = this.enginePosition();
    if (!at) return;
    const searched = this.threat ? threatFen(at.fen) : at.fen;
    if (result.key !== seatKey(this.seatFor(at.fen)) && result.key !== seatKey(this.seatFor(searched))) return;
    if (this.practice) { this.practice.check(); return; }
    this.renderCeval();
    this.renderShapes();
    if (result.done) { this.partner.update(); if (result.complete && result.fen === this.current.fen) this.background(); }
    // Live annotations change only with a new depth.
    if (this.settings.liveGlyphs && this.lastDepth.get(result.fen) !== result.depth) {
      this.lastDepth.set(result.fen, result.depth);
      this.renderMoves();
    }
  }

  /** Whether an engine move (e1g1) is the tree's move (chessops writes castling as e1h1). */
  private sameMove(fen: string, engineUci: string | undefined, node: TreeNode): boolean {
    if (!engineUci) return false;
    if (engineUci === node.uci) return true;
    if (!node.san.startsWith('O-O')) return false;
    const move = readMove(positionOf(fen), engineUci);
    return !!move && makeUci(move) === node.uci;
  }

  /** Lichess's live annotation: what the move lost against the engine's best before it. Not for a move whose hands were edited after it. */
  private glyph(node: TreeNode): Glyph | undefined {
    if (!this.settings.liveGlyphs || node.hand) return undefined;
    const parent = this.tree.parent(node.id);
    const before = parent && this.evalOf(parent.fen);
    if (!parent || !before) return undefined;
    const best = before.lines[0];
    if (!best || this.sameMove(parent.fen, best.pv[0], node)) return undefined;
    const after = before.lines.find((l) => this.sameMove(parent.fen, l.pv[0], node)) ?? this.evalOf(node.fen)?.lines[0];
    if (!after) return undefined;
    return liveGlyph(positionOf(parent.fen).turn, best, after);
  }

  private renderCeval() {
    const at = this.enginePosition();
    const fen = at ? (this.threat ? threatFen(at.fen) : at.fen) : '';
    this.ceval.render({
      enabled: this.settings.engineOn,
      fen,
      ply: at?.ply ?? 0,
      multiPv: this.settings.multiPv,
      infinite: false,
      searchMs: this.searchSettings().searchMs,
      result: at ? this.evalOf(fen) : undefined,
      status: this.engineStatus,
      threat: this.threat,
      inCheck: !!at && positionOf(at.fen).isCheck(),
      over: at && outcomeOf(at.fen),
      unplayable: at ? null : 'Waiting for a legal position',
      orientation: this.orientation,
      scoreKind: this.twoBoards ? 'team' : 'board',
    });
  }

  /** The engine panel's button: download the engine (phones ask first), or try again after a failure. */
  private startEngine() {
    if (this.engineStatus.kind === 'ask') this.engine.allow();
    else this.analyse();
  }

  private toggleEngine(on = !this.settings.engineOn) {
    if (this.practice) return;
    this.settings.engineOn = on;
    if (!on) this.threat = false;
    saveSettings(this.settings);
    this.renderCeval();
    this.renderShapes();
    this.analyse();
  }

  /** Lichess's "Show threat" (X): what the other side would play if it were its move. */
  private toggleThreat(on = !this.threat) {
    const at = this.enginePosition();
    if (on === this.threat || this.practice || !this.settings.engineOn || !at || positionOf(at.fen).isCheck() || outcomeOf(at.fen)) return;
    this.threat = on;
    this.hoverUci = null;
    this.renderCeval();
    this.renderShapes();
    this.analyse();
  }

  private toggleSetting(key: Toggle) {
    this.settings[key] = !this.settings[key];
    saveSettings(this.settings);
    this.renderMoves();
    this.renderShapes();
    if (this.menuOpen) this.renderActionMenu();
  }

  // ── Practice ────────────────────────────────────────────────────
  private togglePractice(on = !this.practice) {
    if (on === !!this.practice || this.mode === 'editor' || (on && this.twoBoards)) return;
    this.stopAutoplay();
    this.closeActionMenu();
    if (on) {
      this.threat = false;
      // The host's getters read the app's current fields; a getter cannot be an arrow.
      // oxlint-disable-next-line typescript/no-this-alias
      const app = this;
      this.practice = new Practice({
        get tree() { return app.tree; },
        get current() { return app.current; },
        evalOf: (fen) => this.evalOf(fen),
        playUci: (uci) => { this.play(uci, 'engine'); },
        goTo: (node) => this.goTo(node),
        changed: () => { this.renderPractice(); this.renderShapes(); },
        shapesChanged: () => this.renderShapes(),
        stop: () => this.togglePractice(false),
      }, this.orientation, $('ch-practice'));
    } else this.practice = null;
    this.renderAll();
    this.analyse();
    this.practice?.check();
  }

  private renderPractice() {
    const box = $('ch-practice');
    box.hidden = !this.practice;
    $('ch-analysis').classList.toggle('practising', !!this.practice);
    $('ch-practice-toggle').setAttribute('aria-pressed', String(!!this.practice));
    this.practice?.render();
  }

  // ── Move list ───────────────────────────────────────────────────
  private renderMoves() {
    if (this.mode === 'analysis') this.moves.render();
  }

  // ── Two boards ──────────────────────────────────────────────────
  /** One board or two: a setting, kept in this browser. With one, board 1 is shown and board 2 is out of play. */
  private toggleBoards(two = !this.twoBoards) {
    if (two === this.twoBoards || this.mode !== 'analysis') return;
    if (two && this.practice) this.togglePractice(false);
    this.settings.boards = two ? 2 : 1;
    saveSettings(this.settings);
    if (!two) this.active = 0;
    this.threat = false;
    this.hoverUci = null;
    this.renderAll();
    this.analyse();
    this.updateUrl();
    this.scheduleSave();
  }

  /** Works on the partner board instead: it becomes the large one. */
  private switchBoard() {
    if (!this.twoBoards || this.mode !== 'analysis') return;
    this.stopAutoplay();
    this.moves.closeMenu();
    this.active = this.active === 0 ? 1 : 0;
    this.dropping = null;
    this.threat = false;
    this.hoverUci = null;
    this.forkIndex = 0;
    this.pgnDirty = false;
    this.renderAll();
    this.analyse();
    this.scheduleSave();
  }

  /** The partner board beside the large one: its position, hands, and HypeBeast's word on it. */
  private renderPartner() {
    const box = $('ch-partner');
    box.hidden = !this.twoBoards;
    if (!this.twoBoards) return;
    const other = this.other.current;
    const pos = positionOf(other.fen);
    const orientation = opposite(this.orientation);
    const config = {
      fen: other.fen.split(' ')[0].replace(/\[.*\]$/, ''), orientation, turnColor: pos.turn,
      lastMove: other.uci ? squaresOf(other.uci) : undefined, check: pos.isCheck(),
    };
    if (!this.partnerCg)
      this.partnerCg = Chessground($('ch-partner-cg'), { ...config, viewOnly: true, coordinates: false, animation: { enabled: true, duration: 150 }, drawable: { enabled: false, visible: true } });
    else this.partnerCg.set(config);
    const result = this.evalOf(other.fen, this.active === 0 ? 1 : 0);
    const line = result?.lines[0];
    this.partnerCg.setAutoShapes(line?.pv[0] && this.settings.engineOn ? engineShapes(pos.turn, [line], false) : []);
    for (const [id, color] of [['ch-partner-hand-top', opposite(orientation)], ['ch-partner-hand-bottom', orientation]] as const)
      this.renderPocket($(id), color, pos.pockets![color]);
    $('ch-partner-name').textContent = `${BOARD_NAMES[this.active === 0 ? 1 : 0][0].toUpperCase()}${BOARD_NAMES[this.active === 0 ? 1 : 0].slice(1)} · ${pos.turn === 'white' ? 'White' : 'Black'} to play`;
    const evalBox = $('ch-partner-eval');
    const over = outcomeOf(other.fen);
    if (over) evalBox.textContent = over;
    else if (!this.settings.engineOn || !line) evalBox.textContent = '';
    else {
      const best = line.pv[0] ? sanLine(other.fen, [line.pv[0]])[0] : '';
      const board = line.mate === undefined ? boardScore(line) : undefined;
      evalBox.textContent = `Team ${formatEval(line)}${board === undefined ? '' : ` · board ${formatEval({ cp: board })}`}${best ? ` · ${best}` : ''}${result?.done ? '' : ' …'}`;
    }
  }

  /** A hand shown as lila's pocket, without controls (the partner board's). */
  private renderPocket(box: HTMLElement, color: Color, material: { [role in Role]: number }) {
    const well = document.createElement('div');
    well.className = 'zh-pocket ch-well ch-partner-well';
    well.setAttribute('aria-label', `${color === 'white' ? 'White' : 'Black'}’s hand`);
    for (const role of HAND_ROLES) {
      const slot = document.createElement('span');
      slot.className = 'zh-slot';
      slot.dataset.nb = String(material[role]);
      const img = document.createElement('img');
      img.src = `/piece/${color === 'white' ? 'w' : 'b'}${ROLE_LETTER[role]}.svg`;
      img.alt = '';
      slot.append(img);
      if (material[role]) {
        const nb = document.createElement('span');
        nb.className = 'zh-nb';
        nb.textContent = String(material[role]);
        slot.append(nb);
      }
      well.append(slot);
    }
    box.replaceChildren(well);
  }

  // ── ☰ menu ──────────────────────────────────────────────────────
  private toggleActionMenu(open = !this.menuOpen) {
    this.menuOpen = open && this.mode === 'analysis';
    this.renderActionMenu();
  }

  private closeActionMenu() { if (this.menuOpen) this.toggleActionMenu(false); }

  private renderActionMenu() {
    $('ch-tools').classList.toggle('menu-open', this.menuOpen);
    $('ch-menu-toggle').setAttribute('aria-expanded', String(this.menuOpen));
    const box = $('ch-action-menu');
    box.hidden = !this.menuOpen;
    if (!this.menuOpen) { box.replaceChildren(); return; }
    let mainline = 0;
    for (let n = this.tree.root; n.children[0]; n = n.children[0]) mainline++;
    renderMenu(box, {
      settings: this.settings,
      practising: !!this.practice,
      autoplay: this.autoplay?.delay ?? null,
      canReplay: mainline > 3,
      hasMoves: this.tree.root.children.length > 0,
      flip: () => { this.flip(); this.closeActionMenu(); },
      editor: () => { this.closeActionMenu(); this.openEditor(); },
      practice: () => this.togglePractice(),
      help: () => openHelp([], HELP_NOTES),
      clearMoves: () => this.clearMoves(),
      replay: (delay) => this.replay(delay),
      toggle: (key) => this.toggleSetting(key),
    });
  }

  private clearMoves() {
    this.tree = new Tree(this.tree.root.fen);
    this.pgnDirty = false;
    this.treeChanged();
    this.closeActionMenu();
    this.goTo(this.tree.root);
  }

  // ── Editor ──────────────────────────────────────────────────────
  private openEditor() {
    if (this.mode === 'editor') return;
    if (this.practice) this.togglePractice(false);
    this.stopAutoplay();
    this.closeActionMenu();
    this.draft = draftOf(this.current.fen);
    this.mode = 'editor';
    this.dropping = null;
    this.threat = false;
    this.moves.closeMenu();
    $('ch').dataset.mode = 'editor';
    this.board.showEditor(this.current.fen, this.orientation, 'pointer');
    this.renderAll();
    // As on lila, the engine follows the position being set up; the sit panel stands down.
    this.analyse();
  }

  private closeEditor(apply: boolean) {
    if (this.mode !== 'editor') return;
    if (apply) {
      const read = readFen(this.draftFen());
      if (!read.ok) return;
      this.tree = new Tree(fenOf(read.pos));
      this.current = this.tree.root;
      this.pgnDirty = false;
      this.scheduleSave();
    }
    this.mode = 'analysis';
    this.draft = null;
    $('ch').dataset.mode = 'analysis';
    this.renderAll();
    this.analyse();
    this.updateUrl();
  }

  /** What stands on a square of the board being edited. */
  private readonly pieceAt = (square: SquareName) => this.board.cg.state.pieces.get(square);

  private draftFen(): string {
    return fenOfDraft(this.draft!, this.board.boardFen(), this.pieceAt);
  }

  /** A ticked right counts only while its king and rook stand on their starting squares. */
  private draftCanCastle(right: CastlingRight): boolean {
    return castlingPossible(right, this.pieceAt);
  }

  private draftEpOptions(): SquareName[] {
    return enPassantOptions(this.draft!.turn, this.pieceAt);
  }

  private draftPieceCount(): number {
    return this.board.cg.state.pieces.size + this.draft!.hands.size();
  }

  private draftChanged() {
    const d = this.draft!;
    if (d.guessCastling)
      for (const right of ['K', 'Q', 'k', 'q'] as const) d.castling[right] = this.draftCanCastle(right);
    this.renderHands();
    this.renderEditorPanel();
    this.renderUnder();
    // A position painted square by square is searched once the brush rests.
    this.threat = false;
    this.renderCeval();
    clearTimeout(this.editorSearchTimer);
    this.editorSearchTimer = window.setTimeout(() => this.search(), 150);
  }

  private setDraftFen(fen: string): string | null {
    const read = readDraftFen(this.draft!, fen);
    if ('error' in read) return read.error;
    this.board.cg.set({ fen: read.board });
    this.draftChanged();
    return null;
  }

  private renderSpares() {
    const editing = this.mode === 'editor';
    const top: Color = this.orientation === 'white' ? 'black' : 'white';
    for (const [id, color] of [['ch-spare-top', top], ['ch-spare-bottom', top === 'white' ? 'black' : 'white']] as const) {
      const box = $(id);
      box.hidden = !editing;
      if (!editing) { box.replaceChildren(); continue; }
      box.replaceChildren(...this.board.spareStrip(color, this.draft!.brush, (brush) => this.setBrush(brush)));
    }
  }

  private setBrush(brush: Brush) {
    this.draft!.brush = brush;
    this.board.setBrush(brush);
    this.renderSpares();
  }

  private renderEditorPanel() {
    if (this.mode !== 'editor') return;
    const d = this.draft!;
    for (const b of document.querySelectorAll<HTMLButtonElement>('#ch-turn button'))
      b.setAttribute('aria-checked', String(b.dataset.turn === d.turn));
    for (const box of document.querySelectorAll<HTMLInputElement>('#ch-castling input')) {
      const right = box.dataset.right as CastlingRight;
      box.disabled = !this.draftCanCastle(right);
      box.checked = d.castling[right] && !box.disabled;
    }
    const options = this.draftEpOptions();
    const ep = $('ch-ep');
    ep.hidden = !options.length;
    const choice = d.ep && options.includes(d.ep as SquareName) ? d.ep : null;
    ep.querySelector('.ch-choice')!.replaceChildren(...[null, ...options].map((square) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.setAttribute('role', 'radio');
      b.setAttribute('aria-checked', String(square === choice));
      b.textContent = square ?? 'None';
      b.onclick = () => { this.draft!.ep = square; this.draftChanged(); };
      return b;
    }));
    const read = readFen(this.draftFen());
    const error = $('ch-editor-error');
    error.textContent = read.ok ? '' : read.error;
    $<HTMLButtonElement>('ch-editor-apply').disabled = !read.ok;
  }

  // ── Under the board: FEN and PGN ─────────────────────────────────
  private renderUnder() {
    const fen = $<HTMLInputElement>('ch-fen');
    if (document.activeElement !== fen) fen.value = lichessFen(this.mode === 'editor' ? this.draftFen() : this.current.fen);
    fen.removeAttribute('aria-invalid');
  }

  private renderPgn() {
    const area = $<HTMLTextAreaElement>('ch-pgn');
    if (!this.pgnDirty) area.value = this.tree.pgn();
    $<HTMLButtonElement>('ch-pgn-import').disabled = !this.pgnDirty;
  }

  private loadFen(text: string) {
    if (this.mode === 'editor') {
      const error = this.setDraftFen(text);
      this.fenError(error);
      return;
    }
    const read = readFen(text);
    if (!read.ok) { this.fenError(read.error); return; }
    const fen = fenOf(read.pos);
    if (fen === this.current.fen) return;
    this.newTree(new Tree(fen), null);
  }

  private fenError(error: string | null) {
    const input = $<HTMLInputElement>('ch-fen');
    if (error) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
    $('ch-fen-error').textContent = error ?? '';
  }

  private importPgn() {
    const tree = Tree.fromPgn($<HTMLTextAreaElement>('ch-pgn').value);
    if (!tree) { $('ch-pgn-error').textContent = 'No moves found in that PGN.'; return; }
    $('ch-pgn-error').textContent = '';
    this.newTree(tree, tree.lineEnd(tree.root.id));
  }

  private newTree(tree: Tree, at: TreeNode | null) {
    if (this.practice) this.togglePractice(false);
    this.tree = tree;
    this.pgnDirty = false;
    this.evals.clear();
    this.treeChanged();
    this.goTo(at ?? tree.root);
  }

  private updateUrl() {
    linkBoards(this.boards, this.twoBoards);
  }

  private scheduleSave() {
    clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => keepBoards(this.boards, this.active), 300);
  }

  private flash(text: string) {
    $('ch-fen-error').textContent = text;
  }

  private toast(text: string) {
    const box = $('ch-toast');
    box.textContent = text;
    box.hidden = false;
    clearTimeout(this.toastTimer);
    this.toastTimer = window.setTimeout(() => { box.hidden = true; }, 1800);
  }

  // ── Rendering and wiring ────────────────────────────────────────
  private renderAll() {
    $('ch').dataset.mode = this.mode;
    $('ch').dataset.boards = String(this.settings.boards);
    this.renderPartner();
    this.renderBoard();
    this.renderHands();
    this.renderSpares();
    if (this.mode === 'analysis') {
      this.renderCeval();
      this.renderMoves();
      this.renderPractice();
    } else {
      this.renderCeval();
      this.renderEditorPanel();
    }
    this.renderActionMenu();
    this.renderControls();
    this.renderUnder();
    this.renderPgn();
  }

  private renderControls() {
    const analysis = this.mode === 'analysis';
    const atRoot = this.current === this.tree.root, atEnd = !this.current.children.length;
    $<HTMLButtonElement>('ch-first').disabled = !analysis || atRoot;
    $<HTMLButtonElement>('ch-prev').disabled = !analysis || atRoot;
    $<HTMLButtonElement>('ch-next').disabled = !analysis || atEnd;
    $<HTMLButtonElement>('ch-last').disabled = !analysis || atEnd;
    $('ch-edit').setAttribute('aria-pressed', String(!analysis));
    $<HTMLButtonElement>('ch-practice-toggle').disabled = !analysis || this.twoBoards;
    $('ch-practice-toggle').title = this.twoBoards ? 'Practice with computer (one board only)' : 'Practice with computer';
    $('ch-boards').setAttribute('aria-pressed', String(this.twoBoards));
    $<HTMLButtonElement>('ch-boards').disabled = !analysis;
    $<HTMLButtonElement>('ch-menu-toggle').disabled = !analysis;
    $('ch-controls').classList.toggle('replaying', !!this.autoplay);
  }

  private bind() {
    $('ch-first').onclick = () => this.first();
    $('ch-prev').onclick = () => this.prev();
    $('ch-next').onclick = () => this.next();
    $('ch-last').onclick = () => this.last();
    $('ch-flip').onclick = () => this.flip();
    $('ch-edit').onclick = () => this.mode === 'editor' ? this.closeEditor(false) : this.openEditor();
    $('ch-practice-toggle').onclick = () => this.togglePractice();
    $('ch-boards').onclick = () => this.toggleBoards();
    $('ch-partner-board').onclick = () => this.switchBoard();
    $('ch-partner-switch').onclick = () => this.switchBoard();
    $('ch-menu-toggle').onclick = () => this.toggleActionMenu();
    $('ch-engine-on').onchange = (e) => this.toggleEngine((e.target as HTMLInputElement).checked);
    $('ch-threat').onclick = () => this.toggleThreat();

    // The gear: lila's engine settings, dropped over the engine lines; a click elsewhere or Esc closes it.
    const settings = $('ch-settings');
    const gearButton = $('ch-gear');
    const showGear = (open: boolean) => {
      settings.hidden = !open;
      gearButton.setAttribute('aria-expanded', String(open));
      if (open) this.renderGear();
    };
    gearButton.onclick = () => showGear(settings.hidden);
    document.addEventListener('pointerdown', (e) => {
      const target = e.target as Node;
      if (!settings.hidden && !settings.contains(target) && !gearButton.contains(target)) showGear(false);
    });
    this.closeGear = () => { if (settings.hidden) return false; showGear(false); gearButton.focus(); return true; };
    const changed = (restart: boolean) => {
      saveSettings(this.settings);
      this.renderGear();
      if (restart) this.engine.configure(threadsFor(this.settings));
      this.renderCeval();
      this.analyse();
    };
    this.gear = new GearPanel(settings, {
      searchSeconds: (seconds) => { this.settings.searchSeconds = seconds; changed(false); },
      lines: (n) => { this.settings.multiPv = n; this.evals.clear(); changed(false); },
      threads: (n) => { this.settings.threads = n; changed(true); },
      valuesSeconds: (n) => { this.settings.valuesSeconds = n; changed(false); },
    });

    // Editor panel
    for (const b of document.querySelectorAll<HTMLButtonElement>('#ch-turn button'))
      b.onclick = () => { this.draft!.turn = b.dataset.turn as Color; this.draft!.ep = null; this.draftChanged(); };
    for (const box of document.querySelectorAll<HTMLInputElement>('#ch-castling input'))
      box.onchange = () => {
        this.draft!.castling[box.dataset.right as keyof Draft['castling']] = box.checked;
        this.draft!.guessCastling = false;
        this.draftChanged();
      };
    $('ch-editor-start').onclick = () => this.setDraftFen(START_FEN);
    $('ch-editor-clear').onclick = () => {
      this.board.cg.set({ fen: '8/8/8/8/8/8/8/8' });
      this.draft!.hands = Material.empty();
      this.draft!.castling = { K: false, Q: false, k: false, q: false };
      this.draft!.ep = null;
      this.draft!.guessCastling = true;
      this.draftChanged();
    };
    $('ch-editor-apply').onclick = () => this.closeEditor(true);
    $('ch-editor-cancel').onclick = () => this.closeEditor(false);

    // FEN and PGN
    const fen = $<HTMLInputElement>('ch-fen');
    fen.onchange = () => this.loadFen(fen.value);
    // Enter loads and leaves the box, as on lila; a later click would otherwise reload it under the pointer.
    fen.onkeydown = (e) => {
      if (e.key !== 'Enter') return;
      e.preventDefault();
      this.loadFen(fen.value);
      if (!fen.getAttribute('aria-invalid')) fen.blur();
    };
    fen.onblur = () => { if (!fen.getAttribute('aria-invalid')) this.renderUnder(); };
    $('ch-fen-copy').onclick = () => void navigator.clipboard?.writeText(fen.value).then(() => this.flashCopied());
    const pgn = $<HTMLTextAreaElement>('ch-pgn');
    pgn.oninput = () => { this.pgnDirty = true; $<HTMLButtonElement>('ch-pgn-import').disabled = false; };
    $('ch-pgn-import').onclick = () => this.importPgn();
    $('ch-pgn-copy').onclick = () => void navigator.clipboard?.writeText(this.tree.pgn()).then(() => this.toast('PGN copied'));

    document.addEventListener('keydown', (e) => this.key(e));
  }

  private closeGear: () => boolean = () => false;

  private renderGear() {
    if (!this.gear || $('ch-settings').hidden) return;
    const max = maxThreads();
    this.gear.render({
      settings: this.settings,
      valuesSeconds: valuesSecondsFor(this.settings),
      maxThreads: max,
      recommendedThreads: recommendedThreads(max),
      threads: threadsFor(this.settings),
    });
  }

  private flashCopied() {
    const b = $('ch-fen-copy');
    b.textContent = 'Copied';
    setTimeout(() => { b.textContent = 'Copy'; }, 1200);
  }

  private key(e: KeyboardEvent) {
    const target = e.target as HTMLElement;
    // Esc closes the gear from its own sliders too.
    if (e.key === 'Escape' && target.closest('#ch-settings') && this.closeGear()) return;
    if (target.closest('input, textarea, [contenteditable], dialog') || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === 'Escape') {
      if (this.closeGear()) return;
      if (this.moves.menuOpen) { this.moves.closeMenu(); return; }
      if (this.menuOpen) { this.closeActionMenu(); return; }
      if (this.dropping) { this.dropping = null; this.renderBoard(); this.renderHands(); return; }
      if (this.mode === 'editor') { this.closeEditor(false); return; }
      if (this.autoplay) { this.stopAutoplay(); return; }
    }
    const shift = e.shiftKey;
    // The editor keeps only F (flip) and ? (this help).
    const actions: Record<string, () => void> = this.mode === 'editor' ? {
      f: () => this.flip(), '?': () => openHelp([], HELP_NOTES),
    } : shift ? {
      ArrowLeft: () => this.goTo(this.tree.previousBranch(this.current.id)),
      K: () => this.goTo(this.tree.previousBranch(this.current.id)),
      ArrowRight: () => this.goTo(this.tree.nextBranch(this.current.id, this.forkIndex)),
      J: () => this.goTo(this.tree.nextBranch(this.current.id, this.forkIndex)),
      ArrowUp: () => this.goTo(this.tree.stepLine(this.current.id, 'prev')),
      ArrowDown: () => this.goTo(this.tree.stepLine(this.current.id, 'next')),
      I: () => this.toggleSetting('inline'),
      '?': () => openHelp([], HELP_NOTES),
      $: () => this.last(),
    } : {
      ArrowLeft: () => this.prev(), ArrowRight: () => this.next(),
      ArrowUp: () => { if (!this.forkStep(-1)) this.first(); },
      ArrowDown: () => { if (!this.forkStep(1)) this.last(); },
      Home: () => this.first(), End: () => this.last(), '0': () => this.first(),
      j: () => this.next(), k: () => this.prev(),
      f: () => this.flip(), l: () => this.toggleEngine(), x: () => this.toggleThreat(),
      a: () => this.toggleSetting('bestArrows'), v: () => this.toggleSetting('variationArrows'),
      b: () => this.openEditor(), h: () => this.toggleActionMenu(),
      s: () => this.switchBoard(),
      ' ': () => { if (this.practice) return; if (this.settings.engineOn) this.playBest(); else this.toggleEngine(true); },
    };
    const action = actions[e.key];
    if (!action) return;
    if (target.closest('button') && (e.key === ' ' || e.key === 'Enter')) return;
    e.preventDefault();
    this.moves.closeMenu();
    action();
  }
}

function squareIndex(key: Key): number {
  return (key.charCodeAt(0) - 97) + (Number(key[1]) - 1) * 8;
}
