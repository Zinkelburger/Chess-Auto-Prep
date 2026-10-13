import { MAX_PGN_BYTES, type Game } from './pgn';
export function parsePgnAsync(text: string): Promise<Game[]> {
  if (new Blob([text]).size > MAX_PGN_BYTES) return Promise.reject(new Error('Open a PGN smaller than 10 MB.'));
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./pgn.worker.ts', import.meta.url), { type: 'module' });
    const timeout = setTimeout(() => { worker.terminate(); reject(new Error('This PGN took too long to read. Try a smaller file.')); }, 30000);
    worker.onmessage = event => { clearTimeout(timeout); worker.terminate(); event.data.error ? reject(new Error(event.data.error)) : resolve(event.data.games); };
    worker.onerror = () => { clearTimeout(timeout); worker.terminate(); reject(new Error('Could not read this PGN. Reload and retry.')); };
    worker.postMessage({ text });
  });
}
