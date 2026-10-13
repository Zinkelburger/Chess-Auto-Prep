/**
 * Crazyhouse Analysis: lichess.org/analysis/crazyhouse on one board, plus a
 * − and + under every piece in both hands and lila's board editor. Built for
 * bughouse questions such as "what if my opponent had a pawn here": the
 * rules and the engine are crazyhouse, and the hands are whatever you set.
 */
import type { DrawShape } from '@lichess-org/chessground/draw';
import type { Key, Piece } from '@lichess-org/chessground/types';
import { makePockets } from 'chessops/fen';
import { Material } from 'chessops/setup';
import type { Color, Role } from 'chessops/types';
import { CrazyBoard, type Brush } from './board';
import { DEFAULT_THREADS, Engine, MAX_THREADS, type EngineLine, type EngineResult, type EngineStatus, type SearchSettings } from './engine';
import { renderHand } from './hand';
import {
  HAND_ROLES, START_FEN, Tree, boardDests, dropSquares, fenOf, handEdit, positionOf, readFen, sanLine,
  type TreeNode,
} from './tree';

const LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };
const SPARE_ROLES: Role[] = ['king', 'queen', 'rook', 'bishop', 'knight', 'pawn'];
const SETTINGS_KEY = 'crazyhouse-analysis-v1';
const PV_MOVES = 14;

interface Settings extends SearchSettings { engineOn: boolean }

interface Draft {
  turn: Color;
  castling: { K: boolean; Q: boolean; k: boolean; q: boolean };
  hands: Material;
  fullmoves: number;
  brush: Brush;
}

const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;

function loadSettings(): Settings {
  const base: Settings = { engineOn: true, multiPv: 2, threads: DEFAULT_THREADS, hashMb: 128, infinite: false };
  try {
    const saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) ?? '{}');
    return {
      engineOn: typeof saved.engineOn === 'boolean' ? saved.engineOn : base.engineOn,
      multiPv: clamp(saved.multiPv, 1, 5, base.multiPv),
      threads: clamp(saved.threads, 1, MAX_THREADS, base.threads),
      hashMb: clamp(saved.hashMb, 16, 512, base.hashMb),
      infinite: typeof saved.infinite === 'boolean' ? saved.infinite : base.infinite,
    };
  } catch { return base; }
}

function clamp(value: unknown, lo: number, hi: number, fallback: number): number {
  const n = Math.round(Number(value));
  return Number.isFinite(n) ? Math.min(hi, Math.max(lo, n)) : fallback;
}

export function formatEval(line: Pick<EngineLine, 'cp' | 'mate'>): string {
  if (line.mate !== undefined) return `#${line.mate}`;
  const pawns = (line.cp ?? 0) / 100;
  return `${pawns > 0 ? '+' : ''}${pawns.toFixed(1)}`;
}

function squaresOf(uci: string): Key[] {
  return (uci.includes('@') ? [uci.slice(2, 4)] : [uci.slice(0, 2), uci.slice(2, 4)]) as Key[];
}

export class CrazyhouseApp {
  private tree: Tree;
  private current: TreeNode;
  private orientation: Color = 'white';
  private mode: 'analysis' | 'editor' = 'analysis';
  private dropping: Role | null = null;
  private settings = loadSettings();
  private evals = new Map<string, EngineResult>();
  private engineStatus: EngineStatus = { kind: 'off' };
  private readonly engine: Engine;
  private readonly board: CrazyBoard;
  private draft: Draft | null = null;
  private pgnDirty = false;
  private menu: HTMLElement | null = null;

  constructor() {
    const fen = new URLSearchParams(location.search).get('fen');
    const read = fen ? readFen(fen) : null;
    this.tree = new Tree(read?.ok ? fenOf(read.pos) : START_FEN);
    this.current = this.tree.root;
    if (read && !read.ok) this.flash(`Could not open the linked position: ${read.error}`);
    if (read?.ok && read.pos.turn === 'black') this.orientation = 'black';

    this.engine = new Engine(
      (status) => { this.engineStatus = status; this.renderCeval(); },
      (result) => this.engineResult(result),
    );
    this.board = new CrazyBoard($('ch-board-wrap'), $('ch-board'), {
      move: (orig, dest) => void this.boardMove(orig, dest),
      drop: (role, key) => this.playUci(`${LETTER[role]}@${key}`),
      clickSquare: (key) => this.clickSquare(key),
      wheel: (forward) => forward ? this.next() : this.prev(),
      edited: () => this.draftChanged(),
    });
    this.bind();
    this.renderAll();
    this.analyse();
  }

  // ── Navigation and moves ─────────────────────────────────────────
  private goTo(node: TreeNode) {
    this.current = node;
    this.dropping = null;
    this.renderAll();
    this.analyse();
    this.updateUrl();
  }

  private prev() { const p = this.tree.parent(this.current.id); if (p) this.goTo(p); }
  private next() { const c = this.current.children[0]; if (c) this.goTo(c); }
  private first() { if (this.current !== this.tree.root) this.goTo(this.tree.root); }
  private last() { const end = this.tree.lineEnd(this.current.id); if (end !== this.current) this.goTo(end); }

  private playUci(uci: string): boolean {
    const node = this.tree.play(this.current.id, uci);
    if (!node) { this.renderBoard(); return false; }
    this.treeChanged();
    this.goTo(node);
    return true;
  }

  private async boardMove(orig: Key, dest: Key) {
    const pos = positionOf(this.current.fen);
    const piece = pos.board.get(squareIndex(orig));
    const rank = dest[1];
    if (piece?.role === 'pawn' && (rank === '1' || rank === '8')) {
      const role = await this.board.pickPromotion(dest, piece.color, this.orientation);
      if (!role) { this.renderBoard(); return; }
      this.playUci(orig + dest + (role === 'knight' ? 'n' : role[0]));
      return;
    }
    this.playUci(orig + dest);
  }

  private clickSquare(key: Key) {
    const role = this.dropping;
    if (!role) return;
    this.dropping = null;
    if (!this.playUci(`${LETTER[role]}@${key}`)) this.renderAll();
  }

  private playBest() {
    const result = this.evals.get(this.current.fen);
    const best = result?.lines[0]?.pv[0];
    if (best) this.playUci(best);
  }

  /** Plays an engine line from the current position up to and including move `upTo`. */
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
    this.renderPgn();
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
        top: boxId === 'ch-hand-top',
        roomForMore: total < 64,
        picked: !editing && pos!.turn === color ? this.dropping : null,
        usable: (role) => !editing && pos!.turn === color && !pos!.isEnd() && dropSquares(this.current.fen, role).length > 0,
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
    const over = pos.isEnd();
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

  private shapes(): DrawShape[] {
    if (!this.settings.engineOn) return [];
    const result = this.evals.get(this.current.fen);
    if (!result) return [];
    const turn = positionOf(this.current.fen).turn;
    return result.lines.map((line, i): DrawShape | null => {
      const uci = line.pv[0];
      if (!uci) return null;
      const brush = i === 0 ? 'paleBlue' : 'paleGrey';
      const modifiers = { lineWidth: i === 0 ? 12 : 7 };
      if (uci[1] === '@') {
        const role = ({ P: 'pawn', N: 'knight', B: 'bishop', R: 'rook', Q: 'queen' } as Record<string, Role>)[uci[0]];
        return { orig: uci.slice(2, 4) as Key, brush, piece: { role, color: turn, scale: 0.8 } };
      }
      return { orig: uci.slice(0, 2) as Key, dest: uci.slice(2, 4) as Key, brush, modifiers };
    }).filter((s): s is DrawShape => !!s);
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
    if (!this.settings.engineOn || this.mode === 'editor') { this.engine.stop(); return; }
    const pos = positionOf(this.current.fen);
    if (pos.isEnd()) { this.engine.stop(); this.renderCeval(); return; }
    this.engine.analyse(this.current.fen, this.settings);
    this.engine.load().catch(() => { /* Shown in the engine header. */ });
  }

  private engineResult(result: EngineResult) {
    const kept = this.evals.get(result.fen);
    if (!kept || result.depth >= kept.depth || result.lines.length > kept.lines.length || kept.lines.length > this.settings.multiPv)
      this.evals.set(result.fen, result);
    if (result.fen !== this.current.fen) return;
    this.renderCeval();
    if (this.mode === 'analysis') this.board.cg.setAutoShapes(this.shapes());
  }

  private renderCeval() {
    const pearl = $('ch-pearl'), engineName = $('ch-engine-name'), info = $('ch-engine-info'), pvs = $('ch-pvs');
    $<HTMLInputElement>('ch-engine-on').checked = this.settings.engineOn;
    const pos = positionOf(this.current.fen);
    pvs.replaceChildren();
    engineName.textContent = 'Fairy-Stockfish 14 NNUE';
    $('ch-ceval').classList.toggle('off', !this.settings.engineOn);
    if (pos.isCheckmate()) { pearl.textContent = '#'; info.textContent = 'Checkmate'; return; }
    if (pos.isStalemate()) { pearl.textContent = '½'; info.textContent = 'Stalemate'; return; }
    if (!this.settings.engineOn) { pearl.textContent = ''; info.textContent = 'Off · press L to turn on'; return; }
    const status = this.engineStatus;
    const result = this.evals.get(this.current.fen);
    if (!result) {
      pearl.innerHTML = '<span class="ch-spinner" aria-hidden="true"></span>';
      info.textContent = status.kind === 'loading' ? status.text : status.kind === 'failed' ? status.text : 'Calculating…';
      info.classList.toggle('ch-failed', status.kind === 'failed');
      return;
    }
    info.classList.remove('ch-failed');
    pearl.textContent = formatEval(result.lines[0]);
    info.textContent = `Depth ${result.depth}${result.knps ? ` · ${result.knps.toLocaleString()} kn/s` : ''}`;
    for (const line of result.lines) pvs.append(this.pvRow(line));
  }

  private pvRow(line: EngineLine): HTMLElement {
    const row = document.createElement('div');
    row.className = 'ch-pv';
    const score = document.createElement('strong');
    score.textContent = formatEval(line);
    row.append(score);
    const sans = sanLine(this.current.fen, line.pv, PV_MOVES);
    let ply = this.current.ply;
    sans.forEach((san, i) => {
      ply++;
      const white = ply % 2 === 1;
      if (white || i === 0) {
        const n = document.createElement('span');
        n.className = 'ch-pv-num';
        n.textContent = `${Math.floor((ply + 1) / 2)}.${white ? '' : '..'}`;
        row.append(n);
      }
      const move = document.createElement('button');
      move.type = 'button';
      move.className = 'ch-pv-move';
      move.textContent = san;
      move.onclick = () => this.playLine(line.pv, i);
      row.append(move);
    });
    return row;
  }

  private saveSettings() {
    try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(this.settings)); } catch { /* Settings stay for this visit. */ }
  }

  private toggleEngine(on = !this.settings.engineOn) {
    this.settings.engineOn = on;
    this.saveSettings();
    this.renderCeval();
    this.renderBoard();
    this.analyse();
  }

  // ── Move list (lila's column view) ──────────────────────────────
  private renderMoves() {
    const box = $('ch-moves');
    const out: HTMLElement[] = [];
    const rootEdit = handEdit(this.tree.loadedFen, this.tree.root.fen);
    if (rootEdit) out.push(el('div', 'ch-root-edit', `Hands edited at the start: ${rootEdit}`));
    let node = this.tree.root;
    let needIndex = true;
    while (node.children.length) {
      const [main, ...alternatives] = node.children;
      const white = main.ply % 2 === 1;
      if (white) out.push(el('index', '', String(Math.floor((main.ply + 1) / 2))));
      else if (needIndex) { out.push(el('index', '', String(Math.floor((main.ply + 1) / 2)))); out.push(el('span', 'ch-empty', '…')); }
      out.push(this.moveEl(main, 'ch-move'));
      needIndex = false;
      if (alternatives.length) {
        if (white) out.push(el('span', 'ch-empty', '…'));
        const interrupt = el('div', 'ch-interrupt');
        for (const alt of alternatives) {
          const line = el('div', 'ch-line');
          this.inline(alt, line, true);
          interrupt.append(line);
        }
        out.push(interrupt);
        needIndex = true;
      }
      node = main;
    }
    if (!this.tree.root.children.length && !rootEdit) out.push(el('div', 'ch-moves-empty', 'Play a move on the board, or drag a piece in from a hand.'));
    box.replaceChildren(...out);
    const active = box.querySelector<HTMLElement>('.active');
    if (active) {
      const top = active.offsetTop - box.offsetTop;
      if (top < box.scrollTop || top > box.scrollTop + box.clientHeight - active.offsetHeight) box.scrollTop = top - box.clientHeight / 2;
    } else if (this.current === this.tree.root) box.scrollTop = 0;
  }

  /** A variation written inline: `12...Nf6 13.N@e5 (13.Bd3 P@h6) Qe7`. */
  private inline(start: TreeNode, out: HTMLElement, numbered: boolean) {
    let node = start;
    out.append(this.moveEl(node, 'ch-vmove', numbered));
    let needNumber = false;
    while (node.children.length) {
      const [main, ...alternatives] = node.children;
      out.append(this.moveEl(main, 'ch-vmove', needNumber));
      needNumber = false;
      for (const alt of alternatives) {
        out.append(el('span', 'ch-paren', '('));
        this.inline(alt, out, true);
        out.append(el('span', 'ch-paren', ')'));
        needNumber = true;
      }
      node = main;
    }
  }

  private moveEl(node: TreeNode, cls: string, numbered = false): HTMLElement {
    const b = document.createElement('button');
    b.type = 'button';
    b.className = cls + (node === this.current ? ' active' : '');
    b.dataset.id = node.id;
    const white = node.ply % 2 === 1;
    const number = Math.floor((node.ply + 1) / 2);
    if (cls === 'ch-vmove' && (white || numbered)) b.append(el('span', 'ch-num', `${number}.${white ? '' : '..'}`));
    b.append(document.createTextNode(node.san));
    const edit = handEdit(this.tree.expectedFen(node.id), node.fen);
    if (edit) {
      const chip = el('span', 'ch-edit', edit);
      chip.title = 'Hands edited after this move';
      b.append(chip);
    }
    return b;
  }

  private openMenu(node: TreeNode, x: number, y: number) {
    this.closeMenu();
    const menu = el('div', 'ch-menu');
    menu.setAttribute('role', 'menu');
    const item = (text: string, action: () => void) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.setAttribute('role', 'menuitem');
      b.textContent = text;
      b.onclick = () => { this.closeMenu(); action(); };
      menu.append(b);
    };
    if (!this.tree.isMainline(node.id)) item('Make main line', () => { this.tree.promote(node.id); this.treeChanged(); this.renderMoves(); });
    item('Delete from here', () => {
      const inside = this.tree.path(this.current.id).includes(node);
      const parent = this.tree.delete(node.id);
      this.treeChanged();
      if (inside && parent) this.goTo(parent); else this.renderMoves();
    });
    document.body.append(menu);
    const rect = menu.getBoundingClientRect();
    menu.style.left = `${Math.min(x, innerWidth - rect.width - 8)}px`;
    menu.style.top = `${Math.min(y, innerHeight - rect.height - 8)}px`;
    (menu.querySelector('button') as HTMLButtonElement).focus();
    this.menu = menu;
  }

  private closeMenu() { this.menu?.remove(); this.menu = null; }

  // ── Editor ──────────────────────────────────────────────────────
  private openEditor() {
    if (this.mode === 'editor') return;
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
    this.engine.stop();
    this.closeMenu();
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
    this.tree = new Tree(fen);
    this.evals.clear();
    this.pgnDirty = false;
    this.treeChanged();
    this.goTo(this.tree.root);
  }

  private fenError(error: string | null) {
    const input = $<HTMLInputElement>('ch-fen');
    if (error) input.setAttribute('aria-invalid', 'true'); else input.removeAttribute('aria-invalid');
    $('ch-fen-error').textContent = error ?? '';
  }

  private importPgn() {
    const tree = Tree.fromPgn($<HTMLTextAreaElement>('ch-pgn').value);
    if (!tree) { $('ch-pgn-error').textContent = 'No crazyhouse moves found in that PGN.'; return; }
    $('ch-pgn-error').textContent = '';
    this.tree = tree;
    this.pgnDirty = false;
    this.evals.clear();
    this.treeChanged();
    this.goTo(tree.lineEnd(tree.root.id));
  }

  private updateUrl() {
    const url = new URL(location.href);
    if (this.current.fen === START_FEN) url.searchParams.delete('fen'); else url.searchParams.set('fen', this.current.fen);
    history.replaceState(null, '', url);
  }

  private flash(text: string) {
    $('ch-fen-error').textContent = text;
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
    } else this.renderEditorPanel();
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
  }

  private bind() {
    $('ch-first').onclick = () => this.first();
    $('ch-prev').onclick = () => this.prev();
    $('ch-next').onclick = () => this.next();
    $('ch-last').onclick = () => this.last();
    $('ch-flip').onclick = () => this.flip();
    $('ch-edit').onclick = () => this.mode === 'editor' ? this.closeEditor(false) : this.openEditor();
    $('ch-engine-on').onchange = (e) => this.toggleEngine((e.target as HTMLInputElement).checked);

    const settings = $('ch-settings');
    $('ch-gear').onclick = () => {
      settings.hidden = !settings.hidden;
      $('ch-gear').setAttribute('aria-expanded', String(!settings.hidden));
    };
    const number = (id: string, key: 'multiPv' | 'threads' | 'hashMb', lo: number, hi: number) => {
      const input = $<HTMLInputElement>(id);
      input.min = String(lo);
      input.max = String(hi);
      input.value = String(this.settings[key]);
      input.onchange = () => {
        this.settings[key] = clamp(input.value, lo, hi, this.settings[key]);
        input.value = String(this.settings[key]);
        this.saveSettings();
        if (key === 'multiPv') this.evals.clear();
        this.renderCeval();
        this.analyse();
      };
    };
    number('ch-set-lines', 'multiPv', 1, 5);
    number('ch-set-threads', 'threads', 1, MAX_THREADS);
    number('ch-set-hash', 'hashMb', 16, 512);
    $('ch-set-threads-max').textContent = `of ${MAX_THREADS}`;
    const infinite = $<HTMLInputElement>('ch-set-infinite');
    infinite.checked = this.settings.infinite;
    infinite.onchange = () => { this.settings.infinite = infinite.checked; this.saveSettings(); this.analyse(); };

    $('ch-moves').addEventListener('click', (e) => {
      const id = (e.target as HTMLElement).closest<HTMLElement>('[data-id]')?.dataset.id;
      const node = id && this.tree.get(id);
      if (node) this.goTo(node);
    });
    $('ch-moves').addEventListener('contextmenu', (e) => {
      const id = (e.target as HTMLElement).closest<HTMLElement>('[data-id]')?.dataset.id;
      const node = id && this.tree.get(id);
      if (!node) return;
      e.preventDefault();
      this.openMenu(node, e.clientX, e.clientY);
    });
    document.addEventListener('mousedown', (e) => { if (this.menu && !this.menu.contains(e.target as Node)) this.closeMenu(); });

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

    document.addEventListener('keydown', (e) => this.key(e));
  }

  private flashCopied() {
    const b = $('ch-fen-copy');
    b.textContent = 'Copied';
    setTimeout(() => { b.textContent = 'Copy'; }, 1200);
  }

  private key(e: KeyboardEvent) {
    const target = e.target as HTMLElement;
    if (target.closest('input, textarea, [contenteditable]') || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === 'Escape') {
      if (this.menu) { this.closeMenu(); return; }
      if (this.dropping) { this.dropping = null; this.renderBoard(); this.renderHands(); return; }
      if (this.mode === 'editor') { this.closeEditor(false); return; }
    }
    if (this.mode === 'editor') return;
    const actions: Record<string, () => void> = {
      ArrowLeft: () => this.prev(), ArrowRight: () => this.next(),
      ArrowUp: () => this.first(), ArrowDown: () => this.last(),
      Home: () => this.first(), End: () => this.last(),
      j: () => this.next(), k: () => this.prev(),
      f: () => this.flip(), l: () => this.toggleEngine(), ' ': () => this.playBest(),
    };
    const action = actions[e.key];
    if (!action) return;
    if (target.closest('button') && (e.key === ' ' || e.key === 'Enter')) return;
    e.preventDefault();
    action();
  }
}

function el(tag: string, cls: string, text?: string): HTMLElement {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}

function squareIndex(key: Key): number {
  return (key.charCodeAt(0) - 97) + (Number(key[1]) - 1) * 8;
}

const POINTER_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 11V6a2 2 0 0 0-4 0v0M14 10V4a2 2 0 0 0-4 0v2M10 10.5V6a2 2 0 0 0-4 0v8"/><path d="M18 8a2 2 0 1 1 4 0v6a8 8 0 0 1-8 8h-2c-2.8 0-4.5-.86-5.99-2.34l-3.6-3.6a2 2 0 0 1 2.83-2.82L7 15"/></svg>';
const TRASH_SVG = '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M3 6h18M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6M10 11v6M14 11v6M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"/></svg>';
