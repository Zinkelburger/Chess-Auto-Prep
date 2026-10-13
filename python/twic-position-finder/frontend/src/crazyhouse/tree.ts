/**
 * The analysis tree for one crazyhouse board, with hands that can be edited
 * between moves. A hand edit is kept on its node as a change against the
 * position its move produced, and is carried through every move after it, as
 * material arriving from a partner would be. Replaying after an earlier edit
 * re-applies each later edit; a continuation that is no longer legal (a drop
 * of a piece no longer in hand) is cut. The tree never checks material counts: any hand chessops accepts
 * is allowed (no kings, at most 64 pieces), capped per piece at what
 * Fairy-Stockfish's NNUE can represent.
 */
import { makeFen, parseFen, INITIAL_FEN } from 'chessops/fen';
import { makeSan as chessopsSan, parseSan } from 'chessops/san';
import { parsePgn, startingPosition, type PgnNodeData, type Node as PgnNode } from 'chessops/pgn';
import { Crazyhouse } from 'chessops/variant';
import { makeSquare, makeUci, parseUci } from 'chessops/util';
import { normalizeMove } from 'chessops/chess';
import { chessgroundDests } from 'chessops/compat';
import type { Color, Move, Role, SquareName } from 'chessops/types';

export const START_FEN = INITIAL_FEN.replace(' w ', '[] w ');
/** Fairy-Stockfish's NNUE has 16 slots per piece type and side for counts in hand. */
export const MAX_IN_HAND = 16;
export const HAND_ROLES: Role[] = ['pawn', 'knight', 'bishop', 'rook', 'queen'];
const LETTER: Record<Role, string> = { pawn: 'p', knight: 'n', bishop: 'b', rook: 'r', queen: 'q', king: 'k' };

export interface TreeNode {
  id: string;
  ply: number;
  /** The move from the parent, as UCI (`e2e4`, `N@f3`); empty at the root. */
  uci: string;
  san: string;
  fen: string;
  /** The hand edit made at this position, if any. */
  hand?: HandDelta;
  children: TreeNode[];
}

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

/** The SAN line of UCI moves from a position, stopping at the first that is not legal. */
export function sanLine(fen: string, ucis: string[], limit = ucis.length): string[] {
  const pos = positionOf(fen);
  const out: string[] = [];
  for (const uci of ucis.slice(0, limit)) {
    const move = readMove(pos, uci);
    if (!move) break;
    out.push(makeSan(pos, move));
    pos.play(move);
  }
  return out;
}

let nextId = 0;
const newId = () => `n${++nextId}`;

export class Tree {
  root: TreeNode;
  /** The position as loaded, so an edit of the root hand can be shown. */
  loadedFen: string;
  private parents = new Map<string, TreeNode | null>();
  private byId = new Map<string, TreeNode>();

  constructor(fen = START_FEN) {
    this.loadedFen = fen;
    this.root = { id: newId(), ply: plyOf(fen), uci: '', san: '', fen, children: [] };
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

  /** The node and its first children to the end of its line. */
  lineEnd(id: string): TreeNode {
    let node = this.get(id)!;
    while (node.children.length) node = node.children[0];
    return node;
  }

  isMainline(id: string): boolean {
    return this.path(id).every((n, i, all) => i === 0 || all[i - 1].children[0] === n);
  }

  /** The position this node's move produced, before any edit of its hand. */
  expectedFen(id: string): string {
    const node = this.get(id)!;
    const parent = this.parent(id);
    if (!parent) return this.loadedFen;
    const pos = positionOf(parent.fen);
    pos.play(parseUci(node.uci)!);
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
    pos.play(move);
    const child: TreeNode = { id: newId(), ply: parent.ply + 1, uci: makeUci(move), san, fen: fenOf(pos), children: [] };
    parent.children.push(child);
    this.index(child, parent);
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
      if (!move || !pos.isLegal(move)) { this.unindex(child); continue; }
      child.san = makeSan(pos, move);
      pos.play(move);
      child.fen = applyDelta(fenOf(pos), child.hand);
      kept.push(child);
      this.replay(child);
    }
    node.children = kept;
  }

  delete(id: string): TreeNode | null {
    const parent = this.parent(id);
    if (!parent) return null;
    const node = this.get(id)!;
    parent.children = parent.children.filter((c) => c !== node);
    this.unindex(node);
    return parent;
  }

  /** Makes the node's line the main line all the way from the root. */
  promote(id: string) {
    for (const node of this.path(id)) {
      const parent = this.parent(node.id);
      if (!parent) continue;
      parent.children = [node, ...parent.children.filter((c) => c !== node)];
    }
  }

  pgn(): string {
    const headers = ['[Event "Crazyhouse analysis"]', '[Site "https://chessautoprep.com/crazyhouse"]', '[Variant "Crazyhouse"]'];
    if (this.root.fen !== START_FEN) headers.push(`[FEN "${this.root.fen}"]`, '[SetUp "1"]');
    const tokens: string[] = [];
    const rootEdit = handEdit(this.loadedFen, this.root.fen);
    if (rootEdit) tokens.push(`{ Hands edited: ${rootEdit} }`);
    this.writeLine(this.root, tokens, true);
    tokens.push('*');
    return `${headers.join('\n')}\n\n${tokens.join(' ')}\n`;
  }

  private writeLine(parent: TreeNode, out: string[], forceNumber: boolean) {
    let node = parent;
    let numbered = forceNumber;
    while (node.children.length) {
      const [main, ...variations] = node.children;
      this.writeMove(main, out, numbered);
      numbered = false;
      for (const variation of variations) {
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

  /** A tree from a crazyhouse PGN (the first game; any variant tag is read as crazyhouse). */
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
        const after = pos.clone();
        after.play(move);
        walk(child, next, after);
      }
    };
    walk(game.moves, tree.root, start.value as Crazyhouse);
    return tree.root.children.length || game.headers.has('FEN') ? tree : null;
  }
}

function plyOf(fen: string): number {
  const parts = fen.trim().split(/\s+/);
  const full = Number(parts[5] ?? 1) || 1;
  return (full - 1) * 2 + (parts[1] === 'b' ? 1 : 0);
}

