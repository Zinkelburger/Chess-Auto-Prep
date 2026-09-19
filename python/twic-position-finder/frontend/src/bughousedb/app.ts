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
  type BookMove, type BookPosition, type BookScore, type Clock, type RawSearch, type Team,
} from '../lib/api';

type BoardName = 'A' | 'B';
type Colour = 'white' | 'black';
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

const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const root = el('bughousedb');
const engine = new BrowserEngine((message) => setStatus(message));

/** Seats: board A has A (White) and B (Black); board B has D (White) and C (Black). */
const SEAT: Record<BoardName, Record<Colour, string>> = { A: { white: 'A', black: 'B' }, B: { white: 'D', black: 'C' } };
const BOTTOM: Record<BoardName, Colour> = { A: 'white', B: 'black' };
const PIECE_NAMES: Record<string, string> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };

/**
 * The game is one interleaved line of moves, like a FICS bpgn; each board's
 * history shows only its own moves. `ply` is the position on screen, and the
 * moves after it stay in the line until a different move replaces them.
 */
interface Step { fen: string; board: BoardName | null; colour: Colour | null; num: number; uci: string; san: string }
let line: Step[] = [{ fen: START_DUAL, board: null, colour: null, num: 0, uci: '', san: '' }];
let ply = 0;
let cur: BookPosition | null = null;
let selected: { board: BoardName; from?: string; drop?: string } | null = null;
let hover: BookMove | null = null;
let job: { fen: string; cancelled: boolean } | null = null;
/** A piece being dragged from a square or a pocket; `ghost` exists once it has moved. */
let drag: { board: BoardName; from?: string; drop?: string; piece: string; x: number; y: number; ghost?: HTMLImageElement } | null = null;
let swallowClick = false;

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

function image(piece: string): HTMLImageElement {
  const img = document.createElement('img');
  img.src = `/piece/${piece === piece.toUpperCase() ? 'w' : 'b'}${piece.toUpperCase()}.svg`;
  img.alt = '';
  return img;
}

function squares(uci: string): string[] {
  return uci.includes('@') ? [uci.slice(2, 4)] : [uci.slice(0, 2), uci.slice(2, 4)];
}

function lastMove(board: BoardName): Step | undefined {
  for (let i = ply; i > 0; i--) if (line[i].board === board) return line[i];
  return undefined;
}

function candidates(board: BoardName): BookMove[] {
  if (!cur || selected?.board !== board) return [];
  return cur.moves.filter((m) => m.board === board && (selected?.drop
    ? m.uci.startsWith(`${selected.drop}@`)
    : !m.uci.includes('@') && m.uci.startsWith(selected?.from ?? '?')));
}

/** Square centre in the board's 8×8 view box. */
function centre(board: BoardName, square: string): [number, number] {
  const file = 'abcdefgh'.indexOf(square[0]);
  const rank = Number(square[1]);
  return BOTTOM[board] === 'white' ? [file + 0.5, 8 - rank + 0.5] : [7 - file + 0.5, rank - 0.5];
}

/** Hovering a table row draws the move, as Lichess's explorer does. */
function renderArrow(board: BoardName) {
  const svg = el(`bdb-arrow-${board}`);
  if (!hover || hover.board !== board) { svg.innerHTML = ''; return; }
  const [to] = squares(hover.uci).slice(-1);
  const [x2, y2] = centre(board, to);
  const brush = 'stroke="#003088" stroke-opacity="0.5"';
  if (hover.uci.includes('@')) {
    svg.innerHTML = `<circle cx="${x2}" cy="${y2}" r="0.44" fill="none" ${brush} stroke-width="0.08"/>`;
    return;
  }
  const [x1, y1] = centre(board, hover.uci.slice(0, 2));
  const len = Math.hypot(x2 - x1, y2 - y1);
  const [ex, ey] = [x2 - ((x2 - x1) / len) * 0.3, y2 - ((y2 - y1) / len) * 0.3];
  svg.innerHTML = `<defs><marker id="bdb-head-${board}" orient="auto" markerWidth="4" markerHeight="4" refX="2.05" refY="2">`
    + `<path d="M0,0 V4 L3,2 Z" fill="#003088" fill-opacity="0.5"/></marker></defs>`
    + `<line x1="${x1}" y1="${y1}" x2="${ex}" y2="${ey}" ${brush} stroke-width="0.2" stroke-linecap="round" marker-end="url(#bdb-head-${board})"/>`;
}

function renderBoard(name: BoardName) {
  const data = boardsOf(cur?.fen ?? line[ply].fen)[name];
  const bottom = BOTTOM[name];
  const files = bottom === 'white' ? 'abcdefgh' : 'hgfedcba';
  const ranks = bottom === 'white' ? '87654321' : '12345678';
  const container = el(`bdb-board-${name}`);
  container.replaceChildren();
  const last = lastMove(name);
  const marks = last ? squares(last.uci) : [];
  const targets = candidates(name).map((m) => m.uci.slice(2, 4));
  for (let row = 0; row < 8; row++) for (let col = 0; col < 8; col++) {
    const square = files[col] + ranks[row];
    const piece = data.pieces[square];
    const button = document.createElement('button');
    button.className = `bdb-square${(row + col) % 2 ? ' dark' : ''}`;
    if (marks.includes(square)) button.classList.add('last');
    if (selected?.board === name && selected.from === square) button.classList.add('selected');
    if (targets.includes(square)) button.classList.add('target');
    if (drag?.ghost && drag.board === name && drag.from === square) button.classList.add('dragging');
    button.dataset.board = name;
    button.dataset.square = square;
    if (piece && cur?.moves.some((m) => m.board === name && m.uci.startsWith(square))) {
      button.onpointerdown = (e) => startDrag(e, { board: name, from: square, piece });
    }
    button.setAttribute('aria-label', `Board ${name === 'A' ? 1 : 2} ${square}${piece ? ` ${piece === piece.toUpperCase() ? 'white' : 'black'} ${PIECE_NAMES[piece.toLowerCase()]}` : ''}`);
    if (piece) button.append(image(piece));
    if (row === 7) { const f = document.createElement('span'); f.className = 'bdb-coord file'; f.textContent = files[col]; button.append(f); }
    if (col === 0) { const r = document.createElement('span'); r.className = 'bdb-coord rank'; r.textContent = ranks[row]; button.append(r); }
    button.onclick = () => clickSquare(name, square);
    container.append(button);
  }
  renderArrow(name);
  const turn = cur?.turn[name];
  for (const [where, colour] of [['top', bottom === 'white' ? 'black' : 'white'], ['bottom', bottom]] as const) {
    const box = el(`bdb-player-${where}-${name}`);
    box.replaceChildren();
    box.classList.toggle('to-move', turn === colour);
    const dot = document.createElement('span');
    dot.className = `turn ${colour}`;
    dot.title = `${colour === 'white' ? 'White' : 'Black'} to move`;
    const who = document.createElement('span');
    who.className = 'who';
    who.textContent = `Player ${SEAT[name][colour]}`;
    box.append(dot, who);
    const pocket = data.pockets[colour];
    for (const p of ['p', 'n', 'b', 'r', 'q']) {
      const count = [...pocket].filter((c) => c.toLowerCase() === p).length;
      if (!count) continue;
      const button = document.createElement('button');
      button.className = 'bdb-pocket';
      const letter = p.toUpperCase();
      button.append(image(colour === 'white' ? letter : p), document.createTextNode(String(count)));
      button.setAttribute('aria-label', `Player ${SEAT[name][colour]}: ${count} ${PIECE_NAMES[p]} in reserve`);
      button.setAttribute('aria-pressed', String(selected?.board === name && selected.drop === letter));
      button.disabled = turn !== colour || !cur?.moves.some((m) => m.board === name && m.uci.startsWith(`${letter}@`));
      button.onclick = () => { selected = selected?.board === name && selected.drop === letter ? null : { board: name, drop: letter }; renderBoards(); };
      if (!button.disabled) button.onpointerdown = (e) => startDrag(e, { board: name, drop: letter, piece: colour === 'white' ? letter : p });
      box.append(button);
    }
  }
}

function renderBoards() { renderBoard('A'); renderBoard('B'); }

function renderTables() {
  for (const name of ['A', 'B'] as BoardName[]) {
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
      tr.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); play(m); } };
      body.append(tr);
    });
  }
}

/** Each board's own moves, numbered as that board counts them. */
function renderHistory(name: BoardName) {
  const list = el(`bdb-history-${name}`);
  list.replaceChildren();
  const current = lastMove(name);
  let row: HTMLLIElement | null = null;
  line.forEach((step, i) => {
    if (step.board !== name) return;
    if (!row || step.colour === 'white') {
      row = document.createElement('li');
      const num = document.createElement('span');
      num.className = 'num';
      num.textContent = `${step.num}.`;
      row.append(num);
      if (step.colour === 'black') { const gap = document.createElement('span'); gap.className = 'none'; gap.textContent = '…'; row.append(gap); }
      list.append(row);
    }
    const b = document.createElement('button');
    b.textContent = step.san;
    b.title = `Player ${SEAT[name][step.colour!]}`;
    if (i > ply) b.classList.add('future');
    b.setAttribute('aria-current', String(step === current));
    b.onclick = () => go(i);
    row.append(b);
    if (step.colour === 'black') row = null;
  });
  list.querySelector('[aria-current="true"]')?.scrollIntoView({ block: 'nearest' });
}

function renderNav() {
  el<HTMLButtonElement>('bdb-first').disabled = ply === 0;
  el<HTMLButtonElement>('bdb-prev').disabled = ply === 0;
  el<HTMLButtonElement>('bdb-next').disabled = ply === line.length - 1;
  el<HTMLButtonElement>('bdb-last').disabled = ply === line.length - 1;
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
  renderBoards(); renderTables(); renderHistory('A'); renderHistory('B'); renderNav(); renderMissing();
  // Only a browser analysis is worth a note: it is much shallower than the book.
  el('bdb-source').textContent = cur?.meta && cur.meta.source !== 'desktop' ? 'Analyzed in a browser: a quick, shallower search.' : '';
  el<HTMLInputElement>('bdb-fen').value = cur?.fen ?? line[ply].fen;
}

function setHover(m: BookMove | null) { hover = m; renderArrow('A'); renderArrow('B'); }

function setStatus(text: string, error = false) {
  const s = el('bdb-status');
  s.textContent = text;
  s.dataset.error = String(error);
}

// ── Navigation ────────────────────────────────────────────────────

async function load() {
  const step = line[ply];
  selected = null; hover = null;
  history.replaceState(null, '', step.fen === START_DUAL ? location.pathname : `?fen=${encodeURIComponent(step.fen)}`);
  try {
    const pos = await bookPosition(step.fen);
    if (line[ply] !== step) return;  // navigated on while this was loading
    cur = pos;
    if (!job) setStatus('');
  } catch (e) {
    cur = null;
    setStatus(e instanceof ApiError ? e.message : 'Could not reach the book.', true);
  }
  render();
}

function go(to: number) {
  const next = Math.max(0, Math.min(line.length - 1, to));
  if (next === ply) return;
  ply = next;
  load();
}

function play(m: BookMove) {
  if (!cur) return;
  const ahead = line[ply + 1];
  if (ahead && ahead.board === m.board && ahead.uci === m.uci) { go(ply + 1); return; }
  line = line.slice(0, ply + 1);
  line.push({ fen: m.child_fen, board: m.board, colour: cur.turn[m.board], num: moveNumber(cur.fen, m.board), uci: m.uci, san: m.san });
  go(line.length - 1);
}

function reset(fen: string) {
  line = [{ fen, board: null, colour: null, num: 0, uci: '', san: '' }];
  ply = 0;
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

// ── Drag and drop ─────────────────────────────────────────────────
// A press that moves more than a few pixels becomes a drag; a still press
// stays a click, so click-to-move keeps working.

function startDrag(e: PointerEvent, from: { board: BoardName; from?: string; drop?: string; piece: string }) {
  if (e.button !== 0 || !cur) return;
  e.preventDefault();
  drag = { ...from, x: e.clientX, y: e.clientY };
}

document.addEventListener('pointermove', (e) => {
  if (!drag) return;
  if (!drag.ghost) {
    if (Math.hypot(e.clientX - drag.x, e.clientY - drag.y) < 5) return;
    const size = el(`bdb-board-${drag.board}`).getBoundingClientRect().width / 8;
    drag.ghost = image(drag.piece);
    drag.ghost.className = 'bdb-ghost';
    drag.ghost.style.width = drag.ghost.style.height = `${size}px`;
    document.body.append(drag.ghost);
    selected = { board: drag.board, from: drag.from, drop: drag.drop };
    renderBoards();
  }
  drag.ghost.style.left = `${e.clientX}px`;
  drag.ghost.style.top = `${e.clientY}px`;
});

function endDrag(e: PointerEvent) {
  const d = drag;
  drag = null;
  if (!d?.ghost) return;
  d.ghost.remove();
  swallowClick = true;
  setTimeout(() => { swallowClick = false; });
  const target = (document.elementFromPoint(e.clientX, e.clientY) as HTMLElement | null)?.closest<HTMLElement>('.bdb-square');
  const hit = target?.dataset.board === d.board
    ? candidates(d.board).filter((m) => m.uci.slice(2, 4) === target.dataset.square) : [];
  if (hit.length) { play(hit.find((m) => m.uci.endsWith('q')) ?? hit[0]); return; }
  selected = null;
  renderBoards();
}
document.addEventListener('pointerup', endDrag);
document.addEventListener('pointercancel', () => { drag?.ghost?.remove(); drag = null; selected = null; renderBoards(); });
// The click that ends a drag is not a second, separate click.
document.addEventListener('click', (e) => { if (swallowClick) { swallowClick = false; e.stopPropagation(); e.preventDefault(); } }, true);

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
el('bdb-first').onclick = () => go(0);
el('bdb-prev').onclick = () => go(ply - 1);
el('bdb-next').onclick = () => go(ply + 1);
el('bdb-last').onclick = () => go(line.length - 1);
el<HTMLFormElement>('bdb-fen-form').onsubmit = (e) => {
  e.preventDefault();
  const fen = el<HTMLInputElement>('bdb-fen').value.trim();
  if (fen) reset(fen);
};
document.addEventListener('keydown', (e) => {
  const t = e.target as HTMLElement;
  if (t.tagName === 'INPUT' || t.tagName === 'TEXTAREA') return;
  const to = { ArrowLeft: ply - 1, ArrowRight: ply + 1, Home: 0, End: line.length - 1 }[e.key];
  if (to !== undefined) { e.preventDefault(); go(to); }
  else if (e.key === 'Escape' && selected) { selected = null; renderBoards(); }
});

reset(new URLSearchParams(location.search).get('fen') || START_DUAL);
