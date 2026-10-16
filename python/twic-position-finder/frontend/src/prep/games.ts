/**
 * The games open on the page, kept in this browser (IndexedDB) so a reload
 * comes back to them: each game's headers and PGN, the game shown, and the
 * move shown in it. A file or pasted PGN is split into games in a worker, so
 * a large file does not stall the page. Saving is debounced; a failed save is
 * reported and the games stay open.
 */
import { MAX_PGN_BYTES } from './pgn';
import { workspaceStore } from './storage';

export interface StoredGame { headers: Record<string, string>; pgn: string }

export interface Collection {
  version: 1;
  games: StoredGame[];
  index: number;
  /** Child indexes from the root to the move shown. */
  path: number[];
  orientation: 'white' | 'black';
}

const KEY = 'analysis-v1';
/** The PGN workspace before October 2026, read once when nothing newer is saved. */
const OLD_KEY = 'current';

export const MAX_GAMES = 20_000;

export function splitGames(text: string): Promise<StoredGame[]> {
  if (new Blob([text]).size > MAX_PGN_BYTES) return Promise.reject(new Error('Open a PGN smaller than 10 MB.'));
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./games.worker.ts', import.meta.url), { type: 'module' });
    const timeout = setTimeout(() => { worker.terminate(); reject(new Error('That PGN took too long to read. Try a smaller file.')); }, 60_000);
    worker.onmessage = (e: MessageEvent<{ games?: StoredGame[]; error?: string }>) => {
      clearTimeout(timeout);
      worker.terminate();
      if (e.data.error) reject(new Error(e.data.error));
      else if (!e.data.games?.length) reject(new Error('No games found in that PGN.'));
      else if (e.data.games.length > MAX_GAMES) reject(new Error(`That PGN has more than ${MAX_GAMES.toLocaleString()} games. Split it into smaller files.`));
      else resolve(e.data.games);
    };
    worker.onerror = () => { clearTimeout(timeout); worker.terminate(); reject(new Error('Could not read that PGN.')); };
    worker.postMessage({ text });
  });
}

export async function loadCollection(): Promise<Collection | null> {
  const saved = await workspaceStore('read', undefined, KEY) as Collection | undefined;
  if (saved?.version === 1 && Array.isArray(saved.games) && saved.games.length) return saved;
  const old = await workspaceStore('read', undefined, OLD_KEY) as { version?: number; pgn?: string; game?: number } | undefined;
  if (old?.version === 1 && typeof old.pgn === 'string' && old.pgn.trim()) {
    const games = await splitGames(old.pgn).catch(() => null);
    if (games) return { version: 1, games, index: Math.min(games.length - 1, Math.max(0, old.game ?? 0)), path: [], orientation: 'white' };
  }
  return null;
}

export function saveCollection(collection: Collection): Promise<unknown> {
  return workspaceStore('write', collection, KEY);
}
