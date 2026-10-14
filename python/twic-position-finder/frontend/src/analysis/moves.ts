/**
 * The move list as on lichess.org/analysis: lila's column view with
 * variations interrupting it, or inline notation; fold buttons in disclosure
 * mode; live annotations; the moves after this one to choose from (the fork);
 * and the right-click menu of a move.
 */
import type { Glyph } from './judge';
import type { Settings } from './settings';
import { handEdit, type Tree, type TreeNode } from './tree';

export interface MoveListHost {
  readonly tree: Tree;
  readonly current: TreeNode;
  readonly settings: Settings;
  /** The move's live annotation, when that setting is on and the engine has seen both positions. */
  glyph(node: TreeNode): Glyph | undefined;
  /** The fork choice (↑/↓) among the current position's moves. */
  readonly forkIndex: number;
  goTo(node: TreeNode): void;
  /** The tree changed shape (promote, delete, fold): save it and redraw. */
  treeChanged(): void;
  /** A move and everything after it was deleted. */
  deleted(parent: TreeNode, hadCurrent: boolean): void;
  copied(text: string): void;
}

const GLYPH_CLASS: Record<Glyph['symbol'], string> = { '?!': 'inaccuracy', '?': 'mistake', '??': 'blunder' };

export class MoveList {
  private menu: HTMLElement | null = null;
  /** Moves an open menu item would copy or delete, highlighted as on Lichess. */
  private pending: { ids: Set<string>; kind: 'copy' | 'delete' } | null = null;

  constructor(private readonly box: HTMLElement, private readonly fork: HTMLElement, private readonly host: MoveListHost) {
    box.addEventListener('click', (e) => {
      const target = e.target as HTMLElement;
      const fold = target.closest<HTMLElement>('[data-fold]');
      if (fold) { this.toggleFold(fold.dataset.fold!); return; }
      const node = this.nodeAt(target);
      if (node) host.goTo(node);
    });
    box.addEventListener('contextmenu', (e) => {
      const node = this.nodeAt(e.target as HTMLElement);
      if (!node) return;
      e.preventDefault();
      this.openMenu(node, e.clientX, e.clientY);
    });
    fork.addEventListener('click', (e) => {
      const node = this.nodeAt(e.target as HTMLElement);
      if (node) host.goTo(node);
    });
    document.addEventListener('mousedown', (e) => { if (this.menu && !this.menu.contains(e.target as Node)) this.closeMenu(); });
  }

  get menuOpen(): boolean { return !!this.menu; }

  private nodeAt(target: HTMLElement): TreeNode | undefined {
    const id = target.closest<HTMLElement>('[data-id]')?.dataset.id;
    return id ? this.host.tree.get(id) : undefined;
  }

  render() {
    const { tree, settings } = this.host;
    const out: HTMLElement[] = [];
    const rootEdit = handEdit(tree.loadedFen, tree.root.fen);
    if (rootEdit) out.push(el('div', 'ch-root-edit', `Hands edited at the start: ${rootEdit}`));
    if (settings.inline) out.push(this.inlineView());
    else out.push(...this.columns());
    this.box.classList.toggle('ch-moves-inline', settings.inline);
    this.box.replaceChildren(...out);
    this.renderFork();
    const active = this.box.querySelector<HTMLElement>('.active');
    if (active) {
      const top = active.offsetTop - this.box.offsetTop;
      if (top < this.box.scrollTop || top > this.box.scrollTop + this.box.clientHeight - active.offsetHeight) this.box.scrollTop = top - this.box.clientHeight / 2;
    } else if (this.host.current === tree.root) this.box.scrollTop = 0;
  }

  /** lila's column view: two columns of main-line moves, variations in blocks between them. */
  private columns(): HTMLElement[] {
    const { tree } = this.host;
    const out: HTMLElement[] = [];
    let node = tree.root;
    let needIndex = true;
    for (;;) {
      const main = tree.mainChild(node);
      const alternatives = main ? node.children.slice(1) : node.children;
      if (!main && !alternatives.length) break;
      if (main) {
        const white = main.ply % 2 === 1;
        if (white) out.push(el('index', '', String(Math.floor((main.ply + 1) / 2))));
        else if (needIndex) { out.push(el('index', '', String(Math.floor((main.ply + 1) / 2)))); out.push(el('span', 'ch-empty', '…')); }
        out.push(this.moveEl(main, 'ch-move'));
        needIndex = false;
        if (alternatives.length && white) out.push(el('span', 'ch-empty', '…'));
      }
      if (alternatives.length) {
        out.push(this.interrupt(node, alternatives));
        needIndex = true;
      }
      if (!main) break;
      node = main;
    }
    return out;
  }

  private interrupt(parent: TreeNode, lines: TreeNode[]): HTMLElement {
    const box = el('div', 'ch-interrupt');
    if (this.host.settings.disclosure) {
      box.append(this.foldButton(parent));
      if (parent.collapsed) return box;
    }
    for (const alt of lines) {
      const line = el('div', 'ch-line');
      this.inline(alt, line, true);
      box.append(line);
    }
    return box;
  }

  private foldButton(parent: TreeNode): HTMLElement {
    const folded = !!parent.collapsed;
    const count = parent.children.length - (this.host.tree.mainChild(parent) ? 1 : 0);
    const b = el('button', 'ch-fold', folded ? `+ ${count} ${count === 1 ? 'variation' : 'variations'}` : '−');
    (b as HTMLButtonElement).type = 'button';
    b.dataset.fold = parent.id;
    b.title = folded ? 'Show variations' : 'Hide variations';
    b.setAttribute('aria-expanded', String(!folded));
    return b;
  }

  /** Inline notation: the whole tree as text, variations in brackets. */
  private inlineView(): HTMLElement {
    const box = el('div', 'ch-inline');
    const first = this.host.tree.root.children[0];
    if (!first) return box;
    const root = this.host.tree.root;
    if (root.children.length > 1) this.siblings(root, box);
    else this.inline(first, box, true);
    return box;
  }

  /** All lines from a position written inline: the first, then the others in brackets. */
  private siblings(parent: TreeNode, out: HTMLElement) {
    const [first, ...rest] = parent.children;
    out.append(this.moveEl(first, 'ch-vmove', true));
    this.variations(parent, rest, out);
    this.continueInline(first, out, rest.length > 0);
  }

  private variations(parent: TreeNode, alternatives: TreeNode[], out: HTMLElement) {
    if (!alternatives.length) return;
    if (this.host.settings.disclosure && parent.collapsed) { out.append(this.foldButton(parent)); return; }
    if (this.host.settings.disclosure) out.append(this.foldButton(parent));
    for (const alt of alternatives) {
      out.append(el('span', 'ch-paren', '('));
      this.inline(alt, out, true);
      out.append(el('span', 'ch-paren', ')'));
    }
  }

  /** A line written inline from `start`: `12...Nf6 13.N@e5 (13.Bd3 P@h6) Qe7`. */
  private inline(start: TreeNode, out: HTMLElement, numbered: boolean) {
    out.append(this.moveEl(start, 'ch-vmove', numbered));
    this.continueInline(start, out, false);
  }

  private continueInline(from: TreeNode, out: HTMLElement, needNumber: boolean) {
    let node = from;
    let number = needNumber;
    while (node.children.length) {
      const [main, ...alternatives] = node.children;
      out.append(this.moveEl(main, 'ch-vmove', number));
      number = false;
      if (alternatives.length) { this.variations(node, alternatives, out); number = true; }
      node = main;
    }
  }

  private moveEl(node: TreeNode, cls: string, numbered = false): HTMLElement {
    const { current, tree } = this.host;
    const b = document.createElement('button');
    b.type = 'button';
    b.className = cls + (node === current ? ' active' : '');
    if (this.pending?.ids.has(node.id)) b.classList.add(`ch-pending-${this.pending.kind}`);
    b.dataset.id = node.id;
    const white = node.ply % 2 === 1;
    const number = Math.floor((node.ply + 1) / 2);
    if (cls === 'ch-vmove' && (white || numbered)) b.append(el('span', 'ch-num', `${number}.${white ? '' : '..'}`));
    b.append(document.createTextNode(node.san));
    const glyph = this.host.glyph(node);
    if (glyph) {
      const g = el('span', `ch-glyph ch-glyph-${GLYPH_CLASS[glyph.symbol]}`, glyph.symbol);
      g.title = glyph.name;
      b.append(g);
      b.classList.add(`ch-move-${GLYPH_CLASS[glyph.symbol]}`);
    }
    const edit = handEdit(tree.expectedFen(node.id), node.fen);
    if (edit) {
      const chip = el('span', 'ch-edit', edit);
      chip.title = 'Hands edited after this move';
      b.append(chip);
    }
    return b;
  }

  /** The moves already played from here when there is more than one (Lichess's fork). */
  private renderFork() {
    const { current } = this.host;
    if (current.children.length < 2) { this.fork.hidden = true; this.fork.replaceChildren(); return; }
    this.fork.hidden = false;
    this.fork.replaceChildren(...current.children.map((child, i) => {
      const b = this.moveEl(child, 'ch-vmove', true);
      b.classList.remove('active');
      b.classList.toggle('selected', i === this.host.forkIndex);
      return b;
    }));
  }

  private toggleFold(id: string) {
    const node = this.host.tree.get(id);
    if (!node) return;
    if (node.collapsed) delete node.collapsed; else node.collapsed = true;
    this.host.treeChanged();
  }

  // ── Right-click menu (lila treeView/contextMenu.ts) ─────────────
  openMenu(node: TreeNode, x: number, y: number) {
    this.closeMenu();
    const { tree } = this.host;
    const menu = el('div', 'ch-menu');
    menu.setAttribute('role', 'menu');
    const white = node.ply % 2 === 1;
    menu.append(el('p', 'ch-menu-title', `${Math.floor((node.ply + 1) / 2)}${white ? '.' : '...'} ${node.san}`));
    const item = (glyph: keyof typeof GLYPHS, text: string, action: () => void, preview?: { ids: Set<string>; kind: 'copy' | 'delete' }) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.setAttribute('role', 'menuitem');
      b.innerHTML = `<svg viewBox="0 0 512 512" fill="currentColor" aria-hidden="true"><path d="${GLYPHS[glyph]}"/></svg>`;
      b.append(text);
      b.onclick = () => { this.closeMenu(); action(); };
      if (preview) {
        const show = (on: boolean) => { this.pending = on ? preview : null; this.render(); };
        b.onmouseenter = () => show(true);
        b.onmouseleave = () => show(false);
        b.onfocus = () => show(true);
        b.onblur = () => show(false);
      }
      menu.append(b);
    };
    const onMainline = tree.isMainline(node.id);
    if (this.host.settings.disclosure && tree.someCollapsible(false)) item('collapse', 'Collapse all', () => { tree.setCollapsedAll(true); this.host.treeChanged(); });
    if (this.host.settings.disclosure && tree.someCollapsible(true)) item('expand', 'Expand all', () => { tree.setCollapsedAll(false); this.host.treeChanged(); });
    if (!onMainline && this.canPromote(node)) item('promote', 'Promote variation', () => { tree.promote(node.id, false); this.host.treeChanged(); });
    if (!onMainline) item('mainline', 'Make main line', () => { tree.promote(node.id, true); this.host.treeChanged(); });
    if (onMainline) item('force', 'Force variation', () => { tree.setForceVariation(node.id, true); this.host.treeChanged(); });
    const copy = tree.copyLine(node.id, !onMainline);
    item('copy', onMainline ? 'Copy main line PGN' : 'Copy variation PGN', () => this.host.copied(copy.pgn), { ids: copy.ids, kind: 'copy' });
    const below = new Set<string>();
    const walk = (n: TreeNode) => { below.add(n.id); n.children.forEach(walk); };
    walk(node);
    item('delete', 'Delete from here', () => {
      const hadCurrent = tree.path(this.host.current.id).includes(node);
      const parent = tree.delete(node.id);
      if (parent) this.host.deleted(parent, hadCurrent);
    }, { ids: below, kind: 'delete' });
    document.body.append(menu);
    const rect = menu.getBoundingClientRect();
    menu.style.left = `${Math.max(8, Math.min(x, innerWidth - rect.width - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(y, innerHeight - rect.height - 8))}px`;
    menu.querySelector<HTMLButtonElement>('button')?.focus();
    this.menu = menu;
  }

  /** Lichess offers "Promote variation" unless the move already heads the first variation of its main-line fork. */
  private canPromote(node: TreeNode): boolean {
    const { tree } = this.host;
    let fork: TreeNode = tree.root;
    for (const n of tree.path(node.id)) { if (tree.isMainline(n.id)) fork = n; else break; }
    for (let it: TreeNode | undefined = fork.children[1]; it; it = it.children[0]) if (it === node) return false;
    return true;
  }

  closeMenu() {
    if (!this.menu) return;
    this.menu.remove();
    this.menu = null;
    if (this.pending) { this.pending = null; this.render(); }
  }
}

/** Lichess's context-menu glyphs (lila public/font/lichess.ttf), 512-unit outlines. */
const GLYPHS = {
  collapse: 'M293 293H384Q391 293 397 287Q402 282 402 274V238Q402 230 397 225Q391 219 384 219L212 220L128 219Q121 219 115 225Q110 230 110 238V274Q110 282 115 287Q121 293 128 293ZM475 119V393Q475 427 451 451Q427 475 393 475H119Q85 475 61 451Q37 427 37 393V119Q37 85 61 61Q85 37 119 37H393Q427 37 451 61Q475 85 475 119Z',
  expand: 'M402 274V238Q402 230 397 225Q391 219 384 219H293V128Q293 121 287 115Q282 110 274 110H238Q230 110 225 115Q219 121 219 128V219H128Q121 219 115 225Q110 230 110 238V274Q110 282 115 287Q121 293 128 293H219V384Q219 391 225 397Q230 402 238 402H274Q282 402 287 397Q293 391 293 384V293H384Q391 293 397 287Q402 282 402 274ZM475 119V393Q475 427 451 451Q427 475 393 475H119Q85 475 61 451Q37 427 37 393V119Q37 85 61 61Q85 37 119 37H393Q427 37 451 61Q475 85 475 119Z',
  promote: 'M480 352 256 128 32 352Z',
  mainline: 'M469 181 263 388 224 427Q214 435 204 435Q193 435 185 427L43 285Q35 277 35 265Q35 253 43 246L81 207Q91 199 101 199Q112 199 120 207L204 291L392 103Q400 95 411 95Q421 95 431 103L469 142Q477 150 477 162Q477 174 469 181Z',
  force: 'M369 269 214 424Q208 430 201 430Q194 430 188 424Q183 419 183 411V329H55Q49 329 42 324Q37 319 37 311V201Q37 193 42 188Q49 183 55 183H183V101Q183 93 188 88Q194 82 201 82Q208 82 214 88L369 243Q375 249 375 256Q375 263 369 269ZM475 155V357Q475 391 451 415Q427 439 393 439H302Q298 439 295 436Q293 434 293 430L292 428Q292 426 292 424V416Q292 415 292.5 413Q293 411 293 410Q293 406 296 404Q298 402 302 402H393Q412 402 425 389Q439 375 439 357V155Q439 137 425 123Q412 110 393 110H304Q303 110 301 109H297Q297 108 295 107Q293 105 293 104V101L292 99Q292 97 292 95V87Q292 86 292.5 84Q293 82 293 81Q293 76 296 75Q298 73 302 73H393Q427 73 451 97Q475 121 475 155Z',
  copy: 'M384 64Q410 64 429 83Q448 102 448 128V448Q448 475 429.5 493.5Q411 512 384 512H128Q101 512 82.5 493.5Q64 475 64 448V128Q64 101 82.5 82.5Q101 64 128 64H178Q183 36 205 18Q227 0 256 0Q285 0 306.5 18Q328 36 334 64ZM273 55Q266 48 256 48Q246 48 239 55Q232 62 232 72Q232 82 239 89Q246 96 256 96Q266 96 273 89Q280 82 280 72Q280 62 273 55ZM400 448V128Q400 121 395.5 116.5Q391 112 384 112H366Q368 121 368 128V144Q368 151 363.5 155.5Q359 160 352 160H160Q153 160 148.5 155.5Q144 151 144 144V128Q144 121 146 112H128Q121 112 116.5 116.5Q112 121 112 128V448Q112 455 116.5 459.5Q121 464 128 464H384Q391 464 395.5 459.5Q400 455 400 448Z',
  delete: 'M201 210V375Q201 379 199 381Q196 384 192 384H174Q170 384 167 381Q165 380 165 375V210Q165 205 167 204Q170 201 174 201H192Q196 201 199 204Q201 206 201 210ZM274 210V375Q274 379 272 381Q269 384 265 384H247Q243 384 240 381Q238 379 238 375V210Q238 206 240 204Q243 201 247 201H265Q269 201 272 204Q274 206 274 210ZM347 210V375Q347 380 345 381Q342 384 338 384H320Q316 384 313 381Q311 379 311 375V210Q311 206 313 204Q316 201 320 201H338Q342 201 345 204Q347 205 347 210ZM384 417V146H128V417Q128 421 130 429Q132 434 134 436L137 439H375L378 436Q380 434 382 429Q384 421 384 417ZM192 110H320L306 76Q305 75 301 73H211Q207 75 206 76ZM457 119V137Q457 140 455 144Q451 146 448 146H421V417Q421 441 407 458Q394 475 375 475H137Q118 475 105 459Q91 442 91 418V146H64Q61 146 57 144Q55 140 55 137V119Q55 116 57 112Q61 110 64 110H152L172 62Q177 51 188 44Q198 37 210 37H302Q314 37 324 44Q335 51 340 62L360 110H448Q451 110 455 112Q457 116 457 119Z',
};

export function el(tag: string, cls: string, text?: string): HTMLElement {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
