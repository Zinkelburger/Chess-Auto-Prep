/**
 * BughouseDB: browse Hivemind's precomputed bughouse book, and analyse a
 * missing position in this browser (the /bughouse WASM engine) for everyone.
 *
 * The server (bughousedb.py) owns positions, legal moves and every derived
 * score; this page renders what it returns and, for a missing position, runs
 * the raw searches the server asks for and uploads them unchanged.
 */
import { BrowserEngine, type NodeSearchResult } from '../bughouse/engine';
import {
  ApiError, bookPosition, bookTicket, bookUpload,
  type BookMove, type BookPosition, type Clock, type RawSearch, type Team,
} from '../lib/api';

type BoardName = 'A' | 'B';
type Colour = 'white' | 'black';

const START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
const START_DUAL = `${START}|${START}`;
const CLOCKS: Clock[] = ['ahead', 'even', 'behind'];
// The browser engine runs one network evaluation (about 80 ms) per node, so a
// browser analysis is far shallower than the desktop builder's 1500/200.
const OWN_NODES = 200;    // each search of the position itself
const CHILD_NODES = 16;   // each search after one move (1 would leave q = -1)
const SECONDS_PER_NODE = 0.085;
const ENGINE = 'hivemind-web';

const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const root = el('bughousedb');
const engine = new BrowserEngine((message) => setStatus(message));

/** Seats: board A has A (White) and B (Black); board B has D (White) and C (Black). */
const SEAT: Record<BoardName, Record<Colour, string>> = { A: { white: 'A', black: 'B' }, B: { white: 'D', black: 'C' } };
const BOTTOM: Record<BoardName, Colour> = { A: 'white', B: 'black' };
const PIECE_NAMES: Record<string, string> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };

interface Step { fen: string; seat: string | null; san: string | null }
let path: Step[] = [{ fen: START_DUAL, seat: null, san: null }];
let cur: BookPosition | null = null;
let selected: { board: BoardName; from?: string; drop?: string } | null = null;
let hover: BookMove | null = null;
let job: { fen: string; cancelled: boolean } | null = null;

// ── Reading a dual FEN for display ────────────────────────────────

function parseBoard(fen: string): { pieces: Record<string, string>; pockets: Record<Colour, string> } {
  const field = fen.split(' ')[0];
  const open = field.indexOf('[');
  const placement = (open >= 0 ? field.slice(0, open) : field).replace(/~/g, '');
  const pocket = open >= 0 ? field.slice(open + 1, field.indexOf(']', open)) : '';
  const pieces: Record<string, string> = {};
  placement.split('/').forEach((rank, r) => {
    let file = 0;
    for (const ch of rank) {
      if (/\d/.test(ch)) { file += Number(ch); continue; }
      pieces['abcdefgh'[file] + String(8 - r)] = ch;
      file += 1;
    }
  });
  return { pieces, pockets: { white: [...pocket].filter((c) => c === c.toUpperCase()).join(''), black: [...pocket].filter((c) => c !== c.toUpperCase()).join('') } };
}

function boardsOf(fen: string): Record<BoardName, ReturnType<typeof parseBoard>> {
  const [a, b] = fen.split('|');
  return { A: parseBoard(a), B: parseBoard(b) };
}

// ── Scores ────────────────────────────────────────────────────────

function forMover(m: BookMove, clock: Clock): number {
  const s = m.scores?.[clock];
  if (!s) return -Infinity;
  const ours = s.mate !== null ? Math.sign(s.mate) * (2 - Math.abs(s.mate) / 1000) : (s.q ?? -Infinity);
  return m.seat === 'A' || m.seat === 'C' ? ours : -ours;
}

function scoreText(m: BookMove, clock: Clock): string {
  return formatScore(m.scores?.[clock]);
}

/** Lichess-style pawns, or a mate count; + is good for A + C. */
function formatScore(s: { cp: number | null; mate: number | null } | undefined): string {
  if (!s) return '—';
  if (s.mate !== null) return `#${s.mate}`;
  if (s.cp === null) return '—';
  const pawns = s.cp / 100;
  return `${pawns > 0 ? '+' : pawns < 0 ? '−' : ''}${Math.abs(pawns).toFixed(2)}`;
}

// ── Rendering ─────────────────────────────────────────────────────

function image(piece: string): HTMLImageElement {
  const img = document.createElement('img');
  img.src = `/piece/${piece === piece.toUpperCase() ? 'w' : 'b'}${piece.toUpperCase()}.svg`;
  img.alt = '';
  return img;
}

function highlightSquares(board: BoardName): string[] {
  if (!hover || hover.board !== board) return [];
  const u = hover.uci;
  return u.includes('@') ? [u.slice(2, 4)] : [u.slice(0, 2), u.slice(2, 4)];
}

function candidates(board: BoardName): BookMove[] {
  if (!cur || selected?.board !== board) return [];
  return cur.moves.filter((m) => m.board === board && (selected?.drop
    ? m.uci.startsWith(`${selected.drop}@`)
    : !m.uci.includes('@') && m.uci.startsWith(selected?.from ?? '?')));
}

function renderBoard(name: BoardName) {
  const data = cur ? boardsOf(cur.fen)[name] : boardsOf(path[path.length - 1].fen)[name];
  const bottom = BOTTOM[name];
  const files = bottom === 'white' ? 'abcdefgh' : 'hgfedcba';
  const ranks = bottom === 'white' ? '87654321' : '12345678';
  const container = el(`bdb-board-${name}`);
  container.replaceChildren();
  const marks = highlightSquares(name);
  const targets = candidates(name).map((m) => m.uci.slice(2, 4));
  for (let row = 0; row < 8; row++) for (let col = 0; col < 8; col++) {
    const square = files[col] + ranks[row];
    const piece = data.pieces[square];
    const button = document.createElement('button');
    button.className = `bdb-square${(row + col) % 2 ? ' dark' : ''}`;
    if (marks.includes(square)) button.classList.add('hl');
    if (selected?.board === name && selected.from === square) button.classList.add('selected');
    if (targets.includes(square)) button.classList.add('target');
    button.setAttribute('aria-label', `Board ${name === 'A' ? 1 : 2} ${square}${piece ? ` ${piece === piece.toUpperCase() ? 'white' : 'black'} ${PIECE_NAMES[piece.toLowerCase()]}` : ''}`);
    if (piece) button.append(image(piece));
    if (row === 7) { const f = document.createElement('span'); f.className = 'bdb-coord file'; f.textContent = files[col]; button.append(f); }
    if (col === 0) { const r = document.createElement('span'); r.className = 'bdb-coord rank'; r.textContent = ranks[row]; button.append(r); }
    button.onclick = () => clickSquare(name, square);
    container.append(button);
  }
  const turn = cur?.turn[name];
  el(`bdb-turn-${name}`).textContent = turn ? `${SEAT[name][turn]} to move` : '';
  for (const [where, colour] of [['top', bottom === 'white' ? 'black' : 'white'], ['bottom', bottom]] as const) {
    const box = el(`bdb-reserve-${where}-${name}`);
    box.replaceChildren();
    const who = document.createElement('span');
    who.className = `who${turn === colour ? ' to-move' : ''}`;
    who.textContent = SEAT[name][colour];
    box.append(who);
    const pocket = data.pockets[colour];
    for (const p of ['p', 'n', 'b', 'r', 'q']) {
      const count = [...pocket].filter((c) => c.toLowerCase() === p).length;
      if (!count) continue;
      const button = document.createElement('button');
      button.className = 'bdb-pocket';
      const letter = p.toUpperCase();
      button.append(image(colour === 'white' ? letter : p), document.createTextNode(String(count)));
      button.setAttribute('aria-label', `${SEAT[name][colour]}: ${count} ${PIECE_NAMES[p]} in reserve`);
      button.setAttribute('aria-pressed', String(selected?.board === name && selected.drop === letter));
      button.disabled = turn !== colour || !cur?.moves.some((m) => m.board === name && m.uci.startsWith(`${letter}@`));
      button.onclick = () => { selected = selected?.board === name && selected.drop === letter ? null : { board: name, drop: letter }; renderBoards(); };
      box.append(button);
    }
  }
}

function renderBoards() { renderBoard('A'); renderBoard('B'); }

function renderTables() {
  for (const name of ['A', 'B'] as BoardName[]) {
    const body = el(`bdb-moves-${name}`);
    body.replaceChildren();
    if (!cur) continue;
    const rows = cur.moves.filter((m) => m.board === name);
    rows.sort(cur.found ? (x, y) => forMover(y, 'even') - forMover(x, 'even') : (x, y) => x.san.localeCompare(y.san));
    rows.forEach((m, i) => {
      const tr = document.createElement('tr');
      tr.tabIndex = 0;
      if (cur?.found && i === 0) tr.classList.add('best');
      const move = document.createElement('td');
      const seat = document.createElement('span'); seat.className = 'seat'; seat.textContent = m.seat;
      move.append(seat, document.createTextNode(m.san));
      tr.append(move);
      for (const clock of CLOCKS) {
        const td = document.createElement('td');
        td.textContent = scoreText(m, clock);
        if (!m.scores) td.classList.add('none');
        tr.append(td);
      }
      tr.onmouseenter = tr.onfocus = () => setHover(m);
      tr.onmouseleave = tr.onblur = () => setHover(null);
      tr.onclick = () => play(m);
      tr.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); play(m); } };
      body.append(tr);
    });
  }
}

function renderPv() {
  for (const clock of CLOCKS) {
    const out = el(`bdb-pv-${clock}`);
    if (hover) {
      out.textContent = hover.scores ? `${scoreText(hover, clock)}  ${hover.scores[clock].pv}` : '';
      continue;
    }
    // At rest: Hivemind's own pick for the team to move on board 1.
    const team: Team | undefined = cur ? (cur.turn.A === 'white' ? 'AC' : 'BD') : undefined;
    const pick = cur?.picks.find((p) => p.clock === clock && p.team === team)
      ?? cur?.picks.find((p) => p.clock === clock);
    out.textContent = pick ? `${formatScore(pick)}  ${pick.pv || pick.best}` : '';
  }
}

function renderPath() {
  const nav = el('bdb-path');
  nav.replaceChildren();
  path.forEach((step, i) => {
    if (i) { const sep = document.createElement('span'); sep.className = 'sep'; sep.textContent = '›'; nav.append(sep); }
    const b = document.createElement('button');
    b.setAttribute('aria-current', String(i === path.length - 1));
    if (step.seat) { const s = document.createElement('span'); s.className = 'seat'; s.textContent = step.seat; b.append(s); }
    b.append(document.createTextNode(step.san ?? 'Start'));
    b.onclick = () => { path = path.slice(0, i + 1); load(); };
    nav.append(b);
  });
  el<HTMLButtonElement>('bdb-back').disabled = path.length < 2;
}

function renderMissing() {
  const missing = el('bdb-missing');
  const running = job !== null;
  missing.hidden = !(running || (cur && !cur.found));
  el<HTMLButtonElement>('bdb-analyse').hidden = running;
  el<HTMLButtonElement>('bdb-cancel').hidden = !running;
  el('bdb-progress').hidden = !running;
  el('bdb-missing-text').textContent = running
    ? (job!.fen === cur?.fen ? 'Analyzing this position on your computer.' : 'Analyzing an earlier position on your computer.')
    : `No data for this position. Analyzing it here takes about ${estimate()} and adds it to the book.`;
}

function estimate(): string {
  if (!cur) return '';
  const nodes = cur.teams.length * 2 * OWN_NODES + cur.moves.length * 2 * CHILD_NODES;
  const minutes = Math.max(1, Math.round((nodes * SECONDS_PER_NODE) / 60));
  return `${minutes} minute${minutes === 1 ? '' : 's'}`;
}

function renderMeta() {
  const meta = cur?.meta;
  el('bdb-meta').textContent = meta
    ? `Hivemind · ${meta.nodes.toLocaleString()} nodes a position, ${meta.child_nodes.toLocaleString()} a move · ${meta.source === 'desktop' ? 'desktop engine' : 'computed in a browser'}`
    : '';
}

function render() {
  renderPath(); renderMeta(); renderBoards(); renderTables(); renderPv(); renderMissing();
  el<HTMLInputElement>('bdb-fen').value = cur?.fen ?? path[path.length - 1].fen;
}

function setHover(m: BookMove | null) { hover = m; renderBoards(); renderPv(); }

function setStatus(text: string, error = false) {
  const s = el('bdb-status');
  s.textContent = text;
  s.dataset.error = String(error);
}

// ── Navigation ────────────────────────────────────────────────────

async function load() {
  const step = path[path.length - 1];
  selected = null; hover = null;
  history.replaceState(null, '', step.fen === START_DUAL ? location.pathname : `?fen=${encodeURIComponent(step.fen)}`);
  try {
    cur = await bookPosition(step.fen);
    if (!job) setStatus('');
  } catch (e) {
    cur = null;
    setStatus(e instanceof ApiError ? e.message : 'Could not reach the book.', true);
  }
  render();
}

function play(m: BookMove) {
  path.push({ fen: m.child_fen, seat: m.seat, san: m.san });
  load();
}

function clickSquare(board: BoardName, square: string) {
  if (!cur) return;
  const own = cur.moves.filter((m) => m.board === board);
  if (selected?.board === board) {
    const hit = candidates(board).filter((m) => m.uci.slice(2, 4) === square);
    if (hit.length) { play(hit.find((m) => m.uci.endsWith('q')) ?? hit[0]); return; }
  }
  selected = own.some((m) => !m.uci.includes('@') && m.uci.startsWith(square)) ? { board, from: square } : null;
  renderBoards();
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
el('bdb-start').onclick = () => { path = [path[0]]; load(); };
el('bdb-back').onclick = () => { if (path.length > 1) { path.pop(); load(); } };
el<HTMLFormElement>('bdb-fen-form').onsubmit = (e) => {
  e.preventDefault();
  const fen = el<HTMLInputElement>('bdb-fen').value.trim();
  if (fen) { path = [{ fen, seat: null, san: null }]; load(); }
};
document.addEventListener('keydown', (e) => {
  const t = e.target as HTMLElement;
  if (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA') return;
  if (e.key === 'ArrowLeft' && path.length > 1) { e.preventDefault(); path.pop(); load(); }
  else if (e.key === 'Home') { e.preventDefault(); path = [path[0]]; load(); }
  else if (e.key === 'Escape' && selected) { selected = null; renderBoards(); }
});

const initial = new URLSearchParams(location.search).get('fen');
if (initial) path = [{ fen: initial, seat: null, san: null }];
load();
