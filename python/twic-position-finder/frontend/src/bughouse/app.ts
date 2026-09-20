/**
 * Bughouse Lab: two boards and Hivemind running entirely in this browser
 * (engine.worker.ts). The worker replays each board's kept moves and
 * searches; boards, move lists and setup boxes are shared with BughouseDB
 * (./boards).
 */
import {
  BOARDS, Boards, LineView, Lines, PIECE_NAMES, SEAT, SetupBoxes, squaresOf,
  type BoardName, type BoardView, type Colour,
} from './boards';
import { BrowserEngine } from './engine';

interface Move { uci: string; san: string }
interface Board {
  fen: string; pieces: Record<string, string>; turn: Colour; we_play: Colour;
  pockets: Record<Colour, string>; legal_moves: Move[]; movetext: string; check: boolean;
}
interface Position { dual_fen: string; boards: Record<BoardName, Board> }
interface Joint { A: string; B: string; uci: string }
interface Analysis {
  best: Joint | null; advantage: number | null; mate: number | null;
  calibration: { source: string }; nodes: number;
  lines: { best: Joint | null }[];
}

const START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1';
const START_DUAL = `${START}|${START}`;
const LICHESS_K = 0.00368208;  // Lichess's win-chance curve, as BughouseDB's scores

const el = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id) as T;
const engine = new BrowserEngine((message) => status(message));
const choice = (name: string) => document.querySelector<HTMLInputElement>(`#bh-analyse-form input[name="${name}"]:checked`)!.value;

const lines = new Lines(START_DUAL);
/** The last line the engine accepted, to step back to if it refuses one. */
let accepted = lines.snapshot();
let state: Position | null = null;
let flipped = false;
let busy = false;
let searching = false;
let hover: Joint | null = null;

const boards = new Boards('bh', { view, play: choosePlay });
const lineView = new LineView('bh', lines, () => { if (busy) { lines.restore(accepted); lineView.render(); } else void load(); });
const setup = new SetupBoxes('bh');

function status(text: string, error = false) {
  el('bh-status').textContent = text;
  el('bh-status').dataset.error = String(error);
}

function errorMessage(error: unknown) { return error instanceof Error ? error.message : 'Something went wrong. Please try again.'; }

/** Our team's colour on board 1 sits at the bottom there; Flip turns both boards. */
function orientation(name: BoardName): Colour {
  const white = (choice('team') === 'white') !== flipped;
  return (name === 'A' ? white : !white) ? 'white' : 'black';
}

/** The two halves of a joint action as UCI, `null` where that board sits. */
function halves(joint: Joint): Record<BoardName, string | null> {
  const [a, b] = joint.uci.replace(/[()]/g, '').split(',');
  const move = (u: string | undefined) => (!u || ['pass', 'none', '0000'].includes(u) ? null : u);
  return { A: move(a), B: move(b) };
}

function view(name: BoardName): BoardView {
  const board = state?.boards[name];
  const last = lines.current(name);
  return {
    pieces: board?.pieces ?? {}, pockets: board?.pockets ?? { white: '', black: '' },
    turn: board?.turn ?? null, bottom: orientation(name),
    legal: board?.legal_moves.map((m) => m.uci) ?? [],
    last: last ? squaresOf(last.uci) : [],
    arrow: hover ? halves(hover)[name] : null,
    disabled: busy || !state,
  };
}

function render() {
  boards.render();
  lineView.render();
  if (busy) document.querySelectorAll<HTMLButtonElement>('.bb-nav button').forEach((b) => { b.disabled = true; });
  setup.fill(state?.dual_fen ?? lines.root);
}

function lock(value: boolean) {
  busy = value;
  document.querySelectorAll<HTMLButtonElement | HTMLInputElement>('#bughouse-lab button, #bughouse-lab input')
    .forEach((control) => { control.disabled = value; });
  el<HTMLButtonElement>('bh-stop').disabled = !searching;
  el('bh-stop').hidden = !searching;
  el('bh-analyse').hidden = searching;
  el<HTMLButtonElement>('bh-analyse').disabled = value || !state;
  render();
}

function clearResult() {
  el('bh-result').replaceChildren();
  hover = null;
}

/** The position for the moves each board has kept; a refused step goes back. */
async function load(): Promise<boolean> {
  if (busy) return false;
  const asked = lines.snapshot();
  lock(true);
  try {
    state = await engine.request<Position>('position', { dual_fen: lines.root, moves: lines.tokens(), team: choice('team') });
    accepted = asked;
    boards.selected = null;
    setup.error('');
    clearResult();
    status('Move on either board, or ask Hivemind for a move.');
    return true;
  } catch (error) {
    const message = errorMessage(error);
    if (lines.moves.length && JSON.stringify(accepted) !== JSON.stringify(asked)) {
      lines.restore(accepted);
      setup.error(`Can’t step there: ${message}. A drop may need the capture on the other board.`);
    } else setup.error(message);
    return false;
  } finally { lock(false); }
}

function fullmove(name: BoardName): number {
  return Number(state!.boards[name].fen.trim().split(/\s+/)[5]) || 1;
}

/** Records `uci` on board `name` from the position on screen. */
function record(name: BoardName, uci: string) {
  const board = state!.boards[name];
  const san = board.legal_moves.find((m) => m.uci === uci)?.san ?? uci;
  lines.play({ board: name, uci, san, colour: board.turn, num: fullmove(name) });
}

function choosePlay(name: BoardName, ucis: string[]) {
  if (busy || !state) return;
  if (ucis.length === 1) { record(name, ucis[0]); void load(); return; }
  const dialog = el<HTMLDialogElement>('bh-promotion');
  el('bh-promotion-options').replaceChildren();
  for (const uci of ucis) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'btn btn-primary';
    button.textContent = PIECE_NAMES[uci[4]];
    button.onclick = () => { dialog.close(); record(name, uci); void load(); };
    el('bh-promotion-options').append(button);
  }
  dialog.showModal();
}

/** Plays both halves of a suggestion; a sitting board keeps its moves. */
function playJoint(joint: Joint) {
  if (busy || !state) return;
  const moves = halves(joint);
  const played = BOARDS.filter((name) => moves[name]);
  if (!played.length) return;
  for (const name of played) record(name, moves[name]!);
  void load();
}

// ── Hivemind's suggestions ────────────────────────────────────────

/**
 * Hivemind's clock input is one bit per team, from its board-1 player's
 * diagonal: A + B has priority when A has more time than D, C + D when C has
 * more than B (hivemind src/domain/board2planes.py). Ours goes to our
 * search, theirs to the calibration search of the other team.
 */
function clockBits(): { time_advantage: boolean; their_time_advantage: boolean } {
  const clock = choice('clock');
  const ad = clock === 'AB';
  const bc = clock === 'CD';
  return choice('team') === 'white'
    ? { time_advantage: ad, their_time_advantage: bc }
    : { time_advantage: bc, their_time_advantage: ad };
}

const teamLabel = () => (choice('team') === 'white' ? 'A + B' : 'C + D');

function pawns(q: number): string {
  const cp = (2 / LICHESS_K) * Math.atanh(Math.max(-0.9999, Math.min(0.9999, q)));
  const p = cp / 100;
  return `${p > 0 ? '+' : p < 0 ? '−' : ''}${Math.abs(p).toFixed(2)}`;
}

function renderAnalysis(result: Analysis) {
  const container = el('bh-result');
  container.replaceChildren();
  const evaluation = document.createElement('p');
  evaluation.className = 'bh-evaluation';
  if (result.mate != null) evaluation.textContent = `${result.mate > 0 ? 'Mate for' : 'Mate against'} ${teamLabel()}`;
  else if (result.calibration.source === 'measured' && result.advantage != null) evaluation.textContent = `${teamLabel()}: ${pawns(result.advantage)}`;
  else evaluation.textContent = 'No score for this position; the moves below are still Hivemind’s picks.';
  container.append(evaluation);
  const joints = [result.best, ...result.lines.map((line) => line.best)].filter((j): j is Joint => j !== null);
  const unique = joints.filter((j, index) => joints.findIndex((other) => other.uci === j.uci) === index).slice(0, 3);
  if (!unique.length) {
    const p = document.createElement('p');
    p.textContent = 'No move returned. Try the other team or a different position.';
    container.append(p);
    return;
  }
  const table = document.createElement('table');
  table.className = 'bh-table';
  const head = table.createTHead().insertRow();
  for (const label of ['', 'Board 1', 'Board 2']) { const th = document.createElement('th'); th.textContent = label; th.scope = 'col'; head.append(th); }
  const body = table.createTBody();
  unique.forEach((joint, index) => {
    const row = body.insertRow();
    row.tabIndex = 0;
    const seats = BOARDS.map((name) => SEAT[name][state!.boards[name].turn]);
    row.insertCell().textContent = index === 0 ? 'Best' : `${index + 1}`;
    BOARDS.forEach((name, i) => { row.insertCell().textContent = joint[name] === 'sit' ? `${seats[i]} sits` : `${seats[i]} ${joint[name]}`; });
    row.setAttribute('aria-label', `Play board 1 ${joint.A}, board 2 ${joint.B}`);
    row.onmouseenter = row.onfocus = () => { hover = joint; boards.renderArrows(); };
    row.onmouseleave = row.onblur = () => { hover = null; boards.renderArrows(); };
    row.onclick = () => playJoint(joint);
    row.onkeydown = (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); e.stopPropagation(); playJoint(joint); } };
  });
  container.append(table);
  const note = document.createElement('p');
  note.className = 'bh-note dim';
  note.textContent = `${result.nodes.toLocaleString()} nodes. Click a row to play it; “sits” waits on that board.`;
  container.append(note);
}

el('bh-analyse-form').onsubmit = async (event) => {
  event.preventDefault();
  if (busy || !state) return;
  searching = true; lock(true); clearResult();
  status('Hivemind is comparing both teams…');
  let analysis: Analysis | null = null;
  try {
    analysis = await engine.request<Analysis>('analyse', {
      dual_fen: state.dual_fen, team: choice('team'),
      ...clockBits(),
      require_move_on: choice('required'),
      movetime_ms: Number(choice('budget')), multipv: 3,
    });
    status('Hover a row to see it on the boards.');
  } catch (error) { const message = errorMessage(error); status(message, !message.includes('cancelled')); }
  finally { searching = false; lock(false); if (analysis) renderAnalysis(analysis); }
};
el('bh-stop').onclick = () => { engine.cancel(); el<HTMLButtonElement>('bh-stop').disabled = true; status('Stopping after the current evaluation…'); };
el<HTMLFormElement>('bh-position-form').onsubmit = (event) => {
  event.preventDefault();
  const dual = setup.read();
  if (!dual || busy) return;
  // A position the engine refuses leaves the boards as they were.
  const before = accepted;
  lines.reset(dual);
  accepted = lines.snapshot();
  void load().then((ok) => {
    if (ok) return;
    const message = document.getElementById('bh-fen-error-A')!.textContent ?? '';
    lines.restore(before);
    accepted = before;
    render();
    setup.error(message);
  });
};
el('bh-reset').onclick = () => { lines.reset(START_DUAL); accepted = lines.snapshot(); void load(); };
el('bh-flip').onclick = () => { flipped = !flipped; boards.render(); };
el('bh-promotion-cancel').onclick = () => el<HTMLDialogElement>('bh-promotion').close();
for (const input of document.querySelectorAll<HTMLInputElement>('#bh-analyse-form input')) {
  input.addEventListener('change', () => { boards.selected = null; clearResult(); boards.render(); });
}
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') boards.deselect(); });
void load();
