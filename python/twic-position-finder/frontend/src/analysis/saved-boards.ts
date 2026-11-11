/**
 * Where the analysis boards are kept between visits: both trees in this
 * browser's storage, and the positions shown in the page's link.
 */
import { START_FEN, Tree, fenOf, lichessFen, readFen, type SavedTree, type TreeNode } from './tree';

/** Both boards' trees, kept in this browser so a reload comes back to them (Lichess keeps its tree too). */
export const BOARDS_KEY = 'bughouse-analysis-boards-v1';
/** The single tree kept before there were two boards: read as board 1 when nothing newer is kept. */
export const TREE_KEY = 'bughouse-analysis-tree-v1';

export interface SavedBoards { boards: [SavedTree, SavedTree]; active: 0 | 1 }

/** One board's moves and the move it is at. */
export interface BoardState { tree: Tree; current: TreeNode }

export function loadSaved<T>(key: string): T | null {
  try { return JSON.parse(localStorage.getItem(key) ?? 'null') as T | null; } catch { return null; }
}

/** A board's tree from the link, or the kept tree when it is at that position (or no position was linked). */
export function openBoard(saved: SavedTree | null | undefined, fen: string | null, flash: (text: string) => void): BoardState {
  const read = fen ? readFen(fen) : null;
  const target = read?.ok ? fenOf(read.pos) : START_FEN;
  const restored = saved ? Tree.restore(saved) : null;
  if (read && !read.ok) flash(`Could not open the linked position: ${read.error}`);
  if (restored && (!fen || (read?.ok && restored.current.fen === target))) return { tree: restored.tree, current: restored.current };
  const tree = new Tree(target);
  return { tree, current: tree.root };
}

/** Keeps both boards' trees in this browser. */
export function keepBoards(boards: readonly [BoardState, BoardState], active: 0 | 1): void {
  const kept: SavedBoards = { boards: [boards[0].tree.save(boards[0].current.id), boards[1].tree.save(boards[1].current.id)], active };
  try { localStorage.setItem(BOARDS_KEY, JSON.stringify(kept)); } catch { /* Kept for this visit only. */ }
}

/** Puts the boards' positions in the page's link: `fen` unless one board stands at the start, `fen2` with two boards. */
export function linkBoards(boards: readonly [BoardState, BoardState], twoBoards: boolean): void {
  const url = new URL(location.href);
  const [one, two] = boards.map((b) => b.current.fen);
  if (one === START_FEN && !twoBoards) url.searchParams.delete('fen'); else url.searchParams.set('fen', lichessFen(one));
  if (twoBoards) url.searchParams.set('fen2', lichessFen(two)); else url.searchParams.delete('fen2');
  history.replaceState(null, '', url);
}
