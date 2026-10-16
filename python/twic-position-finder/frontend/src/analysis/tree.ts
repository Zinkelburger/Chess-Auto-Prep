/**
 * The analysis tree for one bughouse board, with hands that can be edited
 * between moves. A hand edit is kept on its node as a change against the
 * position its move produced, and is carried through every move after it, as
 * material arriving from a partner would be. Replaying after an earlier edit
 * re-applies each later edit; a continuation that is no longer legal (a drop
 * of a piece no longer in hand) is cut. The tree never checks material counts: any hand chessops accepts
 * is allowed (no kings, at most 64 pieces), capped per piece.
 *
 * Bughouse rules for one board, as the engine plays them with its partner board held still:
 * a capture leaves the board for the partner instead of going to the
 * capturer's hand, and pieces arrive only through a hand edit. Positions are
 * kept in chessops' crazyhouse form, which reads and writes hands in FENs.
 */
import { makeFen, parseFen, INITIAL_FEN } from 'chessops/fen';
import { makeSan as chessopsSan, parseSan } from 'chessops/san';
import { parsePgn, startingPosition, type PgnNodeData, type Node as PgnNode } from 'chessops/pgn';
import { Crazyhouse } from 'chessops/variant';
import { makeSquare, makeUci, parseUci } from 'chessops/util';
import { normalizeMove } from 'chessops/chess';
import { chessgroundDests } from 'chessops/compat';
import type { Color, Move, Role, SquareName } from 'chessops/types';
import { VariationTree, newId, plyOf, type LineMove, type VariationNode } from './variation-tree';

export const START_FEN = INITIAL_FEN.replace(' w ', '[] w ');
/** The most of one piece a hand holds (a full board's worth of pawns and then some). */
export const MAX_IN_HAND = 16;
export const HAND_ROLES: Role[] = ['pawn', 'knight', 'bishop', 'rook', 'queen'];
const LETTER: Record<Role, string> = { pawn: 'p', knight: 'n', bishop: 'b', rook: 'r', queen: 'q', king: 'k' };

/** Plays a legal move by bughouse rules: chessops banks a capture in the mover's hand, but it goes to the partner. */
function playMove(pos: Crazyhouse, move: Move) {
  const turn = pos.turn;
  const hand = pos.pockets![turn].clone();
  pos.play(move);
  if ('role' in move) hand[move.role]--;
  pos.pockets![turn] = hand;
}

/** Checkmate or stalemate; null while play goes on. */
export function outcomeOf(fen: string): 'Checkmate' | 'Stalemate' | null {
  const pos = positionOf(fen);
  return pos.isCheckmate() ? 'Checkmate' : pos.isStalemate() ? 'Stalemate' : null;
}

export interface TreeNode extends VariationNode {
  /** The move from the parent, as UCI (`e2e4`, `N@f3`); empty at the root. */
  uci: string;
  /** The hand edit made at this position, if any. */
  hand?: HandDelta;
}

/** A tree as kept in the browser between visits: moves, hand edits and folds, replayed on load. */
export interface SavedTree {
  loadedFen: string;
  root: SavedNode;
  current: number[];
}
interface SavedNode { uci: string; hand?: HandDelta; fv?: true; c?: true; children: SavedNode[] }

/** Pieces added to (or, negative, taken from) the hands at one position. */
export type HandDelta = Partial<Record<`${Color}-${Role}`, number>>;

/** SAN as Lichess writes it: pawn drops keep their letter (`P@e6`, not `@e6`). */
function makeSan(pos: Crazyhouse, move: Move): string {
  const san = chessopsSan(pos, move);
  return san.startsWith('@') ? `P${san}` : san;
}

export type PositionResult = { ok: true; pos: Crazyhouse } | { ok: false; error: string };

const ERRORS: Record<string, string> = {
  ERR_EMPTY: 'The board is empty.',
  ERR_KINGS: 'Each side needs exactly one king, and kings cannot be in hand.',
  ERR_OPPOSITE_CHECK: 'The side not to move is in check.',
  ERR_PAWNS_ON_BACKRANK: 'Pawns cannot stand on the first or last rank.',
  ERR_VARIANT: 'More than 64 pieces on the board and in hand.',
};

export function readFen(fen: string): PositionResult {
  const setup = parseFen(fen.trim());
  if (setup.isErr) return { ok: false, error: 'That is not a FEN.' };
  const pos = Crazyhouse.fromSetup(setup.value);
  if (pos.isErr) return { ok: false, error: ERRORS[pos.error.message] ?? 'That position is not playable.' };
  return { ok: true, pos: pos.value };
}

export function positionOf(fen: string): Crazyhouse {
  const read = readFen(fen);
  if (!read.ok) throw new Error(read.error);
  return read.pos;
}

export function fenOf(pos: Crazyhouse): string {
  return makeFen(pos.toSetup());
}

/** The FEN with one more or one fewer piece in a hand, or null when that is not allowed. */
export function adjustHand(fen: string, color: Color, role: Role, delta: 1 | -1): string | null {
  const read = readFen(fen);
  if (!read.ok) return null;
  const setup = read.pos.toSetup();
  const pockets = setup.pockets!;
  const next = pockets[color][role] + delta;
  if (next < 0 || next > MAX_IN_HAND) return null;
  pockets[color][role] = next;
  const pos = Crazyhouse.fromSetup(setup);
  return pos.isOk ? fenOf(pos.value) : null;
}

function deltaBetween(expectedFen: string, fen: string): HandDelta | undefined {
  const a = positionOf(expectedFen).pockets, b = positionOf(fen).pockets;
  if (!a || !b) return undefined;
  const delta: HandDelta = {};
  for (const color of ['white', 'black'] as Color[])
    for (const role of HAND_ROLES) {
      const d = b[color][role] - a[color][role];
      if (d) delta[`${color}-${role}`] = d;
    }
  return Object.keys(delta).length ? delta : undefined;
}

/** The position with a node's hand edit applied, each count kept within 0 and 16. */
function applyDelta(fen: string, delta: HandDelta | undefined): string {
  if (!delta) return fen;
  const setup = positionOf(fen).toSetup();
  for (const [key, d] of Object.entries(delta)) {
    const [color, role] = key.split('-') as [Color, Role];
    setup.pockets![color][role] = Math.min(MAX_IN_HAND, Math.max(0, setup.pockets![color][role] + (d ?? 0)));
  }
  const pos = Crazyhouse.fromSetup(setup);
  return pos.isOk ? fenOf(pos.value) : fen;
}

/** What a hand holds as FEN letters, white upper case: `QNp`. */
export function handLetters(fen: string): string {
  const pockets = positionOf(fen).pockets;
  if (!pockets) return '';
  let out = '';
  for (const color of ['white', 'black'] as Color[])
    for (const role of [...HAND_ROLES].reverse())
      out += (color === 'white' ? LETTER[role].toUpperCase() : LETTER[role]).repeat(pockets[color][role]);
  return out;
}

/**
 * The hand change made at this node by an edit, against the position its move
 * (or, at the root, the loaded position) produced: `+p −N`. Empty when none.
 */
export function handEdit(expectedFen: string, fen: string): string {
  const a = positionOf(expectedFen).pockets, b = positionOf(fen).pockets;
  if (!a || !b) return '';
  const out: string[] = [];
  for (const color of ['white', 'black'] as Color[])
    for (const role of HAND_ROLES) {
      const d = b[color][role] - a[color][role];
      if (!d) continue;
      const letter = color === 'white' ? LETTER[role].toUpperCase() : LETTER[role];
      out.push(`${d > 0 ? '+' : '−'}${Math.abs(d) > 1 ? Math.abs(d) : ''}${letter}`);
    }
  return out.join(' ');
}

/** Chessground's destinations, with both forms of castling. */
export function boardDests(fen: string): Map<SquareName, SquareName[]> {
  return chessgroundDests(positionOf(fen));
}

/** The squares the side to move can drop this piece on; none when it is not in hand. */
export function dropSquares(fen: string, role: Role): SquareName[] {
  const pos = positionOf(fen);
  if (!pos.pockets?.[pos.turn][role]) return [];
  const out: SquareName[] = [];
  for (const sq of pos.dropDests()) {
    const rank = sq >> 3;
    if (role === 'pawn' && (rank === 0 || rank === 7)) continue;
    out.push(makeSquare(sq));
  }
  return out;
}

/** A legal move in chessops' form (castling as king takes rook), from engine or board UCI. */
export function readMove(pos: Crazyhouse, uci: string): Move | undefined {
  const raw = parseUci(uci);
  if (!raw) return undefined;
  const move = normalizeMove(pos, raw);
  return pos.isLegal(move) ? move : undefined;
}

/** UCI moves played from a position, with SAN and the position after each, stopping at the first that is not legal. */
export function playLine(fen: string, ucis: string[], limit = ucis.length): LineMove[] {
  const pos = positionOf(fen);
  const out: LineMove[] = [];
  for (const uci of ucis.slice(0, limit)) {
    const move = readMove(pos, uci);
    if (!move) break;
    const san = makeSan(pos, move);
    playMove(pos, move);
    out.push({ uci, san, fen: fenOf(pos) });
  }
  return out;
}

/** The SAN line of UCI moves from a position, stopping at the first that is not legal. */
export function sanLine(fen: string, ucis: string[], limit = ucis.length): string[] {
  return playLine(fen, ucis, limit).map((m) => m.san);
}

/** The position with the other side to move, for the engine's threat search (Lichess's "Show threat"). */
export function threatFen(fen: string): string {
  const fields = fen.split(' ');
  fields[1] = fields[1] === 'w' ? 'b' : 'w';
  fields[3] = '-';
  return fields.join(' ');
}

export class Tree extends VariationTree<TreeNode> {
  /** The position as loaded, so an edit of the root hand can be shown. */
  loadedFen: string;

  constructor(fen = START_FEN) {
    super({ id: newId(), ply: plyOf(fen), uci: '', san: '', fen, children: [] });
    this.loadedFen = fen;
  }

  /** The position this node's move produced, before any edit of its hand. */
  expectedFen(id: string): string {
    const node = this.get(id)!;
    const parent = this.parent(id);
    if (!parent) return this.loadedFen;
    const pos = positionOf(parent.fen);
    playMove(pos, parseUci(node.uci)!);
    return fenOf(pos);
  }

  /** Plays a move after a node, reusing an existing child with that move. */
  play(id: string, uci: string): TreeNode | null {
    const parent = this.get(id)!;
    const pos = positionOf(parent.fen);
    const move = readMove(pos, uci);
    if (!move) return null;
    const existing = parent.children.find((c) => c.uci === makeUci(move));
    if (existing) return existing;
    const san = makeSan(pos, move);
    playMove(pos, move);
    const child: TreeNode = { id: newId(), ply: parent.ply + 1, uci: makeUci(move), san, fen: fenOf(pos), children: [] };
    this.attach(parent, child);
    return child;
  }

  /** One more or one fewer piece in a hand at this node, carried through the moves after it. */
  adjustHand(id: string, color: Color, role: Role, delta: 1 | -1): boolean {
    const node = this.get(id)!;
    const fen = adjustHand(node.fen, color, role, delta);
    if (!fen) return false;
    node.hand = deltaBetween(this.expectedFen(id), fen);
    node.fen = fen;
    this.replay(node);
    return true;
  }

  private replay(node: TreeNode) {
    const kept: TreeNode[] = [];
    for (const child of node.children) {
      const pos = positionOf(node.fen);
      const move = parseUci(child.uci);
      if (!move || !readMove(pos, child.uci)) { this.unindex(child); continue; }
      child.san = makeSan(pos, move);
      playMove(pos, move);
      child.fen = applyDelta(fenOf(pos), child.hand);
      kept.push(child);
      this.replay(child);
    }
    node.children = kept;
  }

  /**
   * Lichess's "Copy main line PGN" / "Copy variation PGN": the moves from the
   * start to this one and what follows it, the variations after it only for a
   * variation. Also returns the nodes it covers, to highlight before copying.
   */
  copyLine(id: string, withVariations: boolean): { pgn: string; ids: Set<string> } {
    const path = this.path(id).slice(1);
    const ids = new Set(path.map((n) => n.id));
    const tokens: string[] = [];
    const rootEdit = handEdit(this.loadedFen, this.root.fen);
    if (rootEdit) tokens.push(`{ Hands edited: ${rootEdit} }`);
    let numbered = true;
    for (const node of path) {
      this.writeMove(node, tokens, numbered);
      numbered = false;
      const edit = handEdit(this.expectedFen(node.id), node.fen);
      if (edit) { tokens.push(`{ Hands edited: ${edit} }`); numbered = true; }
    }
    const end = this.get(id)!;
    const collect = (n: TreeNode, all: boolean) => {
      const kids = all ? n.children : n.children.slice(0, 1);
      for (const k of kids) { ids.add(k.id); collect(k, all); }
    };
    collect(end, withVariations);
    this.writeLine(end, tokens, numbered, withVariations);
    tokens.push('*');
    return { pgn: `${this.headers().join('\n')}\n\n${tokens.join(' ')}\n`, ids };
  }

  save(currentId: string): SavedTree {
    const write = (n: TreeNode): SavedNode => ({
      uci: n.uci,
      ...(n.hand ? { hand: n.hand } : {}),
      ...(n.forceVariation ? { fv: true as const } : {}),
      ...(n.collapsed ? { c: true as const } : {}),
      children: n.children.map(write),
    });
    return { loadedFen: this.loadedFen, root: write(this.root), current: this.indexPath(currentId) };
  }

  /** A saved tree replayed move by move; moves that no longer play are dropped. */
  static restore(saved: SavedTree): { tree: Tree; current: TreeNode } | null {
    if (!readFen(saved.loadedFen).ok) return null;
    const tree = new Tree(saved.loadedFen);
    const apply = (node: TreeNode, data: SavedNode) => {
      if (data.hand) {
        node.hand = data.hand;
        node.fen = applyDelta(node.fen, data.hand);
      }
      if (data.fv) node.forceVariation = true;
      if (data.c) node.collapsed = true;
      for (const child of data.children ?? []) {
        const next = tree.play(node.id, child.uci);
        if (next) apply(next, child);
      }
    };
    try { apply(tree.root, saved.root); } catch { return null; }
    return { tree, current: tree.follow(saved.current ?? []) };
  }

  private headers(): string[] {
    const headers = ['[Event "Bughouse analysis"]', '[Site "https://chessautoprep.com/bughouse"]', '[Variant "Bughouse"]'];
    if (this.root.fen !== START_FEN) headers.push(`[FEN "${this.root.fen}"]`, '[SetUp "1"]');
    return headers;
  }

  pgn(): string {
    const headers = this.headers();
    const tokens: string[] = [];
    const rootEdit = handEdit(this.loadedFen, this.root.fen);
    if (rootEdit) tokens.push(`{ Hands edited: ${rootEdit} }`);
    this.writeLine(this.root, tokens, true);
    tokens.push('*');
    return `${headers.join('\n')}\n\n${tokens.join(' ')}\n`;
  }

  private writeLine(parent: TreeNode, out: string[], forceNumber: boolean, withVariations = true) {
    let node = parent;
    let numbered = forceNumber;
    while (node.children.length) {
      const [main, ...variations] = node.children;
      this.writeMove(main, out, numbered);
      numbered = false;
      for (const variation of withVariations ? variations : []) {
        out.push('(');
        this.writeMove(variation, out, true);
        this.writeLine(variation, out, false);
        out.push(')');
        numbered = true;
      }
      const edit = handEdit(this.expectedFen(main.id), main.fen);
      if (edit) { out.push(`{ Hands edited: ${edit} }`); numbered = true; }
      node = main;
    }
  }

  private writeMove(node: TreeNode, out: string[], numbered: boolean) {
    const white = node.ply % 2 === 1;
    const number = Math.floor((node.ply + 1) / 2);
    if (white) out.push(`${number}.`);
    else if (numbered) out.push(`${number}...`);
    out.push(node.san);
  }

  /** A tree from a bughouse or crazyhouse PGN (the first game; any variant tag is read as this page's rules). */
  static fromPgn(text: string): Tree | null {
    const game = parsePgn(text)[0];
    if (!game) return null;
    game.headers.set('Variant', 'Crazyhouse');
    const start = startingPosition(game.headers);
    if (start.isErr) return null;
    const tree = new Tree(fenOf(start.value as Crazyhouse));
    const walk = (pgnNode: PgnNode<PgnNodeData>, node: TreeNode, pos: Crazyhouse) => {
      for (const child of pgnNode.children) {
        const move = parseSan(pos, child.data.san);
        if (!move) continue;
        const next = tree.play(node.id, makeUci(move));
        if (!next) continue;
        for (const comment of child.data.comments ?? []) applyEditComment(tree, next, comment);
        walk(child, next, positionOf(next.fen));
      }
    };
    walk(game.moves, tree.root, start.value as Crazyhouse);
    return tree.root.children.length || game.headers.has('FEN') ? tree : null;
  }
}

/** Re-applies a `Hands edited: +N −2p` comment written by `pgn()`. */
function applyEditComment(tree: Tree, node: TreeNode, comment: string) {
  const edit = /Hands edited:\s*([^}]*)/.exec(comment)?.[1];
  if (!edit) return;
  const roles: Record<string, Role> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen' };
  for (const [, sign, count, letter] of edit.matchAll(/([+−-])(\d*)([pnbrqPNBRQ])/g)) {
    const color: Color = letter === letter.toUpperCase() ? 'white' : 'black';
    for (let i = 0; i < (Number(count) || 1); i++)
      tree.adjustHand(node.id, color, roles[letter.toLowerCase()], sign === '+' ? 1 : -1);
  }
}

