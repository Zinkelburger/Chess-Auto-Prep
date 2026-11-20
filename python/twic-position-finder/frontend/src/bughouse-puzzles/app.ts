/**
 * Bughouse Puzzles page controller. It loads the chosen set's index (FICS
 * games from /bughouse-puzzles/, engine games from /bughouse-puzzles/engine/),
 * filters it in memory, fetches shards as puzzles are opened, and runs one
 * Attempt at a time on the PuzzleBoard. Each set keeps its own results,
 * filter and place; a deep link opens the set its id belongs to. The flow and
 * key map follow the Tactics Trainer: a wrong move shows briefly and is
 * taken back, a right one gets the defender's reply, and View solution
 * plays out the rest. The current puzzle's id lives in the URL hash.
 * Clicking a move, ←/→, Home/End or the step buttons show an earlier board
 * of the line; the board is locked until play returns to the latest move.
 * The board can be solved by keyboard alone (board.ts); while it has the
 * focus the arrows are its own.
 *
 * Solving shows only the board, the task and the moves; choosing puzzles,
 * progress and the notes on the set live in the Settings sheet.
 */
import type { Colour } from '../bughouse/types';
import { PuzzleBoard } from './board';
import { Attempt, analysisLink, inCheck, type Puzzle } from './puzzle';
import {
  DEFAULT_FILTER, DIFFICULTIES, DIFFICULTY_LABELS, LENGTHS, PuzzleStore, SETS, SET_KEY, SET_NAMES, applyFilter, facetCounts,
  gameLines, initialSet, lengthLabel, normalizeFilter, parseHash, puzzleHash, setOfId, themeCounts, themeLabel,
  type Filter, type IndexEntry, type KindFilter, type PuzzleIndex, type SetName,
} from './set';

type Outcome = 'win' | 'fail';
type Feedback = 'intro' | 'turn' | 'good' | 'bad' | 'win' | 'fail' | 'revealed' | 'error';
type State = 'loading' | 'ready' | 'error' | 'empty';
/** Theme chips shown before "more" expands the facet. */
const THEME_CAP = 8;
/** The first version's results carry over to the FICS set. */
const OLD_STORE_KEY = 'bughouse-puzzles-v1';
interface Saved { version: 2; outcomes: Record<string, Outcome>; filter: Filter; current: string | null }

/** What Space presses itself instead of showing the solution. */
const CONTROLS = 'button, a[href], summary, label, [role="button"], [role="link"], [role="radio"], [role="checkbox"], [role="option"], [role="tab"], [contenteditable="true"]';

/** How long the opponent's last move is shown arriving before the solver may move. */
const INTRO_MS = 200;

function $<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing #${id}`);
  return el as T;
}

const sideName = (c: Colour) => (c === 'white' ? 'White' : 'Black');

function load(set: SetName): Saved {
  const fresh: Saved = { version: 2, outcomes: {}, filter: { ...DEFAULT_FILTER }, current: null };
  try {
    const s = JSON.parse(localStorage.getItem(SETS[set].storeKey) ?? 'null') as Partial<Saved> | null;
    if (s && typeof s.outcomes === 'object' && s.outcomes) {
      return { version: 2, outcomes: s.outcomes, filter: normalizeFilter(s.filter), current: typeof s.current === 'string' ? s.current : null };
    }
    // Results from the first version carry over; its mate-length filter does not.
    const old = set === 'human' ? JSON.parse(localStorage.getItem(OLD_STORE_KEY) ?? 'null') as { outcomes?: Record<string, Outcome> } | null : null;
    if (old && typeof old.outcomes === 'object' && old.outcomes) fresh.outcomes = old.outcomes;
  } catch { /* private mode or a damaged entry: start fresh */ }
  return fresh;
}

function savedSet(): unknown {
  try { return localStorage.getItem(SET_KEY); } catch { return null; }
}

export class BughousePuzzlesApp {
  private readonly stores: Record<SetName, PuzzleStore> = { human: new PuzzleStore(SETS.human.base), engine: new PuzzleStore(SETS.engine.base) };
  private set: SetName = initialSet(parseHash(location.hash), savedSet());
  private all: IndexEntry[] = [];
  private list: IndexEntry[] = [];
  private index = 0;
  private attempt: Attempt | null = null;
  private board: PuzzleBoard | null = null;
  private saved = load(this.set);
  private timer: ReturnType<typeof setTimeout> | null = null;
  /** A wrong move shown on the board until it is taken back. */
  private wrong: string | null = null;
  /** The number of moves on the board being looked at; null shows the latest. */
  private view: number | null = null;
  /** Whether the theme facet shows every theme or only the commonest. */
  private themesOpen = false;
  /** Counts up on every `go`, so a slow shard cannot land on a later puzzle. */
  private generation = 0;
  private feedback: Feedback = 'turn';
  /** Counts up on every set load, so a slow index cannot land after the set changed again. */
  private loading = 0;
  /** Whether the last input was a pointer (mouse, pen or touch) rather than a key. */
  private pointer = false;

  constructor() {
    this.bind();
    void this.start();
  }

  private get store(): PuzzleStore { return this.stores[this.set]; }

  /** Load the current set and open the linked puzzle, else the saved place. */
  private async start(linked: string | null = parseHash(location.hash)) {
    const loading = ++this.loading;
    this.clearTimer();
    this.attempt = null;
    this.all = [];
    this.list = [];
    this.setState('loading');
    this.say('turn', 'Loading');
    this.setText('.bp-counter', '— / —');
    for (const id of ['bp-prev', 'bp-next', 'bp-retry', 'bp-solution']) $<HTMLButtonElement>(id).disabled = true;
    this.showAfter(false);
    this.renderFilters();
    let index: PuzzleIndex;
    try {
      index = this.store.index ?? await this.store.loadIndex();
    } catch (e) {
      if (loading !== this.loading) return;
      $('bp-error-copy').textContent = e instanceof Error && /^\d{3} /.test(e.message) ? `The server answered ${e.message.slice(0, 3)}.` : 'Check the connection and try again.';
      this.setState('error');
      this.say('error', 'Nothing to solve yet', 'The puzzle set did not load.');
      return;
    }
    if (loading !== this.loading) return;
    try { localStorage.setItem(SET_KEY, this.set); } catch { /* not kept; fine */ }
    this.all = index.puzzles;
    $('bp-source').textContent = `${index.count} puzzles from ${index.source}. Your results are kept in this browser only.`;
    if (!this.board) {
      this.board = new PuzzleBoard($('bp-board'), { top: $('bp-seat-top'), bottom: $('bp-seat-bottom') },
        { move: (uci) => this.onMove(uci), next: () => this.next() }, $('bp-live'));
    }
    // A deep link wins over the saved place, and over a filter that would hide it.
    if (linked && this.all.some((e) => e.id === linked)) {
      if (!applyFilter(this.all, this.saved.filter).some((e) => e.id === linked)) this.saved.filter = { ...DEFAULT_FILTER };
      this.applyFilter(this.saved.filter, linked);
    } else {
      this.applyFilter(this.saved.filter, this.saved.current);
    }
  }

  /** Change to the other set, keeping each set's own results, filter and place. */
  private switchSet(set: SetName, linked: string | null = null) {
    if (set === this.set) return;
    this.persist();
    this.set = set;
    this.saved = load(set);
    this.themesOpen = false;
    void this.start(linked);
  }

  /** The other set's size, for its chip; fetched when Settings opens. */
  private loadOtherIndex() {
    const other = SET_NAMES.find((n) => n !== this.set)!;
    if (this.stores[other].index) return;
    this.stores[other].loadIndex().then(() => this.renderFilters(), () => { /* its chip shows no count */ });
  }

  private bind() {
    $('bp-prev').onclick = () => this.go(this.index - 1);
    $('bp-next').onclick = () => this.next();
    $('bp-retry').onclick = () => this.go(this.index);
    $('bp-solution').onclick = () => this.reveal();
    $('bp-back').onclick = () => this.browse(this.shown - 1);
    $('bp-forward').onclick = () => this.browse(this.shown + 1);
    $('bp-retry-load').onclick = () => { if (this.all.length) this.go(this.index); else void this.start(); };
    $('bp-clear-filters').onclick = () => this.applyFilter({ ...DEFAULT_FILTER }, this.list[this.index]?.id ?? null);
    const sheet = $<HTMLDialogElement>('bp-settings');
    $('bp-settings-open').onclick = () => { sheet.showModal(); this.loadOtherIndex(); };
    $('bp-settings-close').onclick = () => sheet.close();
    // A click on the backdrop (the dialog itself, outside its content) closes it.
    sheet.addEventListener('click', (e) => { if (e.target === sheet) sheet.close(); });
    $('bp-session').addEventListener('keydown', (e) => this.sessionKey(e));
    // chessground cancels its presses, so Chrome takes a mouse solve for keyboard use and would ring
    // the Next button it focuses. The page keeps track itself: a key brings the ring back.
    const next = $('bp-next');
    document.addEventListener('pointerdown', () => { this.pointer = true; }, true);
    document.addEventListener('keydown', () => { this.pointer = false; next.classList.remove('bp-quiet'); }, true);
    next.addEventListener('blur', () => next.classList.remove('bp-quiet'));
    window.addEventListener('hashchange', () => {
      const id = parseHash(location.hash);
      if (id && setOfId(id) !== this.set) { this.switchSet(setOfId(id), id); return; }
      const at = id ? this.list.findIndex((e) => e.id === id) : -1;
      if (at >= 0 && at !== this.index) this.go(at);
      else if (id && at < 0 && this.all.some((e) => e.id === id)) this.applyFilter({ ...DEFAULT_FILTER }, id);
    });
    document.addEventListener('keydown', (e) => {
      const target = e.target as HTMLElement;
      if (target.matches('input, select, textarea') || e.ctrlKey || e.metaKey || e.altKey) return;
      if ($<HTMLDialogElement>('bp-settings').open) return;
      // Space on a focused button, link or other control presses that control.
      if (e.key === ' ' && target.closest(CONTROLS)) return;
      const key = e.key.toLowerCase();
      if (e.key === 'ArrowUp' || key === 'p') { e.preventDefault(); this.go(this.index - 1); }
      else if (e.key === 'ArrowDown' || key === 's') { e.preventDefault(); this.next(); }
      else if (e.key === ' ') { e.preventDefault(); this.reveal(); }
      else if (key === 'r') { e.preventDefault(); this.go(this.index); }
      else if (e.key === 'ArrowLeft') { e.preventDefault(); this.browse(this.shown - 1); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); this.browse(this.shown + 1); }
      else if (e.key === 'Home') { e.preventDefault(); this.browse(0); }
      else if (e.key === 'End') { e.preventDefault(); this.browse(this.attempt?.ply ?? 0); }
    });
  }

  private setState(state: State) { $('bp').dataset.state = state; }

  private setText(selector: string, text: string) {
    for (const el of document.querySelectorAll<HTMLElement>(selector)) el.textContent = text;
  }

  private persist() {
    this.saved.current = this.list[this.index]?.id ?? null;
    try { localStorage.setItem(SETS[this.set].storeKey, JSON.stringify(this.saved)); } catch { /* not kept; fine */ }
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
      this.say('turn', 'No puzzles match', 'Change the settings to continue.');
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
    this.renderFacet($('bp-set'), 'bp-set', SET_NAMES.map((n) => ({
      value: n, label: SETS[n].label, count: n === this.set && this.all.length ? this.all.length : this.stores[n].index?.count ?? null, checked: n === this.set,
    })), (v) => this.switchSet(v as SetName));

    const kinds: KindFilter[] = ['all', 'mate', 'advantage'];
    const kindCounts = facetCounts(this.all, f, 'kind', kinds);
    this.renderFacet($('bp-kind'), 'bp-kind', kinds.filter((k) => k === 'all' || this.all.some((e) => e.kind === k)).map((k) => ({
      value: k, label: k === 'all' ? 'All' : k === 'mate' ? 'Mates' : 'Tactics', count: kindCounts.get(k) ?? 0, checked: f.kind === k,
    })), (v) => this.change({ kind: v as KindFilter }));

    const lengths = facetCounts(this.all, f, 'length', ['all', ...LENGTHS]);
    const lengthChips = LENGTHS.filter((l) => facetCounts(this.all, { ...DEFAULT_FILTER, kind: f.kind }, 'length', [l]).get(l))
      .map((l) => ({ value: l, label: lengthLabel(l, f.kind), count: lengths.get(l) ?? 0, checked: f.length === l }));
    this.renderFacet($('bp-length'), 'bp-length', [{ value: 'all', label: 'Any', count: lengths.get('all') ?? 0, checked: f.length === 'all' }, ...lengthChips],
      (v) => this.change({ length: v as Filter['length'] }));

    const difficulties = facetCounts(this.all, f, 'difficulty', ['all', ...DIFFICULTIES]);
    this.renderFacet($('bp-difficulty'), 'bp-difficulty', [
      { value: 'all', label: 'Any', count: difficulties.get('all') ?? 0, checked: f.difficulty === 'all' },
      ...DIFFICULTIES.map((d) => ({ value: String(d), label: DIFFICULTY_LABELS[d], count: difficulties.get(d) ?? 0, checked: f.difficulty === d })),
    ], (v) => this.change({ difficulty: v === 'all' ? 'all' : (Number(v) as 1 | 2 | 3) }));

    const missed = facetCounts(this.all, f, 'missed', [true]).get(true) ?? 0;
    const box = $('bp-missed');
    box.replaceChildren(this.chip('checkbox', 'bp-missed', 'missed', SETS[this.set].missed, missed, f.missed, () => this.change({ missed: !f.missed })));

    const themes = themeCounts(this.all, f).filter(([, n]) => n > 0);
    $('bp-theme-setting').hidden = themes.length < 2 && !f.theme;
    const active = [f.kind !== 'all', f.length !== 'all', f.difficulty !== 'all', !!f.theme, f.missed].filter(Boolean).length;
    const activeEl = $('bp-filter-active');
    activeEl.hidden = !active;
    activeEl.textContent = String(active);
    // Only the commonest themes show at first, so the board stays above the fold.
    const shown = this.themesOpen ? themes : themes.filter(([t], i) => i < THEME_CAP || t === f.theme);
    this.renderFacet($('bp-theme'), 'bp-theme', [
      { value: '', label: 'Any', count: applyFilter(this.all, { ...f, theme: null }).length, checked: !f.theme },
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

  private renderFacet(box: HTMLElement, name: string, chips: { value: string; label: string; count: number | null; checked: boolean }[], pick: (value: string) => void) {
    box.replaceChildren(...chips.map((c) => this.chip('radio', name, c.value, c.label, c.count, c.checked, () => pick(c.value))));
  }

  /** A choice with its count; a null count (not known yet) shows none and never disables it. */
  private chip(type: 'radio' | 'checkbox', name: string, value: string, text: string, count: number | null, checked: boolean, change: () => void): HTMLElement {
    const label = document.createElement('label');
    label.className = 'choice';
    const input = document.createElement('input');
    input.type = type;
    input.name = name;
    input.value = value;
    input.checked = checked;
    input.disabled = count === 0 && !checked;
    input.onchange = change;
    const span = document.createElement('span');
    span.append(text);
    if (count !== null) {
      const b = document.createElement('b');
      b.textContent = String(count);
      span.append(b);
    }
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
    this.view = null;
    this.attempt = null;
    this.showAfter(false);
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
    this.board?.resetCursor();
    this.setState('ready');
    this.renderPuzzle();
    const intro = a.intro();
    if (intro) {
      // Show the board before the opponent's move, then let chessground animate it in.
      this.renderBoard(false, intro);
      this.say('intro');
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
      this.board!.announce(`${sideName(a.solver === 'white' ? 'black' : 'white')} played ${a.played.at(-1)}`);
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
    this.view = null;
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
    this.showAfter(true);
    // Enter or Space goes on: the board keeps the focus if it has it, else Next takes it.
    const next = $<HTMLButtonElement>('bp-next');
    if (document.activeElement !== $('bp-board') && !next.disabled) {
      next.classList.toggle('bp-quiet', this.pointer);
      next.focus({ preventScroll: true });
    }
  }

  /** The game's lines and the analysis link, below the buttons in a block whose room is always kept. */
  private showAfter(shown: boolean) { $('bp-after').classList.toggle('is-shown', shown); }

  /** How many moves of the line the board shows now. */
  private get shown(): number { return this.view ?? this.attempt?.ply ?? 0; }

  /** Show the board after `ply` moves; the latest move returns to play. Waits out a reply or a take-back. */
  private browse(ply: number) {
    const a = this.attempt;
    if (!a || this.timer || ply < 0 || ply > a.ply || ply === this.shown) return;
    this.view = ply === a.ply ? null : ply;
    this.renderLine();
    this.renderBoard();
  }

  private clearTimer() {
    if (this.timer) clearTimeout(this.timer);
    this.timer = null;
  }

  // ── Rendering ──────────────────────────────────────────────────

  private renderBoard(showWrong = false, intro: Attempt['pos'] | null = null) {
    const a = this.attempt!;
    const past = intro ? null : this.view === null ? null : a.history[this.view];
    let pos = intro ?? past?.pos ?? a.pos;
    let last = intro ? [] : past?.last ?? a.last;
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
      legal: this.timer || intro || past || a.done ? [] : a.legal(),
      last,
      check: !showWrong && !intro && inCheck(pos),
      finished: a.done && !past && !intro,
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
    this.renderNav();
    $<HTMLAnchorElement>('bp-analysis-link').href = analysisLink(a.puzzle);
    // Written now, shown when the puzzle is over, so showing them moves nothing.
    const [game, found] = gameLines(a.puzzle, this.set);
    $('bp-game').textContent = game;
    $('bp-found').textContent = found;
    this.showAfter(false);
    this.renderLine();
  }

  private renderLine() {
    const a = this.attempt!;
    const box = $('bp-line');
    box.replaceChildren();
    const startNo = Number(a.puzzle.fen.split(' ')[5]) || 1;
    const blackStarts = a.solver === 'black';
    const token = (i: number, san: string, cls: string, ply: number | null) => {
      const whiteMove = blackStarts ? i % 2 === 1 : i % 2 === 0;
      if (whiteMove || i === 0) {
        const n = document.createElement('span');
        n.className = 'san-num';
        n.textContent = `${startNo + Math.floor((i + (blackStarts ? 1 : 0)) / 2)}.${whiteMove ? '' : '..'}`;
        box.append(n);
      }
      // A move of the line is a button that shows the board after it.
      const t = document.createElement(ply === null ? 'span' : 'button');
      t.className = `san-token ${ply === null ? 'played ' : ''}${cls}`.trimEnd();
      t.textContent = san;
      if (t instanceof HTMLButtonElement) {
        t.type = 'button';
        t.onclick = () => this.browse(ply!);
        if (ply === this.shown && !this.wrong) t.setAttribute('aria-current', 'true');
      }
      box.append(t);
    };
    const shown = this.shown;
    a.played.forEach((san, i) => token(i, san, `${i % 2 === 0 ? 'best' : ''}${i + 1 === shown && !this.wrong ? ' active' : ''}`.trim(), i + 1));
    if (this.wrong) token(a.played.length, this.wrongLabel(this.wrong), 'wrong', null);
    $<HTMLButtonElement>('bp-back').disabled = shown === 0 || !!this.wrong;
    $<HTMLButtonElement>('bp-forward').disabled = shown >= a.ply || !!this.wrong;
    // The box is two lines tall; a longer line scrolls inside it, the current move in view.
    const current = box.querySelector<HTMLElement>('.wrong, .active');
    if (current) {
      // Measured inside the padding, so whole rows show and no sliver of the one above.
      const r = current.getBoundingClientRect();
      const b = box.getBoundingClientRect();
      const pad = parseFloat(getComputedStyle(box).paddingTop);
      if (r.top < b.top + pad) box.scrollTop += r.top - b.top - pad;
      else if (r.bottom > b.bottom - pad) box.scrollTop += r.bottom - b.bottom + pad;
    } else box.scrollTop = 0;
  }

  /** A wrong move has no SAN in the data: "Nf7", "e5", "e8=N" or the drop as written. */
  private wrongLabel(uci: string): string {
    if (uci[1] === '@') return uci;
    const piece = this.attempt!.pos.pieces[uci.slice(0, 2)] ?? '';
    const letter = piece.toLowerCase() === 'p' ? '' : piece.toUpperCase();
    return `${letter}${uci.slice(2, 4)}${uci[4] ? `=${uci[4].toUpperCase()}` : ''}`;
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
    if (title !== undefined) {
      titleEl.textContent = title;
      subEl.textContent = sub ?? '';
      subEl.hidden = !sub;
      return;
    }
    subEl.hidden = true;
    if (!a) return;
    const over = state === 'win' || state === 'fail' || state === 'revealed';
    $<HTMLButtonElement>('bp-solution').disabled = over;
    // One line: whose move it is while solving, then only the verdict.
    const toMove = `${sideName(a.solver)} to move`;
    const copy: Record<Exclude<Feedback, 'error'>, string> = {
      intro: toMove,
      turn: toMove,
      good: 'Best move!',
      bad: 'Not the move',
      win: 'Solved!',
      fail: 'Solved after a miss',
      revealed: 'Solution shown',
    };
    if (state === 'error') return;
    titleEl.textContent = copy[state];
  }

  private renderSession() {
    const strip = $('bp-session');
    // The grid is one Tab stop; a rebuild keeps the focus on it, on the current puzzle.
    const focused = strip.contains(document.activeElement);
    strip.replaceChildren();
    const outcomes = this.list.map((p) => this.saved.outcomes[p.id]);
    const won = outcomes.filter((o) => o === 'win').length;
    const done = outcomes.filter(Boolean).length;
    this.setText('.bp-score', done ? `· ${won} of ${done} first try` : '');
    this.list.forEach((p, i) => {
      const cell = document.createElement('button');
      cell.type = 'button';
      const o = outcomes[i];
      const what = p.kind === 'mate' ? `Mate in ${p.mate}` : `Tactic, ${p.moves} move${p.moves === 1 ? '' : 's'}`;
      cell.className = `session-cell${o ? ` ${o}` : ''}${i === this.index ? ' current' : ''}`;
      cell.tabIndex = i === this.index ? 0 : -1;
      cell.title = `${i + 1}. ${what}`;
      cell.setAttribute('aria-label', `Puzzle ${i + 1}, ${what.toLowerCase()}${o === 'win' ? ', solved' : o === 'fail' ? ', missed' : ''}`);
      cell.addEventListener('click', () => this.go(i));
      strip.append(cell);
    });
    // Scroll the strip itself, never the page: on a phone the strip sits below the board.
    const cell = strip.children[this.index] as HTMLElement | undefined;
    if (cell) this.showCell(cell, focused);
  }

  private showCell(cell: HTMLElement, focus: boolean) {
    const strip = $('bp-session');
    if (focus) cell.focus({ preventScroll: true });
    const r = cell.getBoundingClientRect();
    const box = strip.getBoundingClientRect();
    if (r.top < box.top) strip.scrollTop += r.top - box.top;
    else if (r.bottom > box.bottom) strip.scrollTop += r.bottom - box.bottom;
  }

  /** Arrows move between the progress cells (up and down by row), Home and End to the ends; Enter opens one. */
  private sessionKey(e: KeyboardEvent) {
    const cells = [...$('bp-session').children] as HTMLElement[];
    const at = cells.indexOf(document.activeElement as HTMLElement);
    if (at < 0) return;
    let to = -1;
    if (e.key === 'ArrowLeft') to = at - 1;
    else if (e.key === 'ArrowRight') to = at + 1;
    else if (e.key === 'Home') to = 0;
    else if (e.key === 'End') to = cells.length - 1;
    else if (e.key === 'ArrowUp' || e.key === 'ArrowDown') {
      // The cell in the row above or below nearest to this one's column.
      const here = cells[at];
      const down = e.key === 'ArrowDown';
      const row = cells.filter((c) => (down ? c.offsetTop > here.offsetTop : c.offsetTop < here.offsetTop));
      const y = down ? Math.min(...row.map((c) => c.offsetTop)) : Math.max(...row.map((c) => c.offsetTop));
      const near = row.filter((c) => c.offsetTop === y).sort((a, b) => Math.abs(a.offsetLeft - here.offsetLeft) - Math.abs(b.offsetLeft - here.offsetLeft))[0];
      to = near ? cells.indexOf(near) : at;
    } else return;
    e.preventDefault();
    to = Math.max(0, Math.min(cells.length - 1, to));
    cells[at].tabIndex = -1;
    cells[to].tabIndex = 0;
    this.showCell(cells[to], true);
  }
}
