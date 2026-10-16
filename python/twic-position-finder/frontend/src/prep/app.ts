/**
 * The analysis board behind /pgn and /expectimax: lichess.org/analysis for
 * standard chess, with Stockfish's lines above two tabs.
 *
 * - PGN: the games opened from a file or pasted (a list to pick from when
 *   there are several) and the move list, with comments and variations.
 * - Expectimax: the practical search's table for the board's position
 *   (expectimax-view.ts), searched only when the player asks.
 *
 * This file wires the parts together: the tree and the current position, the
 * board (shared with /bughouse), Stockfish's panel, the move list, the games,
 * the ☰ menu, the board editor and the FEN and PGN boxes under the board.
 */
import type { DrawShape } from '@lichess-org/chessground/draw';
import type { Key, Piece } from '@lichess-org/chessground/types';
import type { Color, Role } from 'chessops/types';
import { makeUci } from 'chessops/util';
import { CrazyBoard, type Brush } from '../analysis/board';
import { liveGlyph, type Glyph } from '../analysis/judge';
import { openHelp, renderMenu } from '../analysis/menu';
import { el } from '../analysis/moves';
import { loadSettings, saveSettings, type Settings, type Toggle } from '../analysis/settings';
import { engineShapes, glyphShape, moveShapes, threatShapes, variationShapes } from '../analysis/shapes';
import { CevalView } from './ceval';
import { DEFAULT_OPTIONS, type ExpectimaxOptions } from './expectimax';
import { ExpectimaxRunner } from './expectimax-runner';
import { ExpectimaxView } from './expectimax-view';
import { loadCollection, saveCollection, splitGames, type StoredGame } from './games';
import { GearPanel } from './gear';
import { LiveEngine, type EngineResult, type EngineStatus } from './live-engine';
import { MoveList } from './moves';
import {
  START_FEN, Tree, boardDests, fenOf, gameTitle, headerValue, outcomeOf, positionOf, readFen, readMove, threatFen, type TreeNode,
} from './tree';

const LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };
const SPARE_ROLES: Role[] = ['king', 'queen', 'rook', 'bishop', 'knight', 'pawn'];
const SETTINGS_KEY = 'prep-analysis-v1';
const HELP_KEYS: [string, string][] = [['E', 'PGN or Expectimax tab']];
const OPTIONS_KEY = 'prep-expectimax-v1';
type Tab = 'pgn' | 'expectimax';

interface Draft {
  turn: Color;
  castling: { K: boolean; Q: boolean; k: boolean; q: boolean };
  fullmoves: number;
  brush: Brush;
}

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;

const squaresOf = (uci: string) => [uci.slice(0, 2), uci.slice(2, 4)] as Key[];
const legalMoves = (fen: string) => [...boardDests(fen).values()].reduce((n, d) => n + d.length, 0);

function loadOptions(): ExpectimaxOptions {
  const out = { ...DEFAULT_OPTIONS };
  try {
    const saved = JSON.parse(localStorage.getItem(OPTIONS_KEY) ?? '{}') as Partial<ExpectimaxOptions>;
    for (const key of Object.keys(out) as (keyof ExpectimaxOptions)[])
      if (typeof saved[key] === 'number' && Number.isFinite(saved[key])) out[key] = saved[key]!;
  } catch { /* Defaults. */ }
  return out;
}

export class PrepApp {
  private games: StoredGame[] = [];
  private gameIndex = 0;
  private tree: Tree;
  private current: TreeNode;
  private orientation: Color = 'white';
  private mode: 'analysis' | 'editor' = 'analysis';
  private tab: Tab;
  private settings: Settings;
  private options: ExpectimaxOptions;
  private evals = new Map<string, EngineResult>();
  private engineStatus: EngineStatus = { kind: 'loading' };
  private readonly engine: LiveEngine;
  private readonly board: CrazyBoard;
  private readonly moves: MoveList;
  private readonly ceval: CevalView;
  private readonly runner: ExpectimaxRunner;
  private readonly expectimax: ExpectimaxView;
  private gear!: GearPanel;
  private draft: Draft | null = null;
  private pgnDirty = false;
  private threat = false;
  private forkIndex = 0;
  private hoverUci: string | null = null;
  private hoverBrush = 'paleBlue';
  private menuOpen = false;
  private listOpen = false;
  private autoplay: { delay: number; timer: number } | null = null;
  private stepping = false;
  private saveTimer = 0;
  private toastTimer = 0;
  private xRenderQueued = false;
  private lastDepth = new Map<string, number>();
  private restored = false;

  constructor() {
    this.settings = loadSettings(SETTINGS_KEY, []);
    this.options = loadOptions();
    this.tab = $('ch').dataset.tab === 'expectimax' ? 'expectimax' : 'pgn';
    this.tree = new Tree();
    this.current = this.tree.root;
    this.games = [{ headers: {}, pgn: this.tree.pgn() }];

    this.engine = new LiveEngine(
      (status) => { this.engineStatus = status; this.renderCeval(); },
      (result) => this.engineResult(result),
    );
    this.board = new CrazyBoard($('ch-board-wrap'), $('ch-board'), {
      move: (orig, dest) => void this.boardMove(orig, dest),
      drop: () => undefined,
      clickSquare: () => undefined,
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
      copied: (text) => this.copy(text, 'PGN copied'),
      editComment: (node) => this.editComment(node),
    });
    this.ceval = new CevalView({
      header: $('ch-ceval'), pearl: $('ch-pearl'), name: $('ch-engine-name'), info: $('ch-engine-info'), bar: $('ch-bar'),
      threat: $<HTMLButtonElement>('ch-threat'), pvs: $('ch-pvs'), board: $('ch-pv-board'), switch: $<HTMLInputElement>('ch-engine-on'),
      action: $<HTMLButtonElement>('ch-engine-action'), live: $('ch-eval-live'),
    }, {
      hover: (uci) => this.hover(uci, 'paleBlue'),
      play: (pv, upTo) => this.playLine(pv, upTo),
      start: () => this.analyse(),
    });
    this.runner = new ExpectimaxRunner(() => this.queueExpectimax());
    this.expectimax = new ExpectimaxView($('px-expectimax'), this.runner, {
      get fen() { return app.current.fen; },
      get orientation() { return app.orientation; },
      get options() { return app.options; },
      set options(o) { app.options = o; },
      optionsChanged: () => { try { localStorage.setItem(OPTIONS_KEY, JSON.stringify(this.options)); } catch { /* For this visit. */ } },
      hover: (uci) => this.hover(uci, 'blue'),
      play: (uci) => this.play(uci),
    });

    this.bind();
    this.renderAll();
    void this.restore();
  }

  /** The saved games and searches, then a linked position (?fen=) as a new game beside them. */
  private async restore() {
    const status = $('px-save');
    let collection = null;
    try { collection = await loadCollection(); } catch (e) { status.textContent = (e as Error).message; }
    if (collection) {
      this.games = collection.games;
      this.orientation = collection.orientation === 'black' ? 'black' : 'white';
      this.openGame(Math.min(collection.index, this.games.length - 1), collection.path);
    }
    // From here an edit is saved; before, it would overwrite the games being read.
    this.restored = true;
    const linked = new URLSearchParams(location.search).get('fen');
    if (linked) {
      const read = readFen(linked);
      if (read.ok) this.newGame(fenOf(read.pos), { Event: 'Analysis' });
      else this.toast(`Could not open the linked position: ${read.error}`);
      const url = new URL(location.href);
      url.searchParams.delete('fen');
      history.replaceState(null, '', url);
    }
    await this.runner.restore();
    this.renderAll();
    this.analyse();
  }

  // ── Games ──────────────────────────────────────────────────────
  /** Shows a game of the collection, at a move given by child indexes (its last main-line move by default). */
  private openGame(index: number, path?: number[]) {
    const read = Tree.fromPgn(this.games[index]?.pgn ?? '');
    this.gameIndex = index;
    this.tree = read?.tree ?? new Tree();
    if (read?.skipped) this.toast(`${read.skipped} ${read.skipped === 1 ? 'move' : 'moves'} of this game could not be played and were left out`);
    this.current = path ? this.tree.follow(path) : this.tree.root;
    if (positionOf(this.tree.root.fen).turn === 'black' && !path) this.orientation = 'black';
    this.pgnDirty = false;
    this.listOpen = false;
    this.goTo(this.current);
  }

  private newGame(fen: string, headers: Record<string, string> = {}) {
    const tree = new Tree(fen, new Map(Object.entries(headers)));
    this.games.push({ headers, pgn: tree.pgn() });
    this.openGame(this.games.length - 1);
    this.scheduleSave();
  }

  /** Replaces the open games with a PGN's, as opening a file does. */
  private async openPgn(text: string, name: string) {
    const error = $('ch-pgn-error');
    error.textContent = '';
    try {
      const games = await splitGames(text);
      // A paste with nothing playable in it leaves the open games as they are.
      if (!games.some((g) => 'FEN' in g.headers || (Tree.fromPgn(g.pgn)?.tree.root.children.length ?? 0) > 0)) throw new Error('No playable moves in that PGN.');
      this.games = games;
      this.orientation = 'white';
      this.openGame(0);
      this.scheduleSave();
      this.toast(games.length === 1 ? `Opened ${name}` : `Opened ${games.length.toLocaleString()} games from ${name}`);
      if (games.length > 1) { this.listOpen = true; this.renderGames(); }
    } catch (e) {
      error.textContent = (e as Error).message;
    }
  }

  private renderGames() {
    const headers = this.tree.headers;
    const title = gameTitle(headers, 'Analysis');
    const result = headers.get('Result');
    // A game without players is titled by its event, which then is not repeated under it.
    const named = !!(headerValue(headers, 'White') || headerValue(headers, 'Black'));
    const details = [named ? headerValue(headers, 'Event') : '', headerValue(headers, 'Date')].filter(Boolean).join(' · ');
    $('px-game-title').textContent = title + (result && result !== '*' ? `  ${result}` : '');
    $('px-game-details').textContent = details;
    $('px-game-count').textContent = this.games.length > 1 ? `${this.gameIndex + 1} / ${this.games.length.toLocaleString()}` : '';
    $<HTMLButtonElement>('px-game-prev').disabled = this.gameIndex === 0;
    $<HTMLButtonElement>('px-game-next').disabled = this.gameIndex >= this.games.length - 1;
    $('px-game-prev').hidden = $('px-game-next').hidden = this.games.length < 2;
    $('px-game-list').setAttribute('aria-expanded', String(this.listOpen));
    $('px-pgn').classList.toggle('list-open', this.listOpen);
    $('px-games').hidden = !this.listOpen;
    if (this.listOpen) this.renderGameList();
  }

  private renderGameList() {
    const filter = $<HTMLInputElement>('px-games-filter').value.trim().toLowerCase();
    const list = $('px-games-list');
    const rows: HTMLElement[] = [];
    for (let i = 0; i < this.games.length && rows.length < 400; i++) {
      const h = this.games[i].headers;
      const text = [gameTitle(h, `Game ${i + 1}`), headerValue(h, 'Event'), headerValue(h, 'Date')].join(' ');
      if (filter && !text.toLowerCase().includes(filter)) continue;
      const b = el('button', 'px-games-row') as HTMLButtonElement;
      b.type = 'button';
      b.dataset.game = String(i);
      if (i === this.gameIndex) b.classList.add('active');
      b.append(el('span', 'px-games-num', String(i + 1)), el('span', 'px-games-name', gameTitle(h, `Game ${i + 1}`)), el('span', 'px-games-result', h.Result && h.Result !== '*' ? h.Result : ''));
      const sub = [headerValue(h, 'White') || headerValue(h, 'Black') ? headerValue(h, 'Event') : '', headerValue(h, 'Date')].filter(Boolean).join(' · ');
      if (sub) b.append(el('span', 'px-games-sub', sub));
      rows.push(b);
    }
    if (!rows.length) rows.push(el('p', 'px-games-empty dim', 'No game matches.'));
    list.replaceChildren(...rows);
  }

  private toggleList(open = !this.listOpen) {
    this.listOpen = open;
    this.renderGames();
    if (open) $('px-games-filter').focus({ preventScroll: true });
  }

  // ── Tabs ───────────────────────────────────────────────────────
  private setTab(tab: Tab) {
    if (tab === this.tab) return;
    this.tab = tab;
    const path = `/${tab}${location.pathname.endsWith('/') ? '/' : ''}`;
    history.replaceState(null, '', path + location.search);
    document.title = `${tab === 'pgn' ? 'PGN Viewer' : 'Expectimax'} — Chess Auto Prep`;
    for (const a of document.querySelectorAll<HTMLAnchorElement>('.nav-links a')) {
      const on = a.getAttribute('href') === `/${tab}`;
      a.classList.toggle('active', on);
      if (on) a.setAttribute('aria-current', 'page'); else a.removeAttribute('aria-current');
    }
    this.renderTabs();
    this.renderShapes();
  }

  private renderTabs() {
    $('ch').dataset.tab = this.tab;
    for (const t of ['pgn', 'expectimax'] as const) {
      $(`px-tab-${t}`).setAttribute('aria-selected', String(this.tab === t));
      $(`px-tab-${t}`).tabIndex = this.tab === t ? 0 : -1;
      $(`px-${t}`).hidden = this.tab !== t;
    }
    if (this.tab === 'expectimax') this.expectimax.render();
    else this.moves.render();
  }

  private queueExpectimax() {
    if (this.xRenderQueued) return;
    this.xRenderQueued = true;
    setTimeout(() => {
      this.xRenderQueued = false;
      if (this.tab === 'expectimax' && this.mode === 'analysis') this.expectimax.render();
    }, 200);
  }

  // ── Navigation and moves ─────────────────────────────────────────
  private goTo(node: TreeNode) {
    const from = this.current;
    if (!this.stepping) this.stopAutoplay();
    this.moves.closeMenu();
    this.current = node;
    if (node !== from) { this.threat = false; this.forkIndex = 0; this.hoverUci = null; }
    this.renderAll();
    this.analyse();
    this.scheduleSave();
  }

  private prev() { const p = this.tree.parent(this.current.id); if (p) this.goTo(p); }
  private next() { const c = this.current.children[this.forkIndex] ?? this.current.children[0]; if (c) this.goTo(c); }
  private first() { if (this.current !== this.tree.root) this.goTo(this.tree.root); }
  private last() { const end = this.tree.lineEnd(this.current.id); if (end !== this.current) this.goTo(end); }

  private forkStep(dir: 1 | -1): boolean {
    const n = this.current.children.length;
    if (n < 2) return false;
    this.forkIndex = (this.forkIndex + dir + n) % n;
    this.moves.render();
    this.renderShapes();
    return true;
  }

  private play(uci: string): boolean {
    const node = this.tree.play(this.current.id, uci);
    if (!node) { this.renderBoard(); return false; }
    this.treeChanged();
    this.goTo(node);
    return true;
  }

  private async boardMove(orig: Key, dest: Key) {
    const pos = positionOf(this.current.fen);
    const piece = pos.board.get((orig.charCodeAt(0) - 97) + (Number(orig[1]) - 1) * 8);
    if (piece?.role === 'pawn' && (dest[1] === '1' || dest[1] === '8')) {
      const role = await this.board.pickPromotion(dest, piece.color, this.orientation);
      if (!role) { this.renderBoard(); return; }
      this.play(orig + dest + (role === 'knight' ? 'n' : role[0]));
      return;
    }
    this.play(orig + dest);
  }

  private playBest() {
    const best = this.evals.get(this.current.fen)?.lines[0]?.pv[0];
    if (best) this.play(best);
  }

  private playLine(pv: string[], upTo: number) {
    let node = this.current;
    for (const uci of pv.slice(0, upTo + 1)) {
      const next = this.tree.play(node.id, uci);
      if (!next) break;
      node = next;
    }
    if (node !== this.current) { this.treeChanged(); this.goTo(node); }
  }

  private treeChanged() {
    this.games[this.gameIndex] = { headers: Object.fromEntries(this.tree.headers), pgn: this.tree.pgn() };
    this.renderPgn();
    this.scheduleSave();
  }

  private editComment(node: TreeNode) {
    const dialog = document.createElement('dialog');
    dialog.className = 'ch-help px-comment-dialog';
    const label = node === this.tree.root ? 'Comment before the first move' : `Comment after ${Math.floor((node.ply + 1) / 2)}${node.ply % 2 ? '.' : '...'} ${node.san}`;
    dialog.setAttribute('aria-label', label);
    const area = document.createElement('textarea');
    area.rows = 5;
    area.value = (node.comments ?? []).join(' ');
    const save = el('button', 'btn btn-primary btn-sm', 'Save') as HTMLButtonElement;
    const cancel = el('button', 'btn btn-outline btn-sm', 'Cancel') as HTMLButtonElement;
    save.type = cancel.type = 'button';
    save.onclick = () => { this.tree.setComment(node.id, area.value); this.treeChanged(); this.renderMoves(); dialog.close(); };
    cancel.onclick = () => dialog.close();
    const row = el('div', 'ch-editor-row ch-editor-actions');
    row.append(cancel, save);
    dialog.append(el('h2', '', label), area, row);
    dialog.addEventListener('close', () => dialog.remove());
    document.body.append(dialog);
    dialog.showModal();
    area.focus();
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
      this.goTo(child);
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
      dropping: null,
      dropSquares: [],
    });
    $('ch-board').setAttribute('aria-label', `Chessboard: ${node.fen}`);
  }

  private shapes(): DrawShape[] {
    const pos = positionOf(this.current.fen);
    const turn = pos.turn, other: Color = turn === 'white' ? 'black' : 'white';
    let shapes: DrawShape[] = [];
    const over = !!outcomeOf(this.current.fen);
    const on = this.settings.engineOn && !over;
    if (this.hoverUci && !over) shapes.push(...moveShapes(this.threat ? other : turn, this.hoverUci, this.hoverBrush));
    else if (on && this.settings.bestArrows) {
      const result = this.evals.get(this.current.fen);
      if (result) shapes.push(...engineShapes(turn, result.lines, this.settings.maneuverArrows));
    }
    const threat = this.threat ? threatFen(this.current.fen) : null;
    if (on && threat) {
      const result = this.evals.get(threat);
      if (result) shapes.push(...threatShapes(other, result.lines, this.settings.maneuverArrows));
    }
    const glyph = this.settings.glyphsOnBoard ? this.glyph(this.current) : undefined;
    if (glyph) shapes.push(glyphShape(this.current.uci, this.current.san, glyph));
    if (this.settings.variationArrows && this.current.children.length > 1)
      shapes = shapes.concat(variationShapes(turn, this.current.children.map((c) => c.uci), this.forkIndex, shapes));
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
    } else this.renderAll();
    this.scheduleSave();
  }

  // ── Engine ──────────────────────────────────────────────────────
  private searchFen(): string | null {
    return this.threat ? threatFen(this.current.fen) : this.current.fen;
  }

  private analyse() {
    if (this.mode === 'editor' || !this.settings.engineOn || outcomeOf(this.current.fen)) { this.engine.stop(); this.renderCeval(); return; }
    const fen = this.searchFen();
    if (!fen) { this.engine.stop(); return; }
    const seconds = this.settings.searchSeconds;
    const kept = this.evals.get(fen);
    const search = { multiPv: this.settings.multiPv, infinite: seconds === 0, searchMs: (seconds || 10) * 1000 };
    // A position already searched to its limit is shown as it was, as Lichess keeps its evaluations.
    if (kept?.done && !search.infinite && kept.budget >= search.searchMs && kept.lines.length >= Math.min(search.multiPv, legalMoves(fen))) { this.engine.stop(); return; }
    this.engine.analyse(fen, search);
  }

  private engineResult(result: EngineResult) {
    const kept = this.evals.get(result.fen);
    if (!kept || result.depth >= kept.depth || result.lines.length > kept.lines.length || kept.lines.length > this.settings.multiPv)
      this.evals.set(result.fen, result);
    if (result.fen !== this.current.fen && result.fen !== this.searchFen()) return;
    this.renderCeval();
    this.renderShapes();
    if (this.settings.liveGlyphs && this.lastDepth.get(result.fen) !== result.depth) {
      this.lastDepth.set(result.fen, result.depth);
      this.renderMoves();
    }
  }

  /** Whether an engine move is the tree's move. */
  private sameMove(fen: string, engineUci: string | undefined, node: TreeNode): boolean {
    if (!engineUci) return false;
    if (engineUci === node.uci) return true;
    const pos = positionOf(fen);
    const a = readMove(pos, engineUci), b = readMove(pos, node.uci);
    return !!a && !!b && makeUci(a) === makeUci(b);
  }

  /** Lichess's live annotation: what the move lost against the engine's best before it. */
  private glyph(node: TreeNode): Glyph | undefined {
    if (!this.settings.liveGlyphs) return undefined;
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
    const fen = this.searchFen() ?? this.current.fen;
    const outcome = outcomeOf(this.current.fen);
    this.ceval.render({
      enabled: this.settings.engineOn,
      fen,
      ply: this.current.ply,
      multiPv: this.settings.multiPv,
      infinite: this.settings.searchSeconds === 0,
      searchMs: (this.settings.searchSeconds || 10) * 1000,
      result: this.evals.get(fen),
      status: this.engineStatus,
      threat: this.threat,
      inCheck: pos.isCheck() || !threatFen(this.current.fen),
      over: outcome === 'Draw' ? 'Stalemate' : outcome,
      orientation: this.orientation,
    });
    if (outcome === 'Draw') { $('ch-pearl').textContent = '½'; $('ch-engine-info').textContent = pos.halfmoves >= 100 ? 'Draw by the fifty-move rule' : 'Draw: insufficient material'; }
  }

  private toggleEngine(on = !this.settings.engineOn) {
    this.settings.engineOn = on;
    if (!on) this.threat = false;
    saveSettings(this.settings, SETTINGS_KEY);
    this.renderCeval();
    this.renderShapes();
    this.analyse();
  }

  private toggleThreat(on = !this.threat) {
    if (on === this.threat || !this.settings.engineOn || outcomeOf(this.current.fen) || (on && !threatFen(this.current.fen))) return;
    this.threat = on;
    this.hoverUci = null;
    this.renderCeval();
    this.renderShapes();
    this.analyse();
  }

  private toggleSetting(key: Toggle) {
    this.settings[key] = !this.settings[key];
    saveSettings(this.settings, SETTINGS_KEY);
    this.renderMoves();
    this.renderShapes();
    if (this.menuOpen) this.renderActionMenu();
  }

  private renderMoves() {
    if (this.mode === 'analysis' && this.tab === 'pgn') this.moves.render();
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
      practising: false,
      autoplay: this.autoplay?.delay ?? null,
      canReplay: mainline > 3,
      hasMoves: this.tree.root.children.length > 0,
      flip: () => { this.flip(); this.closeActionMenu(); },
      editor: () => { this.closeActionMenu(); this.openEditor(); },
      help: () => openHelp(HELP_KEYS),
      clearMoves: () => this.clearMoves(),
      replay: (delay) => this.replay(delay),
      toggle: (key) => this.toggleSetting(key),
      extra: [
        { icon: 'M12 5v14M5 12h14', text: 'New analysis', title: 'Add an empty game to the games open here', action: () => { this.closeActionMenu(); this.newGame(START_FEN); } },
        { icon: 'M13 2 3 14h9l-1 8 10-12h-9z', text: 'Find tactics', title: 'Mine puzzles from these games in the Tactics Trainer', action: () => this.sendToTactics() },
      ],
    });
  }

  private clearMoves() {
    this.tree = new Tree(this.tree.root.fen, this.tree.headers);
    this.pgnDirty = false;
    this.treeChanged();
    this.closeActionMenu();
    this.goTo(this.tree.root);
  }

  private sendToTactics() {
    try {
      sessionStorage.setItem('cap-tactics-import', this.games.map((g) => g.pgn).join('\n\n'));
      location.href = '/tactics/';
    } catch { this.toast('These games are too large to send. Download the PGN and open it in Tactics.'); }
  }

  // ── Editor ──────────────────────────────────────────────────────
  private openEditor() {
    if (this.mode === 'editor') return;
    this.stopAutoplay();
    this.closeActionMenu();
    const pos = positionOf(this.current.fen);
    const castling = this.current.fen.split(' ')[2] ?? '-';
    this.draft = {
      turn: pos.turn,
      castling: { K: castling.includes('K'), Q: castling.includes('Q'), k: castling.includes('k'), q: castling.includes('q') },
      fullmoves: pos.fullmoves,
      brush: 'pointer',
    };
    this.mode = 'editor';
    this.threat = false;
    this.engine.stop();
    this.moves.closeMenu();
    $('ch').dataset.mode = 'editor';
    this.board.showEditor(this.current.fen, this.orientation, 'pointer');
    this.renderAll();
  }

  private closeEditor(apply: boolean) {
    if (this.mode !== 'editor') return;
    const fen = this.draftFen();
    this.mode = 'analysis';
    this.draft = null;
    $('ch').dataset.mode = 'analysis';
    if (apply && readFen(fen).ok) { this.newGame(fen, { Event: 'Analysis' }); return; }
    this.renderAll();
    this.analyse();
  }

  private draftFen(): string {
    const d = this.draft!;
    const c = d.castling;
    const castling = `${c.K ? 'K' : ''}${c.Q ? 'Q' : ''}${c.k ? 'k' : ''}${c.q ? 'q' : ''}` || '-';
    return `${this.board.boardFen()} ${d.turn === 'white' ? 'w' : 'b'} ${castling} - 0 ${d.fullmoves}`;
  }

  private draftChanged() {
    this.renderEditorPanel();
    this.renderUnder();
  }

  private setDraftFen(fen: string): string | null {
    const parts = fen.trim().split(/\s+/);
    if (!/^[1-8pnbrqkPNBRQK/]+$/.test(parts[0] ?? '')) return 'That is not a FEN.';
    const d = this.draft!;
    d.turn = parts[1] === 'b' ? 'black' : 'white';
    const castling = parts[2] ?? '-';
    d.castling = { K: castling.includes('K'), Q: castling.includes('Q'), k: castling.includes('k'), q: castling.includes('q') };
    d.fullmoves = Math.max(1, Number(parts[5]) || 1);
    this.board.cg.set({ fen: parts[0] });
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
    $('ch-editor-error').textContent = read.ok ? '' : read.error;
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
    if (!this.pgnDirty) area.value = this.games[this.gameIndex]?.pgn ?? this.tree.pgn();
    $<HTMLButtonElement>('ch-pgn-import').disabled = !this.pgnDirty;
  }

  private loadFen(text: string) {
    if (this.mode === 'editor') { this.fenError(this.setDraftFen(text)); return; }
    const read = readFen(text);
    if (!read.ok) { this.fenError(read.error); return; }
    this.fenError(null);
    const fen = fenOf(read.pos);
    if (fen !== this.current.fen) this.newGame(fen, { Event: 'Analysis' });
  }

  private fenError(error: string | null) {
    const input = $<HTMLInputElement>('ch-fen');
    if (error) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
    $('ch-fen-error').textContent = error ?? '';
  }

  private download() {
    const text = this.games.map((g) => g.pgn.trim()).join('\n\n') + '\n';
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([text], { type: 'application/x-chess-pgn' }));
    const name = this.games.length === 1 ? gameTitle(this.tree.headers, 'analysis').replace(/[^\w-]+/g, '_').replace(/^_+|_+$/g, '') : 'games';
    a.download = `${name || 'analysis'}.pgn`;
    document.body.append(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 1000);
  }

  private scheduleSave() {
    if (!this.restored) return;
    clearTimeout(this.saveTimer);
    this.saveTimer = window.setTimeout(() => {
      const status = $('px-save');
      saveCollection({ version: 1, games: this.games, index: this.gameIndex, path: this.tree.indexPath(this.current.id), orientation: this.orientation })
        .then(() => { status.textContent = ''; }, (e: Error) => { status.textContent = e.message; });
    }, 400);
  }

  private copy(text: string, done: string) {
    void navigator.clipboard?.writeText(text).then(() => this.toast(done), () => this.toast('Copying was blocked by the browser'));
  }

  private toast(text: string) {
    const box = $('ch-toast');
    box.textContent = text;
    box.hidden = false;
    clearTimeout(this.toastTimer);
    this.toastTimer = window.setTimeout(() => { box.hidden = true; }, 2600);
  }

  // ── Rendering and wiring ────────────────────────────────────────
  private renderAll() {
    $('ch').dataset.mode = this.mode;
    this.renderBoard();
    this.renderSpares();
    if (this.mode === 'analysis') {
      this.renderCeval();
      this.renderGames();
      this.renderTabs();
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
    $('ch-menu-toggle').onclick = () => this.toggleActionMenu();
    $('ch-engine-on').onchange = (e) => this.toggleEngine((e.target as HTMLInputElement).checked);
    $('ch-threat').onclick = () => this.toggleThreat();
    for (const t of ['pgn', 'expectimax'] as const) $(`px-tab-${t}`).onclick = () => this.setTab(t);
    $('px-tabs').onkeydown = (e) => {
      if (e.key !== 'ArrowLeft' && e.key !== 'ArrowRight') return;
      e.preventDefault();
      e.stopPropagation();
      const next = this.tab === 'pgn' ? 'expectimax' : 'pgn';
      this.setTab(next);
      $(`px-tab-${next}`).focus();
    };

    // Games
    $('px-game-prev').onclick = () => { if (this.gameIndex > 0) this.openGame(this.gameIndex - 1); };
    $('px-game-next').onclick = () => { if (this.gameIndex < this.games.length - 1) this.openGame(this.gameIndex + 1); };
    $('px-game-list').onclick = () => this.toggleList();
    $('px-games-filter').oninput = () => this.renderGameList();
    $('px-games-list').onclick = (e) => {
      const row = (e.target as HTMLElement).closest<HTMLElement>('[data-game]');
      if (row) this.openGame(Number(row.dataset.game));
    };

    // The engine gear, dropped over the engine lines; a click elsewhere or Esc closes it.
    const settings = $('ch-settings');
    const gearButton = $('ch-gear');
    const showGear = (open: boolean) => {
      settings.hidden = !open;
      gearButton.setAttribute('aria-expanded', String(open));
      if (open) this.gear.render(this.settings);
    };
    gearButton.onclick = () => showGear(settings.hidden);
    document.addEventListener('pointerdown', (e) => {
      const target = e.target as Node;
      if (!settings.hidden && !settings.contains(target) && !gearButton.contains(target)) showGear(false);
    });
    this.closeGear = () => { if (settings.hidden) return false; showGear(false); gearButton.focus(); return true; };
    const changed = () => {
      saveSettings(this.settings, SETTINGS_KEY);
      this.gear.render(this.settings);
      this.renderCeval();
      this.analyse();
    };
    this.gear = new GearPanel(settings, {
      searchSeconds: (s) => { this.settings.searchSeconds = s; changed(); },
      lines: (n) => { this.settings.multiPv = n; this.evals.clear(); changed(); },
    });

    // Editor panel
    for (const b of document.querySelectorAll<HTMLButtonElement>('#ch-turn button'))
      b.onclick = () => { this.draft!.turn = b.dataset.turn as Color; this.draftChanged(); };
    for (const box of document.querySelectorAll<HTMLInputElement>('#ch-castling input'))
      box.onchange = () => { this.draft!.castling[box.dataset.right as keyof Draft['castling']] = box.checked; this.draftChanged(); };
    $('ch-editor-start').onclick = () => this.setDraftFen(START_FEN);
    $('ch-editor-clear').onclick = () => {
      this.board.cg.set({ fen: '8/8/8/8/8/8/8/8' });
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
    $('ch-fen-copy').onclick = () => this.copy(fen.value, 'FEN copied');
    const pgn = $<HTMLTextAreaElement>('ch-pgn');
    pgn.oninput = () => { this.pgnDirty = true; $<HTMLButtonElement>('ch-pgn-import').disabled = false; };
    $('ch-pgn-import').onclick = () => void this.openPgn(pgn.value, 'the pasted PGN');
    $('ch-pgn-copy').onclick = () => this.copy(this.tree.pgn(), 'PGN copied');
    $('ch-pgn-download').onclick = () => this.download();
    const file = $<HTMLInputElement>('ch-pgn-file');
    file.onchange = async () => {
      const chosen = file.files?.[0];
      file.value = '';
      if (chosen) await this.openPgn(await chosen.text(), chosen.name);
    };
    // A PGN file dropped anywhere on the page opens it.
    document.addEventListener('dragover', (e) => { if (e.dataTransfer?.types.includes('Files')) e.preventDefault(); });
    document.addEventListener('drop', async (e) => {
      const chosen = e.dataTransfer?.files?.[0];
      if (!chosen) return;
      e.preventDefault();
      await this.openPgn(await chosen.text(), chosen.name);
    });
    // Pasting a FEN or PGN anywhere outside a text box opens it, as on Lichess.
    document.addEventListener('paste', (e) => {
      const target = e.target as HTMLElement;
      if (target.closest('input, textarea, [contenteditable]')) return;
      const text = e.clipboardData?.getData('text')?.trim();
      if (!text) return;
      if (readFen(text).ok) { e.preventDefault(); this.loadFen(text); }
      else if (/\d\.\s*[a-hNBRQKO]/.test(text) || text.startsWith('[')) { e.preventDefault(); void this.openPgn(text, 'the pasted PGN'); }
    });

    document.addEventListener('keydown', (e) => this.key(e));
  }

  private closeGear: () => boolean = () => false;

  private key(e: KeyboardEvent) {
    const target = e.target as HTMLElement;
    if (e.key === 'Escape' && target.closest('#ch-settings') && this.closeGear()) return;
    if (e.key === 'Escape' && target.closest('.px-settings') && this.expectimax.closeSettings()) return;
    if (e.key === 'Escape' && this.listOpen && target.closest('#px-games')) { this.toggleList(false); return; }
    if (target.closest('input, textarea, [contenteditable], dialog') || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === 'Escape') {
      if (this.closeGear() || this.expectimax.closeSettings()) return;
      if (this.moves.menuOpen) { this.moves.closeMenu(); return; }
      if (this.menuOpen) { this.closeActionMenu(); return; }
      if (this.listOpen) { this.toggleList(false); return; }
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
      '?': () => openHelp(HELP_KEYS),
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
      e: () => this.setTab(this.tab === 'pgn' ? 'expectimax' : 'pgn'),
      ' ': () => { if (this.settings.engineOn) this.playBest(); else this.toggleEngine(true); },
    };
    const action = actions[e.key];
    if (!action) return;
    if (target.closest('button') && (e.key === ' ' || e.key === 'Enter')) return;
    e.preventDefault();
    this.moves.closeMenu();
    action();
  }
}

const POINTER_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 11V6a2 2 0 0 0-4 0v0M14 10V4a2 2 0 0 0-4 0v2M10 10.5V6a2 2 0 0 0-4 0v8"/><path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/></svg>';
const TRASH_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>';
