/**
 * The move tree of one standard chess game, as lichess.org/analysis keeps
 * it: variations, comments and annotation glyphs ($1, $2…) on each move,
 * lila's "force variation" and folded variations. Positions are chessops'.
 * A game is read from PGN and written back to PGN with chessops, so
 * comments with clock and eval tokens survive a round trip untouched.
 *
 * Moves are kept in standard UCI (castling `e1g1`), the form Stockfish and
 * Maia read; chessops' own form (king takes rook) is used only inside.
 */
import { Chess, normalizeMove } from 'chessops/chess';
import { chessgroundDests } from 'chessops/compat';
import { INITIAL_FEN, makeFen, parseFen } from 'chessops/fen';
import { ChildNode, Node as PgnNode, emptyHeaders, makePgn, parsePgn, startingPosition, type Game, type PgnNodeData } from 'chessops/pgn';
import { makeSan, parseSan } from 'chessops/san';
import type { Move, SquareName } from 'chessops/types';
import { makeSquare, parseUci } from 'chessops/util';

export const START_FEN = INITIAL_FEN;

export interface TreeNode {
  id: string;
  ply: number;
  /** The move from the parent in standard UCI (`e1g1` for O-O); empty at the root. */
  uci: string;
  san: string;
  fen: string;
  /** Comments after the move (at the root: before the first move). */
  comments?: string[];
  /** Comments written before the move, at the start of a variation. */
  before?: string[];
  /** Numeric annotation glyphs: 1 is !, 2 is ?, 3 is !!, 4 is ??, 5 is !?, 6 is ?!. */
  nags?: number[];
  forceVariation?: boolean;
  collapsed?: boolean;
  children: TreeNode[];
}

export type PositionResult = { ok: true; pos: Chess } | { ok: false; error: string };

const ERRORS: Record<string, string> = {
  ERR_EMPTY: 'The board is empty.',
  ERR_KINGS: 'Each side needs exactly one king.',
  ERR_OPPOSITE_CHECK: 'The side not to move is in check.',
  ERR_PAWNS_ON_BACKRANK: 'Pawns cannot stand on the first or last rank.',
  ERR_VARIANT: 'That position is not standard chess.',
};

export function readFen(fen: string): PositionResult {
  const setup = parseFen(fen.trim());
  if (setup.isErr) return { ok: false, error: 'That is not a FEN.' };
  const pos = Chess.fromSetup(setup.value);
  if (pos.isErr) return { ok: false, error: ERRORS[pos.error.message] ?? 'That position is not playable.' };
  return { ok: true, pos: pos.value };
}

export function positionOf(fen: string): Chess {
  const read = readFen(fen);
  if (!read.ok) throw new Error(read.error);
  return read.pos;
}

export const fenOf = (pos: Chess): string => makeFen(pos.toSetup());

/** A FEN without the move counters: the same position reached by another move order. */
export const positionKey = (fen: string): string => fen.split(' ').slice(0, 4).join(' ');

/** Checkmate, stalemate or a draw the rules declare; null while play goes on. */
export function outcomeOf(fen: string): 'Checkmate' | 'Stalemate' | 'Draw' | null {
  const pos = positionOf(fen);
  if (pos.isCheckmate()) return 'Checkmate';
  if (pos.isStalemate()) return 'Stalemate';
  if (pos.isInsufficientMaterial() || pos.halfmoves >= 100) return 'Draw';
  return null;
}

/** Chessground's destinations, with both forms of castling. */
export function boardDests(fen: string): Map<SquareName, SquareName[]> {
  return chessgroundDests(positionOf(fen));
}

/** A legal move from standard or chessops UCI, in chessops' form. */
export function readMove(pos: Chess, uci: string): Move | undefined {
  const raw = parseUci(uci);
  if (!raw) return undefined;
  const move = normalizeMove(pos, raw);
  return pos.isLegal(move) ? move : undefined;
}

/** A legal move as standard UCI: castling is the king's two-square step. */
export function standardUci(pos: Chess, move: Move): string {
  if (!('from' in move)) return '';
  const from = makeSquare(move.from), to = makeSquare(move.to);
  const piece = pos.board.get(move.from);
  if (piece?.role === 'king' && pos.board.get(move.to)?.color === piece.color)
    return from + (move.to > move.from ? 'g' : 'c') + from[1];
  return from + to + (move.promotion ? (move.promotion === 'knight' ? 'n' : move.promotion[0]) : '');
}

export interface LineMove { uci: string; san: string; fen: string }

/** UCI moves played from a position, with SAN and the position after each, stopping at the first that is not legal. */
export function playLine(fen: string, ucis: string[], limit = ucis.length): LineMove[] {
  const pos = positionOf(fen);
  const out: LineMove[] = [];
  for (const uci of ucis.slice(0, limit)) {
    const move = readMove(pos, uci);
    if (!move) break;
    const san = makeSan(pos, move);
    const standard = standardUci(pos, move);
    pos.play(move);
    out.push({ uci: standard, san, fen: fenOf(pos) });
  }
  return out;
}

/** The position with the other side to move, for "Show threat"; null when that position is not legal. */
export function threatFen(fen: string): string | null {
  const fields = fen.split(' ');
  fields[1] = fields[1] === 'w' ? 'b' : 'w';
  fields[3] = '-';
  const next = fields.join(' ');
  return readFen(next).ok ? next : null;
}

/** The annotation glyphs lila shows for the first six NAGs. */
export const NAG_SYMBOL: Record<number, string> = { 1: '!', 2: '?', 3: '!!', 4: '??', 5: '!?', 6: '?!' };
const SYMBOL_NAG: Record<string, number> = { '!': 1, '?': 2, '!!': 3, '??': 4, '!?': 5, '?!': 6 };

let nextId = 0;
const newId = () => `m${++nextId}`;

function plyOf(fen: string): number {
  const parts = fen.trim().split(/\s+/);
  const full = Number(parts[5] ?? 1) || 1;
  return (full - 1) * 2 + (parts[1] === 'b' ? 1 : 0);
}

export class Tree {
  root: TreeNode;
  headers: Map<string, string>;
  private parents = new Map<string, TreeNode | null>();
  private byId = new Map<string, TreeNode>();

  constructor(fen = START_FEN, headers?: Map<string, string>) {
    this.root = { id: newId(), ply: plyOf(fen), uci: '', san: '', fen, children: [] };
    this.headers = headers ?? new Map();
    this.index(this.root, null);
  }

  private index(node: TreeNode, parent: TreeNode | null) {
    this.byId.set(node.id, node);
    this.parents.set(node.id, parent);
    for (const child of node.children) this.index(child, node);
  }

  private unindex(node: TreeNode) {
    this.byId.delete(node.id);
    this.parents.delete(node.id);
    for (const child of node.children) this.unindex(child);
  }

  get(id: string): TreeNode | undefined { return this.byId.get(id); }
  parent(id: string): TreeNode | null { return this.parents.get(id) ?? null; }

  /** The nodes from the root to this one. */
  path(id: string): TreeNode[] {
    const out: TreeNode[] = [];
    for (let n: TreeNode | null | undefined = this.get(id); n; n = this.parent(n.id)) out.unshift(n);
    return out;
  }

  /** The child indexes from the root to a node, as kept between visits. */
  indexPath(id: string): number[] {
    const nodes = this.path(id);
    return nodes.slice(1).map((n, i) => nodes[i].children.indexOf(n));
  }

  /** The node at child indexes from the root, as far as they lead. */
  follow(path: number[]): TreeNode {
    let node = this.root;
    for (const i of path) {
      const next = node.children[i];
      if (!next) break;
      node = next;
    }
    return node;
  }

  /** The node and its first children to the end of its line. */
  lineEnd(id: string): TreeNode {
    let node = this.get(id)!;
    while (node.children.length) node = node.children[0];
    return node;
  }

  isMainline(id: string): boolean {
    return this.path(id).every((n, i, all) => i === 0 || (all[i - 1].children[0] === n && !n.forceVariation));
  }

  /** The child that continues the main line from here, if any (a forced variation does not). */
  mainChild(node: TreeNode): TreeNode | undefined {
    const first = node.children[0];
    return first && !first.forceVariation ? first : undefined;
  }

  /** The nearest position before this one where the line forks, as Lichess's shift+←. */
  previousBranch(id: string): TreeNode {
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
  nextBranch(id: string, choice = 0): TreeNode {
    const from = this.get(id)!;
    let node = from.children[choice] ?? from.children[0];
    if (!node) return from;
    while (node.children.length === 1) node = node.children[0];
    return node;
  }

  /** The first move of the next or previous sibling line at the nearest fork, as Lichess's shift+↑/↓. */
  stepLine(id: string, which: 'next' | 'prev'): TreeNode {
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

  /** Plays a move after a node, reusing an existing child with that move. */
  play(id: string, uci: string): TreeNode | null {
    const parent = this.get(id)!;
    const pos = positionOf(parent.fen);
    const move = readMove(pos, uci);
    if (!move) return null;
    const standard = standardUci(pos, move);
    const existing = parent.children.find((c) => c.uci === standard);
    if (existing) return existing;
    const san = makeSan(pos, move);
    pos.play(move);
    const child: TreeNode = { id: newId(), ply: parent.ply + 1, uci: standard, san, fen: fenOf(pos), children: [] };
    parent.children.push(child);
    this.index(child, parent);
    return child;
  }

  delete(id: string): TreeNode | null {
    const parent = this.parent(id);
    if (!parent) return null;
    const node = this.get(id)!;
    parent.children = parent.children.filter((c) => c !== node);
    this.unindex(node);
    return parent;
  }

  /** Lichess's "Promote variation" (one fork up) and "Make main line" (every fork to the root). */
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

  setForceVariation(id: string, on: boolean) {
    const node = this.get(id)!;
    if (on) node.forceVariation = true; else delete node.forceVariation;
  }

  someCollapsible(collapsed: boolean): boolean {
    const walk = (n: TreeNode): boolean => (n.children.length > 1 && !!n.collapsed === collapsed) || n.children.some(walk);
    return walk(this.root);
  }

  setCollapsedAll(collapsed: boolean) {
    const walk = (n: TreeNode) => {
      if (n.children.length > 1) { if (collapsed) n.collapsed = true; else delete n.collapsed; }
      n.children.forEach(walk);
    };
    walk(this.root);
  }

  /** Sets the comment after a move (or before the first move, at the root); empty text removes it. */
  setComment(id: string, text: string) {
    const node = this.get(id)!;
    const clean = text.trim();
    if (clean) node.comments = [clean]; else delete node.comments;
  }

  /**
   * Lichess's "Copy main line PGN" / "Copy variation PGN": the moves from the
   * start to this one and what follows it, the variations after it only for a
   * variation. Also returns the nodes it covers, to highlight before copying.
   */
  copyLine(id: string, withVariations: boolean): { pgn: string; ids: Set<string> } {
    const path = this.path(id);
    const ids = new Set(path.slice(1).map((n) => n.id));
    const end = path[path.length - 1];
    const collect = (n: TreeNode) => {
      const kids = withVariations ? n.children : n.children.slice(0, 1);
      for (const k of kids) { ids.add(k.id); collect(k); }
    };
    collect(end);
    const keep = (n: TreeNode) => ids.has(n.id);
    return { pgn: this.pgn(keep), ids };
  }

  /** The game as PGN, its headers first; `keep` leaves out the moves it refuses. */
  pgn(keep: (n: TreeNode) => boolean = () => true): string {
    const headers = new Map(this.headers);
    if (!headers.has('Result')) headers.set('Result', '*');
    if (this.root.fen !== START_FEN) { headers.set('FEN', this.root.fen); headers.set('SetUp', '1'); }
    else { headers.delete('FEN'); headers.delete('SetUp'); }
    const write = (from: TreeNode, to: PgnNode<PgnNodeData>) => {
      for (const child of from.children) {
        if (!keep(child)) continue;
        const data: PgnNodeData = { san: child.san };
        if (child.comments?.length) data.comments = [...child.comments];
        if (child.before?.length) data.startingComments = [...child.before];
        if (child.nags?.length) data.nags = [...child.nags];
        const node = new ChildNode(data);
        to.children.push(node);
        write(child, node);
      }
    };
    const game: Game<PgnNodeData> = { headers, moves: new PgnNode<PgnNodeData>(), comments: this.root.comments ? [...this.root.comments] : undefined };
    write(this.root, game.moves);
    return makePgn(game);
  }

  /** A tree from one chessops game; moves that do not play are left out with what follows them. */
  static fromGame(game: Game<PgnNodeData>): { tree: Tree; skipped: number } {
    const start = startingPosition(game.headers);
    const fen = start.isOk && start.value.rules === 'chess' ? fenOf(start.value as Chess) : START_FEN;
    const headers = new Map(game.headers);
    headers.delete('FEN');
    headers.delete('SetUp');
    const tree = new Tree(fen, headers);
    if (game.comments?.length) tree.root.comments = [...game.comments];
    let skipped = 0;
    // Iterative, so a long main line stays off the call stack.
    const stack: [PgnNode<PgnNodeData>, TreeNode][] = [[game.moves, tree.root]];
    while (stack.length) {
      const [pgnNode, node] = stack.pop()!;
      const pos = positionOf(node.fen);
      for (const child of pgnNode.children) {
        const san = child.data.san.replace(/[!?]+$/, '');
        const move = parseSan(pos, san);
        const next = move ? tree.play(node.id, standardUci(pos, move)) : null;
        if (!next) { skipped++; continue; }
        if (child.data.comments?.length) next.comments = [...child.data.comments];
        if (child.data.startingComments?.length) next.before = [...child.data.startingComments];
        const suffix = /[!?]+$/.exec(child.data.san)?.[0];
        const nags = [...(child.data.nags ?? []), ...(suffix && SYMBOL_NAG[suffix] ? [SYMBOL_NAG[suffix]] : [])];
        if (nags.length) next.nags = nags;
        stack.push([child, next]);
      }
    }
    return { tree, skipped };
  }

  /** The first game of a PGN text, or null when it holds none. */
  static fromPgn(text: string): { tree: Tree; skipped: number } | null {
    const game = parsePgn(text, emptyHeaders)[0];
    if (!game) return null;
    return Tree.fromGame(game);
  }
}

/** A comment as shown: lila hides the [%clk] and [%eval] tokens. */
export function commentText(comment: string): string {
  return comment.replace(/\[%[^\]]*\]/g, '').replace(/\s+/g, ' ').trim();
}

/** "Carlsen – Nakamura", or the event, or a fallback for a game without names. */
export function gameTitle(headers: Map<string, string> | Record<string, string>, fallback: string): string {
  const get = (k: string) => headerValue(headers, k);
  const white = get('White'), black = get('Black');
  if (white || black) return `${white || '?'} – ${black || '?'}`;
  return get('Event') || fallback;
}

/** A header's value, or empty where it is missing or only the PGN placeholder (`?`, `????.??.??`). */
export function headerValue(headers: Map<string, string> | Record<string, string>, key: string): string {
  const v = (headers instanceof Map ? headers.get(key) : headers[key]) ?? '';
  return /^[?.\s-]*$/.test(v) ? '' : v.replace(/\.\?\?/g, '');
}
