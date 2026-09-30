/** Bughouse Lab's UI. Rules and inference remain in one reusable worker. */
import {
  BOARDS, Boards, LineView, Lines, PIECE_NAMES, SEAT, SetupBoxes, squaresOf,
  type BoardName, type BoardView, type Colour,
} from './boards';
import { BrowserEngine } from './engine';
import type { Analysis, JointMove, Position } from './types';
import { exportBpgn, parseSession, SESSION_KEY, sessionHash, START_DUAL, type SavedSession, type Settings } from './session';

const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const choice = (name: string) => document.querySelector<HTMLInputElement>(`#bh-analyse-form input[name="${name}"]:checked`)!.value;
const engine = new BrowserEngine((message) => status(message));
const lines = new Lines(START_DUAL);
let accepted = lines.snapshot();
let state: Position | null = null;
let flipped = false;
let busy = false;
let searching = false;
let hover: JointMove | null = null;
let lastAnalysis: Analysis | null = null;
let undoReset: ReturnType<Lines['snapshot']> | null = null;
const boards = new Boards('bh', { view, play: choosePlay });
const lineView = new LineView('bh', lines, () => {
  if (busy) { lines.restore(accepted); render(); } else void load();
});
const setup = new SetupBoxes('bh');
const promotion = el<HTMLDialogElement>('bh-promotion');

function status(text: string, error = false) {
  el('bh-status').textContent = text;
  el('bh-status').dataset.error = String(error);
}
function errorMessage(error: unknown) { return error instanceof Error ? error.message : 'Something went wrong. Please try again.'; }
function settings(): Settings {
  return { team: choice('team') as Colour, required: choice('required'), budget: choice('budget'), clock: choice('clock'), flipped };
}
function savedSession(): SavedSession { return { version: 1, line: accepted, settings: settings() }; }
function persist() {
  if (!state) return;
  try { localStorage.setItem(SESSION_KEY, JSON.stringify(savedSession())); el('bh-save-status').textContent = 'Saved on this device'; }
  catch { el('bh-save-status').textContent = 'Auto-save unavailable · copy or download your moves'; }
}
function orientation(name: BoardName): Colour {
  const white = (choice('team') === 'white') !== flipped;
  return (name === 'A' ? white : !white) ? 'white' : 'black';
}
function halves(joint: JointMove): Record<BoardName, string | null> {
  const [a, b] = joint.uci.replace(/[()]/g, '').split(',');
  const move = (u: string | undefined) => (!u || ['pass', 'none', '0000'].includes(u) ? null : u);
  return { A: move(a), B: move(b) };
}
function view(name: BoardName): BoardView {
  const board = state?.boards[name];
  const last = lines.current(name);
  return {
    pieces: board?.pieces ?? {}, pockets: board?.pockets ?? { white: '', black: '' },
    turn: board?.turn ?? null, bottom: orientation(name), check: board?.check,
    legal: board?.legal_moves.map((m) => m.uci) ?? [],
    last: last ? squaresOf(last.uci) : [], arrow: hover ? halves(hover)[name] : null,
    disabled: busy || !state,
  };
}
function canMove(name: BoardName) {
  const board = state?.boards[name];
  const colour = name === 'A' ? choice('team') : choice('team') === 'white' ? 'black' : 'white';
  return !!board && board.turn === colour && board.legal_moves.length > 0;
}
function availability() {
  el('bh-budget-note').textContent = `About ${Number(choice('budget')) / 500} seconds total. First analysis downloads ~44 MB; later searches reuse the engine.`;
  for (const name of BOARDS) {
    const input = document.querySelector<HTMLInputElement>(`input[name="required"][value="${name}"]`)!;
    input.disabled = busy || !canMove(name);
    input.closest('label')!.title = canMove(name) ? '' : 'Our team has no legal move on this board.';
    if (state && !canMove(name) && input.checked) document.querySelector<HTMLInputElement>('input[name="required"][value="none"]')!.checked = true;
  }
  const available = BOARDS.some(canMove);
  el<HTMLButtonElement>('bh-analyse').disabled = busy || !state || !available;
  el('bh-availability').textContent = state && !available ? 'Our team has no move. Choose the other team or play an opponent’s move.' : '';
}
function render() {
  boards.render(); lineView.render();
  if (busy) document.querySelectorAll<HTMLButtonElement>('#bughouse-lab .bb-nav button, #bughouse-lab .bb-history button').forEach((b) => { b.disabled = true; });
  availability();
  for (const name of BOARDS) {
    const board = state?.boards[name];
    el(`bh-description-${name}`).textContent = board
      ? `${board.turn} to move${board.check ? ', in check' : ''}. ${Object.entries(board.pieces).map(([sq, p]) => `${p === p.toUpperCase() ? 'White' : 'Black'} ${PIECE_NAMES[p.toLowerCase()]} ${sq}`).join(', ')}.` : 'Loading position.';
  }
}
function lock(value: boolean) {
  busy = value;
  document.querySelectorAll<HTMLButtonElement | HTMLInputElement | HTMLSelectElement>('#bughouse-lab button, #bughouse-lab input, #bughouse-lab select')
    .forEach((control) => { control.disabled = value; });
  el<HTMLButtonElement>('bh-stop').disabled = !searching;
  el('bh-stop').hidden = !searching;
  el('bh-analyse').hidden = searching;
  el('bh-undo-reset').hidden = !undoReset;
  render();
}
function clearResult() { el('bh-jump').hidden = true; el('bh-result').replaceChildren(); hover = null; lastAnalysis = null; }

/** Replay in bounded batches: the WASM parser accepts 256 moves per call. */
async function position(): Promise<Position> {
  const tokens = lines.tokens();
  let fen = lines.root;
  let result: Position;
  for (let i = 0; i < Math.max(1, tokens.length); i += 200) {
    result = await engine.request<Position>('position', { dual_fen: fen, moves: tokens.slice(i, i + 200), team: choice('team') });
    fen = result.dual_fen;
  }
  return result!;
}
async function load(): Promise<boolean> {
  if (busy) return false;
  const asked = lines.snapshot();
  lock(true);
  try {
    const next = await position();
    state = next; accepted = asked;
    boards.deselect(); setup.error(''); clearResult();
    setup.fill(state.dual_fen);
    status('Move on either board, or ask Hivemind for a move.');
    return true;
  } catch (error) {
    lines.restore(accepted);
    status(`Position unchanged: ${errorMessage(error)}${asked.moves.length ? ' A drop may need a capture on the other board.' : ''}`, true);
    return false;
  } finally { lock(false); persist(); }
}
function record(name: BoardName, uci: string) {
  const board = state!.boards[name];
  const san = board.legal_moves.find((m) => m.uci === uci)?.san ?? uci;
  lines.play({ board: name, uci, san, colour: board.turn, num: Number(board.fen.trim().split(/\s+/)[5]) || 1 });
}
function choosePlay(name: BoardName, ucis: string[]) {
  if (busy || !state) return;
  if (ucis.length === 1) { record(name, ucis[0]); void load(); return; }
  // Chessground has already moved the pawn. Restore the committed position
  // before asking, so Cancel/Escape cannot leave a phantom pawn on rank 8/1.
  boards.deselect(); boards.render();
  el('bh-promotion-options').replaceChildren();
  for (const uci of ucis) {
    const button = document.createElement('button');
    button.type = 'button'; button.className = 'btn btn-primary';
    button.textContent = PIECE_NAMES[uci[4]]; button.dataset.promotion = uci[4];
    button.onclick = () => { promotion.close(); record(name, uci); void load(); };
    el('bh-promotion-options').append(button);
  }
  promotion.showModal();
}
function playJoint(joint: JointMove) {
  if (busy || !state) return;
  const moves = halves(joint);
  const played = BOARDS.filter((name) => moves[name]);
  if (!played.length) return;
  for (const name of played) record(name, moves[name]!);
  void load();
}
function clockBits() {
  const ad = choice('clock') === 'AB', bc = choice('clock') === 'CD';
  return choice('team') === 'white'
    ? { time_advantage: ad, their_time_advantage: bc } : { time_advantage: bc, their_time_advantage: ad };
}
const teamLabel = () => choice('team') === 'white' ? 'A + B' : 'C + D';
function score(q: number): string {
  const p = (2 / 0.00368208) * Math.atanh(Math.max(-0.9999, Math.min(0.9999, q))) / 100;
  return `${p > 0 ? '+' : p < 0 ? '−' : ''}${Math.abs(p).toFixed(2)}`;
}
function renderAnalysis(result: Analysis) {
  el('bh-jump').hidden = false;
  const container = el('bh-result'); container.replaceChildren();
  const evaluation = document.createElement('p'); evaluation.className = 'bh-evaluation';
  if (result.mate != null) evaluation.textContent = `${result.mate > 0 ? 'Mate for' : 'Mate against'} ${teamLabel()}`;
  else if (result.advantage != null) evaluation.textContent = `${teamLabel()}: ${score(result.advantage)} · estimated advantage`;
  else evaluation.textContent = result.calibration.source === 'pending' && searching ? 'Moves ready · estimating advantage…' : 'Move suggestions · no calibrated score';
  container.append(evaluation);
  const joints = [result.best, ...result.lines.map((line) => line.best)].filter((j): j is JointMove => j !== null);
  const unique = joints.filter((j, index) => joints.findIndex((other) => other.uci === j.uci) === index).slice(0, 3);
  if (!unique.length) { container.append('No move returned. Try the other team or a different position.'); return; }
  const table = document.createElement('table'); table.className = 'bh-table';
  const head = table.createTHead().insertRow();
  for (const label of ['', 'Board 1', 'Board 2']) { const th = document.createElement('th'); th.textContent = label; th.scope = 'col'; head.append(th); }
  const body = table.createTBody();
  unique.forEach((joint, index) => {
    const row = body.insertRow(); row.tabIndex = searching ? -1 : 0;
    row.setAttribute('aria-disabled', String(searching));
    row.insertCell().textContent = index === 0 ? 'Best' : `${index + 1}`;
    const labels = BOARDS.map((name) => {
      const turn = state!.boards[name].turn;
      if (joint[name] !== 'sit') return `${SEAT[name][turn]} ${joint[name]}`;
      const ours: Colour = name === 'A' ? choice('team') as Colour : choice('team') === 'white' ? 'black' : 'white';
      return turn !== ours ? 'Waiting for opponent' : canMove(name) ? `${SEAT[name][turn]} sits` : 'Waiting for partner’s piece';
    });
    labels.forEach((label) => { row.insertCell().textContent = label; });
    row.setAttribute('aria-label', `Play board 1 ${labels[0]}, board 2 ${labels[1]}`);
    row.onmouseenter = row.onfocus = () => { hover = joint; boards.renderArrows(); };
    row.onmouseleave = row.onblur = () => { hover = null; boards.renderArrows(); };
    row.onclick = () => playJoint(joint);
    row.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); playJoint(joint); } };
  });
  container.append(table);
  const note = document.createElement('p'); note.className = 'bh-note dim';
  note.textContent = `${(result.total_nodes ?? result.nodes).toLocaleString()} nodes${result.cached ? ' · saved analysis' : ''}. ${searching ? 'Stop to use these moves now.' : 'Select a row to play it.'} Scores are approximate, not material counts or measured win probabilities.`;
  container.append(note);
}
el('bh-analyse-form').onsubmit = async (event) => {
  event.preventDefault();
  if (busy || !state || !BOARDS.some(canMove)) return;
  searching = true; lock(true); clearResult();
  status('Hivemind is comparing both teams…');
  try {
    lastAnalysis = await engine.request<Analysis>('analyse', {
      dual_fen: state.dual_fen, team: choice('team'), ...clockBits(),
      require_move_on: choice('required'), movetime_ms: Number(choice('budget')),
    }, (partial) => { lastAnalysis = partial; renderAnalysis(partial); });
    status(lastAnalysis.cached ? 'Using analysis saved in this tab.' : 'Analysis complete. Select a move below.');
  } catch (error) { const message = errorMessage(error); status(message, !message.includes('cancelled')); }
  finally { searching = false; lock(false); if (lastAnalysis) renderAnalysis(lastAnalysis); }
};
el('bh-stop').onclick = () => { engine.cancel(); el<HTMLButtonElement>('bh-stop').disabled = true; status('Stopping…'); };
el<HTMLFormElement>('bh-position-form').onsubmit = (event) => {
  event.preventDefault(); if (busy) return;
  const dual = setup.read(); if (!dual) return;
  lines.reset(dual); void load();
};
el('bh-reset').onclick = () => { if (lines.moves.length || lines.root !== START_DUAL) undoReset = accepted; lines.reset(START_DUAL); void load(); };
el('bh-undo-reset').onclick = () => { if (undoReset) { lines.restore(undoReset); undoReset = null; void load(); } };
el('bh-flip').onclick = () => { flipped = !flipped; boards.render(); persist(); };
el('bh-edit').onclick = () => {
  const editing = el('bughouse-lab').dataset.editing !== 'true';
  el('bughouse-lab').dataset.editing = String(editing);
  el('bh-edit').setAttribute('aria-expanded', String(editing));
};
el('bh-promotion-cancel').onclick = () => promotion.close();
promotion.addEventListener('close', () => { boards.deselect(); boards.render(); });
for (const input of document.querySelectorAll<HTMLInputElement>('#bh-analyse-form input')) {
  input.addEventListener('change', () => { boards.deselect(); clearResult(); render(); persist(); });
}
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') boards.deselect(); });

// A keyboard/screen-reader route to every legal move, including drops and promotions.
el<HTMLFormElement>('bh-move-form').onsubmit = (event) => {
  event.preventDefault(); if (busy || !state) return;
  const name = el<HTMLSelectElement>('bh-move-board').value as BoardName;
  const field = el<HTMLInputElement>('bh-move');
  const text = field.value.trim().replace(/0/g, 'O');
  const legal = state.boards[name].legal_moves;
  const exact = legal.find((m) => m.uci.toLowerCase() === text.toLowerCase() || m.san.replace(/[+#]$/, '') === text.replace(/[+#]$/, ''));
  const promotions = legal.filter((m) => m.uci.length === 5 && m.uci.slice(0, 4) === text);
  if (!exact && !promotions.length) { status('That move is not legal on this board. Use SAN (Nf3, P@e6, a8=N) or UCI (g1f3).', true); return; }
  field.value = ''; choosePlay(name, exact ? [exact.uci] : promotions.map((m) => m.uci));
};
async function copy(text: string, label: string) {
  try { await navigator.clipboard.writeText(text); el('bh-copy-status').textContent = `${label} copied`; }
  catch {
    el<HTMLTextAreaElement>('bh-copy-text').value = text;
    el<HTMLDialogElement>('bh-copy-dialog').showModal();
    el<HTMLTextAreaElement>('bh-copy-text').select();
    el('bh-copy-status').textContent = 'Select and copy the text, or download the moves.';
  }
}
el('bh-copy').onclick = () => { void copy(exportBpgn(lines), 'Moves'); };
el('bh-share').onclick = () => { void copy(`${location.origin}${location.pathname}${sessionHash(savedSession())}`, 'Link'); };
el('bh-download').onclick = () => {
  const url = URL.createObjectURL(new Blob([exportBpgn(lines)], { type: 'application/x-chess-pgn;charset=utf-8' }));
  const a = document.createElement('a'); a.href = url; a.download = 'bughouse-analysis.bpgn'; a.click();
  setTimeout(() => URL.revokeObjectURL(url), 1000);
  el('bh-copy-status').textContent = 'Moves saved as BPGN';
};
el('bh-copy-close').onclick = () => el<HTMLDialogElement>('bh-copy-dialog').close();

async function start() {
  document.querySelector<HTMLDetailsElement>('.bh-settings')!.open = matchMedia('(min-width: 1101px)').matches;
  let saved: SavedSession | null = null;
  let failure = '';
  try {
    const text = location.hash.startsWith('#lab=') ? decodeURIComponent(location.hash.slice(5)) : localStorage.getItem(SESSION_KEY);
    if (text) saved = parseSession(text);
  } catch { failure = 'Could not restore the saved line. Starting a new position.'; }
  if (saved) {
    lines.restore(saved.line); flipped = saved.settings.flipped;
    for (const name of ['team', 'required', 'budget', 'clock'] as const)
      document.querySelector<HTMLInputElement>(`input[name="${name}"][value="${saved.settings[name]}"]`)!.checked = true;
  }
  const ok = await load();
  if (!ok && saved) { lines.reset(START_DUAL); await load(); failure = 'The saved line could not be replayed. Starting a new position.'; }
  if (failure) status(failure, true);
  else if (saved) status('Saved line restored. Hivemind’s network starts when you analyze.');
  // The link is an import, not a stale override of subsequent saved edits.
  if (location.hash.startsWith('#lab=')) history.replaceState(null, '', location.pathname + location.search);
}
void start();
