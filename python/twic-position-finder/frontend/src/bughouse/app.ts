type BoardName = 'A' | 'B';
type Colour = 'white' | 'black';
interface Move { uci: string; san: string }
interface Board {
  pieces: Record<string, string>; turn: Colour; we_play: Colour;
  pockets: Record<Colour, string>; legal_moves: Move[]; movetext: string; check: boolean;
}
interface Position { dual_fen: string; boards: Record<BoardName, Board> }
interface Joint { A: string; B: string; uci: string }
interface Analysis {
  best: Joint | null; advantage: number | null; mate: number | null;
  calibration: { source: string }; nodes: number;
  lines: { best: Joint | null }[];
}

const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const names: BoardName[] = ['A', 'B'];
const pieceNames: Record<string, string> = { p: 'pawn', n: 'knight', b: 'bishop', r: 'rook', q: 'queen', k: 'king' };
const endpoint = (import.meta.env.PUBLIC_BUGHOUSE_API_URL ?? import.meta.env.PUBLIC_API_URL).replace(/\/$/, '');
const teamInput = el<HTMLSelectElement>('bh-team');
const requiredInput = el<HTMLSelectElement>('bh-required');
const budgetInput = el<HTMLSelectElement>('bh-budget');
const clockInput = el<HTMLInputElement>('bh-clock');
let baseFen: string | null = null;
let moves: string[] = [];
let state: Position | null = null;
let selected: { board: BoardName; from?: string; drop?: string } | null = null;
let flipped = false;
let busy = false;
let analysis: Analysis | null = null;

function status(text: string, error = false) {
  el('bh-status').textContent = text;
  el('bh-status').dataset.error = String(error);
}

async function api<T>(path: string, payload: object): Promise<T> {
  try {
    const response = await fetch(`${endpoint}/api/bughouse/${path}`, {
      method: 'POST', headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(payload), signal: AbortSignal.timeout(45_000),
    });
    const data = await response.json();
    if (!response.ok) throw new Error(typeof data.detail === 'string' ? data.detail : 'The request could not be completed.');
    return data as T;
  } catch (error) {
    if (error instanceof TypeError || error instanceof SyntaxError) {
      throw new Error('Cannot reach Bughouse Lab. Please try New position again in a moment.');
    }
    if (error instanceof DOMException && error.name === 'TimeoutError') {
      throw new Error('The server took too long to answer. Please try again shortly.');
    }
    throw error;
  }
}

function errorMessage(error: unknown) { return error instanceof Error ? error.message : 'Something went wrong. Please try again.'; }
function image(piece: string) {
  const img = document.createElement('img');
  img.src = `/piece/${piece === piece.toUpperCase() ? 'w' : 'b'}${piece.toUpperCase()}.svg`;
  img.alt = ''; img.draggable = false;
  return img;
}

function lock(value: boolean) {
  busy = value;
  document.querySelectorAll<HTMLButtonElement | HTMLSelectElement | HTMLInputElement | HTMLTextAreaElement>(
    '#bughouse-lab button, #bughouse-lab select, #bughouse-lab input, #bughouse-lab textarea',
  ).forEach((control) => { control.disabled = value; });
  el<HTMLButtonElement>('bh-undo').disabled = value || moves.length === 0;
  el<HTMLButtonElement>('bh-analyse').disabled = value || !state;
  el<HTMLButtonElement>('bh-copy').disabled = value || !state;
  renderBoards();
}

function clearResult() {
  analysis = null;
  const p = document.createElement('p'); p.className = 'dim';
  p.textContent = 'Ready to analyse this position from both teams.';
  el('bh-result').replaceChildren(p);
}

async function load(nextFen: string | null, nextMoves: string[]) {
  if (busy) return;
  lock(true);
  try {
    const next = await api<Position>('position', { dual_fen: nextFen, moves: nextMoves, team: teamInput.value });
    state = next; baseFen = nextFen; moves = [...nextMoves]; selected = null;
    el<HTMLTextAreaElement>('bh-fen').value = baseFen ?? '';
    el<HTMLTextAreaElement>('bh-moves').value = moves.join(' ');
    clearResult();
    status('Select a piece, then its destination. Or ask Hivemind for a move.');
  } catch (error) { status(errorMessage(error), true); }
  finally { lock(false); }
}

function candidates(board: Board) {
  if (!selected) return [];
  return board.legal_moves.filter((m) => selected?.drop
    ? m.uci.startsWith(`${selected.drop}@`)
    : !m.uci.includes('@') && m.uci.startsWith(selected?.from ?? '?'));
}

function orientation(name: BoardName): Colour {
  const white = (teamInput.value === 'white') !== flipped;
  return (name === 'A' ? white : !white) ? 'white' : 'black';
}

function renderReserve(name: BoardName, colour: Colour, target: string) {
  const container = el(target); container.replaceChildren();
  const label = document.createElement('span'); label.className = 'bh-reserve-label';
  label.textContent = `${colour === 'white' ? 'White' : 'Black'} reserve`;
  container.append(label);
  const board = state?.boards[name];
  const pocket = board?.pockets[colour] ?? '';
  if (!pocket) { const empty = document.createElement('span'); empty.textContent = '—'; empty.className = 'dim'; container.append(empty); }
  for (const piece of ['p', 'n', 'b', 'r', 'q']) {
    const count = [...pocket].filter((p) => p.toLowerCase() === piece).length;
    if (!count) continue;
    const button = document.createElement('button'); button.className = 'bh-pocket';
    button.append(image(colour === 'white' ? piece.toUpperCase() : piece), document.createTextNode(String(count)));
    button.setAttribute('aria-label', `${name}: ${colour} ${pieceNames[piece]} reserve, ${count}`);
    button.setAttribute('aria-pressed', String(selected?.board === name && selected?.drop === piece.toUpperCase()));
    button.disabled = busy || board?.turn !== colour || !board.legal_moves.some((m) => m.uci.startsWith(`${piece.toUpperCase()}@`));
    button.onclick = () => { selected = selected?.board === name && selected.drop === piece.toUpperCase() ? null : { board: name, drop: piece.toUpperCase() }; renderBoards(); };
    container.append(button);
  }
}

function renderBoards() {
  for (const name of names) {
    const board = state?.boards[name];
    const bottom = orientation(name);
    const files = bottom === 'white' ? 'abcdefgh' : 'hgfedcba';
    const ranks = bottom === 'white' ? '87654321' : '12345678';
    const container = el(`bh-board-${name}`);
    // Keep focus across selection redraws so keyboard users can continue moving.
    const focused = container.contains(document.activeElement) ? (document.activeElement as HTMLElement).dataset.square : null;
    container.replaceChildren();
    const legal = board && selected?.board === name ? candidates(board) : [];
    for (let row = 0; row < 8; row++) for (let col = 0; col < 8; col++) {
      const square = files[col] + ranks[row];
      const piece = board?.pieces[square];
      const button = document.createElement('button');
      button.className = `bh-square${(row + col) % 2 ? ' dark' : ''}`;
      button.dataset.square = square;
      button.disabled = busy || !state;
      button.setAttribute('aria-label', `${name} ${square}${piece ? ` ${piece === piece.toUpperCase() ? 'white' : 'black'} ${pieceNames[piece.toLowerCase()]}` : ' empty'}`);
      if (selected?.board === name && selected.from === square) button.classList.add('selected');
      if (legal.some((m) => m.uci.slice(2, 4) === square)) button.classList.add('target');
      if (piece) button.append(image(piece));
      if (row === 7) { const file = document.createElement('span'); file.className = 'bh-coordinate file'; file.textContent = files[col]; button.append(file); }
      if (col === 0) { const rank = document.createElement('span'); rank.className = 'bh-coordinate rank'; rank.textContent = ranks[row]; button.append(rank); }
      button.onclick = () => clickSquare(name, square);
      button.onkeydown = (event) => {
        const delta = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: -8, ArrowDown: 8 }[event.key];
        if (delta !== undefined) {
          event.preventDefault();
          const index = Math.max(0, Math.min(63, row * 8 + col + delta));
          (container.children[index] as HTMLButtonElement).focus();
        }
        if (event.key === 'Escape') { selected = null; renderBoards(); }
      };
      container.append(button);
    }
    if (focused) container.querySelector<HTMLButtonElement>(`[data-square="${focused}"]`)?.focus();
    el(`bh-turn-${name}`).textContent = board ? `${board.turn === 'white' ? 'White' : 'Black'} to move${board.check ? ' · check' : ''}` : 'White to move';
    el(`bh-movetext-${name}`).textContent = board?.movetext || 'Starting position';
    renderReserve(name, bottom === 'white' ? 'black' : 'white', `bh-reserve-top-${name}`);
    renderReserve(name, bottom, `bh-reserve-bottom-${name}`);
  }
}

function clickSquare(name: BoardName, square: string) {
  if (busy || !state) return;
  const board = state.boards[name];
  if (selected?.board === name) {
    const possible = candidates(board).filter((m) => m.uci.slice(2, 4) === square);
    if (possible.length > 1) { choosePromotion(name, possible); return; }
    if (possible.length === 1) { void load(baseFen, [...moves, `${name}:${possible[0].uci}`]); return; }
  }
  const piece = board.pieces[square];
  if (piece && (piece === piece.toUpperCase()) === (board.turn === 'white')) {
    selected = selected?.board === name && selected.from === square ? null : { board: name, from: square };
  } else selected = null;
  renderBoards();
}

function choosePromotion(name: BoardName, options: Move[]) {
  const dialog = el<HTMLDialogElement>('bh-promotion');
  el('bh-promotion-options').replaceChildren();
  for (const move of options) {
    const button = document.createElement('button'); button.className = 'btn btn-primary';
    button.textContent = pieceNames[move.uci[4]];
    button.onclick = () => { dialog.close(); void load(baseFen, [...moves, `${name}:${move.uci}`]); };
    el('bh-promotion-options').append(button);
  }
  dialog.showModal();
}

function renderAnalysis(result: Analysis) {
  const container = el('bh-result'); container.replaceChildren();
  const evaluation = document.createElement('p'); evaluation.className = 'bh-evaluation';
  if (result.mate != null) evaluation.textContent = `Engine reports ${result.mate > 0 ? 'a mating attack for our team' : 'a mating attack against our team'}.`;
  else if (result.calibration.source === 'measured' && result.advantage != null) {
    const q = result.advantage;
    evaluation.textContent = `${Math.abs(q) < .02 ? 'Roughly balanced' : q > 0 ? 'Our team has the edge' : 'Their team has the edge'} · advantage ${q > 0 ? '+' : ''}${q.toFixed(3)}`;
  } else evaluation.textContent = 'Move suggestions ready. No calibrated advantage available.';
  container.append(evaluation);
  const joints = [result.best, ...result.lines.map((line) => line.best)].filter((j): j is Joint => j !== null);
  const unique = joints.filter((j, index) => joints.findIndex((other) => other.uci === j.uci) === index).slice(0, 3);
  if (!unique.length) { const p = document.createElement('p'); p.textContent = 'No move returned. Try the other team or a different position.'; container.append(p); return; }
  const table = document.createElement('table'); table.className = 'bh-table';
  const head = table.createTHead().insertRow();
  for (const label of ['Choice', 'Board A', 'Board B', '']) { const th = document.createElement('th'); th.textContent = label; th.scope = 'col'; head.append(th); }
  const body = table.createTBody();
  unique.forEach((joint, index) => {
    const row = body.insertRow();
    for (const text of [index === 0 ? 'Best' : `Option ${index + 1}`, joint.A, joint.B]) row.insertCell().textContent = text;
    const button = document.createElement('button'); button.className = 'btn btn-outline'; button.textContent = 'Play';
    button.setAttribute('aria-label', `Play A ${joint.A}, B ${joint.B}`);
    const halves = names.filter((name) => joint[name] !== 'sit').map((name) => `${name}:${joint[name]}`);
    button.disabled = !halves.length;
    button.onclick = () => { if (!busy && halves.length) void load(baseFen, [...moves, ...halves]); };
    row.insertCell().append(button);
  });
  container.append(table);
  const note = document.createElement('p'); note.className = 'dim'; note.textContent = `Both teams searched. ${result.nodes.toLocaleString()} nodes in our search. Sit = wait; it does not advance that board.`;
  container.append(note);
}

el('bh-analyse-form').onsubmit = async (event) => {
  event.preventDefault(); if (busy || !state) return;
  lock(true); status('Hivemind is comparing both teams…'); clearResult();
  el('bh-result').textContent = 'Thinking about moves, drops and whether to sit…';
  try {
    analysis = await api<Analysis>('analyse', {
      dual_fen: state.dual_fen, team: teamInput.value,
      time_advantage: clockInput.checked, require_move_on: requiredInput.value,
      movetime_ms: Number(budgetInput.value), multipv: 3,
    });
    status('Analysis ready. Play a suggestion to explore what happens next.');
  } catch (error) { status(errorMessage(error), true); clearResult(); }
  finally { lock(false); if (analysis) renderAnalysis(analysis); }
};
el('bh-position-form').onsubmit = (event) => { event.preventDefault(); void load(el<HTMLTextAreaElement>('bh-fen').value.trim() || null, el<HTMLTextAreaElement>('bh-moves').value.trim().split(/\s+/).filter(Boolean)); };
el('bh-reset').onclick = () => { requiredInput.value = 'none'; void load(null, []); };
el('bh-undo').onclick = () => { void load(baseFen, moves.slice(0, -1)); };
el('bh-flip').onclick = () => { flipped = !flipped; renderBoards(); };
el('bh-example').onclick = () => { requiredInput.value = 'none'; void load(null, ['A:e4', 'A:d5', 'A:exd5', 'B:e4', 'B:P@e6']); };
el('bh-promotion-cancel').onclick = () => el<HTMLDialogElement>('bh-promotion').close();
el('bh-copy').onclick = async () => {
  if (!state) return;
  try { await navigator.clipboard.writeText(state.dual_fen); status('Current two-board FEN copied.'); }
  catch { status('Clipboard unavailable. The current FEN is selected below; copy it manually.');
    const input = el<HTMLTextAreaElement>('bh-fen'); input.value = state.dual_fen;
    el<HTMLTextAreaElement>('bh-moves').value = '';
    input.closest('details')!.open = true; input.focus(); input.select(); }
};
for (const input of [teamInput, requiredInput, budgetInput, clockInput]) input.addEventListener('change', () => { selected = null; clearResult(); renderBoards(); });
void load(null, []);
