import { readPgn } from './pgn';
onmessage = (event: MessageEvent<{ id: number; text: string }>) => {
  try { postMessage({ id: event.data.id, games: readPgn(event.data.text) }); }
  catch (error) { postMessage({ id: event.data.id, error: (error as Error).message }); }
};
