/**
 * Bughouse Games: the collection as served from /bughouse-games/ (see
 * README.md beside this file for the format), read and checked against the
 * contract, with no DOM. The page never generates a move: every position it
 * shows is a FEN from these files.
 *
 * A broken index entry or line affects only itself and is dropped with a
 * warning; a game whose moves do not follow the contract is refused whole,
 * since its positions cannot be trusted.
 */
import type { BoardName } from '../bughouse/types';

export type Seat = 'Awhite' | 'Ablack' | 'Bwhite' | 'Bblack';
export const SEATS: readonly Seat[] = ['Awhite', 'Ablack', 'Bwhite', 'Bblack'];
export type Glyph = '!' | '!!' | '?' | '??' | '!?' | '?!';
export const GLYPHS: readonly Glyph[] = ['!', '!!', '?', '??', '!?', '?!'];
export type LineKind = 'played' | 'instead' | 'threat' | 'arrives';
export const LINE_KINDS: readonly LineKind[] = ['played', 'instead', 'threat', 'arrives'];

export interface IndexEntry {
  id: string;
  file: string;
  title: string;
  summary: string;
  event: string;
  date: string;
  seats: Record<Seat, string>;
  /** Index into the game's `teams`, or null for a draw. */
  winner: 0 | 1 | null;
  how: string;
  /** Half-moves on both boards. */
  moves: number;
  /** Moves that carry a note. */
  notes: number;
}

export interface GamesIndex {
  version: 1;
  generated: string;
  source: string;
  games: IndexEntry[];
  /** Entries left out because they broke the contract. */
  skipped: number;
}

export interface LineMove { uci: string; san: string; fen: string }

export interface Line {
  id: string;
  /** One of LINE_KINDS; an unknown kind is kept and shown as a plain line. */
  kind: string;
  from: 'before' | 'after';
  board: BoardName;
  start: string;
  /** Pieces the partner is supposed to deliver first, FEN case, already in `start`'s reserve. */
  assume: string;
  moves: LineMove[];
  eval: number | null;
  mate: number | null;
  note: string | null;
}

export interface Waited { seconds: number; why: string }

export interface Move {
  i: number;
  board: BoardName;
  seat: Seat;
  num: number;
  uci: string;
  san: string;
  fen: Record<BoardName, string>;
  t: number | null;
  clocks: Record<Seat, number> | null;
  /** The mover's own score for this board, centipawns from that board's White side. */
  eval: number | null;
  mate: number | null;
  book: boolean;
  waited: Waited | null;
  glyph: Glyph | null;
  note: string | null;
  lines: Line[];
}

export interface Game {
  version: 1;
  id: string;
  title: string;
  summary: string;
  event: string;
  date: string;
  seats: Record<Seat, string>;
  teams: [[Seat, Seat], [Seat, Seat]];
  result: { winner: 0 | 1 | null; how: string; board: BoardName | null; text: string };
  initial_clock: number;
  start: Record<BoardName, string>;
  moves: Move[];
}

export const ID = /^[A-Za-z0-9][\w-]{0,63}$/;
/** One board's FEN with reserves as readBoard reads it: placement (with an optional [pocket]), side, and the rest. */
const FEN = /^[1-8pnbrqkPNBRQK~/]+(\[[pnbrqPNBRQ]*\])? [wb] \S+ \S+ \d+ \d+$/;

class ContractError extends Error {}

function fail(where: string, what: string): never { throw new ContractError(`${where}: ${what}`); }

type Raw = Record<string, unknown>;

function obj(v: unknown, where: string): Raw {
  if (!v || typeof v !== 'object' || Array.isArray(v)) fail(where, 'expected an object');
  return v as Raw;
}
function str(v: unknown, where: string): string {
  if (typeof v !== 'string') fail(where, 'expected text');
  return v;
}
function optStr(v: unknown, where: string): string | null {
  return v === null || v === undefined ? null : str(v, where);
}
function num(v: unknown, where: string): number {
  if (typeof v !== 'number' || !Number.isFinite(v)) fail(where, 'expected a number');
  return v;
}
function optNum(v: unknown, where: string): number | null {
  return v === null || v === undefined ? null : num(v, where);
}
function board(v: unknown, where: string): BoardName {
  if (v !== 'A' && v !== 'B') fail(where, 'expected "A" or "B"');
  return v;
}
function fen(v: unknown, where: string): string {
  const s = str(v, where);
  if (!FEN.test(s)) fail(where, `not a board FEN: ${s.slice(0, 80)}`);
  return s;
}
function winner(v: unknown, where: string): 0 | 1 | null {
  if (v === null || v === 0 || v === 1) return v;
  fail(where, 'expected 0, 1 or null');
}
function seats(v: unknown, where: string): Record<Seat, string> {
  const o = obj(v, where);
  const out = {} as Record<Seat, string>;
  for (const s of SEATS) out[s] = str(o[s], `${where}.${s}`);
  return out;
}
function seat(v: unknown, where: string): Seat {
  if (!SEATS.includes(v as Seat)) fail(where, 'expected a seat (Awhite, Ablack, Bwhite, Bblack)');
  return v as Seat;
}

function readEntry(v: unknown, where: string): IndexEntry {
  const o = obj(v, where);
  const id = str(o.id, `${where}.id`);
  if (!ID.test(id)) fail(`${where}.id`, `not a usable id: ${id}`);
  const file = str(o.file, `${where}.file`);
  // The file sits beside index.json; never a path elsewhere.
  if (!/^[\w.-]+\.json$/.test(file)) fail(`${where}.file`, `not a file name: ${file}`);
  return {
    id, file,
    title: str(o.title, `${where}.title`),
    summary: str(o.summary, `${where}.summary`),
    event: str(o.event, `${where}.event`),
    date: str(o.date, `${where}.date`),
    seats: seats(o.seats, `${where}.seats`),
    winner: winner(o.winner, `${where}.winner`),
    how: str(o.how, `${where}.how`),
    moves: num(o.moves, `${where}.moves`),
    notes: num(o.notes, `${where}.notes`),
  };
}

/** The index: a broken entry is left out and counted; a broken frame throws. */
export function parseIndex(data: unknown, warn: (message: string) => void = () => {}): GamesIndex {
  const o = obj(data, 'index');
  if (o.version !== 1) fail('index.version', `expected 1, got ${JSON.stringify(o.version)}`);
  if (!Array.isArray(o.games)) fail('index.games', 'expected a list');
  const games: IndexEntry[] = [];
  const seen = new Set<string>();
  let skipped = 0;
  o.games.forEach((g, n) => {
    try {
      const entry = readEntry(g, `index.games[${n}]`);
      if (seen.has(entry.id)) fail(`index.games[${n}].id`, `repeats ${entry.id}`);
      seen.add(entry.id);
      games.push(entry);
    } catch (e) {
      if (!(e instanceof ContractError)) throw e;
      skipped += 1;
      warn(e.message);
    }
  });
  return { version: 1, generated: optStr(o.generated, 'index.generated') ?? '', source: optStr(o.source, 'index.source') ?? '', games, skipped };
}

function readLine(v: unknown, where: string): Line {
  const o = obj(v, where);
  const from = o.from;
  if (from !== 'before' && from !== 'after') fail(`${where}.from`, 'expected "before" or "after"');
  const assume = optStr(o.assume, `${where}.assume`) ?? '';
  if (!/^[PNBRQpnbrq]*$/.test(assume)) fail(`${where}.assume`, `not piece letters: ${assume}`);
  if (!Array.isArray(o.moves) || !o.moves.length) fail(`${where}.moves`, 'expected at least one move');
  return {
    id: str(o.id, `${where}.id`),
    kind: str(o.kind, `${where}.kind`),
    from,
    board: board(o.board, `${where}.board`),
    start: fen(o.start, `${where}.start`),
    assume,
    moves: o.moves.map((m, k) => {
      const mo = obj(m, `${where}.moves[${k}]`);
      return { uci: str(mo.uci, `${where}.moves[${k}].uci`), san: str(mo.san, `${where}.moves[${k}].san`), fen: fen(mo.fen, `${where}.moves[${k}].fen`) };
    }),
    eval: optNum(o.eval, `${where}.eval`),
    mate: optNum(o.mate, `${where}.mate`),
    note: optStr(o.note, `${where}.note`),
  };
}

function readMove(v: unknown, at: number, warn: (message: string) => void): Move {
  const where = `moves[${at}]`;
  const o = obj(v, where);
  if (o.i !== at) fail(`${where}.i`, `expected ${at}, got ${JSON.stringify(o.i)}`);
  const b = board(o.board, `${where}.board`);
  const s = seat(o.seat, `${where}.seat`);
  if (s[0] !== b) fail(`${where}.seat`, `${s} does not sit at board ${b}`);
  const f = obj(o.fen, `${where}.fen`);
  let clocks: Record<Seat, number> | null = null;
  if (o.clocks !== null && o.clocks !== undefined) {
    const c = obj(o.clocks, `${where}.clocks`);
    clocks = {} as Record<Seat, number>;
    for (const k of SEATS) clocks[k] = num(c[k], `${where}.clocks.${k}`);
  }
  let waited: Waited | null = null;
  if (o.waited !== null && o.waited !== undefined) {
    const w = obj(o.waited, `${where}.waited`);
    waited = { seconds: num(w.seconds, `${where}.waited.seconds`), why: str(w.why, `${where}.waited.why`) };
  }
  const glyph = o.glyph ?? null;
  if (glyph !== null && !GLYPHS.includes(glyph as Glyph)) fail(`${where}.glyph`, `not a glyph: ${JSON.stringify(glyph)}`);
  if (o.book !== true && o.book !== false) fail(`${where}.book`, 'expected true or false');
  const lines: Line[] = [];
  if (o.lines !== undefined && o.lines !== null) {
    if (!Array.isArray(o.lines)) fail(`${where}.lines`, 'expected a list');
    o.lines.forEach((l, k) => {
      try { lines.push(readLine(l, `${where}.lines[${k}]`)); } catch (e) {
        if (!(e instanceof ContractError)) throw e;
        warn(e.message);
      }
    });
  }
  return {
    i: at, board: b, seat: s,
    num: num(o.num, `${where}.num`),
    uci: str(o.uci, `${where}.uci`),
    san: str(o.san, `${where}.san`),
    fen: { A: fen(f.A, `${where}.fen.A`), B: fen(f.B, `${where}.fen.B`) },
    t: optNum(o.t, `${where}.t`),
    clocks,
    eval: optNum(o.eval, `${where}.eval`),
    mate: optNum(o.mate, `${where}.mate`),
    book: o.book,
    waited,
    glyph: glyph as Glyph | null,
    note: optStr(o.note, `${where}.note`),
    lines,
  };
}

/** One game file. Throws with the first place it breaks the contract; a broken line is dropped with a warning. */
export function parseGame(data: unknown, warn: (message: string) => void = () => {}): Game {
  const o = obj(data, 'game');
  if (o.version !== 1) fail('game.version', `expected 1, got ${JSON.stringify(o.version)}`);
  const id = str(o.id, 'game.id');
  if (!ID.test(id)) fail('game.id', `not a usable id: ${id}`);
  const names = seats(o.seats, 'game.seats');
  if (!Array.isArray(o.teams) || o.teams.length !== 2) fail('game.teams', 'expected two teams');
  const teams = o.teams.map((t, n) => {
    if (!Array.isArray(t) || t.length !== 2) fail(`game.teams[${n}]`, 'expected two seats');
    return [seat(t[0], `game.teams[${n}][0]`), seat(t[1], `game.teams[${n}][1]`)] as [Seat, Seat];
  }) as Game['teams'];
  if (new Set(teams.flat()).size !== 4) fail('game.teams', 'every seat must be on exactly one team');
  const r = obj(o.result, 'game.result');
  const resultBoard = r.board === null || r.board === undefined ? null : board(r.board, 'game.result.board');
  const st = obj(o.start, 'game.start');
  if (!Array.isArray(o.moves)) fail('game.moves', 'expected a list');
  const moves = o.moves.map((m, at) => readMove(m, at, warn));
  const clock = num(o.initial_clock, 'game.initial_clock');
  if (clock <= 0) fail('game.initial_clock', 'expected seconds above 0');
  return {
    version: 1, id,
    title: str(o.title, 'game.title'),
    summary: str(o.summary, 'game.summary'),
    event: str(o.event, 'game.event'),
    date: str(o.date, 'game.date'),
    seats: names,
    teams,
    result: { winner: winner(r.winner, 'game.result.winner'), how: str(r.how, 'game.result.how'), board: resultBoard, text: str(r.text, 'game.result.text') },
    initial_clock: clock,
    start: { A: fen(st.A, 'game.start.A'), B: fen(st.B, 'game.start.B') },
    moves,
  };
}

// ── Deep links ────────────────────────────────────────────────────

export interface Link { id: string; move: number | null }

/** `#<id>` opens a game, `#<id>:<move index>` one of its moves; anything else is null. */
export function parseHash(hash: string): Link | null {
  let text: string;
  try { text = decodeURIComponent(hash.replace(/^#/, '')); } catch { return null; }
  const m = /^([^:]+)(?::(\d{1,5}))?$/.exec(text);
  if (!m || !ID.test(m[1])) return null;
  return { id: m[1], move: m[2] === undefined ? null : Number(m[2]) };
}

/** The hash for a game at a move; the start of the game (move -1) is the bare id. */
export function gameHash(id: string, move: number): string {
  return move >= 0 ? `#${encodeURIComponent(id)}:${move}` : `#${encodeURIComponent(id)}`;
}

// ── Store ─────────────────────────────────────────────────────────

/** Loads the index once and each game on demand; a game read once is kept, a failed read is retried next time. */
export class GameStore {
  private readonly games = new Map<string, Promise<Game>>();
  index: GamesIndex | null = null;

  constructor(
    private readonly base = '/bughouse-games',
    private readonly fetchJson: (url: string) => Promise<unknown> = defaultFetch,
    private readonly warn: (message: string) => void = (m) => console.warn(`bughouse-games: ${m}`),
  ) {}

  async loadIndex(): Promise<GamesIndex> {
    const index = parseIndex(await this.fetchJson(`${this.base}/index.json`), this.warn);
    this.index = index;
    return index;
  }

  get(entry: IndexEntry): Promise<Game> {
    let pending = this.games.get(entry.id);
    if (!pending) {
      pending = this.fetchJson(`${this.base}/${entry.file}`).then((data) => {
        const game = parseGame(data, this.warn);
        if (game.id !== entry.id) throw new ContractError(`${entry.file}: holds game ${game.id}, not ${entry.id}`);
        return game;
      });
      pending.catch(() => { if (this.games.get(entry.id) === pending) this.games.delete(entry.id); });
      this.games.set(entry.id, pending);
    }
    return pending;
  }
}

/** Whether an error is the data breaking the contract (as opposed to the network). */
export function isContractError(e: unknown): boolean { return e instanceof ContractError || e instanceof SyntaxError; }

async function defaultFetch(url: string): Promise<unknown> {
  const res = await fetch(url);
  if (!res.ok) throw new Error(`${res.status} for ${url}`);
  return res.json();
}
