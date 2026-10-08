/**
 * Bughouse Puzzles page controller. It loads the mined set from
 * /bughouse-puzzles.json, filters it by mate length, and runs one Attempt at
 * a time on the PuzzleBoard. The flow and key map follow the Tactics
 * Trainer: a wrong move shows briefly and is taken back, a right one gets the
 * defender's reply, and View solution plays out the rest.
 */
import type { Colour } from '../bughouse/types';
import { PuzzleBoard } from './board';
import { Attempt, formatTimeControl, inCheck, labLink, type Puzzle, type PuzzleSet } from './puzzle';

type Outcome = 'win' | 'fail';
type Filter = 'all' | '1' | '2' | '3' | '4';
const STORE_KEY = 'bughouse-puzzles-v1';
interface Saved { outcomes: Record<string, Outcome>; filter: Filter; current: string | null }

const FILTERS: { id: Filter; label: string }[] = [
  { id: 'all', label: 'All' },
  { id: '1', label: 'Mate in 1' },
  { id: '2', label: 'Mate in 2' },
  { id: '3', label: 'Mate in 3' },
  { id: '4', label: 'Mate in 4+' },
];

function $<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing #${id}`);
  return el as T;
}

const sideName = (c: Colour) => (c === 'white' ? 'White' : 'Black');
const matches = (p: Puzzle, f: Filter) => f === 'all' || (f === '4' ? p.mate >= 4 : p.mate === Number(f));

function load(): Saved {
  try {
    const s = JSON.parse(localStorage.getItem(STORE_KEY) ?? 'null') as Saved | null;
    if (s && typeof s.outcomes === 'object' && FILTERS.some((f) => f.id === s.filter)) return s;
  } catch { /* private mode or a damaged entry: start fresh */ }
  return { outcomes: {}, filter: 'all', current: null };
}

export class BughousePuzzlesApp {
  private all: Puzzle[] = [];
  private list: Puzzle[] = [];
  private index = 0;
  private attempt: Attempt | null = null;
  private board: PuzzleBoard | null = null;
  private saved = load();
  private timer: ReturnType<typeof setTimeout> | null = null;
  /** A wrong move shown on the board until it is taken back. */
  private wrong: string | null = null;

  constructor() {
    void this.start();
  }

  private async start() {
    let set: PuzzleSet;
    try {
      const res = await fetch('/bughouse-puzzles.json');
      if (!res.ok) throw new Error(String(res.status));
      set = await res.json() as PuzzleSet;
    } catch {
      $('bp-loading').innerHTML = '<p class="empty-title">Could not load the puzzles</p><p class="empty-copy">Reload the page to try again.</p>';
      return;
    }
    this.all = set.puzzles;
    $('bp-source').textContent = `${this.all.length} puzzles from ${set.source}. Fairy-Stockfish found and checked each one with the reserves frozen. Your results are kept in this browser only.`;
    $('bp-loading').hidden = true;
    $('bp-train').hidden = false;
    this.board = new PuzzleBoard($('bp-board'), { top: $('bp-player-top'), bottom: $('bp-player-bottom') }, (uci) => this.onMove(uci));
    this.board.preferredPromotion = (options) => {
      const want = this.attempt?.accepted().find((u) => options.includes(u));
      return want ?? options.find((u) => u.endsWith('q')) ?? options[0];
    };
    this.bind();
    this.applyFilter(this.saved.filter, this.saved.current);
  }

  private bind() {
    $('bp-prev').onclick = () => this.go(this.index - 1);
    $('bp-next').onclick = () => this.next();
    $('bp-retry').onclick = () => this.go(this.index);
    $('bp-solution').onclick = () => this.reveal();
    document.addEventListener('keydown', (e) => {
      if ((e.target as HTMLElement).matches('input, select, textarea') || e.ctrlKey || e.metaKey || e.altKey) return;
      const key = e.key.toLowerCase();
      if (e.key === 'ArrowUp' || key === 'p') { e.preventDefault(); this.go(this.index - 1); }
      else if (e.key === 'ArrowDown' || key === 's') { e.preventDefault(); this.next(); }
      else if (e.key === ' ') { e.preventDefault(); this.reveal(); }
      else if (key === 'r') { e.preventDefault(); this.go(this.index); }
    });
  }

  private persist() {
    this.saved.current = this.list[this.index]?.id ?? null;
    try { localStorage.setItem(STORE_KEY, JSON.stringify(this.saved)); } catch { /* not kept; fine */ }
  }

  private applyFilter(filter: Filter, keep: string | null) {
    this.saved.filter = filter;
    this.list = this.all.filter((p) => matches(p, filter));
    const at = this.list.findIndex((p) => p.id === keep);
    this.renderFilters();
    this.go(at >= 0 ? at : 0);
  }

  private renderFilters() {
    const row = $('bp-filters');
    row.replaceChildren();
    for (const f of FILTERS) {
      const count = this.all.filter((p) => matches(p, f.id)).length;
      if (!count) continue;
      const label = document.createElement('label');
      label.className = 'choice';
      const input = document.createElement('input');
      input.type = 'radio';
      input.name = 'bp-filter';
      input.value = f.id;
      input.checked = this.saved.filter === f.id;
      input.onchange = () => this.applyFilter(f.id, this.list[this.index]?.id ?? null);
      const span = document.createElement('span');
      span.textContent = `${f.label} · ${count}`;
      label.append(input, span);
      row.append(label);
    }
  }

  /** The next puzzle not yet tried, else simply the next one. */
  private next() {
    const later = this.list.findIndex((p, i) => i > this.index && !this.saved.outcomes[p.id]);
    this.go(later >= 0 ? later : this.index + 1);
  }

  private go(i: number) {
    if (!this.list.length || i < 0 || i >= this.list.length) return;
    this.clearTimer();
    this.index = i;
    this.wrong = null;
    const p = this.list[i];
    this.attempt = new Attempt(p);
    this.persist();
    this.renderPuzzle();
    this.setTurn('turn');
    this.renderBoard();
    this.renderSession();
  }

  private onMove(uci: string) {
    const a = this.attempt;
    if (!a || this.timer) return;
    const verdict = a.play(uci);
    if (verdict === 'wrong') {
      this.wrong = uci;
      this.setTurn('bad');
      this.renderLine();
      this.renderBoard(true);
      this.timer = setTimeout(() => {
        this.timer = null;
        this.wrong = null;
        this.setTurn('turn');
        this.renderLine();
        this.renderBoard();
      }, 700);
      return;
    }
    this.renderLine();
    if (verdict === 'solved') { this.finish(); return; }
    this.setTurn('good');
    this.renderBoard();
    this.timer = setTimeout(() => {
      this.timer = null;
      a.reply();
      this.setTurn('turn');
      this.renderLine();
      this.renderBoard();
    }, 600);
  }

  private reveal() {
    const a = this.attempt;
    if (!a || a.done) return;
    this.clearTimer();
    this.wrong = null;
    const play = () => {
      a.step();
      this.renderLine();
      this.renderBoard();
      if (a.done) { this.finish(true); return; }
      this.timer = setTimeout(() => { this.timer = null; play(); }, 650);
    };
    play();
  }

  private finish(revealed = false) {
    const a = this.attempt!;
    const id = a.puzzle.id;
    // A puzzle missed once stays missed; Retry is for practice, not the score.
    if (this.saved.outcomes[id] !== 'fail') this.saved.outcomes[id] = a.failed ? 'fail' : 'win';
    this.persist();
    this.setTurn(revealed ? 'revealed' : a.failed ? 'fail' : 'win');
    this.renderBoard();
    this.renderSession();
  }

  private clearTimer() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  // ── Rendering ──────────────────────────────────────────────────

  private renderBoard(showWrong = false) {
    const a = this.attempt!;
    const p = a.puzzle;
    let pos = a.pos;
    let last = a.last;
    if (showWrong && this.wrong) {
      // Show the wrong move where it landed until it is taken back.
      pos = { ...pos, pieces: { ...pos.pieces } };
      const w = this.wrong;
      if (w[1] === '@') pos.pieces[w.slice(2, 4)] = a.solver === 'white' ? w[0].toUpperCase() : w[0].toLowerCase();
      else { pos.pieces[w.slice(2, 4)] = pos.pieces[w.slice(0, 2)]; delete pos.pieces[w.slice(0, 2)]; }
      last = [];
    }
    const name = (c: Colour) => (c === 'white' ? `${p.white} (${p.welo})` : `${p.black} (${p.belo})`);
    this.board!.render({
      pos,
      bottom: a.solver,
      legal: this.timer || a.done ? [] : a.legal(),
      last,
      check: !showWrong && inCheck(a.pos),
      players: { white: name('white'), black: name('black') },
    });
  }

  private renderPuzzle() {
    const a = this.attempt!;
    const p = a.puzzle;
    $('bp-counter').textContent = `${this.index + 1} / ${this.list.length}`;
    $<HTMLButtonElement>('bp-prev').disabled = this.index === 0;
    $<HTMLButtonElement>('bp-next').disabled = this.index >= this.list.length - 1;
    $<HTMLButtonElement>('bp-solution').disabled = false;
    $('bp-task').textContent = `${sideName(a.solver)} mates in ${p.mate}`;
    $('bp-board-badge').textContent = `Board ${p.board}`;
    $('bp-players').textContent = `${p.white} (${p.welo}) – ${p.black} (${p.belo})`;
    $('bp-game-sub').textContent = `FICS game ${p.game} · ${p.date.replace(/\./g, '-')} · ${formatTimeControl(p.tc)}`;
    $('bp-in-game').textContent = p.found
      ? `In the game, ${sideName(a.solver)} found it.`
      : p.played ? `In the game, ${sideName(a.solver)} missed it and played ${p.played}.` : 'The game ended here.';
    $('bp-in-game').hidden = true;  // shown once the puzzle is over, so it gives nothing away
    $<HTMLAnchorElement>('bp-lab-link').href = labLink(p, a.solver);
    this.renderLine();
  }

  private renderLine() {
    const a = this.attempt!;
    const box = $('bp-line');
    box.replaceChildren();
    a.played.forEach((san, i) => {
      const t = document.createElement('span');
      t.className = `san-token played${i % 2 === 0 ? ' best' : ''}`;
      t.textContent = san;
      box.append(t);
    });
    if (this.wrong) {
      const t = document.createElement('span');
      t.className = 'san-token played wrong';
      t.textContent = this.wrongLabel(this.wrong);
      box.append(t);
    }
    if (!box.childElementCount) {
      const t = document.createElement('span');
      t.className = 'dim';
      t.textContent = 'No moves yet';
      box.append(t);
    }
  }

  /** A wrong move has no SAN in the data: "Nf7", "e5" or the drop as written. */
  private wrongLabel(uci: string): string {
    if (uci[1] === '@') return uci;
    const piece = this.attempt!.pos.pieces[uci.slice(0, 2)] ?? '';
    const letter = piece.toLowerCase() === 'p' ? '' : piece.toUpperCase();
    return `${letter}${uci.slice(2, 4)}`;
  }

  private setTurn(state: 'turn' | 'good' | 'bad' | 'win' | 'fail' | 'revealed') {
    const a = this.attempt!;
    const total = a.puzzle.mate;
    const done = Math.ceil(a.ply / 2);
    $('bp-turn').className = `turn-box turn-${state}`;
    $<HTMLImageElement>('bp-turn-icon').src = a.solver === 'white' ? '/piece/wK.svg' : '/piece/bK.svg';
    const title = $('bp-turn-title');
    const sub = $('bp-turn-sub');
    const over = state === 'win' || state === 'fail' || state === 'revealed';
    $('bp-in-game').hidden = !over;
    $<HTMLButtonElement>('bp-solution').disabled = over;
    switch (state) {
      case 'turn':
        title.textContent = 'Your move';
        sub.textContent = a.finalStep
          ? 'Deliver mate.'
          : total > 1 ? `Check, move ${done + 1} of ${total}. Only one keeps the mate.` : 'Deliver mate.';
        break;
      case 'good':
        title.textContent = 'Right';
        sub.textContent = 'Their reply…';
        break;
      case 'bad':
        title.textContent = a.finalStep ? 'Not mate' : 'That doesn’t force mate';
        sub.textContent = a.finalStep ? 'Look at every check, drops included.' : 'Each move must be check and leave no way out.';
        break;
      case 'win':
        title.textContent = 'Checkmate';
        sub.textContent = 'Solved first time.';
        break;
      case 'fail':
        title.textContent = 'Checkmate';
        sub.textContent = 'Solved after a miss.';
        break;
      case 'revealed':
        title.textContent = 'Solution';
        sub.textContent = 'Retry to play it yourself.';
        break;
    }
  }

  private renderSession() {
    const strip = $('bp-session');
    strip.replaceChildren();
    const outcomes = this.list.map((p) => this.saved.outcomes[p.id]);
    const won = outcomes.filter((o) => o === 'win').length;
    const done = outcomes.filter(Boolean).length;
    $('bp-score').textContent = done ? `${won} / ${done} solved first time` : '';
    this.list.forEach((p, i) => {
      const cell = document.createElement('button');
      cell.type = 'button';
      const o = outcomes[i];
      cell.className = `session-cell${o ? ` ${o}` : ''}${i === this.index ? ' current' : ''}`;
      cell.title = `${i + 1}. Mate in ${p.mate}`;
      cell.setAttribute('aria-label', `Puzzle ${i + 1}, mate in ${p.mate}${o === 'win' ? ', solved' : o === 'fail' ? ', missed' : ''}`);
      cell.addEventListener('click', () => this.go(i));
      strip.append(cell);
    });
  }
}
