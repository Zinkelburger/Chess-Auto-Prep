/**
 * Bughouse analysis: lichess.org/analysis on one bughouse board, with a +
 * above and − below every piece in both hands. The board editor is its own
 * page (editor.ts), as lila's.
 * Captures leave for the partner and nothing arrives unless you add it, so
 * the hands are exactly what you set. Hivemind searches it, and the
 * sit panel (sit.ts) shows what one more piece is worth to the side to move.
 *
 * This file wires the parts together: the tree and the current position,
 * the engine, the board, the move list (moves.ts), the engine panel
 * (ceval.ts), practice (practice.ts) and the ☰ menu (menu.ts).
 */
import type { DrawShape } from '@lichess-org/chessground/draw';
import type { Key } from '@lichess-org/chessground/types';
import type { Color, Role } from 'chessops/types';
import { CrazyBoard } from './board';
import { CevalView } from './ceval';
import { Engine, type EngineResult, type EngineStatus, type SearchSettings } from './engine';
import { renderHand } from './hand';
import { liveGlyph, type Glyph } from './judge';
import { defaultOrientation, editorUrl, linkedOrientation } from './links';
import { openHelp, renderMenu } from './menu';
import { MoveList } from './moves';
import { PRACTICE_NODES, Practice } from './practice';
import { GearPanel } from './gear';
import { loadSettings, maxThreads, recommendedThreads, saveSettings, sitNodesFor, threadsFor, type Settings, type Toggle } from './settings';
import { SitPanel } from './sit';
import { engineShapes, glyphShape, moveShapes, threatShapes, variationShapes } from './shapes';
import {
  HAND_ROLES, START_FEN, Tree, boardDests, dropSquares, fenOf, outcomeOf, positionOf, readFen, readMove, threatFen,
  type SavedTree, type TreeNode,
} from './tree';
import { makeUci } from 'chessops/util';

const LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };
/** The analysis tree, kept in this browser so a reload comes back to it (Lichess keeps it too). */
const TREE_KEY = 'bughouse-analysis-tree-v1';

/** What the sit panel may read and do. */
export interface ExtraHost {
  readonly fen: string;
  readonly settings: Settings;
  /** Each row's search, in positions: the setting, or the default for the engine's backend. */
  readonly sitNodes: number;
  /** The engine is on and the board is in analysis (not practice). */
  readonly active: boolean;
  /** The engine has loaded (its files are in this browser's cache). */
  readonly engineReady: boolean;
  /** The engine failed or waits for the player: rows have nothing to wait for. */
  readonly engineStopped: boolean;
  evalOf(fen: string): EngineResult | undefined;
  /** One more of this piece in the hand of the side to move, as if the partner sent it. */
  give(role: Role): void;
  /** Shows a move on the board, in place of the engine's arrows, while the pointer is on it (null to clear). */
  hover(uci: string | null): void;
  /** Searches a position after the analysis of the shown one; null when cancelled or failed. */
  evaluate(fen: string, nodes: number): Promise<EngineResult | null>;
  /** Drops the evaluations asked for so far. */
  cancelEvaluations(): void;
}

export interface Extra {
  /** The position, the engine switch or the settings changed. */
  update(): void;
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
  private dropping: Role | null = null;
  private settings: Settings;
  private evals = new Map<string, EngineResult>();
  private engineStatus: EngineStatus = { kind: 'off' };
  private readonly engine: Engine;
  private readonly board: CrazyBoard;
  private readonly moves: MoveList;
  private readonly ceval: CevalView;
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
  private savePending = false;
  private toastTimer = 0;
  private lastDepth = new Map<string, number>();
  private readonly extra: Extra;
  private gear!: GearPanel;

  constructor() {
    this.settings = loadSettings();
    const params = new URLSearchParams(location.search);
    const fen = params.get('fen');
    const read = fen ? readFen(fen) : null;
    const target = read?.ok ? fenOf(read.pos) : START_FEN;
    const saved = loadSavedTree(TREE_KEY);
    const restored = saved ? Tree.restore(saved) : null;
    // A plain /bughouse is a clean board. A linked position that is the saved analysis's
    // current one reopens that analysis (a reload keeps the moves); any other link opens fresh.
    if (restored && fen && read?.ok && restored.current.fen === target) {
      this.tree = restored.tree;
      this.current = restored.current;
    } else {
      this.tree = new Tree(target);
      this.current = this.tree.root;
    }
    if (read && !read.ok) this.flash(`Could not open the linked position: ${read.error}`);
    this.orientation = linkedOrientation(params) ?? defaultOrientation(this.tree.root.fen);

    const onStatus = (status: EngineStatus) => { this.engineStatus = status; this.renderCeval(); this.renderGear(); this.extra?.update(); };
    const onResult = (result: EngineResult) => this.engineResult(result);
    this.engine = new Engine(onStatus, onResult);
    this.engine.configure({ gpu: this.settings.gpu, threads: threadsFor(this.settings) });
    this.board = new CrazyBoard($('ch-board-wrap'), $('ch-board'), {
      move: (orig, dest) => void this.boardMove(orig, dest),
      drop: (role, key) => this.play(`${LETTER[role]}@${key}`, 'user'),
      clickSquare: (key) => this.clickSquare(key),
      wheel: (forward) => forward ? this.next() : this.prev(),
      edited: () => { /* Only the editor page edits. */ },
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
      action: $<HTMLButtonElement>('ch-engine-action'), live: $('ch-eval-live'),
    }, {
      hover: (uci) => this.hover(uci, 'paleBlue'),
      play: (pv, upTo) => this.playLine(pv, upTo),
      start: () => this.startEngine(),
    });
    this.extra = new SitPanel({
      get fen() { return app.current.fen; },
      get settings() { return app.settings; },
      get sitNodes() { return sitNodesFor(app.settings, app.engine.gpu); },
      get active() { return !app.practice && app.settings.engineOn; },
      get engineReady() { return app.engineStatus.kind === 'ready'; },
      get engineStopped() { return app.engineStatus.kind === 'failed' || app.engineStatus.kind === 'ask'; },
      evalOf: (fen) => this.evals.get(fen),
      give: (role) => this.adjust(positionOf(this.current.fen).turn, role, 1),
      hover: (uci) => this.hover(uci, 'blue'),
      evaluate: (fen, nodes) => this.engine.evaluate(fen, nodes),
      cancelEvaluations: () => this.engine.cancelEvaluations(),
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
    const pos = positionOf(this.current.fen);
    const total = pos.board.occupied.size() + (pos.pockets?.size() ?? 0);
    for (const [boxId, color] of [['ch-hand-top', top], ['ch-hand-bottom', this.orientation === 'white' ? 'white' : 'black']] as const) {
      const material = pos.pockets![color];
      const counts = Object.fromEntries(HAND_ROLES.map((r) => [r, material[r]])) as Record<Role, number>;
      renderHand($(boxId), {
        color,
        counts,
        roomForMore: total < 64,
        picked: pos.turn === color ? this.dropping : null,
        usable: (role) => pos.turn === color && !outcomeOf(this.current.fen) && dropSquares(this.current.fen, role).length > 0,
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
    this.board.setShapes(this.shapes());
  }

  private flip() {
    this.orientation = this.orientation === 'white' ? 'black' : 'white';
    this.renderAll();
    this.updateUrl();
  }

  // ── Engine ──────────────────────────────────────────────────────
  private analyse() {
    this.search();
    this.extra?.update();
  }

  private search() {
    if (outcomeOf(this.current.fen)) { this.engine.stop(); this.renderCeval(); return; }
    if (this.practice) this.engine.analyse(this.current.fen, { ...this.searchSettings(), multiPv: 1, infinite: false, nodes: PRACTICE_NODES });
    else if (!this.settings.engineOn) { this.engine.stop(); return; }
    else {
      const fen = this.threat ? threatFen(this.current.fen) : this.current.fen;
      // A position already searched to its limit is shown as it was, as Lichess keeps its evaluations;
      // the engine's time then goes to the sit panel.
      const kept = this.evals.get(fen);
      const search = this.searchSettings();
      if (kept?.complete && kept.budget >= search.searchMs && kept.lines.length >= search.multiPv && !search.infinite) this.engine.stop();
      else this.engine.analyse(fen, search);
    }
    this.engine.load().catch(() => { /* Shown in the engine header. */ });
  }

  /** The analysis's search: ∞ searches 10 s first, then carries on once the sit panel is done. */
  private searchSettings(): SearchSettings {
    const seconds = this.settings.searchSeconds;
    return { multiPv: this.settings.multiPv, infinite: seconds === 0, searchMs: (seconds || 10) * 1000 };
  }

  private engineResult(result: EngineResult) {
    const kept = this.evals.get(result.fen);
    // A position searched again starts from nothing: keep the further search until the new one passes it.
    if (!kept || result.nodes >= kept.nodes || result.lines.length > kept.lines.length || kept.lines.length > this.settings.multiPv)
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
    const pos = positionOf(this.current.fen);
    const fen = this.threat ? threatFen(this.current.fen) : this.current.fen;
    this.ceval.render({
      enabled: this.settings.engineOn,
      fen,
      ply: this.current.ply,
      multiPv: this.settings.multiPv,
      infinite: this.settings.searchSeconds === 0,
      searchMs: this.searchSettings().searchMs,
      result: this.evals.get(fen),
      status: this.engineStatus,
      threat: this.threat,
      inCheck: pos.isCheck(),
      over: outcomeOf(this.current.fen),
      orientation: this.orientation,
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
    if (on === !!this.practice) return;
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
    this.moves.render();
  }

  // ── ☰ menu ──────────────────────────────────────────────────────
  private toggleActionMenu(open = !this.menuOpen) {
    this.menuOpen = open;
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
      editor: () => this.openEditor(),
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
  /** The board editor is its own page, as lila's /editor: Back returns here. */
  private openEditor() {
    this.saveNow();
    location.assign(editorUrl(this.current.fen, this.orientation));
  }

  // ── Under the board: FEN and PGN ─────────────────────────────────
  private renderUnder() {
    const fen = $<HTMLInputElement>('ch-fen');
    if (document.activeElement !== fen) fen.value = this.current.fen;
    fen.removeAttribute('aria-invalid');
  }

  private renderPgn() {
    const area = $<HTMLTextAreaElement>('ch-pgn');
    if (!this.pgnDirty) area.value = this.tree.pgn();
    $<HTMLButtonElement>('ch-pgn-import').disabled = !this.pgnDirty;
  }

  private loadFen(text: string) {
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
    // The fen stays in the URL while there is an analysis to come back to, so a reload at the root keeps it.
    if (this.current.fen === START_FEN && !this.tree.root.children.length) url.searchParams.delete('fen');
    else url.searchParams.set('fen', this.current.fen);
    // As lila's ?color=: only a board turned from its default (the side to move at the start) is written.
    if (this.orientation === defaultOrientation(this.tree.root.fen)) url.searchParams.delete('color');
    else url.searchParams.set('color', this.orientation);
    history.replaceState(null, '', url);
    $<HTMLAnchorElement>('ch-edit').href = editorUrl(this.current.fen, this.orientation);
  }

  private scheduleSave() {
    clearTimeout(this.saveTimer);
    this.savePending = true;
    this.saveTimer = window.setTimeout(() => this.saveNow(), 300);
  }

  /** A save still waiting, written before leaving so Back to this page finds the moves just made.
   *  A page left untouched writes nothing and leaves the last analysis as it was. */
  private saveNow() {
    clearTimeout(this.saveTimer);
    if (!this.savePending) return;
    this.savePending = false;
    try { localStorage.setItem(TREE_KEY, JSON.stringify(this.tree.save(this.current.id))); } catch { /* Kept for this visit only. */ }
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
    this.renderBoard();
    this.renderHands();
    this.renderCeval();
    this.renderMoves();
    this.renderPractice();
    this.renderActionMenu();
    this.renderControls();
    this.renderUnder();
    this.renderPgn();
  }

  private renderControls() {
    const atRoot = this.current === this.tree.root, atEnd = !this.current.children.length;
    $<HTMLButtonElement>('ch-first').disabled = atRoot;
    $<HTMLButtonElement>('ch-prev').disabled = atRoot;
    $<HTMLButtonElement>('ch-next').disabled = atEnd;
    $<HTMLButtonElement>('ch-last').disabled = atEnd;
    $('ch-controls').classList.toggle('replaying', !!this.autoplay);
  }

  private bind() {
    $('ch-first').onclick = () => this.first();
    $('ch-prev').onclick = () => this.prev();
    $('ch-next').onclick = () => this.next();
    $('ch-last').onclick = () => this.last();
    $('ch-flip').onclick = () => this.flip();
    // A plain link to the editor's page; saved first so Back comes back to these moves.
    $('ch-edit').addEventListener('click', () => this.saveNow());
    window.addEventListener('pagehide', () => this.saveNow());
    $('ch-practice-toggle').onclick = () => this.togglePractice();
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
      if (restart) this.engine.configure({ gpu: this.settings.gpu, threads: threadsFor(this.settings) });
      this.renderCeval();
      this.analyse();
    };
    this.gear = new GearPanel(settings, {
      searchSeconds: (seconds) => { this.settings.searchSeconds = seconds; changed(false); },
      lines: (n) => { this.settings.multiPv = n; this.evals.clear(); changed(false); },
      gpu: (on) => { this.settings.gpu = on; changed(true); },
      threads: (n) => { this.settings.threads = n; changed(true); },
      sitNodes: (n) => { this.settings.sitNodes = n; changed(false); },
    });

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

  private closeGear: () => boolean = () => false;

  private renderGear() {
    if (!this.gear || $('ch-settings').hidden) return;
    const max = maxThreads();
    this.gear.render({
      settings: this.settings,
      sitNodes: sitNodesFor(this.settings, this.engine.gpu),
      gpuAvailable: this.engine.gpuAvailable,
      onGpu: this.engine.gpu,
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
      if (this.autoplay) { this.stopAutoplay(); return; }
    }
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
