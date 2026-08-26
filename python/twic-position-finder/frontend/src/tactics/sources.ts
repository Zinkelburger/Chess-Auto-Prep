/**
 * Game fetchers. Both return the same shape so the miner does not care
 * where a game came from.
 *
 * Lichess: one PGN export with `evals=true` — games the server has analysed
 * arrive with `[%eval]` comments, which the miner uses to skip most engine
 * work. Chess.com: the monthly archive list, walked newest-first until we
 * have enough games of the wanted time classes.
 */
import type { GameMeta, Source } from './miner';
import { parsePgn, splitPgn, timeClassOf, type ParsedPgn } from './pgn';

export interface SourceGame {
  source: Source;
  id: string;
  parsed: ParsedPgn;
  meta: GameMeta;
}

export type TimeClass = 'bullet' | 'blitz' | 'rapid' | 'classical' | 'correspondence';

export class SourceError extends Error {
  constructor(message: string) {
    super(message);
    this.name = 'SourceError';
  }
}

function intOrNull(v: string | undefined): number | null {
  const n = Number.parseInt(v ?? '', 10);
  return Number.isFinite(n) ? n : null;
}

function metaFromHeaders(source: Source, id: string, url: string, parsed: ParsedPgn, timeClass: string): GameMeta {
  const h = parsed.headers;
  return {
    source,
    id,
    url,
    white: h.White ?? '?',
    black: h.Black ?? '?',
    whiteElo: intOrNull(h.WhiteElo),
    blackElo: intOrNull(h.BlackElo),
    result: h.Result ?? '*',
    date: (h.UTCDate ?? h.Date ?? '').replaceAll('.', '-'),
    timeClass,
    moves: parsed.moves.map((m) => m.san),
  };
}

// ── Lichess ─────────────────────────────────────────────────────

const LICHESS_PERF: Record<TimeClass, string[]> = {
  bullet: ['ultraBullet', 'bullet'],
  blitz: ['blitz'],
  rapid: ['rapid'],
  classical: ['classical'],
  correspondence: ['correspondence'],
};

export async function fetchLichessGames(
  username: string, max: number, classes: TimeClass[], signal?: AbortSignal,
): Promise<SourceGame[]> {
  const perfType = classes.flatMap((c) => LICHESS_PERF[c]).join(',');
  const params = new URLSearchParams({
    max: String(max),
    perfType,
    moves: 'true',
    evals: 'true',
    opening: 'false',
    clocks: 'false',
  });
  let res: Response;
  try {
    res = await fetch(`https://lichess.org/api/games/user/${encodeURIComponent(username)}?${params}`, {
      headers: { Accept: 'application/x-chess-pgn' },
      signal,
    });
  } catch (err) {
    if ((err as Error).name === 'AbortError') throw err;
    throw new SourceError('Could not reach Lichess.');
  }
  if (res.status === 404) throw new SourceError(`Lichess user “${username}” not found.`);
  if (res.status === 429) throw new SourceError('Lichess is rate-limiting requests. Wait a minute and try again.');
  if (!res.ok) throw new SourceError(`Lichess returned ${res.status}.`);
  const text = await res.text();
  const games: SourceGame[] = [];
  for (const pgn of splitPgn(text)) {
    const parsed = parsePgn(pgn);
    const url = parsed.headers.Site ?? '';
    const id = /lichess\.org\/([A-Za-z0-9]{8})/.exec(url)?.[1] ?? url ?? String(games.length);
    if (parsed.moves.length === 0) continue;
    games.push({ source: 'lichess', id, parsed, meta: metaFromHeaders('lichess', id, url, parsed, timeClassOf(parsed.headers)) });
  }
  return games;
}

// ── Chess.com ───────────────────────────────────────────────────

interface ChesscomGame {
  url: string;
  pgn: string;
  time_class: string;
  rules?: string;
  end_time?: number;
}

const CHESSCOM_CLASS: Record<string, TimeClass> = {
  bullet: 'bullet', blitz: 'blitz', rapid: 'rapid', daily: 'correspondence',
};

export async function fetchChesscomGames(
  username: string, max: number, classes: TimeClass[], signal?: AbortSignal,
): Promise<SourceGame[]> {
  const user = username.trim().toLowerCase();
  const base = `https://api.chess.com/pub/player/${encodeURIComponent(user)}`;
  let archives: string[];
  try {
    const res = await fetch(`${base}/games/archives`, { signal });
    if (res.status === 404) throw new SourceError(`Chess.com user “${username}” not found.`);
    if (!res.ok) throw new SourceError(`Chess.com returned ${res.status}.`);
    archives = ((await res.json()) as { archives?: string[] }).archives ?? [];
  } catch (err) {
    if (err instanceof SourceError || (err as Error).name === 'AbortError') throw err;
    throw new SourceError('Could not reach Chess.com.');
  }

  const wanted = new Set(classes);
  const games: SourceGame[] = [];
  // Newest month first; stop as soon as we have enough.
  for (const monthUrl of archives.reverse()) {
    if (games.length >= max) break;
    let month: ChesscomGame[];
    try {
      const res = await fetch(monthUrl, { signal });
      if (!res.ok) continue;
      month = ((await res.json()) as { games?: ChesscomGame[] }).games ?? [];
    } catch (err) {
      if ((err as Error).name === 'AbortError') throw err;
      continue;
    }
    // Newest game first within the month.
    month.sort((a, b) => (b.end_time ?? 0) - (a.end_time ?? 0));
    for (const g of month) {
      if (games.length >= max) break;
      if (g.rules && g.rules !== 'chess') continue;
      const cls = CHESSCOM_CLASS[g.time_class];
      if (!cls || !wanted.has(cls)) continue;
      if (!g.pgn) continue;
      const parsed = parsePgn(g.pgn);
      if (parsed.moves.length === 0) continue;
      const id = /\/game\/(?:live|daily)\/(\d+)/.exec(g.url)?.[1] ?? g.url;
      games.push({ source: 'chesscom', id, parsed, meta: metaFromHeaders('chesscom', id, g.url, parsed, cls) });
    }
  }
  return games;
}
