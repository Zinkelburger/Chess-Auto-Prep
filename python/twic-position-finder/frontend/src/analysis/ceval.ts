/**
 * The engine panel of lichess.org/analysis: switch, evaluation, engine and
 * depth, "Show threat", the gear, a progress bar, and the engine lines.
 * Hovering a line shows its first move on the board; hovering a move in it
 * shows a small board of that position (the wheel steps along the line);
 * clicking a move plays the line up to it. When the engine waits for the
 * player (a phone's first download) or has failed, one button starts it.
 * Screen readers hear the evaluation once a search ends, not every update.
 */
import { Chessground } from '@lichess-org/chessground';
import type { Api } from '@lichess-org/chessground/api';
import type { Key } from '@lichess-org/chessground/types';
import type { Color, Role } from 'chessops/types';
import { type EngineLine, type EngineResult, type EngineStatus } from './engine';
import { el } from './moves';
import { HAND_ROLES, playLine, positionOf, type LineMove } from './tree';

const PV_MOVES = 16;
const LETTER: Record<Role, string> = { pawn: 'P', knight: 'N', bishop: 'B', rook: 'R', queen: 'Q', king: 'K' };

export interface CevalState {
  enabled: boolean;
  /** The position searched: the current one, or with the other side to move in threat mode. */
  fen: string;
  ply: number;
  multiPv: number;
  infinite: boolean;
  /** The search time, for the progress bar. */
  searchMs: number;
  result: EngineResult | undefined;
  status: EngineStatus;
  threat: boolean;
  /** The current side is in check: no threat to show. */
  inCheck: boolean;
  /** Checkmate or stalemate on the board. */
  over: string | null;
  orientation: Color;
}

export interface CevalHooks {
  /** A line's first move is hovered (null when the pointer leaves). */
  hover(uci: string | null): void;
  /** Plays a line up to and including move `upTo`. */
  play(pv: string[], upTo: number): void;
  /** Downloads the engine, or tries again after a failure. */
  start(): void;
}

export function formatEval(line: Pick<EngineLine, 'cp' | 'mate'>): string {
  if (line.mate !== undefined) return `#${line.mate}`;
  const pawns = (line.cp ?? 0) / 100;
  return `${pawns > 0 ? '+' : ''}${pawns.toFixed(1)}`;
}

export class CevalView {
  private mini: Api | null = null;
  private hovered: { fen: string; moves: LineMove[]; index: number } | null = null;
  private state: CevalState | null = null;
  private spoken = '';

  constructor(
    private readonly els: {
      header: HTMLElement; pearl: HTMLElement; name: HTMLElement; info: HTMLElement; bar: HTMLElement; threat: HTMLButtonElement;
      pvs: HTMLElement; board: HTMLElement; switch: HTMLInputElement; action: HTMLButtonElement; live: HTMLElement;
    },
    hooks: CevalHooks,
    private readonly engineName = 'Hivemind',
  ) {
    const { pvs } = els;
    els.action.onclick = () => hooks.start();
    pvs.addEventListener('mouseover', (e) => {
      const target = e.target as HTMLElement;
      const row = target.closest<HTMLElement>('.ch-pv');
      hooks.hover(row?.dataset.uci ?? null);
      const move = target.closest<HTMLElement>('.ch-pv-move');
      if (move && row) this.showBoard(row, Number(move.dataset.index));
    });
    pvs.addEventListener('mouseleave', () => { hooks.hover(null); this.hideBoard(); });
    pvs.addEventListener('wheel', (e) => {
      if (!this.hovered) return;
      e.preventDefault();
      const index = Math.max(0, Math.min(this.hovered.moves.length - 1, this.hovered.index + (e.deltaY > 0 ? 1 : -1)));
      this.drawBoard(this.hovered.moves, index);
    }, { passive: false });
    pvs.addEventListener('click', (e) => {
      const move = (e.target as HTMLElement).closest<HTMLElement>('.ch-pv-move');
      const row = move?.closest<HTMLElement>('.ch-pv');
      if (!move || !row || this.state?.threat) return;
      this.hideBoard();
      hooks.play(row.dataset.pv!.split(' '), Number(move.dataset.index));
    });
  }

  render(state: CevalState) {
    this.state = state;
    const { header, pearl, name, info, bar, threat, pvs, switch: toggle, action } = this.els;
    toggle.checked = state.enabled;
    header.classList.toggle('off', !state.enabled);
    header.classList.toggle('ch-threat-mode', state.threat);
    threat.hidden = !state.enabled || state.inCheck || !!state.over;
    threat.setAttribute('aria-pressed', String(state.threat));
    name.textContent = state.threat ? 'Show threat' : state.status.kind === 'ready' ? `${this.engineName} · ${state.status.backend}` : this.engineName;
    info.classList.remove('ch-failed');
    action.hidden = true;
    header.classList.remove('ch-waiting');
    pvs.replaceChildren();
    bar.style.width = '0';
    bar.classList.toggle('threat', state.threat);
    if (state.over) { pearl.textContent = state.over === 'Checkmate' ? '#' : '½'; info.textContent = state.over; this.hideBoard(); return; }
    if (!state.enabled) { pearl.textContent = ''; info.textContent = 'Off · press L to turn on'; this.hideBoard(); return; }
    if (!state.result) this.hideBoard();
    const result = state.result;
    const status = state.status;
    const error = status.kind === 'ready' && status.error?.fen === state.fen ? status.error.text : null;
    if (!result) {
      const waiting = status.kind === 'ask' || status.kind === 'failed' || error !== null;
      header.classList.toggle('ch-waiting', waiting);
      if (waiting) pearl.textContent = '';
      else pearl.innerHTML = '<span class="ch-spinner" aria-hidden="true"></span>';
      if (status.kind === 'ask') {
        info.textContent = `Runs in this browser · ${status.megabytes} MB, once`;
        action.textContent = 'Download';
        action.hidden = false;
      } else if (status.kind === 'failed') {
        info.textContent = status.text;
        info.classList.add('ch-failed');
        action.textContent = 'Try again';
        action.hidden = false;
      } else if (error !== null) {
        info.textContent = error;
        info.classList.add('ch-failed');
      } else if (status.kind === 'loading') {
        info.textContent = status.text;
        if (status.fraction !== undefined) bar.style.width = `${Math.round(100 * status.fraction)}%`;
      } else info.textContent = 'Calculating…';
      return;
    }
    pearl.textContent = formatEval(result.lines[0]);
    info.textContent = result.info;
    if (result.done && !state.threat) this.speak(state.fen, result);
    const progress = result.millis / state.searchMs;
    bar.style.width = `${result.done || state.infinite ? 100 : Math.min(100, 100 * progress)}%`;
    for (let i = 0; i < state.multiPv; i++) pvs.append(this.row(state, result.lines[i]));
    // The board stays while the pointer is on a line of this position; engine updates redraw the rows under it.
    if (this.hovered && this.hovered.fen !== state.fen) this.hideBoard();
  }

  /** Tells a screen reader the finished evaluation and best move, once per result. */
  private speak(fen: string, result: EngineResult) {
    const best = result.lines[0];
    const san = playLine(fen, best.pv, 1)[0]?.san;
    const text = `Evaluation ${formatEval(best)}${san ? `, best move ${san}` : ''}`;
    if (text === this.spoken) return;
    this.spoken = text;
    this.els.live.textContent = text;
  }

  private row(state: CevalState, line: EngineLine | undefined): HTMLElement {
    const row = el('div', 'ch-pv');
    if (!line) { row.append(el('strong', '', '')); return row; }
    row.dataset.uci = line.pv[0];
    row.dataset.pv = line.pv.join(' ');
    row.classList.toggle('ch-pv-threat', state.threat);
    row.append(el('strong', '', formatEval(line)));
    let ply = state.ply + (state.threat ? 1 : 0);
    playLine(state.fen, line.pv, PV_MOVES).forEach((move, i) => {
      ply++;
      const white = ply % 2 === 1;
      if (white || i === 0) row.append(el('span', 'ch-pv-num', `${Math.floor((ply + 1) / 2)}.${white ? '' : '..'}`));
      const b = el('button', 'ch-pv-move', move.san) as HTMLButtonElement;
      b.type = 'button';
      b.dataset.index = String(i);
      if (state.threat) b.tabIndex = -1;
      row.append(b);
    });
    return row;
  }

  private showBoard(row: HTMLElement, index: number) {
    if (!this.state) return;
    const moves = playLine(this.state.fen, row.dataset.pv!.split(' '), PV_MOVES);
    if (!moves[index]) return;
    const box = this.els.board;
    box.hidden = false;
    const rows = this.els.pvs.getBoundingClientRect(), parent = box.offsetParent?.getBoundingClientRect();
    if (parent) box.style.top = `${rows.bottom - parent.top + 4}px`;
    this.drawBoard(moves, index);
  }

  private drawBoard(moves: LineMove[], index: number) {
    const move = moves[index];
    this.hovered = { fen: this.state!.fen, moves, index };
    const box = this.els.board;
    box.hidden = false;
    const orientation = this.state!.orientation;
    const lastMove = (move.uci[1] === '@' ? [move.uci.slice(2, 4)] : [move.uci.slice(0, 2), move.uci.slice(2, 4)]) as Key[];
    if (!this.mini) {
      const host = box.querySelector<HTMLElement>('.ch-pv-board-cg')!;
      this.mini = Chessground(host, { viewOnly: true, coordinates: false, animation: { enabled: false }, drawable: { enabled: false, visible: false } });
    }
    this.mini.set({ fen: move.fen.split(' ')[0].replace(/\[.*$/, ''), orientation, lastMove });
    this.mini.redrawAll();
    const pos = positionOf(move.fen);
    for (const [side, hand] of [['white', box.querySelector<HTMLElement>('.ch-pv-hand-white')!], ['black', box.querySelector<HTMLElement>('.ch-pv-hand-black')!]] as const) {
      hand.replaceChildren(...HAND_ROLES.flatMap((role) => {
        const n = pos.pockets?.[side][role] ?? 0;
        if (!n) return [];
        const span = el('span', 'ch-pv-hand-piece');
        const img = document.createElement('img');
        img.src = `/piece/${side === 'white' ? 'w' : 'b'}${LETTER[role]}.svg`;
        img.alt = '';
        span.append(img);
        if (n > 1) span.append(el('em', '', String(n)));
        return [span];
      }));
    }
    box.classList.toggle('ch-pv-board-flipped', orientation === 'black');
    box.setAttribute('aria-label', `After ${move.san}`);
  }

  private hideBoard() {
    this.hovered = null;
    this.els.board.hidden = true;
  }
}
