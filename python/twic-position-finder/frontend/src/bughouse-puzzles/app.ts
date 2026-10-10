/**
 * Bughouse Puzzles page controller. It loads the set's index from
 * /bughouse-puzzles/, filters it in memory, fetches shards as puzzles are
 * opened, and runs one Attempt at a time on the PuzzleBoard. The flow and
 * key map follow the Tactics Trainer: a wrong move shows briefly and is
 * taken back, a right one gets the defender's reply, and View solution
 * plays out the rest. The current puzzle's id lives in the URL hash.
 */
import type { Colour } from '../bughouse/types';
import { PuzzleBoard } from './board';
import { Attempt, formatTimeControl, inCheck, labLink, type Puzzle } from './puzzle';
import {
  DEFAULT_FILTER, DIFFICULTIES, DIFFICULTY_LABELS, KIND_LABELS, LENGTHS, PuzzleStore, applyFilter, facetCounts,
  lengthLabel, normalizeFilter, parseHash, puzzleHash, themeCounts, themeLabel,
  type Filter, type IndexEntry, type KindFilter, type PuzzleIndex,
} from './set';

type Outcome = 'win' | 'fail';
type Feedback = 'turn' | 'good' | 'bad' | 'win' | 'fail' | 'revealed' | 'error';
type State = 'loading' | 'ready' | 'error' | 'empty';
/** Theme chips shown before "more" expands the facet. */
const THEME_CAP = 8;
const STORE_KEY = 'bughouse-puzzles-v2';
const OLD_STORE_KEY = 'bughouse-puzzles-v1';
interface Saved { version: 2; outcomes: Record<string, Outcome>; filter: Filter; current: string | null }

/** How long the opponent's last move is shown arriving before the solver may move. */
const INTRO_MS = 200;

function $<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing #${id}`);
  return el as T;
}

const sideName = (c: Colour) => (c === 'white' ? 'White' : 'Black');

function load(): Saved {
  const fresh: Saved = { version: 2, outcomes: {}, filter: { ...DEFAULT_FILTER }, current: null };
  try {
    const s = JSON.parse(localStorage.getItem(STORE_KEY) ?? 'null') as Partial<Saved> | null;
    if (s && typeof s.outcomes === 'object' && s.outcomes) {
      return { version: 2, outcomes: s.outcomes, filter: normalizeFilter(s.filter), current: typeof s.current === 'string' ? s.current : null };
    }
    // Results from the first version carry over; its mate-length filter does not.
    const old = JSON.parse(localStorage.getItem(OLD_STORE_KEY) ?? 'null') as { outcomes?: Record<string, Outcome> } | null;
    if (old && typeof old.outcomes === 'object' && old.outcomes) fresh.outcomes = old.outcomes;
  } catch { /* private mode or a damaged entry: start fresh */ }
  return fresh;
}

export class BughousePuzzlesApp {
  private readonly store = new PuzzleStore();
  private all: IndexEntry[] = [];
  private list: IndexEntry[] = [];
  private index = 0;
  private attempt: Attempt | null = null;
  private board: PuzzleBoard | null = null;
  private saved = load();
  private timer: ReturnType<typeof setTimeout> | null = null;
  /** A wrong move shown on the board until it is taken back. */
  private wrong: string | null = null;
  /** Whether the theme facet shows every theme or only the commonest. */
  private themesOpen = false;
  /** Counts up on every `go`, so a slow shard cannot land on a later puzzle. */
  private generation = 0;
  private feedback: Feedback = 'turn';

  constructor() {
    this.bind();
    void this.start();
  }

  private async start() {
    this.setState('loading');
    let index: PuzzleIndex;
    try {
      index = await this.store.loadIndex();
    } catch (e) {
      $('bp-error-copy').textContent = e instanceof Error && /^\d{3} /.test(e.message) ? `The server answered ${e.message.slice(0, 3)}.` : 'Check the connection and try again.';
      this.setState('error');
      this.say('error', 'Nothing to solve yet', 'The puzzle set did not load.');
      return;
    }
    this.all = index.puzzles;
    $('bp-source').textContent = `${index.count} puzzles from ${index.source}, generated ${index.generated}. Fairy-Stockfish found and checked each one with the reserves frozen. Your results are kept in this browser only.`;
    if (!this.board) {
      this.board = new PuzzleBoard($('bp-board'), { top: $('bp-seat-top'), bottom: $('bp-seat-bottom') }, (uci) => this.onMove(uci));
      this.board.preferredPromotion = (options) => {
        const want = this.attempt?.accepted().find((u) => options.includes(u));
        return want ?? options.find((u) => u.endsWith('q')) ?? options[0];
      };
    }
    // A deep link wins over the saved place, and over a filter that would hide it.
    const linked = parseHash(location.hash);
    if (linked && this.all.some((e) => e.id === linked)) {
      if (!applyFilter(this.all, this.saved.filter).some((e) => e.id === linked)) this.saved.filter = { ...DEFAULT_FILTER };
      this.applyFilter(this.saved.filter, linked);
    } else {
      this.applyFilter(this.saved.filter, this.saved.current);
    }
  }

  private bind() {
    $('bp-prev').onclick = () => this.go(this.index - 1);
    $('bp-next').onclick = () => this.next();
    $('bp-retry').onclick = () => this.go(this.index);
    $('bp-solution').onclick = () => this.reveal();
    $('bp-retry-load').onclick = () => { if (this.all.length) this.go(this.index); else void this.start(); };
    $('bp-clear-filters').onclick = () => this.applyFilter({ ...DEFAULT_FILTER }, this.list[this.index]?.id ?? null);
    $('bp-copy-link').onclick = () => void this.copyLink();
    $('bp-filters-toggle').onclick = () => {
      const open = $('bp-filters').classList.toggle('open');
      $('bp-filters-toggle').setAttribute('aria-expanded', String(open));
    };
    window.addEventListener('hashchange', () => {
      const id = parseHash(location.hash);
      const at = id ? this.list.findIndex((e) => e.id === id) : -1;
      if (at >= 0 && at !== this.index) this.go(at);
    });
    document.addEventListener('keydown', (e) => {
      if ((e.target as HTMLElement).matches('input, select, textarea') || e.ctrlKey || e.metaKey || e.altKey) return;
      const key = e.key.toLowerCase();
      if (e.key === 'ArrowUp' || key === 'p') { e.preventDefault(); this.go(this.index - 1); }
      else if (e.key === 'ArrowDown' || key === 's') { e.preventDefault(); this.next(); }
      else if (e.key === ' ') { e.preventDefault(); this.reveal(); }
      else if (key === 'r') { e.preventDefault(); this.go(this.index); }
    });
  }

  private setState(state: State) { $('bp').dataset.state = state; }

  private setText(selector: string, text: string) {
    for (const el of document.querySelectorAll<HTMLElement>(selector)) el.textContent = text;
  }

  private persist() {
    this.saved.current = this.list[this.index]?.id ?? null;
    try { localStorage.setItem(STORE_KEY, JSON.stringify(this.saved)); } catch { /* not kept; fine */ }
  }

  private async copyLink() {
    const id = this.list[this.index]?.id;
    if (!id) return;
    const url = `${location.origin}${location.pathname}${puzzleHash(id)}`;
    const label = $('bp-copy-label');
    const button = $('bp-copy-link');
    try {
      await navigator.clipboard.writeText(url);
      label.textContent = 'Copied';
      button.classList.add('copied');
    } catch {
      label.textContent = 'Copy failed';
    }
    setTimeout(() => { label.textContent = 'Copy link'; button.classList.remove('copied'); }, 1500);
  }

  // ── Filters ────────────────────────────────────────────────────

  private applyFilter(filter: Filter, keep: string | null) {
    this.saved.filter = filter;
    this.list = applyFilter(this.all, filter);
    this.renderFilters();
    if (!this.list.length) {
      this.clearTimer();
      this.attempt = null;
      this.setState('empty');
      this.say('turn', 'No puzzles match', 'Loosen a filter to continue.');
      this.setText('.bp-counter', '0 / 0');
      for (const id of ['bp-prev', 'bp-next', 'bp-retry', 'bp-solution']) $<HTMLButtonElement>(id).disabled = true;
      this.renderSession();
      this.persist();
      return;
    }
    const at = this.list.findIndex((e) => e.id === keep);
    this.go(at >= 0 ? at : 0);
  }

  private change(patch: Partial<Filter>) {
    this.applyFilter({ ...this.saved.filter, ...patch }, this.list[this.index]?.id ?? null);
  }

  private renderFilters() {
    const f = this.saved.filter;
    const kinds: KindFilter[] = ['all', 'mate', 'advantage'];
    const kindCounts = facetCounts(this.all, f, 'kind', kinds);
    this.renderFacet($('bp-kind'), 'bp-kind', kinds.filter((k) => k === 'all' || this.all.some((e) => e.kind === k)).map((k) => ({
      value: k, label: k === 'all' ? 'All' : k === 'mate' ? 'Mates' : 'Tactics', count: kindCounts.get(k) ?? 0, checked: f.kind === k,
    })), (v) => this.change({ kind: v as KindFilter }));

    const lengths = facetCounts(this.all, f, 'length', ['all', ...LENGTHS]);
    const lengthChips = LENGTHS.filter((l) => facetCounts(this.all, { ...DEFAULT_FILTER, kind: f.kind }, 'length', [l]).get(l))
      .map((l) => ({ value: l, label: lengthLabel(l, f.kind), count: lengths.get(l) ?? 0, checked: f.length === l }));
    this.renderFacet($('bp-length'), 'bp-length', [{ value: 'all', label: 'Any length', count: lengths.get('all') ?? 0, checked: f.length === 'all' }, ...lengthChips],
      (v) => this.change({ length: v as Filter['length'] }));

    const difficulties = facetCounts(this.all, f, 'difficulty', ['all', ...DIFFICULTIES]);
    this.renderFacet($('bp-difficulty'), 'bp-difficulty', [
      { value: 'all', label: 'Any level', count: difficulties.get('all') ?? 0, checked: f.difficulty === 'all' },
      ...DIFFICULTIES.map((d) => ({ value: String(d), label: DIFFICULTY_LABELS[d], count: difficulties.get(d) ?? 0, checked: f.difficulty === d })),
    ], (v) => this.change({ difficulty: v === 'all' ? 'all' : (Number(v) as 1 | 2 | 3) }));

    const missed = facetCounts(this.all, f, 'missed', [true]).get(true) ?? 0;
    const box = $('bp-missed');
    box.replaceChildren(this.chip('checkbox', 'bp-missed', 'missed', 'Missed in the game', missed, f.missed, () => this.change({ missed: !f.missed })));

    const themes = themeCounts(this.all, f).filter(([, n]) => n > 0);
    $('bp-theme').hidden = themes.length < 2 && !f.theme;
    const active = [f.kind !== 'all', f.length !== 'all', f.difficulty !== 'all', !!f.theme, f.missed].filter(Boolean).length;
    const activeEl = $('bp-filter-active');
    activeEl.hidden = !active;
    activeEl.textContent = String(active);
    // Only the commonest themes show at first, so the board stays above the fold.
    const shown = this.themesOpen ? themes : themes.filter(([t], i) => i < THEME_CAP || t === f.theme);
    this.renderFacet($('bp-theme'), 'bp-theme', [
      { value: '', label: 'Any theme', count: applyFilter(this.all, { ...f, theme: null }).length, checked: !f.theme },
      ...shown.map(([t, n]) => ({ value: t, label: themeLabel(t), count: n, checked: f.theme === t })),
    ], (v) => this.change({ theme: v || null }));
    if (themes.length > THEME_CAP) {
      const more = document.createElement('button');
      more.type = 'button';
      more.className = 'btn btn-text btn-sm bp-more-themes';
      more.setAttribute('aria-expanded', String(this.themesOpen));
      more.textContent = this.themesOpen ? 'Fewer themes' : `${themes.length - shown.length} more`;
      more.onclick = () => { this.themesOpen = !this.themesOpen; this.renderFilters(); };
      $('bp-theme').append(more);
    }
  }

  private renderFacet(box: HTMLElement, name: string, chips: { value: string; label: string; count: number; checked: boolean }[], pick: (value: string) => void) {
    box.replaceChildren(...chips.map((c) => this.chip('radio', name, c.value, c.label, c.count, c.checked, () => pick(c.value))));
  }

  private chip(type: 'radio' | 'checkbox', name: string, value: string, text: string, count: number, checked: boolean, change: () => void): HTMLElement {
    const label = document.createElement('label');
    label.className = 'choice';
    const input = document.createElement('input');
    input.type = type;
    input.name = name;
    input.value = value;
    input.checked = checked;
    input.disabled = !count && !checked;
    input.onchange = change;
    const span = document.createElement('span');
    const b = document.createElement('b');
    b.textContent = String(count);
    span.append(text, b);
    label.append(input, span);
    return label;
  }

  // ── Navigation ─────────────────────────────────────────────────

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
    this.attempt = null;
    const entry = this.list[i];
    const generation = ++this.generation;
    this.persist();
    history.replaceState(null, '', puzzleHash(entry.id));
    this.renderNav();
    this.renderSession();
    this.store.prefetch(this.list[i + 1]);
    void this.store.get(entry).then((puzzle) => {
      if (generation !== this.generation) return;
      this.open(puzzle);
    }, (e: unknown) => {
      if (generation !== this.generation) return;
      $('bp-error-copy').textContent = e instanceof Error && /^\d{3} /.test(e.message) ? `The server answered ${e.message.slice(0, 3)} for this part of the set.` : 'This part of the set did not load.';
      this.setState('error');
      this.say('error', 'Puzzle not loaded', 'Try again, or move on to the next one.');
    });
  }

  private open(puzzle: Puzzle) {
    const a = new Attempt(puzzle);
    this.attempt = a;
    this.setState('ready');
    this.renderPuzzle();
    const intro = a.intro();
    if (intro) {
      // Show the board before the opponent's move, then let chessground animate it in.
      this.renderBoard(false, intro);
      this.say('turn', 'Their move', 'Watch what just happened.');
      this.timer = setTimeout(() => {
        this.timer = null;
        this.say('turn');
        this.renderBoard();
      }, INTRO_MS);
    } else {
      this.say('turn');
      this.renderBoard();
    }
  }

  private onMove(uci: string) {
    const a = this.attempt;
    if (!a || this.timer) return;
    const verdict = a.play(uci);
    if (verdict === 'wrong') {
      this.wrong = uci;
      this.say('bad');
      this.renderLine();
      this.renderBoard(true);
      this.timer = setTimeout(() => {
        this.timer = null;
        this.wrong = null;
        this.say('turn');
        this.renderLine();
        this.renderBoard();
      }, 700);
      return;
    }
    this.renderLine();
    if (verdict === 'solved') { this.finish(); return; }
    this.say('good');
    this.renderBoard();
    this.timer = setTimeout(() => {
      this.timer = null;
      a.reply();
      this.say('turn');
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
    this.say(revealed ? 'revealed' : a.failed ? 'fail' : 'win');
    this.renderBoard();
    this.renderSession();
    this.renderThemes(true);
  }

  private clearTimer() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  // ── Rendering ──────────────────────────────────────────────────

  private renderBoard(showWrong = false, intro: Attempt['pos'] | null = null) {
    const a = this.attempt!;
    const p = a.puzzle;
    let pos = intro ?? a.pos;
    let last = intro ? [] : a.last;
    if (showWrong && this.wrong) {
      // Show the wrong move where it landed until it is taken back.
      pos = { ...pos, pieces: { ...pos.pieces } };
      const w = this.wrong;
      if (w[1] === '@') pos.pieces[w.slice(2, 4)] = a.solver === 'white' ? w[0].toUpperCase() : w[0].toLowerCase();
      else { pos.pieces[w.slice(2, 4)] = pos.pieces[w.slice(0, 2)]; delete pos.pieces[w.slice(0, 2)]; }
      last = [];
    }
    this.board!.render({
      pos,
      bottom: a.solver,
      solver: a.solver,
      legal: this.timer || intro || a.done ? [] : a.legal(),
      last,
      check: !showWrong && !intro && inCheck(a.pos),
      players: { white: { name: p.white, rating: p.welo }, black: { name: p.black, rating: p.belo } },
    });
  }

  private renderNav() {
    this.setText('.bp-counter', `${this.index + 1} / ${this.list.length}`);
    $<HTMLButtonElement>('bp-prev').disabled = this.index === 0;
    $<HTMLButtonElement>('bp-next').disabled = this.index >= this.list.length - 1;
    $<HTMLButtonElement>('bp-retry').disabled = false;
    $<HTMLButtonElement>('bp-solution').disabled = !this.attempt || this.attempt.done;
  }

  private renderPuzzle() {
    const a = this.attempt!;
    const p = a.puzzle;
    this.renderNav();
    const task = $('bp-task');
    task.replaceChildren();
    if (p.kind === 'mate') {
      task.textContent = `${sideName(a.solver)} mates in ${p.mate}`;
    } else {
      const sep = document.createElement('span');
      sep.className = 'sep';
      sep.textContent = '·';
      task.append(`${sideName(a.solver)} to play`, sep, 'find the best move');
    }
    $('bp-players').innerHTML = '';
    const players = $('bp-players');
    const side = (name: string, elo: number) => {
      const s = document.createElement('span');
      s.textContent = name;
      const r = document.createElement('span');
      r.className = 'rating';
      r.textContent = String(elo);
      s.append(r);
      return s;
    };
    const vs = document.createElement('span');
    vs.className = 'vs';
    vs.textContent = '–';
    players.append(side(p.white, p.welo), vs, side(p.black, p.belo));
    $('bp-game-sub').textContent = `Board ${p.board} · FICS game ${p.game} · ${p.date.replace(/\./g, '-')} · ${formatTimeControl(p.tc)}`;
    $<HTMLAnchorElement>('bp-lab-link').href = labLink(p, a.solver);
    this.renderThemes(false);
    this.renderLine();
  }

  private inGameSentence(): string {
    const a = this.attempt!;
    const p = a.puzzle;
    const who = sideName(a.solver);
    if (p.found) return `In the game, ${who} found it.`;
    return p.played ? `In the game, ${who} played ${p.played}.` : 'The game ended here.';
  }

  /** Kind and difficulty are safe to show at once; the themes would give the idea away. */
  private renderThemes(solved: boolean) {
    const a = this.attempt!;
    const p = a.puzzle;
    const tags = $('bp-tags');
    tags.replaceChildren();
    const badge = (text: string, cls = '') => {
      const b = document.createElement('span');
      b.className = `badge ${cls}`.trim();
      b.textContent = text;
      return b;
    };
    tags.append(badge(KIND_LABELS[p.kind]), badge(DIFFICULTY_LABELS[p.difficulty], p.difficulty === 3 ? 'badge-warn' : p.difficulty === 1 ? 'badge-ok' : ''));
    const box = $('bp-puzzle-themes');
    const list = p.themes.filter((t) => !/^mate$|^mateIn\d+$/.test(t) || p.kind !== 'mate');
    box.hidden = !solved || !list.length;
    $('bp-puzzle-theme-chips').replaceChildren(...list.map((t) => {
      const c = document.createElement('span');
      c.className = 'bp-chip';
      c.textContent = themeLabel(t);
      return c;
    }));
  }

  private renderLine() {
    const a = this.attempt!;
    const box = $('bp-line');
    box.replaceChildren();
    const startNo = Number(a.puzzle.fen.split(' ')[5]) || 1;
    const blackStarts = a.solver === 'black';
    const token = (i: number, san: string, cls: string) => {
      const whiteMove = blackStarts ? i % 2 === 1 : i % 2 === 0;
      if (whiteMove || i === 0) {
        const n = document.createElement('span');
        n.className = 'san-num';
        n.textContent = `${startNo + Math.floor((i + (blackStarts ? 1 : 0)) / 2)}.${whiteMove ? '' : '..'}`;
        box.append(n);
      }
      const t = document.createElement('span');
      t.className = `san-token played ${cls}`.trimEnd();
      t.textContent = san;
      box.append(t);
    };
    a.played.forEach((san, i) => token(i, san, i % 2 === 0 ? 'best' : ''));
    if (this.wrong) token(a.played.length, this.wrongLabel(this.wrong), 'wrong');
  }

  /** A wrong move has no SAN in the data: "Nf7", "e5" or the drop as written. */
  private wrongLabel(uci: string): string {
    if (uci[1] === '@') return uci;
    const piece = this.attempt!.pos.pieces[uci.slice(0, 2)] ?? '';
    const letter = piece.toLowerCase() === 'p' ? '' : piece.toUpperCase();
    return `${letter}${uci.slice(2, 4)}`;
  }

  /** Set the feedback box. Without a title the state writes its own copy for the current attempt. */
  private say(state: Feedback, title?: string, sub?: string) {
    const box = $('bp-turn');
    const changed = this.feedback !== state || title !== undefined;
    this.feedback = state;
    box.className = `turn-box bp-feedback turn-${state}`;
    if (changed) {
      // Restart the one authored motion: the text rises into its new state.
      box.classList.remove('is-fresh');
      void box.offsetWidth;
      box.classList.add('is-fresh');
    }
    const titleEl = $('bp-turn-title');
    const subEl = $('bp-turn-sub');
    const a = this.attempt;
    if (a) $<HTMLImageElement>('bp-turn-icon').src = a.solver === 'white' ? '/piece/wK.svg' : '/piece/bK.svg';
    if (title !== undefined) {
      titleEl.textContent = title;
      subEl.textContent = sub ?? '';
      return;
    }
    if (!a) return;
    const p = a.puzzle;
    const mate = p.kind === 'mate';
    const total = Math.ceil(p.line.length / 2);
    const step = Math.floor(a.ply / 2) + 1;
    const over = state === 'win' || state === 'fail' || state === 'revealed';
    $<HTMLButtonElement>('bp-solution').disabled = over;
    const progress = total > 1 ? `Move ${Math.min(step, total)} of ${total}. ` : '';
    switch (state) {
      case 'turn':
        titleEl.textContent = 'Your move';
        subEl.textContent = mate
          ? (a.finalStep ? `${progress}Deliver mate.` : `Check, move ${step} of ${total}. Only one keeps the mate.`)
          : (a.finalStep && total > 1 ? `${progress}Finish it.` : `${progress}Find the best move.`);
        break;
      case 'good':
        titleEl.textContent = 'Right';
        subEl.textContent = 'Their reply…';
        break;
      case 'bad':
        titleEl.textContent = mate ? (a.finalStep ? 'Not mate' : 'That doesn’t force mate') : 'Not the best move';
        subEl.textContent = mate
          ? (a.finalStep ? 'Look at every check, drops included.' : 'Each move must be check and leave no way out.')
          : 'There is something stronger. Count the drops too.';
        break;
      case 'win':
        titleEl.textContent = mate ? 'Checkmate' : 'Winning';
        subEl.textContent = `Solved first time. ${this.inGameSentence()}`;
        break;
      case 'fail':
        titleEl.textContent = mate ? 'Checkmate' : 'Winning';
        subEl.textContent = `Solved after a miss. ${this.inGameSentence()}`;
        break;
      case 'revealed':
        titleEl.textContent = 'Solution';
        subEl.textContent = `Retry to play it yourself. ${this.inGameSentence()}`;
        break;
      case 'error':
        break;
    }
  }

  private renderSession() {
    const strip = $('bp-session');
    strip.replaceChildren();
    const outcomes = this.list.map((p) => this.saved.outcomes[p.id]);
    const won = outcomes.filter((o) => o === 'win').length;
    const done = outcomes.filter(Boolean).length;
    this.setText('.bp-score', done ? `${won} / ${done} solved first time` : '');
    this.list.forEach((p, i) => {
      const cell = document.createElement('button');
      cell.type = 'button';
      const o = outcomes[i];
      const what = p.kind === 'mate' ? `Mate in ${p.mate}` : `Tactic, ${p.moves} move${p.moves === 1 ? '' : 's'}`;
      cell.className = `session-cell${o ? ` ${o}` : ''}${i === this.index ? ' current' : ''}`;
      cell.title = `${i + 1}. ${what}`;
      cell.setAttribute('aria-label', `Puzzle ${i + 1}, ${what.toLowerCase()}${o === 'win' ? ', solved' : o === 'fail' ? ', missed' : ''}`);
      cell.addEventListener('click', () => this.go(i));
      strip.append(cell);
    });
    // Scroll the strip itself, never the page: on a phone the strip sits below the board.
    const cell = strip.children[this.index] as HTMLElement | undefined;
    if (cell) {
      const r = cell.getBoundingClientRect();
      const box = strip.getBoundingClientRect();
      if (r.top < box.top) strip.scrollTop += r.top - box.top;
      else if (r.bottom > box.bottom) strip.scrollTop += r.bottom - box.bottom;
    }
  }
}
