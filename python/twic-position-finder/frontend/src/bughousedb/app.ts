/**
 * BughouseDB: browse Hivemind's precomputed bughouse book, and analyse a
 * missing position in this browser (the /bughouse WASM engine) for everyone.
 *
 * The server (bughousedb.py) owns positions, legal moves and every derived
 * score; this page renders what it returns and, for a missing position, runs
 * the raw searches the server asks for and uploads them unchanged. Boards,
 * move lists and setup boxes are shared with Bughouse Lab (../bughouse/boards).
 */
import { BrowserEngine, type NodeSearchResult } from '../bughouse/engine';
import {
  BOARDS, Boards, LineView, Lines, SEAT, SetupBoxes, readBoard, squaresOf,
  type BoardName, type BoardView, type Colour,
} from '../bughouse/boards';
import {
  ApiError, bookPosition, bookTicket, bookUpload,
  type BookMove, type BookPosition, type BookScore, type Clock, type RawSearch, type Team,
} from '../lib/api';

/** A table column, from the mover's side: their team ahead, even or behind. */
type Column = 'ahead' | 'even' | 'behind';

const START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
const START_DUAL = `${START}|${START}`;
const COLUMNS: Column[] = ['ahead', 'even', 'behind'];
// The browser engine runs one network evaluation (about 80 ms) per node, so a
// browser analysis is far shallower than the desktop builder's 1500/200.
const OWN_NODES = 200;    // each search of the position itself
const CHILD_NODES = 16;   // each search after one move (1 would leave q = -1)
const SECONDS_PER_NODE = 0.085;
const ENGINE = 'hivemind-web';
const BOTTOM: Record<BoardName, Colour> = { A: 'white', B: 'black' };

const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const root = el('bughousedb');
const engine = new BrowserEngine((message) => setStatus(message));

const lines = new Lines(START_DUAL);
/** The last line the server accepted, to step back to if it refuses one. */
let accepted = lines.snapshot();
let cur: BookPosition | null = null;
let hover: BookMove | null = null;
let job: { fen: string; cancelled: boolean } | null = null;

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

const moverTeam = (m: BookMove): Team => (m.seat === 'A' || m.seat === 'C' ? 'AC' : 'BD');

/** Stored scores are for A + C and A + C's clock; the tables read from the mover's side. */
function moverScore(m: BookMove, column: Column): BookScore | undefined {
  const ac = moverTeam(m) === 'AC';
  const clock: Clock = column === 'even' ? 'even' : (column === 'ahead') === ac ? 'ahead' : 'behind';
  const s = m.scores?.[clock];
  if (!s || ac) return s;
  return { ...s, q: s.q === null ? null : -s.q, cp: s.cp === null ? null : -s.cp, mate: s.mate === null ? null : -s.mate };
}

function rank(m: BookMove): number {
  const s = moverScore(m, 'even');
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
      for (const column of COLUMNS) {
        const td = document.createElement('td');
        const s = moverScore(m, column);
        td.textContent = formatScore(s);
        if (s) td.title = s.pv;
        else td.classList.add('none');
        tr.append(td);
      }
      tr.onmouseenter = tr.onfocus = () => setHover(m);
      tr.onmouseleave = tr.onblur = () => setHover(null);
      tr.onclick = () => play(m);
      tr.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); play(m); } };
      body.append(tr);
    });
  }
}

function renderMissing() {
  const missing = el('bdb-missing');
  const running = job !== null;
  missing.hidden = !(running || (cur && !cur.found));
  el<HTMLButtonElement>('bdb-analyse').hidden = running;
  el<HTMLButtonElement>('bdb-cancel').hidden = !running;
  el('bdb-progress').hidden = !running;
  el('bdb-missing-text').textContent = running
    ? (job!.fen === cur?.fen ? 'Analyzing on this computer…' : 'Analyzing an earlier position on this computer…')
    : `Not in the book yet · about ${estimate()}`;
}

function estimate(): string {
  if (!cur) return '';
  const nodes = cur.teams.length * 2 * OWN_NODES + cur.moves.length * 2 * CHILD_NODES;
  const minutes = Math.max(1, Math.round((nodes * SECONDS_PER_NODE) / 60));
  return `${minutes} minute${minutes === 1 ? '' : 's'}`;
}

function render() {
  boards.render(); lineView.render(); renderTables(); renderMissing();
  // Only a browser analysis is worth a note: it is much shallower than the book.
  el('bdb-source').textContent = cur?.meta && cur.meta.source !== 'desktop' ? 'Analyzed in a browser: a quick, shallower search.' : '';
  setup.fill(cur?.fen ?? lines.root);
}

function setHover(m: BookMove | null) { hover = m; boards.renderArrows(); }

function setStatus(text: string, error = false) {
  const s = el('bdb-status');
  s.textContent = text;
  s.dataset.error = String(error);
}

// ── Navigation ────────────────────────────────────────────────────

/**
 * The position for the moves each board has kept. A step the server refuses
 * (one board's drop needed the other's capture) goes back to the last line
 * it accepted.
 */
async function load() {
  const asked = lines.snapshot();
  boards.selected = null; hover = null;
  try {
    const pos = await bookPosition(lines.root, lines.tokens());
    if (JSON.stringify(lines.snapshot()) !== JSON.stringify(asked)) return;  // moved on meanwhile
    cur = pos;
    accepted = asked;
    if (!job) setStatus('');
    setup.error('');
    history.replaceState(null, '', pos.fen === START_DUAL ? location.pathname : `?fen=${encodeURIComponent(pos.fen)}`);
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

function turnstileToken(): string {
  const t = (window as unknown as { turnstile?: { getResponse(): string | undefined } }).turnstile;
  return root.dataset.turnstile ? (t?.getResponse() ?? '') : '';
}

async function search(fen: string, team: Team, ahead: boolean, nodes: number): Promise<RawSearch | null> {
  try {
    const r = await engine.request<NodeSearchResult>('search', {
      dual_fen: fen, team: team === 'AC' ? 'white' : 'black', time_advantage: ahead, nodes,
    });
    return { q: r.mate === null ? r.q : null, mate: r.mate, pv: r.pv, best: r.best?.uci ?? null, nodes: r.nodes };
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
  const total = pos.teams.length * 2 + pos.moves.length * 2;
  let done = 0;
  const started = performance.now();
  const tick = () => {
    done += 1;
    bar.style.width = `${(100 * done) / total}%`;
    const left = ((performance.now() - started) / done) * (total - done) / 1000;
    setStatus(`Searched ${done} of ${total} · about ${left < 90 ? `${Math.round(left)} s` : `${Math.round(left / 60)} min`} left`);
  };
  try {
    setStatus('Getting a ticket…');
    const { ticket } = await bookTicket(pos.fen, turnstileToken());
    setStatus('Loading Hivemind (about 44 MB the first time)…');
    const own: { team: Team; ahead: boolean; search: RawSearch }[] = [];
    for (const team of pos.teams) for (const ahead of [true, false]) {
      if (mine.cancelled) throw new Error('cancelled');
      const s = await search(pos.fen, team, ahead, OWN_NODES);
      if (s) own.push({ team, ahead, search: s });
      tick();
    }
    const moves = [];
    for (const m of pos.moves) {
      if (mine.cancelled) throw new Error('cancelled');
      const on = await search(m.child_fen, m.answerer, true, CHILD_NODES); tick();
      const off = await search(m.child_fen, m.answerer, false, CHILD_NODES); tick();
      moves.push({ board: m.board, uci: m.uci, on, off });
    }
    setStatus('Uploading…');
    await bookUpload({ ticket, fen: pos.fen, engine: ENGINE, nodes: OWN_NODES, child_nodes: CHILD_NODES, own, moves });
    setStatus('Added to the book. Thank you.');
    job = null;
    if (cur?.fen === pos.fen) await load(); else renderMissing();
  } catch (e) {
    job = null;
    if (mine.cancelled) setStatus('Cancelled.');
    else if (e instanceof ApiError && e.status === 409) { setStatus('Someone else just added this position.'); await load(); }
    else setStatus(e instanceof Error && !(e instanceof ApiError) ? e.message : (e as ApiError).message, true);
    bar.style.width = '0';
    renderMissing();
    try { (window as unknown as { turnstile?: { reset(): void } }).turnstile?.reset(); } catch { /* not loaded */ }
  }
}

// ── Wiring ────────────────────────────────────────────────────────

el('bdb-analyse').onclick = () => { analyse(); };
el('bdb-cancel').onclick = () => { if (job) { job.cancelled = true; engine.cancel(); } };
el<HTMLFormElement>('bdb-fen-form').onsubmit = (e) => {
  e.preventDefault();
  const dual = setup.read();
  if (dual) reset(dual);
};
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') boards.deselect(); });

reset(new URLSearchParams(location.search).get('fen') || START_DUAL);
