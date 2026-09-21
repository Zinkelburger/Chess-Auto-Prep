/**
 * BughouseDB: browse Hivemind's precomputed bughouse book, and analyse a
 * missing position in this browser (the /bughouse WASM engine) for everyone.
 *
 * The server (bughousedb.py) owns positions, legal moves and every derived
 * score; this page renders what it returns and, for a missing position, runs
 * the raw searches the server asks for and uploads them unchanged. Boards,
 * move lists and setup boxes are shared with Bughouse Lab (../bughouse/boards).
 */
import { EnginePool, type BrowserEngine, type NodeSearchResult } from '../bughouse/engine';
import {
  BOARDS, Boards, LineView, Lines, SEAT, SetupBoxes, readBoard, squaresOf,
  type BoardName, type BoardView, type Colour, type LineMove,
} from '../bughouse/boards';
import {
  ApiError, bookPosition, bookTicket, bookUpload,
  type BookMove, type BookPosition, type BookScore, type Clock, type RawSearch, type Team,
} from '../lib/api';

const START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
const START_DUAL = `${START}|${START}`;
/**
 * Which team is up on the diagonal clock, and so may wait rather than move
 * while it is on move. The tables show one column, for the clock picked below
 * them.
 *
 * Three states, not four. Both boards start together and exactly one clock per
 * board runs, so `tA + tC = tB + tD` and therefore `tA - tD = tB - tC`: the two
 * diagonal margins are one number, and a team is up, level or down. `both` is
 * stored and served but never offered, because it would need that number to be
 * positive and negative at once; it is the same two searches as `ahead` and
 * `behind` read against a different offset, so it lands on top of Equal.
 */
const PRIORITIES: Clock[] = ['ahead', 'even', 'behind'];
let priority: Clock = 'even';
// The browser engine runs one network evaluation (about 80 ms) per node, so the
// position's own search is far shallower than the desktop builder's 1500. The
// time goes to each board's few moves the search liked most, searched as deeply
// as the desktop builder searches every move; the rest stay unscored.
const OWN_NODES = 200;    // each search of the position itself
const CHILD_NODES = 200;  // each search after one of the top moves
const TOP_MOVES = 4;      // per board
const SECONDS_PER_NODE = 0.085;
const ENGINE = 'hivemind-web';
const BOTTOM: Record<BoardName, Colour> = { A: 'white', B: 'black' };

const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const root = el('bughousedb');
const pool = new EnginePool((message) => setStatus(message));

const lines = new Lines(START_DUAL);
/** The last line the server accepted, to step back to if it refuses one. */
let accepted = lines.snapshot();
let cur: BookPosition | null = null;
let hover: BookMove | null = null;
let job: { fen: string; cancelled: boolean } | null = null;
/** The latest message from loading or analysing; empty shows the position's own note. */
let status = { text: '', error: false };

const boards = new Boards('bdb', { view, play: playUci });
const lineView = new LineView('bdb', lines, () => { void load(); });
const setup = new SetupBoxes('bdb');

function view(name: BoardName): BoardView {
  const data = readBoard((cur?.fen ?? lines.root).split('|')[name === 'A' ? 0 : 1] ?? '');
  const last = lines.current(name);
  return {
    ...data, bottom: BOTTOM[name], turn: cur?.turn[name] ?? null,
    legal: cur ? cur.moves.filter((m) => m.board === name).map((m) => m.uci) : [],
    last: last ? squaresOf(last.uci) : [],
    arrow: hover?.board === name ? hover.uci : null,
  };
}

function moveNumber(fen: string, board: BoardName): number {
  const fields = fen.split('|')[board === 'A' ? 0 : 1].trim().split(/\s+/);
  return Number(fields[5]) || 1;
}

// ── Scores ────────────────────────────────────────────────────────

const moverTeam = (m: BookMove): Team => (m.seat === 'A' || m.seat === 'B' ? 'AB' : 'CD');

/** Stored scores are for A + B; the tables read them from the mover's side. */
function moverScore(m: BookMove, clock: Clock): BookScore | undefined {
  const s = m.scores?.[clock];
  if (!s || moverTeam(m) === 'AB') return s;
  return { ...s, q: s.q === null ? null : -s.q, cp: s.cp === null ? null : -s.cp, mate: s.mate === null ? null : -s.mate };
}

function rank(m: BookMove): number {
  const s = moverScore(m, priority);
  if (!s) return -Infinity;
  return s.mate !== null ? Math.sign(s.mate) * (2 - Math.abs(s.mate) / 1000) : (s.q ?? -Infinity);
}

/** Lichess-style pawns, or a mate count; + is good for the mover. */
function formatScore(s: BookScore | undefined): string {
  if (!s) return '—';
  if (s.mate !== null) return `#${s.mate}`;
  if (s.cp === null) return '—';
  const pawns = s.cp / 100;
  return `${pawns > 0 ? '+' : pawns < 0 ? '−' : ''}${Math.abs(pawns).toFixed(2)}`;
}

// ── Rendering ─────────────────────────────────────────────────────

function renderTables() {
  for (const name of BOARDS) {
    const body = el(`bdb-moves-${name}`);
    body.replaceChildren();
    const turn = cur?.turn[name];
    el(`bdb-mover-${name}`).textContent = turn ? `Move: Player ${SEAT[name][turn]}` : 'Move';
    if (!cur) continue;
    const rows = cur.moves.filter((m) => m.board === name);
    rows.sort(cur.found ? (x, y) => rank(y) - rank(x) : (x, y) => x.san.localeCompare(y.san));
    rows.forEach((m, i) => {
      const tr = document.createElement('tr');
      tr.tabIndex = 0;
      if (cur?.found && i === 0) tr.classList.add('best');
      const move = document.createElement('td');
      move.textContent = m.san;
      tr.append(move);
      const td = document.createElement('td');
      const s = moverScore(m, priority);
      td.textContent = formatScore(s);
      if (s) td.title = s.pv;
      else td.classList.add('none');
      tr.append(td);
      tr.onmouseenter = tr.onfocus = () => setHover(m);
      tr.onmouseleave = tr.onblur = () => setHover(null);
      tr.onclick = () => play(m);
      tr.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); play(m); } };
      body.append(tr);
    });
  }
}

/** The analyse controls keep their place when hidden, and the status line under
 * them is always there, so nothing above the tables moves. */
function renderMissing() {
  const running = job !== null;
  const missing = !!cur && !cur.found;
  el('bdb-missing').dataset.shown = String(running || missing);
  el<HTMLButtonElement>('bdb-analyse').hidden = running;
  el<HTMLButtonElement>('bdb-cancel').hidden = !running;
  el('bdb-progress').hidden = !running;
  coresInput.disabled = running;
  const earlier = running && job!.fen !== cur?.fen ? 'Analyzing an earlier position · ' : '';
  el('bdb-status-text').textContent = earlier + (status.text
    || (missing ? `Not in the book yet · about ${estimate()}` : '')
    // Only a browser analysis is worth a note: it is much shallower than the book.
    || (cur?.meta && cur.meta.source !== 'desktop' ? 'Analyzed in a browser: a quick, shallower search.' : ''));
  el('bdb-status').dataset.error = String(!!status.text && status.error);
}

function estimate(): string {
  if (!cur) return '';
  // Two rounds: the position's own searches, then two per top move.
  const round = (searches: number, nodes: number) => Math.ceil(searches / cores()) * nodes;
  const nodes = round(cur.teams.length * 2, OWN_NODES) + round(2 * topCount(cur), CHILD_NODES);
  const seconds = nodes * SECONDS_PER_NODE;
  return seconds < 90 ? `${Math.max(10, Math.round(seconds / 10) * 10)} s` : `${Math.round(seconds / 60)} min`;
}

// ── Cores ─────────────────────────────────────────────────────────
// One engine worker per core, half the machine's by default; the choice is
// remembered in this browser only.

const coresInput = el<HTMLInputElement>('bdb-cores');
coresInput.max = String(EnginePool.cores());
coresInput.value = (() => {
  try { return localStorage.getItem('bughousedb.cores') ?? ''; } catch { return ''; }
})() || String(EnginePool.defaultSize());

function cores(): number {
  const n = Math.round(Number(coresInput.value));
  return Number.isFinite(n) ? Math.max(1, Math.min(EnginePool.cores(), n)) : EnginePool.defaultSize();
}

coresInput.addEventListener('change', () => {
  coresInput.value = String(cores());
  try { localStorage.setItem('bughousedb.cores', coresInput.value); } catch { /* storage is optional */ }
  renderMissing();
});

function render() {
  boards.render(); lineView.render(); renderTables(); renderMissing();
  setup.fill(cur?.fen ?? lines.root);
}

function setHover(m: BookMove | null) { hover = m; boards.renderArrows(); }

function setStatus(text: string, error = false) {
  status = { text, error };
  renderMissing();
}

// ── The line in the URL ───────────────────────────────────────────
// The address keeps the starting position and the moves played from it, so a
// reload (or a shared link) opens the same position with its history intact
// and every earlier move still there to step back to.

/**
 * The start, the whole line, and how far each board has stepped along it:
 * `?moves=A:e2e4 B:e7e5&at=1,0`. The moves past the cursor are kept too, so
 * stepping back and reloading still leaves them to step forward into.
 */
function writeUrl() {
  const params = new URLSearchParams();
  if (lines.root !== START_DUAL) params.set('fen', lines.root);
  if (lines.moves.length) params.set('moves', lines.moves.map((m) => `${m.board}:${m.uci}`).join(' '));
  if (BOARDS.some((name) => lines.upto[name] < lines.of(name).length)) {
    params.set('at', BOARDS.map((name) => lines.upto[name]).join(','));
  }
  const query = params.toString();
  history.replaceState(null, '', query ? `?${query}` : location.pathname);
}

/**
 * The position each move of the line was played in, asked for at once. A
 * server that refuses overlapping requests is asked again one at a time, so
 * the line still comes back for a visitor whose server is older than this.
 */
async function positionsAlong(root: string, tokens: string[]): Promise<(BookPosition | null)[]> {
  const ask = (k: number) => bookPosition(root, tokens.slice(0, k)).catch(() => null);
  const together = await Promise.all(tokens.map((_, k) => ask(k)));
  if (together.every(Boolean)) return together;
  const alone: (BookPosition | null)[] = [];
  for (const [k, pos] of together.entries()) alone.push(pos ?? await ask(k));
  return alone;
}

/**
 * The moves of a line from the URL, each with the SAN, side and move number
 * of the position it was played in — the same `LineMove` clicking it builds.
 * A move the book no longer accepts ends the line there rather than dropping
 * the whole history.
 */
async function replay(root: string, tokens: string[]): Promise<LineMove[]> {
  const before = await positionsAlong(root, tokens);
  const played: LineMove[] = [];
  for (const [k, token] of tokens.entries()) {
    const pos = before[k];
    const board = token.slice(0, token.indexOf(':')) as BoardName;
    const uci = token.slice(token.indexOf(':') + 1);
    const move = pos?.moves.find((m) => m.board === board && m.uci === uci);
    if (!pos || !move) break;
    played.push({ board, uci, san: move.san, colour: pos.turn[board], num: moveNumber(pos.fen, board) });
  }
  return played;
}

/**
 * Open a start position, with a line played out on it if the URL kept one and
 * each board stepped to where it was left (`at`, default the whole line).
 */
async function openLine(root: string, tokens: string[], at: number[]) {
  lines.reset(root);
  if (tokens.length) {
    setStatus('Replaying the line…');
    for (const move of await replay(root, tokens)) lines.play(move);
    BOARDS.forEach((name, i) => { if (at[i] !== undefined) lines.go(name, at[i]); });
  }
  accepted = lines.snapshot();
  await load();
}

// ── Navigation ────────────────────────────────────────────────────

/**
 * The position for the moves each board has kept. A step the server refuses
 * (one board's drop needed the other's capture) goes back to the last line
 * it accepted.
 */
async function load() {
  const asked = lines.snapshot();
  boards.deselect(); hover = null;
  try {
    const pos = await bookPosition(lines.root, lines.tokens());
    if (JSON.stringify(lines.snapshot()) !== JSON.stringify(asked)) return;  // moved on meanwhile
    cur = pos;
    accepted = asked;
    if (!job) setStatus('');
    setup.error('');
    writeUrl();
  } catch (e) {
    if (JSON.stringify(lines.snapshot()) !== JSON.stringify(asked)) return;
    const message = e instanceof ApiError ? e.message : 'Could not reach the book.';
    if (e instanceof ApiError && e.status === 400 && lines.moves.length) {
      lines.restore(accepted);
      setup.error(`Can’t step there: ${message} A drop may need the capture on the other board.`);
    } else {
      cur = null;
      setup.error(message);
    }
  }
  render();
}

function play(m: BookMove) {
  if (!cur) return;
  lines.play({ board: m.board, uci: m.uci, san: m.san, colour: cur.turn[m.board], num: moveNumber(cur.fen, m.board) });
  void load();
}

/** From the board: several moves only when a pawn promotes; the book takes the queen. */
function playUci(name: BoardName, ucis: string[]) {
  const uci = ucis.find((u) => u.endsWith('q')) ?? ucis[0];
  const m = cur?.moves.find((x) => x.board === name && x.uci === uci);
  if (m) play(m);
}

function reset(fen: string) {
  lines.reset(fen);
  accepted = lines.snapshot();
  void load();
}

// ── Analysing a missing position in this browser ──────────────────

// ── CAPTCHA ───────────────────────────────────────────────────────
// A ticket needs a fresh Turnstile token. The widget sits in the "not in the
// book" strip, which is hidden when the page loads, so Cloudflare's automatic
// render never draws it and no token ever comes: it is rendered here instead,
// once per analysis, and its token awaited. Usually no puzzle appears at all.

interface Turnstile {
  render(el: HTMLElement, options: Record<string, unknown>): string;
  remove(widget: string): void;
}
let captcha: string | null = null;

async function turnstileApi(): Promise<Turnstile> {
  for (let waited = 0; waited < 15000; waited += 100) {
    const t = (window as unknown as { turnstile?: Turnstile }).turnstile;
    if (t) return t;
    await new Promise((r) => setTimeout(r, 100));
  }
  throw new Error('The CAPTCHA did not load. Check that challenges.cloudflare.com is not blocked.');
}

/** A token for one ticket, or '' when the site runs without a CAPTCHA. */
async function captchaToken(): Promise<string> {
  const sitekey = root.dataset.turnstile;
  if (!sitekey) return '';
  const turnstile = await turnstileApi();
  if (captcha !== null) turnstile.remove(captcha);
  return new Promise((resolve, reject) => {
    captcha = turnstile.render(el('bdb-captcha'), {
      sitekey,
      appearance: 'interaction-only',
      callback: (token: string) => resolve(token),
      'error-callback': (code: string) => reject(new Error(`The CAPTCHA failed (${code}). Try again.`)),
      'timeout-callback': () => reject(new Error('The CAPTCHA timed out. Try again.')),
    });
  });
}

/** How many moves an analysis scores: up to TOP_MOVES on each board. */
function topCount(pos: BookPosition): number {
  return BOARDS.reduce((n, name) => n + Math.min(TOP_MOVES, pos.moves.filter((m) => m.board === name).length), 0);
}

/**
 * Each board's TOP_MOVES from its mover's own searches (both clock bits),
 * ranked by the visits the searches gave them, then by the network's prior.
 */
function topMoves(pos: BookPosition, own: { team: Team; ranked: NodeSearchResult['moves'] }[]): Set<string> {
  const picked = new Set<string>();
  for (const name of BOARDS) {
    const legal = pos.moves.filter((m) => m.board === name);
    if (!legal.length) continue;
    const mover = moverTeam(legal[0]);
    const score = new Map<string, { visits: number; prior: number }>();
    for (const o of own) {
      if (o.team !== mover) continue;
      for (const m of o.ranked) {
        if (m.board !== name) continue;
        const s = score.get(m.uci) ?? { visits: 0, prior: 0 };
        score.set(m.uci, { visits: s.visits + m.visits, prior: Math.max(s.prior, m.prior) });
      }
    }
    legal.map((m) => m.uci).filter((uci) => score.has(uci))
      .sort((a, b) => score.get(b)!.visits - score.get(a)!.visits || score.get(b)!.prior - score.get(a)!.prior)
      .slice(0, TOP_MOVES)
      .forEach((uci) => picked.add(`${name}:${uci}`));
  }
  return picked;
}

async function search(engine: BrowserEngine, fen: string, team: Team, ahead: boolean, nodes: number): Promise<(RawSearch & { ranked: NodeSearchResult['moves'] }) | null> {
  try {
    const r = await engine.request<NodeSearchResult>('search', {
      dual_fen: fen, team: team === 'AB' ? 'white' : 'black', time_advantage: ahead, nodes,
    });
    return { q: r.mate === null ? r.q : null, mate: r.mate, pv: r.pv, best: r.best?.uci ?? null, nodes: r.nodes, ranked: r.moves ?? [] };
  } catch (e) {
    // The answering side can have no legal move (mated); that search is empty.
    if (e instanceof Error && /no move available/i.test(e.message)) return null;
    throw e;
  }
}

async function analyse() {
  if (!cur || cur.found || job) return;
  const pos = cur;
  const mine = { fen: pos.fen, cancelled: false };
  job = mine;
  renderMissing();
  const bar = el('bdb-progress').firstElementChild as HTMLElement;
  let total = pos.teams.length * 2 + 2 * topCount(pos);
  let done = 0;
  const started = performance.now();
  const tick = () => {
    done += 1;
    bar.style.width = `${(100 * done) / total}%`;
    const left = ((performance.now() - started) / done) * (total - done) / 1000;
    setStatus(`Searched ${done} of ${total} · about ${left < 90 ? `${Math.round(left)} s` : `${Math.round(left / 60)} min`} left`);
  };
  try {
    setStatus('Checking you are not a robot…');
    const token = await captchaToken();
    setStatus('Getting a ticket…');
    const { ticket } = await bookTicket(pos.fen, token);
    setStatus('Loading Hivemind (about 44 MB the first time)…');
    // The position's own searches first; they rank each board's moves.
    type Task = { fen: string; team: Team; ahead: boolean; nodes: number };
    const run = (tasks: Task[]) => pool.map(cores(), tasks, async (engine, t) => {
      if (mine.cancelled) throw new Error('cancelled');
      const s = await search(engine, t.fen, t.team, t.ahead, t.nodes);
      tick();
      return s;
    });
    const ownTasks: Task[] = pos.teams.flatMap((team) => [true, false].map((ahead) => ({ fen: pos.fen, team, ahead, nodes: OWN_NODES })));
    const ownResults = await run(ownTasks);
    const top = topMoves(pos, ownTasks.flatMap((t, i) => (ownResults[i] ? [{ team: t.team, ranked: ownResults[i]!.ranked }] : [])));
    // Then the answering team's search after each top move, under both clock bits.
    const scored = pos.moves.filter((m) => top.has(`${m.board}:${m.uci}`));
    total = ownTasks.length + 2 * scored.length;
    const moveTasks: Task[] = scored.flatMap((m) => [true, false].map((ahead) => ({ fen: m.child_fen, team: m.answerer, ahead, nodes: CHILD_NODES })));
    const moveResults = await run(moveTasks);
    const raw = (s: Awaited<ReturnType<typeof search>> | undefined): RawSearch | null =>
      s ? { q: s.q, mate: s.mate, pv: s.pv, best: s.best, nodes: s.nodes } : null;
    const own = ownTasks.flatMap((t, i) => (ownResults[i] ? [{ team: t.team, ahead: t.ahead, search: raw(ownResults[i])! }] : []));
    // Every legal move is sent; the unscored ones carry no search.
    const moves = pos.moves.map((m) => {
      const i = scored.indexOf(m);
      return { board: m.board, uci: m.uci, on: i < 0 ? null : raw(moveResults[2 * i]), off: i < 0 ? null : raw(moveResults[2 * i + 1]) };
    });
    setStatus('Uploading…');
    await bookUpload({ ticket, fen: pos.fen, engine: ENGINE, nodes: OWN_NODES, child_nodes: CHILD_NODES, own, moves });
    job = null;
    if (cur?.fen === pos.fen) await load();
    setStatus('Added to the book. Thank you.');
  } catch (e) {
    job = null;
    if (mine.cancelled) setStatus('Cancelled.');
    else if (e instanceof ApiError && e.status === 409) { setStatus('Someone else just added this position.'); await load(); }
    else setStatus(e instanceof Error && !(e instanceof ApiError) ? e.message : (e as ApiError).message, true);
    bar.style.width = '0';
    renderMissing();
  }
}

// ── Wiring ────────────────────────────────────────────────────────

el('bdb-analyse').onclick = () => { analyse(); };
el('bdb-cancel').onclick = () => { if (job) { job.cancelled = true; pool.cancel(); } };
el<HTMLFormElement>('bdb-fen-form').onsubmit = (e) => {
  e.preventDefault();
  const dual = setup.read();
  if (dual) reset(dual);
};
for (const input of document.querySelectorAll<HTMLInputElement>('input[name="bdb-priority"]')) {
  input.addEventListener('change', () => {
    if (!input.checked) return;
    priority = PRIORITIES.find((p) => p === input.value) ?? 'even';
    render();
  });
}
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') boards.deselect(); });

const opened = new URLSearchParams(location.search);
void openLine(
  opened.get('fen') || START_DUAL,
  (opened.get('moves') ?? '').split(/\s+/).filter(Boolean),
  (opened.get('at') ?? '').split(',').filter((n) => n !== '').map(Number).filter(Number.isInteger),
);
