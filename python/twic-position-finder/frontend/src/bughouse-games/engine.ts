/**
 * The Bughouse Games page's own engine: HypeBeast as on /bughouse, run in
 * this page on request. When it is switched on it searches the board in
 * focus with both boards as the game has them, and follows the reader
 * through the game; the panel is the analysis board's (../analysis/ceval.ts).
 * Searches finished at a position are kept, so stepping back shows them at
 * once. Lines, threads and search time are the analysis board's settings;
 * whether the engine is on is this page's own choice.
 */
import { CevalView } from '../analysis/ceval';
import { Engine, seatKey, type EngineResult, type EngineStatus, type SearchSettings, type Seat } from '../analysis/engine';
import { loadSettings, threadsFor } from '../analysis/settings';
import { outcomeOf, playLine, positionOf } from '../analysis/tree';
import type { BoardName, Colour } from '../bughouse/types';

const ON_KEY = 'bughouse-games-engine';

/** What the engine looks at: both boards as shown, and the one searched. */
export interface EngineTarget {
  fens: Record<BoardName, string>;
  board: BoardName;
  /** The searched board's side at the bottom, for the small board of a hovered move. */
  orientation: Colour;
}

export interface GameEngineHooks {
  /** A move of an engine line was clicked: show the line on `board` up to it. */
  showLine(board: BoardName, fen: string, pv: string[], upTo: number): void;
}

function loadOn(): boolean {
  try { return localStorage.getItem(ON_KEY) === '1'; } catch { return false; }
}

/** The ply of a FEN's position, for move numbers in the lines. */
function plyOf(fen: string): number {
  const fields = fen.split(' ');
  return ((Number(fields[5]) || 1) - 1) * 2 + (fields[1] === 'b' ? 1 : 0);
}

export class GameEngine {
  private readonly engine: Engine;
  private readonly view: CevalView;
  private readonly evals = new Map<string, EngineResult>();
  private status: EngineStatus = { kind: 'off' };
  private target: EngineTarget | null = null;
  private on = loadOn();

  constructor(private readonly toggle: HTMLInputElement, hooks: GameEngineHooks) {
    const $ = (id: string) => document.getElementById(id)!;
    this.engine = new Engine(
      (status) => { this.status = status; this.render(); },
      (result) => this.received(result),
      () => { /* Piece values belong to the analysis board. */ },
    );
    this.engine.configure(threadsFor(loadSettings()));
    this.view = new CevalView({
      header: $('bg-ceval'), pearl: $('bg-pearl'), name: $('bg-engine-name'), info: $('bg-engine-info'), bar: $('bg-bar'),
      // No threat search here: the button is never shown.
      threat: document.createElement('button'),
      pvs: $('bg-pvs'), board: $('bg-pv-board'), switch: toggle,
      action: $('bg-engine-action') as HTMLButtonElement, live: $('bg-eval-live'),
    }, {
      hover: () => { /* The game boards draw no arrows. */ },
      play: (pv, upTo) => { if (this.target) hooks.showLine(this.target.board, this.target.fens[this.target.board], pv, upTo); },
      start: () => { if (this.status.kind === 'ask') this.engine.allow(); else this.search(); },
    }, { engineName: 'HypeBeast', playLine, hands: (fen) => positionOf(fen).pockets });
    toggle.addEventListener('change', () => this.setOn(toggle.checked));
  }

  get enabled(): boolean { return this.on; }

  setOn(on: boolean) {
    this.on = on;
    try { localStorage.setItem(ON_KEY, on ? '1' : '0'); } catch { /* not kept; fine */ }
    this.search();
  }

  /** The game is put away: nothing to search. */
  hide() {
    this.target = null;
    this.engine.stop();
  }

  /** The position shown changed: search it when the engine is on. */
  show(target: EngineTarget) {
    const before = this.seat();
    this.target = target;
    // The same boards again (a flip, the game back from an engine line): the search carries on.
    if (before && seatKey(before) === seatKey(this.seat()!)) { this.render(); return; }
    this.search();
  }

  private seat(): Seat | null {
    const t = this.target;
    return t && { fens: [t.fens.A, t.fens.B], board: t.board === 'A' ? 0 : 1 };
  }

  private settings(): SearchSettings {
    const s = loadSettings();
    return { multiPv: s.multiPv, searchMs: (s.searchSeconds || 10) * 1000 };
  }

  private search() {
    const seat = this.seat();
    if (!this.on || !seat || outcomeOf(seat.fens[seat.board])) { this.engine.stop(); this.render(); return; }
    const settings = this.settings();
    // A position already searched to its limit is shown as it was.
    const kept = this.evals.get(seatKey(seat));
    if (kept?.complete && kept.budget >= settings.searchMs && kept.multiPv >= settings.multiPv) this.engine.stop();
    else this.engine.analyse(seat, settings);
    this.render();
    this.engine.load().catch(() => { /* Shown in the engine header. */ });
  }

  private received(result: EngineResult) {
    const kept = this.evals.get(result.key);
    // A position searched again starts from depth 1: keep the deeper search until the new one reaches it.
    if (!kept || result.done || result.depth >= kept.depth || result.lines.length > kept.lines.length) this.evals.set(result.key, result);
    const seat = this.seat();
    if (seat && result.key === seatKey(seat)) this.render();
  }

  private render() {
    const t = this.target;
    const fen = t ? t.fens[t.board] : '';
    this.toggle.checked = this.on;
    const seat = this.seat();
    this.view.render({
      enabled: this.on,
      title: t ? `HypeBeast · board ${t.board}` : undefined,
      fen,
      ply: t ? plyOf(fen) : 0,
      multiPv: this.settings().multiPv,
      infinite: false,
      searchMs: this.settings().searchMs,
      result: seat ? this.evals.get(seatKey(seat)) : undefined,
      status: this.status,
      threat: false,
      inCheck: false,
      over: t ? outcomeOf(fen) : null,
      orientation: t?.orientation ?? 'white',
      scoreKind: 'team',
    });
  }
}
