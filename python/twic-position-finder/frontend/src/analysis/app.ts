/**
 * Bughouse analysis: lichess.org/analysis on one bughouse board, with a +
 * above and − below every piece in both hands and lila's board editor.
 * Captures leave for the partner and nothing arrives unless you add it, so
 * the hands are exactly what you set. Fairy-Stockfish searches it, and the
 * sit panel (sit.ts) shows what one more piece is worth to the side to move.
 *
 * This file wires the parts together: the tree and the current position,
 * the engine, the board, the move list (moves.ts), the engine panel
 * (ceval.ts), practice (practice.ts), the ☰ menu (menu.ts) and the editor.
 */
import type { DrawShape } from '@lichess-org/chessground/draw';
import type { Key, Piece } from '@lichess-org/chessground/types';
import { makePockets } from 'chessops/fen';
import { Material } from 'chessops/setup';
import type { Color, Role } from 'chessops/types';
import { CrazyBoard, type Brush } from './board';
import { CevalView } from './ceval';
import { Engine, MAX_THREADS, type EngineResult, type EngineStatus } from './engine';
import { renderHand } from './hand';
import { liveGlyph, winningChances, type Glyph } from './judge';
import { openHelp, renderMenu } from './menu';
import { MoveList } from './moves';
import { PRACTICE_NODES, Practice } from './practice';
import { clamp, loadSettings, saveSettings, type Settings, type Toggle } from './settings';
import { SitPanel } from './sit';
import { engineShapes, glyphShape, moveShapes, threatShapes, variationShapes } from './shapes';
import {
  HAND_ROLES, START_FEN, Tree, boardDests, dropSquares, fenOf, outcomeOf, positionOf, readFen, readMove, threatFen,
  type SavedTree, type TreeNode,
} from './tree';
import { makeUci } from 'chessops/util';

const LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };
const SPARE_ROLES: Role[] = ['king', 'queen', 'rook', 'bishop', 'knight', 'pawn'];
/** The analysis tree, kept in this browser so a reload comes back to it (Lichess keeps it too). */
const TREE_KEY = 'bughouse-analysis-tree-v1';

/** What the sit panel may read and do. */
export interface ExtraHost {
  readonly fen: string;
  readonly settings: Settings;
  /** The engine is on and the board is in analysis (not the editor or practice). */
  readonly active: boolean;
  /** The engine has loaded (its files are in this browser's cache). */
  readonly engineReady: boolean;
  evalOf(fen: string): EngineResult | undefined;
  /** One more of this piece in the hand of the side to move, as if the partner sent it. */
  give(role: Role): void;
  /** Shows a move on the board, in place of the engine's arrows, while the pointer is on it (null to clear). */
  hover(uci: string | null): void;
}

export interface Extra {
  /** The position, the engine switch or the settings changed. */
  update(): void;
}

interface Draft {
  turn: Color;
  castling: { K: boolean; Q: boolean; k: boolean; q: boolean };
  hands: Material;
  fullmoves: number;
  brush: Brush;
}

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;

function squaresOf(uci: string): Key[] {
  return (uci.includes('@') ? [uci.slice(2, 4)] : [uci.slice(0, 2), uci.slice(2, 4)]) as Key[];
}

/** A tree move as the arrow Lichess draws: castling to the king's square, not the rook's. */
function arrowUci(node: TreeNode): string {
  if (!node.san.startsWith('O-O')) return node.uci;
  return node.uci.slice(0, 2) + (node.san.startsWith('O-O-O') ? 'c' : 'g') + node.uci[1];
}

function loadSavedTree(key: string): SavedTree | null {
  try { return JSON.parse(localStorage.getItem(key) ?? 'null') as SavedTree | null; } catch { return null; }
}

export class BughouseApp {
  private tree: Tree;
  private current: TreeNode;
  private orientation: Color = 'white';
  private mode: 'analysis' | 'editor' = 'analysis';
  private dropping: Role | null = null;
  private settings: Settings;
  private evals = new Map<string, EngineResult>();
  private engineStatus: EngineStatus = { kind: 'off' };
  private readonly engine: Engine;
  private readonly board: CrazyBoard;
  private readonly moves: MoveList;
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
  private toastTimer = 0;
  private lastDepth = new Map<string, number>();
  private readonly extra: Extra;

  constructor() {
    this.settings = loadSettings();
    const fen = new URLSearchParams(location.search).get('fen');
    const read = fen ? readFen(fen) : null;
    const target = read?.ok ? fenOf(read.pos) : START_FEN;
    const saved = loadSavedTree(TREE_KEY);
    const restored = saved ? Tree.restore(saved) : null;
    if (restored && restored.current.fen === target && !(read && !read.ok)) {
      this.tree = restored.tree;
      this.current = restored.current;
    } else {
      this.tree = new Tree(target);
      this.current = this.tree.root;
    }
    if (read && !read.ok) this.flash(`Could not open the linked position: ${read.error}`);
    if (positionOf(this.tree.root.fen).turn === 'black') this.orientation = 'black';

    const onStatus = (status: EngineStatus) => { this.engineStatus = status; this.renderCeval(); this.extra?.update(); };
    const onResult = (result: EngineResult) => this.engineResult(result);
    this.engine = new Engine(onStatus, onResult);
    this.board = new CrazyBoard($('ch-board-wrap'), $('ch-board'), {
      move: (orig, dest) => void this.boardMove(orig, dest),
      drop: (role, key) => this.play(`${LETTER[role]}@${key}`, 'user'),
      clickSquare: (key) => this.clickSquare(key),
      wheel: (forward) => forward ? this.next() : this.prev(),
      edited: () => this.draftChanged(),
    });

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
    });
    this.ceval = new CevalView({
      header: $('ch-ceval'), pearl: $('ch-pearl'), name: $('ch-engine-name'), info: $('ch-engine-info'), bar: $('ch-bar'),
      threat: $<HTMLButtonElement>('ch-threat'), pvs: $('ch-pvs'), board: $('ch-pv-board'), switch: $<HTMLInputElement>('ch-engine-on'),
    }, {
      hover: (uci) => this.hover(uci, 'paleBlue'),
      play: (pv, upTo) => this.playLine(pv, upTo),
    });
    this.extra = new SitPanel({
      get fen() { return app.current.fen; },
      get settings() { return app.settings; },
      get active() { return app.mode === 'analysis' && !app.practice && app.settings.engineOn; },
      get engineReady() { return app.engineStatus.kind === 'ready'; },
      evalOf: (fen) => this.evals.get(fen),
      give: (role) => this.adjust(positionOf(this.current.fen).turn, role, 1),
      hover: (uci) => this.hover(uci, 'blue'),
    }, $('bs-sit'));

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
    const node = this.tree.play(this.current.id, uci);
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
    if (!this.play(`${LETTER[role]}@${key}`, 'user')) this.renderAll();
  }

  private playBest() {
    const best = this.evals.get(this.current.fen)?.lines[0]?.pv[0];
    if (best) this.play(best, 'user');
  }

  /** Plays an engine line from the current position up to and including move `upTo`. */
  private playLine(pv: string[], upTo: number) {
    let node = this.current;
    for (const uci of pv.slice(0, upTo + 1)) {
      const next = this.tree.play(node.id, uci);
      if (!next) break;
      node = next;
    }
    if (node !== this.current) { this.treeChanged(); this.goTo(node, false); }
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
      const result = this.evals.get(this.current.fen);
      if (result) shapes.push(...engineShapes(turn, result.lines, this.settings.maneuverArrows));
    }
    if (on && this.threat) {
      const result = this.evals.get(threatFen(this.current.fen));
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
    this.search();
    this.extra?.update();
  }

  private search() {
    if (this.mode === 'editor') { this.engine.stop(); return; }
    if (outcomeOf(this.current.fen)) { this.engine.stop(); this.renderCeval(); return; }
    if (this.practice) this.engine.analyse(this.current.fen, { ...this.settings, multiPv: 1, infinite: false, nodes: PRACTICE_NODES });
    else if (!this.settings.engineOn) { this.engine.stop(); return; }
    else this.engine.analyse(this.threat ? threatFen(this.current.fen) : this.current.fen, this.settings);
    this.engine.load().catch(() => { /* Shown in the engine header. */ });
  }

  private engineResult(result: EngineResult) {
    const kept = this.evals.get(result.fen);
    if (!kept || result.depth >= kept.depth || result.lines.length > kept.lines.length || kept.lines.length > this.settings.multiPv)
      this.evals.set(result.fen, result);
    const searched = this.threat ? threatFen(this.current.fen) : this.current.fen;
    if (result.fen !== this.current.fen && result.fen !== searched) return;
    if (this.practice) { this.practice.check(); return; }
    this.renderCeval();
    this.renderShapes();
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
    const before = parent && this.evals.get(parent.fen);
    if (!parent || !before) return undefined;
    const best = before.lines[0];
    if (!best || this.sameMove(parent.fen, best.pv[0], node)) return undefined;
    const after = before.lines.find((l) => this.sameMove(parent.fen, l.pv[0], node)) ?? this.evals.get(node.fen)?.lines[0];
    if (!after) return undefined;
    return liveGlyph(positionOf(parent.fen).turn, best, after);
  }

  private renderCeval() {
    this.renderGauge();
    const pos = positionOf(this.current.fen);
    const fen = this.threat ? threatFen(this.current.fen) : this.current.fen;
    this.ceval.render({
      enabled: this.settings.engineOn,
      fen,
      ply: this.current.ply,
      multiPv: this.settings.multiPv,
      infinite: this.settings.infinite,
      result: this.evals.get(fen),
      status: this.engineStatus,
      threat: this.threat,
      inCheck: pos.isCheck(),
      over: outcomeOf(this.current.fen),
      orientation: this.orientation,
    });
  }

  /** Lichess's evaluation gauge beside the board: White's winning chances, white from the bottom (top when flipped). */
  private renderGauge() {
    const gauge = document.getElementById('ch-gauge');
    if (!gauge) return;
    const over = outcomeOf(this.current.fen);
    const line = this.evals.get(this.current.fen)?.lines[0];
    const shown = this.mode === 'analysis' && this.settings.engineOn && (!!line || over === 'Checkmate');
    gauge.classList.toggle('off', !shown);
    gauge.classList.toggle('flipped', this.orientation === 'black');
    if (!shown) return;
    const white = over === 'Checkmate'
      ? (positionOf(this.current.fen).turn === 'white' ? -1 : 1)
      : winningChances(line!);
    gauge.querySelector<HTMLElement>('.ch-gauge-black')!.style.transform = `scaleY(${(1 - white) / 2})`;
    gauge.title = line ? `Evaluation ${line.mate !== undefined ? `#${line.mate}` : ((line.cp ?? 0) / 100).toFixed(1)}` : over!;
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
    const pos = positionOf(this.current.fen);
    if (on === this.threat || this.practice || !this.settings.engineOn || pos.isCheck() || outcomeOf(this.current.fen)) return;
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
    if (on === !!this.practice || this.mode === 'editor') return;
    this.stopAutoplay();
    this.closeActionMenu();
    if (on) {
      this.threat = false;
      const app = this;
      this.practice = new Practice({
        get tree() { return app.tree; },
        get current() { return app.current; },
        evalOf: (fen) => this.evals.get(fen),
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
      help: () => openHelp(),
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
    const pos = positionOf(this.current.fen);
    const castling = this.current.fen.split(' ')[2] ?? '-';
    this.draft = {
      turn: pos.turn,
      castling: { K: castling.includes('K'), Q: castling.includes('Q'), k: castling.includes('k'), q: castling.includes('q') },
      hands: pos.pockets ? pos.pockets.clone() : Material.empty(),
      fullmoves: pos.fullmoves,
      brush: 'pointer',
    };
    this.mode = 'editor';
    this.dropping = null;
    this.threat = false;
    this.engine.stop();
    this.moves.closeMenu();
    $('ch').dataset.mode = 'editor';
    this.board.showEditor(this.current.fen, this.orientation, 'pointer');
    this.renderAll();
  }

  private closeEditor(apply: boolean) {
    if (this.mode !== 'editor') return;
    if (apply) {
      const read = readFen(this.draftFen());
      if (!read.ok) return;
      this.tree = new Tree(fenOf(read.pos));
      this.current = this.tree.root;
      this.evals.clear();
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

  private draftFen(): string {
    const d = this.draft!;
    const c = d.castling;
    const castling = `${c.K ? 'K' : ''}${c.Q ? 'Q' : ''}${c.k ? 'k' : ''}${c.q ? 'q' : ''}` || '-';
    return `${this.board.boardFen()}[${makePockets(d.hands)}] ${d.turn === 'white' ? 'w' : 'b'} ${castling} - 0 ${d.fullmoves}`;
  }

  private draftPieceCount(): number {
    return this.board.cg.state.pieces.size + this.draft!.hands.size();
  }

  private draftChanged() {
    this.renderHands();
    this.renderEditorPanel();
    this.renderUnder();
  }

  private setDraftFen(fen: string): string | null {
    const setupFen = fen.trim();
    const read = readFen(setupFen);
    // The editor takes positions the analysis board would refuse too; only the FEN itself must parse.
    const parts = setupFen.split(/\s+/);
    if (!read.ok && !/^[1-8pnbrqkPNBRQK~/]+(\[[pnbrqPNBRQ]*\])?$/.test(parts[0] ?? '')) return 'That is not a FEN.';
    const d = this.draft!;
    const board = parts[0].replace(/\[.*$/, '');
    const hand = /\[([^\]]*)\]/.exec(parts[0])?.[1] ?? '';
    d.hands = Material.empty();
    for (const ch of hand) {
      const role = (({ p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen' }) as Record<string, Role>)[ch.toLowerCase()];
      if (role) d.hands[ch === ch.toUpperCase() ? 'white' : 'black'][role]++;
    }
    d.turn = parts[1] === 'b' ? 'black' : 'white';
    const castling = parts[2] ?? '-';
    d.castling = { K: castling.includes('K'), Q: castling.includes('Q'), k: castling.includes('k'), q: castling.includes('q') };
    d.fullmoves = Math.max(1, Number(parts[5]) || 1);
    this.board.cg.set({ fen: board });
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
      const brush = this.draft!.brush;
      const items: HTMLElement[] = [];
      const tool = (name: 'pointer' | 'trash', label: string, svg: string) => {
        const b = document.createElement('button');
        b.type = 'button';
        b.className = `ch-spare-tool ch-${name}`;
        b.title = label;
        b.setAttribute('aria-label', label);
        b.setAttribute('aria-pressed', String(brush === name));
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
      box.replaceChildren(...items);
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
    for (const box of document.querySelectorAll<HTMLInputElement>('#ch-castling input'))
      box.checked = d.castling[box.dataset.right as keyof Draft['castling']];
    const read = readFen(this.draftFen());
    const error = $('ch-editor-error');
    error.textContent = read.ok ? '' : read.error;
    $<HTMLButtonElement>('ch-editor-apply').disabled = !read.ok;
  }

  // ── Under the board: FEN and PGN ─────────────────────────────────
  private renderUnder() {
    const fen = $<HTMLInputElement>('ch-fen');
    if (document.activeElement !== fen) fen.value = this.mode === 'editor' ? this.draftFen() : this.current.fen;
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
    const url = new URL(location.href);
    if (this.current.fen === START_FEN) url.searchParams.delete('fen'); else url.searchParams.set('fen', this.current.fen);
    history.replaceState(null, '', url);
  }

  private scheduleSave() {
    clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => {
      try { localStorage.setItem(TREE_KEY, JSON.stringify(this.tree.save(this.current.id))); } catch { /* Kept for this visit only. */ }
    }, 300);
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
    this.renderBoard();
    this.renderHands();
    this.renderSpares();
    if (this.mode === 'analysis') {
      this.renderCeval();
      this.renderMoves();
      this.renderPractice();
    } else this.renderEditorPanel();
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
    $<HTMLButtonElement>('ch-practice-toggle').disabled = !analysis;
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
    $('ch-menu-toggle').onclick = () => this.toggleActionMenu();
    $('ch-engine-on').onchange = (e) => this.toggleEngine((e.target as HTMLInputElement).checked);
    $('ch-threat').onclick = () => this.toggleThreat();

    const settings = $('ch-settings');
    $('ch-gear').onclick = () => {
      settings.hidden = !settings.hidden;
      $('ch-gear').setAttribute('aria-expanded', String(!settings.hidden));
    };
    const number = (id: string, key: 'multiPv' | 'threads' | 'hashMb' | 'sitNodes', lo: number, hi: number) => {
      const input = document.getElementById(id) as HTMLInputElement | null;
      if (!input) return;
      input.min = String(lo);
      input.max = String(hi);
      input.value = String(this.settings[key]);
      input.onchange = () => {
        this.settings[key] = clamp(input.value, lo, hi, this.settings[key]);
        input.value = String(this.settings[key]);
        saveSettings(this.settings);
        if (key === 'multiPv') this.evals.clear();
        this.renderCeval();
        this.analyse();
      };
    };
    number('ch-set-lines', 'multiPv', 1, 5);
    number('ch-set-threads', 'threads', 1, MAX_THREADS);
    number('ch-set-hash', 'hashMb', 16, 512);
    number('ch-set-sit', 'sitNodes', 20, 5000);
    $('ch-set-threads-max').textContent = `of ${MAX_THREADS}`;
    const infinite = $<HTMLInputElement>('ch-set-infinite');
    infinite.checked = this.settings.infinite;
    infinite.onchange = () => { this.settings.infinite = infinite.checked; saveSettings(this.settings); this.analyse(); };

    // Editor panel
    for (const b of document.querySelectorAll<HTMLButtonElement>('#ch-turn button'))
      b.onclick = () => { this.draft!.turn = b.dataset.turn as Color; this.draftChanged(); };
    for (const box of document.querySelectorAll<HTMLInputElement>('#ch-castling input'))
      box.onchange = () => { this.draft!.castling[box.dataset.right as keyof Draft['castling']] = box.checked; this.draftChanged(); };
    $('ch-editor-start').onclick = () => this.setDraftFen(START_FEN);
    $('ch-editor-clear').onclick = () => {
      this.board.cg.set({ fen: '8/8/8/8/8/8/8/8' });
      this.draft!.hands = Material.empty();
      this.draft!.castling = { K: false, Q: false, k: false, q: false };
      this.draftChanged();
    };
    $('ch-editor-apply').onclick = () => this.closeEditor(true);
    $('ch-editor-cancel').onclick = () => this.closeEditor(false);

    // FEN and PGN
    const fen = $<HTMLInputElement>('ch-fen');
    fen.onchange = () => this.loadFen(fen.value);
    fen.onkeydown = (e) => { if (e.key === 'Enter') { e.preventDefault(); this.loadFen(fen.value); } };
    fen.onblur = () => { if (!fen.getAttribute('aria-invalid')) this.renderUnder(); };
    $('ch-fen-copy').onclick = () => void navigator.clipboard?.writeText(fen.value).then(() => this.flashCopied());
    const pgn = $<HTMLTextAreaElement>('ch-pgn');
    pgn.oninput = () => { this.pgnDirty = true; $<HTMLButtonElement>('ch-pgn-import').disabled = false; };
    $('ch-pgn-import').onclick = () => this.importPgn();
    $('ch-pgn-copy').onclick = () => void navigator.clipboard?.writeText(this.tree.pgn()).then(() => this.toast('PGN copied'));

    document.addEventListener('keydown', (e) => this.key(e));
  }

  private flashCopied() {
    const b = $('ch-fen-copy');
    b.textContent = 'Copied';
    setTimeout(() => { b.textContent = 'Copy'; }, 1200);
  }

  private key(e: KeyboardEvent) {
    const target = e.target as HTMLElement;
    if (target.closest('input, textarea, [contenteditable], dialog') || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === 'Escape') {
      if (this.moves.menuOpen) { this.moves.closeMenu(); return; }
      if (this.menuOpen) { this.closeActionMenu(); return; }
      if (this.dropping) { this.dropping = null; this.renderBoard(); this.renderHands(); return; }
      if (this.mode === 'editor') { this.closeEditor(false); return; }
      if (this.autoplay) { this.stopAutoplay(); return; }
    }
    if (this.mode === 'editor') return;
    const shift = e.shiftKey;
    const actions: Record<string, () => void> = shift ? {
      ArrowLeft: () => this.goTo(this.tree.previousBranch(this.current.id)),
      K: () => this.goTo(this.tree.previousBranch(this.current.id)),
      ArrowRight: () => this.goTo(this.tree.nextBranch(this.current.id, this.forkIndex)),
      J: () => this.goTo(this.tree.nextBranch(this.current.id, this.forkIndex)),
      ArrowUp: () => this.goTo(this.tree.stepLine(this.current.id, 'prev')),
      ArrowDown: () => this.goTo(this.tree.stepLine(this.current.id, 'next')),
      I: () => this.toggleSetting('inline'),
      '?': () => openHelp(),
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

const POINTER_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 11V6a2 2 0 0 0-4 0v0M14 10V4a2 2 0 0 0-4 0v2M10 10.5V6a2 2 0 0 0-4 0v8"/><path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/></svg>';
const TRASH_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>';
