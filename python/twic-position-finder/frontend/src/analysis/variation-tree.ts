/**
 * The shape of lichess.org/analysis's move tree, whatever the rules: nodes
 * with variations, lila's "force variation" and folded variations, and the
 * ways of walking and reordering them. The bughouse board (`tree.ts`) and the
 * PGN page (`../prep/tree.ts`) extend it with playing moves, hands, comments
 * and PGN.
 */

export interface VariationNode {
  id: string;
  ply: number;
  /** The move from the parent, as UCI; empty at the root. */
  uci: string;
  san: string;
  fen: string;
  /** A first child shown as a variation, as Lichess's "Force variation". */
  forceVariation?: boolean;
  /** The variations after this position are folded away. */
  collapsed?: boolean;
  children: this[];
}

/** A move of a line with its SAN and the position after it. */
export interface LineMove { uci: string; san: string; fen: string }

let nextId = 0;
export const newId = () => `n${++nextId}`;

/** The ply of a FEN's position, from its side to move and move number. */
export function plyOf(fen: string): number {
  const parts = fen.trim().split(/\s+/);
  const full = Number(parts[5] ?? 1) || 1;
  return (full - 1) * 2 + (parts[1] === 'b' ? 1 : 0);
}

export abstract class VariationTree<N extends VariationNode> {
  root: N;
  private parents = new Map<string, N | null>();
  private byId = new Map<string, N>();

  constructor(root: N) {
    this.root = root;
    this.index(root, null);
  }

  protected index(node: N, parent: N | null) {
    this.byId.set(node.id, node);
    this.parents.set(node.id, parent);
    for (const child of node.children) this.index(child, node);
  }

  protected unindex(node: N) {
    this.byId.delete(node.id);
    this.parents.delete(node.id);
    for (const child of node.children) this.unindex(child);
  }

  get(id: string): N | undefined { return this.byId.get(id); }
  parent(id: string): N | null { return this.parents.get(id) ?? null; }

  /** The nodes from the root to this one. */
  path(id: string): N[] {
    const out: N[] = [];
    for (let n: N | null | undefined = this.get(id); n; n = this.parent(n.id)) out.unshift(n);
    return out;
  }

  /** The child indexes from the root to a node, as kept between visits. */
  indexPath(id: string): number[] {
    const nodes = this.path(id);
    return nodes.slice(1).map((n, i) => nodes[i].children.indexOf(n));
  }

  /** The node at child indexes from the root, as far as they lead. */
  follow(path: number[]): N {
    let node = this.root;
    for (const i of path) {
      const next = node.children[i];
      if (!next) break;
      node = next;
    }
    return node;
  }

  /** The node and its first children to the end of its line. */
  lineEnd(id: string): N {
    let node = this.get(id)!;
    while (node.children.length) node = node.children[0];
    return node;
  }

  /** On the main line: every move is its parent's first child, and none is a forced variation. */
  isMainline(id: string): boolean {
    return this.path(id).every((n, i, all) => i === 0 || (all[i - 1].children[0] === n && !n.forceVariation));
  }

  /** The child that continues the main line from here, if any (a forced variation does not). */
  mainChild(node: N): N | undefined {
    const first = node.children[0];
    return first && !first.forceVariation ? first : undefined;
  }

  /** The nearest position before this one where the line forks, as Lichess's shift+←. */
  previousBranch(id: string): N {
    let node = this.parent(id);
    if (!node) return this.get(id)!;
    while (node.children.length < 2) {
      const up = this.parent(node.id);
      if (!up) break;
      node = up;
    }
    return node;
  }

  /** The next position along `choice` (then first moves) where the line forks; the line's end when none. */
  nextBranch(id: string, choice = 0): N {
    const from = this.get(id)!;
    let node = from.children[choice] ?? from.children[0];
    if (!node) return from;
    while (node.children.length === 1) node = node.children[0];
    return node;
  }

  /** The first move of the next or previous sibling line at the nearest fork, as Lichess's shift+↑/↓. */
  stepLine(id: string, which: 'next' | 'prev'): N {
    let child = this.get(id)!;
    let parent = this.parent(id);
    while (parent && parent.children.length < 2 && !this.isMainline(parent.id)) {
      child = parent;
      parent = this.parent(parent.id);
    }
    if (!parent) return this.get(id)!;
    const kids = parent.children, i = kids.indexOf(child);
    const to = which === 'next' ? kids[i + 1] ?? kids[0] : kids[i - 1] ?? kids[kids.length - 1];
    return to ?? this.get(id)!;
  }

  /** Adds a played move under its parent. */
  protected attach(parent: N, child: N) {
    parent.children.push(child);
    this.index(child, parent);
  }

  delete(id: string): N | null {
    const parent = this.parent(id);
    if (!parent) return null;
    const node = this.get(id)!;
    parent.children = parent.children.filter((c) => c !== node);
    this.unindex(node);
    return parent;
  }

  /**
   * Lichess's "Promote variation" (one fork up) and "Make main line" (every
   * fork to the root). A forced variation on the way counts as one step.
   */
  promote(id: string, toMainline: boolean) {
    const nodes = this.path(id);
    for (let i = nodes.length - 1; i > 0; i--) {
      const node = nodes[i], parent = nodes[i - 1];
      if (parent.children[0] !== node) {
        parent.children = [node, ...parent.children.filter((c) => c !== node)];
        if (!toMainline) return;
      } else if (node.forceVariation) {
        delete node.forceVariation;
        if (!toMainline) return;
      }
    }
  }

  /** Shows a main-line move as a variation, or back. */
  setForceVariation(id: string, on: boolean) {
    const node = this.get(id)!;
    if (on) node.forceVariation = true; else delete node.forceVariation;
  }

  /** Whether any variation can be folded (`collapsed` false) or unfolded (true). */
  someCollapsible(collapsed: boolean): boolean {
    const walk = (n: N): boolean => (n.children.length > 1 && !!n.collapsed === collapsed) || n.children.some(walk);
    return walk(this.root);
  }

  setCollapsedAll(collapsed: boolean) {
    const walk = (n: N) => {
      if (n.children.length > 1) { if (collapsed) n.collapsed = true; else delete n.collapsed; }
      n.children.forEach(walk);
    };
    walk(this.root);
  }

  /**
   * Lichess's "Copy main line PGN" / "Copy variation PGN": the moves from the
   * start to this one and what follows it, the variations after it only for a
   * variation. Also returns the nodes it covers, to highlight before copying.
   */
  abstract copyLine(id: string, withVariations: boolean): { pgn: string; ids: Set<string> };
}
