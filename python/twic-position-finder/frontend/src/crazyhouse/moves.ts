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
    if (!tree.root.children.length && !rootEdit) out.push(el('div', 'ch-moves-empty', 'Play a move on the board, or drag a piece in from a hand.'));
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
    const item = (text: string, action: () => void, preview?: { ids: Set<string>; kind: 'copy' | 'delete' }) => {
      const b = document.createElement('button');
      b.type = 'button';
      b.setAttribute('role', 'menuitem');
      b.textContent = text;
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
    if (this.host.settings.disclosure && tree.someCollapsible(false)) item('Collapse all', () => { tree.setCollapsedAll(true); this.host.treeChanged(); });
    if (this.host.settings.disclosure && tree.someCollapsible(true)) item('Expand all', () => { tree.setCollapsedAll(false); this.host.treeChanged(); });
    if (!onMainline && this.canPromote(node)) item('Promote variation', () => { tree.promote(node.id, false); this.host.treeChanged(); });
    if (!onMainline) item('Make main line', () => { tree.promote(node.id, true); this.host.treeChanged(); });
    if (onMainline) item('Force variation', () => { tree.setForceVariation(node.id, true); this.host.treeChanged(); });
    const copy = tree.copyLine(node.id, !onMainline);
    item(onMainline ? 'Copy main line PGN' : 'Copy variation PGN', () => this.host.copied(copy.pgn), { ids: copy.ids, kind: 'copy' });
    const below = new Set<string>();
    const walk = (n: TreeNode) => { below.add(n.id); n.children.forEach(walk); };
    walk(node);
    item('Delete from here', () => {
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

export function el(tag: string, cls: string, text?: string): HTMLElement {
  const e = document.createElement(tag);
  if (cls) e.className = cls;
  if (text !== undefined) e.textContent = text;
  return e;
}
