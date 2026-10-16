/** Splits a PGN file into its games off the page's thread: each game's headers and its own PGN text. */
import { emptyHeaders, makePgn, parsePgn } from 'chessops/pgn';
import type { StoredGame } from './games';

onmessage = (event: MessageEvent<{ text: string }>) => {
  try {
    const games: StoredGame[] = parsePgn(event.data.text, emptyHeaders).map((game) => ({ headers: Object.fromEntries(game.headers), pgn: makePgn(game) }));
    postMessage({ games });
  } catch (e) {
    postMessage({ error: (e as Error).message || 'Could not read that PGN.' });
  }
};
