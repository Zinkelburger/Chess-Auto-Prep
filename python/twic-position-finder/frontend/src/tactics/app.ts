/**
 * Tactics Trainer page controller: three views (setup → analysing → train)
 * over one puzzle session. Analysis keeps running in the background once the
 * first puzzles are in, so training can start before every game is done.
 */
import type { Key } from 'chessground/types';
import { HoverBoard } from '../lib/board-preview';
import { TrainerBoard, type PromotionPiece } from './board';
import { EnginePool } from './engine/engine-pool';
import { EngineAbortError } from './engine/uci-worker';
import { lineToSan, mineGame, trainablePlyCount, userColorOf, type Puzzle } from './miner';
import { fetchChesscomGames, fetchLichessGames, SourceError, type SourceGame } from './sources';
import { ALL_TIME_CLASSES, LIMITS, loadSettings, saveSettings, type Settings } from './settings';
import { puzzlesAtSeverity, recordSatisfies, TacticsStore } from './store';
import { SEVERITY_GLYPH } from './win-chances';
import { Chess } from 'chess.js';

type PuzzleOutcome = 'pending' | 'win' | 'fail';

function $<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing #${id}`);
  return el as T;
}

function fmtElapsed(ms: number): string {
  const s = Math.floor(ms / 1000);
  return s < 60 ? `${s}s` : `${Math.floor(s / 60)}m ${String(s % 60).padStart(2, '0')}s`;
}

/** Lichess-style eval: +0.3, -1.7, or # for a forced mate. */
function fmtEval(cpWhite: number): string {
  if (Math.abs(cpWhite) >= 1000) return cpWhite > 0 ? '#' : '-#';
  const v = cpWhite / 100;
  return `${v > 0 ? '+' : ''}${v.toFixed(1)}`;
}

const TIME_LABEL: Record<string, string> = {
  bullet: 'Bullet', blitz: 'Blitz', rapid: 'Rapid', classical: 'Classical', correspondence: 'Daily', unknown: '',
};

export class TacticsApp {
  private settings = loadSettings();
  private readonly store = new TacticsStore();
  private pool: EnginePool | null = null;
  private board: TrainerBoard | null = null;
  private hover: HoverBoard | null = null;

  // Analysis run
  private abort: AbortController | null = null;
  private runStartedAt = 0;
  private elapsedTimer: ReturnType<typeof setInterval> | null = null;
  private analysing = false;

  // Session
  private puzzles: Puzzle[] = [];
  private outcomes: PuzzleOutcome[] = [];
  private index = 0;
  private solved = false;
  private revealed = false;
  /** Plies of the trainable line already on the board (user + opponent). */
  private solvedPlies = 0;
  private replyTimer: ReturnType<typeof setTimeout> | null = null;
  /** The 700ms "put the board back after a wrong move" timer. */
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  /** Set by bindTrain, which owns the checkbox element. */
  private toggleAutoNext: () => void = () => {};
  private attemptedWrong = false;
  private reviewPly = -1; // -1 = puzzle start; n = after best-line move n
  private autoNextTimer: ReturnType<typeof setTimeout> | null = null;

  private readonly views = {
    setup: $('view-setup'),
    analysis: $('view-analysis'),
    train: $('view-train'),
  };

  constructor() {
    this.bindSetup();
    this.bindAnalysis();
    this.bindTrain();
    this.warmEngine();
  }

  // ── View switching ───────────────────────────────────────────

  private show(view: keyof typeof this.views): void {
    this.hover?.hide();
    if (view !== 'train') this.board?.setShapes([]);
    for (const [k, el] of Object.entries(this.views)) el.hidden = k !== view;
    if (view === 'train') requestAnimationFrame(() => this.board?.redraw());
    window.scrollTo({ top: 0 });
  }

  // ── Setup view ───────────────────────────────────────────────

  private bindSetup(): void {
    const s = this.settings;
    $<HTMLInputElement>('f-lichess').value = s.lichessUser;
    $<HTMLInputElement>('f-chesscom').value = s.chesscomUser;
    $<HTMLInputElement>('f-games').value = String(s.numGames);
    $<HTMLInputElement>('f-depth').value = String(s.depth);
    const workers = $<HTMLInputElement>('f-workers');
    workers.value = String(s.workers);
    workers.max = String(LIMITS.workers.max);
    $('f-workers-max').textContent = String(LIMITS.workers.max);
    $<HTMLSelectElement>('f-severity').value = s.minSeverity;

    const tcRow = $('f-timeclasses');
    tcRow.replaceChildren();
    for (const tc of ALL_TIME_CLASSES) {
      const label = document.createElement('label');
      label.className = 'choice';
      const input = document.createElement('input');
      input.type = 'checkbox';
      input.name = 'tc';
      input.value = tc.id;
      input.checked = s.timeClasses.includes(tc.id);
      const span = document.createElement('span');
      span.textContent = tc.label;
      label.append(input, span);
      tcRow.appendChild(label);
    }

    $<HTMLFormElement>('setup-form').addEventListener('submit', (e) => {
      e.preventDefault();
      void this.start();
    });
    $('btn-clear-cache').addEventListener('click', () => {
      void this.store.clear().then(() => this.flashSetup('Cached analysis cleared.', 'info'));
    });
  }

  private readSettings(): Settings | null {
    const num = (id: string, lo: number, hi: number) =>
      Math.max(lo, Math.min(hi, Number.parseInt($<HTMLInputElement>(id).value, 10) || lo));
    const classes = [...document.querySelectorAll<HTMLInputElement>('input[name="tc"]:checked')]
      .map((i) => i.value as Settings['timeClasses'][number]);
    const s: Settings = {
      lichessUser: $<HTMLInputElement>('f-lichess').value.trim(),
      chesscomUser: $<HTMLInputElement>('f-chesscom').value.trim(),
      numGames: num('f-games', LIMITS.numGames.min, LIMITS.numGames.max),
      depth: num('f-depth', LIMITS.depth.min, LIMITS.depth.max),
      workers: num('f-workers', LIMITS.workers.min, LIMITS.workers.max),
      timeClasses: classes,
      minSeverity: $<HTMLSelectElement>('f-severity').value === 'inaccuracy' ? 'inaccuracy' : 'mistake',
      autoNext: this.settings.autoNext,
    };
    if (!s.lichessUser && !s.chesscomUser) {
      this.flashSetup('Enter a Lichess or Chess.com username.', 'error');
      return null;
    }
    if (s.timeClasses.length === 0) {
      this.flashSetup('Pick at least one time control.', 'error');
      return null;
    }
    return s;
  }

  private flashSetup(msg: string, kind: 'error' | 'info'): void {
    const el = $('setup-alert');
    el.className = `alert alert-${kind}`;
    el.textContent = msg;
    el.hidden = false;
  }

  private ensurePool(size: number): EnginePool {
    if (this.pool && this.pool.size !== size) {
      this.pool.dispose();
      this.pool = null;
    }
    if (!this.pool) {
      this.pool = new EnginePool(size);
      this.pool.onStatus((st) => {
        const txt = st.ready === 0
          ? 'Engine loading…'
          : `Stockfish · ${st.ready}/${st.size} worker${st.size === 1 ? '' : 's'} ready`;
        $('engine-status').textContent = txt;
        $('an-engine').textContent = st.ready === 0 ? 'loading…' : `${st.ready} worker${st.ready === 1 ? '' : 's'}`;
      });
    }
    return this.pool;
  }

  /** Boot the engine as soon as the page opens so the first run has no wait. */
  private warmEngine(): void {
    const pool = this.ensurePool(this.settings.workers);
    pool.start().catch((err: Error) => {
      $('engine-status').textContent = `Engine failed to load: ${err.message}`;
    });
  }

  // ── Analysis run ─────────────────────────────────────────────

  private bindAnalysis(): void {
    $('btn-cancel').addEventListener('click', () => this.cancel(true));
    $('btn-train-now').addEventListener('click', () => this.enterTraining());
  }

  private cancel(backToSetup: boolean): void {
    this.abort?.abort();
    this.abort = null;
    this.stopElapsed();
    this.analysing = false;
    if (backToSetup) this.show('setup');
  }

  private startElapsed(): void {
    this.runStartedAt = performance.now();
    this.stopElapsed();
    this.elapsedTimer = setInterval(() => {
      $('an-elapsed').textContent = fmtElapsed(performance.now() - this.runStartedAt);
    }, 1000);
  }

  private stopElapsed(): void {
    if (this.elapsedTimer) clearInterval(this.elapsedTimer);
    this.elapsedTimer = null;
  }

  private async start(): Promise<void> {
    $('setup-alert').hidden = true;
    const s = this.readSettings();
    if (!s) return;
    this.settings = s;
    saveSettings(s);

    // Reset session
    this.cancel(false);
    this.puzzles = [];
    this.outcomes = [];
    this.index = 0;
    const ctl = new AbortController();
    this.abort = ctl;
    this.analysing = true;

    const pool = this.ensurePool(s.workers);
    pool.start().catch(() => { /* reported via evaluate() */ });

    $('an-title').textContent = 'Fetching games…';
    $('an-sub').textContent = [s.lichessUser && `Lichess: ${s.lichessUser}`, s.chesscomUser && `Chess.com: ${s.chesscomUser}`]
      .filter(Boolean).join(' · ');
    $('an-games').textContent = '0 / 0';
    $('an-found').textContent = '0';
    $('an-shortcuts').textContent = '0';
    $('an-current').textContent = '';
    $('an-note').hidden = true;
    $<HTMLButtonElement>('btn-train-now').disabled = true;
    this.setProgress(0);
    this.startElapsed();
    this.show('analysis');

    // Fetch both sources in parallel; a failure in one is reported but does
    // not sink the other.
    const notes: string[] = [];
    const fetches: Promise<SourceGame[]>[] = [];
    if (s.lichessUser) {
      fetches.push(fetchLichessGames(s.lichessUser, s.numGames, s.timeClasses, ctl.signal).catch((err: Error) => {
        if (err.name !== 'AbortError') notes.push(err instanceof SourceError ? err.message : 'Lichess fetch failed.');
        return [];
      }));
    }
    if (s.chesscomUser) {
      fetches.push(fetchChesscomGames(s.chesscomUser, s.numGames, s.timeClasses, ctl.signal).catch((err: Error) => {
        if (err.name !== 'AbortError') notes.push(err instanceof SourceError ? err.message : 'Chess.com fetch failed.');
        return [];
      }));
    }
    const games = (await Promise.all(fetches)).flat();
    if (ctl.signal.aborted) return;

    if (notes.length) {
      const note = $('an-note');
      note.textContent = notes.join(' ');
      note.hidden = false;
    }
    if (games.length === 0) {
      this.finishAnalysis(notes.length ? notes.join(' ') : 'No games found for those settings.');
      return;
    }

    $('an-title').textContent = `Analysing ${games.length} game${games.length === 1 ? '' : 's'}…`;
    let gamesDone = 0;
    let shortcuts = 0;
    const fractions = new Map<number, number>();
    const updateProgress = () => {
      const partial = [...fractions.values()].reduce((a, b) => a + b, 0);
      this.setProgress((gamesDone + partial) / games.length);
      $('an-games').textContent = `${gamesDone} / ${games.length}`;
      $('an-shortcuts').textContent = String(shortcuts);
    };

    // Two games in flight keeps the pool saturated across game boundaries.
    let next = 0;
    // Set when the run aborts *itself* after repeated engine errors, to tell
    // that case apart from the user pressing Cancel: the user's path has
    // already torn the run down, but ours still has to stop the clock and
    // say what happened, or the screen keeps counting up forever.
    let gaveUp = false;
    const runner = async () => {
      while (next < games.length && !ctl.signal.aborted) {
        const i = next++;
        const g = games[i];
        const username = g.source === 'lichess' ? s.lichessUser : s.chesscomUser;
        const color = userColorOf(g.parsed.headers, username);
        try {
          if (color) {
            const key = TacticsStore.gameKey(g.source, g.id, username, s.depth);
            const cached = await this.store.getGame(key);
            $('an-current').textContent = `${g.meta.white} – ${g.meta.black}`;
            // A record mined at a stricter threshold never saw the puzzles a
            // looser run wants, so it cannot stand in for one; a looser record
            // can, once the puzzles below the new threshold are filtered out.
            if (cached && recordSatisfies(cached, s.minSeverity)) {
              shortcuts += cached.sites;
              this.addPuzzles(puzzlesAtSeverity(cached, s.minSeverity));
            } else {
              const res = await mineGame(g.parsed, g.meta, color, {
                pool, store: this.store, depth: s.depth, signal: ctl.signal, minSeverity: s.minSeverity,
                onSite: (done, total) => {
                  fractions.set(i, total ? done / total : 1);
                  updateProgress();
                },
              });
              shortcuts += res.shortcuts;
              this.store.putGame({
                key,
                puzzles: res.puzzles,
                analysedAt: Date.now(),
                sites: res.sites,
                minSeverity: s.minSeverity,
              });
              this.addPuzzles(res.puzzles);
            }
          }
        } catch (err) {
          if (err instanceof EngineAbortError || (err as Error).name === 'AbortError') return;
          notes.push(`Engine error: ${(err as Error).message}`);
          const note = $('an-note');
          note.textContent = notes.join(' ');
          note.hidden = false;
          if (notes.length > 3) {
            gaveUp = true;
            ctl.abort();
          }
        } finally {
          fractions.delete(i);
          gamesDone++;
          updateProgress();
        }
      }
    };
    await Promise.all([runner(), runner()]);
    // The runners can spend a moment unwinding after an abort. If the user
    // pressed Cancel (or started another run) in that window, this run is no
    // longer the current one and must not touch shared state — finishing here
    // would clear the *new* run's abort controller and elapsed timer, or drag
    // the user off the setup screen into the trainer.
    if (this.abort !== ctl) return;
    if (gaveUp) {
      this.finishAnalysis('The engine kept failing, so the run stopped early.');
      return;
    }
    if (ctl.signal.aborted) return;
    this.finishAnalysis(null);
  }

  private setProgress(fraction: number): void {
    const pct = Math.max(0, Math.min(100, Math.round(fraction * 100)));
    $('an-bar').style.width = `${pct}%`;
    $('an-progress').setAttribute('aria-valuenow', String(pct));
  }

  private addPuzzles(list: Puzzle[]): void {
    if (list.length === 0) return;
    this.puzzles.push(...list);
    this.outcomes.push(...list.map((): PuzzleOutcome => 'pending'));
    $('an-found').textContent = String(this.puzzles.length);
    $<HTMLButtonElement>('btn-train-now').disabled = false;
    if (!this.views.train.hidden) {
      this.renderSession();
      this.renderCounter();
    }
  }

  private finishAnalysis(problem: string | null): void {
    this.analysing = false;
    this.stopElapsed();
    this.abort = null;
    $('an-current').textContent = '';
    if (this.puzzles.length === 0) {
      $('an-title').textContent = problem ?? 'No mistakes found';
      $('an-sub').textContent = problem
        ? ''
        : 'Nothing lost 20% or more winning chances at this depth. Try more games, or include inaccuracies.';
      $<HTMLButtonElement>('btn-cancel').textContent = 'Back';
      return;
    }
    $('an-title').textContent = `Done — ${this.puzzles.length} puzzle${this.puzzles.length === 1 ? '' : 's'}`;
    if (this.views.train.hidden) this.enterTraining();
    else this.renderAnalysingBanner();
  }

  // ── Training view ────────────────────────────────────────────

  private bindTrain(): void {
    $('btn-back').addEventListener('click', () => {
      this.cancel(true);
      $<HTMLButtonElement>('btn-cancel').textContent = 'Cancel';
    });
    $('btn-prev').addEventListener('click', () => this.go(this.index - 1));
    $('btn-next').addEventListener('click', () => this.go(this.index + 1));
    $('btn-solution').addEventListener('click', () => this.reveal());
    $('btn-retry').addEventListener('click', () => this.loadPuzzle(this.index));
    $('btn-line-prev').addEventListener('click', () => this.review(this.reviewPly - 1));
    $('btn-line-next').addEventListener('click', () => this.review(this.reviewPly + 1));
    const auto = $<HTMLInputElement>('chk-autonext');
    auto.checked = this.settings.autoNext;
    auto.addEventListener('change', () => {
      this.settings.autoNext = auto.checked;
      saveSettings(this.settings);
    });
    this.toggleAutoNext = () => {
      auto.checked = !auto.checked;
      auto.dispatchEvent(new Event('change'));
    };

    // The Dart app's key map, which this mirrors: ←/→ step *moves* on every
    // board screen, so the puzzle queue is stepped by P/S (↑/↓ as aliases)
    // instead. Space shows the solution; S is next puzzle, not "solution".
    document.addEventListener('keydown', (e) => {
      if (this.views.train.hidden) return;
      if ((e.target as HTMLElement).matches('input, select, textarea')) return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;
      const key = e.key.toLowerCase();
      if (e.key === 'ArrowLeft') { e.preventDefault(); this.review(this.reviewPly - 1); }
      else if (e.key === 'ArrowRight') { e.preventDefault(); this.review(this.reviewPly + 1); }
      else if (e.key === 'ArrowUp' || key === 'p') { e.preventDefault(); this.go(this.index - 1); }
      else if (e.key === 'ArrowDown' || key === 's') { e.preventDefault(); this.go(this.index + 1); }
      else if (e.key === ' ') { e.preventDefault(); this.reveal(); }
      else if (key === 'j') { e.preventDefault(); this.toggleAutoNext(); }
    });
  }

  private enterTraining(): void {
    if (!this.board) {
      this.board = new TrainerBoard($('board'), {
        onMove: (uci) => this.onMove(uci),
        promotionFor: (orig, dest) => this.expectedPromotion(orig + dest),
      });
    }
    this.show('train');
    this.renderAnalysingBanner();
    this.loadPuzzle(this.index);
  }

  private renderAnalysingBanner(): void {
    const banner = $('tr-analysing');
    banner.hidden = !this.analysing;
    if (this.analysing) {
      // Not querySelector('span'): the first span is the spinner, and the
      // message would render inside a 14px circle, aria-hidden.
      $('tr-analysing-text').textContent = `Still analysing in the background — ${this.puzzles.length} puzzle${this.puzzles.length === 1 ? '' : 's'} so far.`;
    }
  }

  private get current(): Puzzle | null {
    return this.puzzles[this.index] ?? null;
  }

  private go(i: number): void {
    if (i < 0 || i >= this.puzzles.length) return;
    this.clearAutoNext();
    this.loadPuzzle(i);
  }

  private clearAutoNext(): void {
    if (this.autoNextTimer) clearTimeout(this.autoNextTimer);
    this.autoNextTimer = null;
  }

  private clearReply(): void {
    if (this.replyTimer) clearTimeout(this.replyTimer);
    this.replyTimer = null;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
  }

  /**
   * The part of the best line the user has to play, in UCI. Derived rather
   * than stored so puzzles already cached in IndexedDB get it too.
   */
  private trainLine(p: Puzzle): string[] {
    return p.bestLineUci.slice(0, trainablePlyCount(p.bestLineSan));
  }

  /** Put the board back to the end of the part already solved. */
  private resetToProgress(p: Puzzle): void {
    if (!this.board) return;
    const fen = this.lineFens(p)[this.solvedPlies] ?? p.fen;
    const prev = this.solvedPlies > 0 ? p.bestLineUci[this.solvedPlies - 1] : null;
    this.board.setPosition(fen, prev ? [prev.slice(0, 2) as Key, prev.slice(2, 4) as Key] : undefined);
  }

  private loadPuzzle(i: number): void {
    const p = this.puzzles[i];
    if (!p || !this.board) return;
    this.index = i;
    this.solved = false;
    this.revealed = false;
    this.attemptedWrong = false;
    this.reviewPly = -1;
    this.solvedPlies = 0;
    this.clearAutoNext();
    this.clearReply();

    this.board.setOrientation(p.color);
    this.board.setPosition(p.fen);
    this.board.setInteractive(true);
    this.board.setShapes([]);

    this.setTurnBox('turn', p);
    this.renderMeta(p);
    this.renderLine(p, false);
    this.renderCounter();
    this.renderSession();
    $<HTMLButtonElement>('btn-solution').disabled = false;
    $('tr-line-nav').hidden = true;
  }

  private setTurnBox(state: 'turn' | 'good' | 'bad' | 'win' | 'fail' | 'revealed', p: Puzzle): void {
    const box = $('tr-turn');
    box.className = `turn-box turn-${state}`;
    const title = $('tr-turn-title');
    const sub = $('tr-turn-sub');
    $<HTMLImageElement>('tr-turn-icon').src = p.color === 'white' ? '/piece/wK.svg' : '/piece/bK.svg';
    const side = p.color === 'white' ? 'White' : 'Black';
    // User moves sit at even plies, so a 3-ply line is two moves to find.
    const total = (this.trainLine(p).length + 1) >> 1;
    const done = (this.solvedPlies + 1) >> 1;
    switch (state) {
      case 'turn':
        title.textContent = 'Your move';
        sub.textContent = total > 1
          ? `Find the best move for ${side} — move ${done + 1} of ${total}.`
          : `Find the best move for ${side}.`;
        break;
      case 'good':
        title.textContent = 'Best move!';
        sub.textContent = `${done} of ${total} — now the opponent replies…`;
        break;
      case 'bad':
        title.textContent = "That's not the move";
        sub.textContent = 'Try something else.';
        break;
      case 'win':
        title.textContent = 'Success';
        sub.textContent = this.attemptedWrong
          ? 'Solved on a later try.'
          : total > 1
            ? `Found all ${total} moves first time.`
            : 'Found the best move first time.';
        break;
      case 'fail':
        title.textContent = 'Puzzle failed';
        sub.textContent = 'But the solution is below — play through it.';
        break;
      case 'revealed':
        title.textContent = 'Solution';
        sub.textContent = 'Click a move to see it on the board.';
        break;
    }
  }

  private renderMeta(p: Puzzle): void {
    const g = p.game;
    const elo = (n: number | null) => (n ? ` (${n})` : '');
    $('tr-players').textContent = `${g.white}${elo(g.whiteElo)} – ${g.black}${elo(g.blackElo)}`;
    const res = $('tr-result');
    res.textContent = g.result.replaceAll('1/2-1/2', '½–½').replaceAll('1-0', '1–0').replaceAll('0-1', '0–1');
    const bits = [TIME_LABEL[g.timeClass] ?? g.timeClass, g.date, g.source === 'lichess' ? 'Lichess' : 'Chess.com']
      .filter(Boolean);
    $('tr-game-sub').textContent = bits.join(' · ');
    const link = $<HTMLAnchorElement>('tr-game-link');
    link.hidden = !g.url;
    link.href = g.url;
    const analyse = $<HTMLAnchorElement>('tr-analyse-link');
    analyse.href = `https://lichess.org/analysis/standard/${p.fen.replaceAll(' ', '_')}?color=${p.color}`;

    const playedNo = `${p.moveNumber}${p.color === 'white' ? '.' : '…'}`;
    const glyph = SEVERITY_GLYPH[p.severity];
    const played = $('tr-played');
    played.innerHTML = `<span class="eyebrow">You played</span> <span class="san-token played ${p.severity}">${playedNo}${p.userMoveSan}${glyph}</span>
      <span class="win-shift num"><span>${fmtEval(p.cpBeforeWhite ?? 0)}</span> <span aria-hidden="true">→</span> <span>${fmtEval(p.cpAfterWhite ?? 0)}</span></span>`;
    played.title = `${p.severity[0].toUpperCase()}${p.severity.slice(1)}: winning chances ${Math.round(p.winBefore)}% → ${Math.round(p.winAfter)}%`;
    const badge = $('tr-severity');
    badge.className = 'badge';
    badge.textContent = `${p.severity} ${glyph}`;
  }

  /** The solution line as clickable/hoverable SAN tokens. */
  private renderLine(p: Puzzle, visible: boolean): void {
    const wrap = $('tr-line');
    const list = $('tr-line-moves');
    // Every token about to be discarded may be the one under the pointer.
    this.hover?.hide();
    wrap.hidden = !visible;
    list.replaceChildren();
    if (!visible) return;

    const hover = (this.hover ??= new HoverBoard());
    const fens = this.lineFens(p);
    const trainable = this.trainLine(p).length;
    let moveNo = p.moveNumber;
    let white = p.color === 'white';
    p.bestLineSan.forEach((san, i) => {
      const tok = document.createElement('button');
      tok.type = 'button';
      tok.className = `san-token${i < trainable && i % 2 === 0 ? ' best' : ''}`;
      tok.dataset.ply = String(i);
      const prefix = white ? `${moveNo}.` : i === 0 ? `${moveNo}…` : '';
      tok.textContent = `${prefix}${san}`;
      tok.title = 'Click to show on the board';
      const last: [Key, Key] = [p.bestLineUci[i].slice(0, 2) as Key, p.bestLineUci[i].slice(2, 4) as Key];
      tok.addEventListener('click', () => this.review(i));
      tok.addEventListener('pointerenter', () => hover.show(tok, fens[i + 1], { flipped: p.color === 'black', highlight: last, caption: tok.textContent ?? '' }));
      tok.addEventListener('pointerleave', () => hover.hide());
      tok.addEventListener('blur', () => hover.hide());
      list.appendChild(tok);
      if (!white) moveNo++;
      white = !white;
    });
    this.markReviewPly();
  }

  /** FENs along the best line: index 0 = puzzle start, i+1 = after move i. */
  private lineFens(p: Puzzle): string[] {
    const fens = [p.fen];
    try {
      const chess = new Chess(p.fen);
      for (const uci of p.bestLineUci) {
        chess.move({ from: uci.slice(0, 2), to: uci.slice(2, 4), promotion: uci[4] });
        fens.push(chess.fen());
      }
    } catch { /* stop at the first illegal move */ }
    return fens;
  }

  /** Jump the main board to a point in the solution line. */
  private review(ply: number): void {
    const p = this.current;
    if (!p || !this.board || !(this.solved || this.revealed)) return;
    const max = p.bestLineUci.length - 1;
    ply = Math.max(-1, Math.min(max, ply));
    this.reviewPly = ply;
    const fens = this.lineFens(p);
    if (ply < 0) {
      this.board.setPosition(p.fen);
      this.board.setShapes([this.board.arrow(p.bestLineUci[0])]);
    } else {
      const uci = p.bestLineUci[ply];
      this.board.setPosition(fens[ply + 1], [uci.slice(0, 2) as Key, uci.slice(2, 4) as Key]);
      const nextUci = p.bestLineUci[ply + 1];
      this.board.setShapes(nextUci ? [this.board.arrow(nextUci, 'blue')] : []);
    }
    this.board.setInteractive(false);
    this.markReviewPly();
    $<HTMLButtonElement>('btn-line-prev').disabled = ply < 0;
    $<HTMLButtonElement>('btn-line-next').disabled = ply >= max;
  }

  private markReviewPly(): void {
    document.querySelectorAll<HTMLElement>('#tr-line-moves .san-token').forEach((el) => {
      el.classList.toggle('active', Number(el.dataset.ply) === this.reviewPly);
    });
  }

  /**
   * The piece the solution promotes to on this from→to, so the board plays
   * the line's move instead of always queening. Without it an underpromotion
   * puzzle accepts the queen and then continues from a position the rest of
   * the line does not describe.
   */
  private expectedPromotion(fromTo: string): PromotionPiece | undefined {
    const p = this.current;
    if (!p) return undefined;
    const correct = this.trainLine(p)[this.solvedPlies] ?? '';
    if (correct.length !== 5 || correct.slice(0, 4).toLowerCase() !== fromTo.toLowerCase()) return undefined;
    return correct[4] as PromotionPiece;
  }

  private onMove(uci: string): void {
    const p = this.current;
    if (!p || !this.board || this.solved || this.revealed) return;
    const line = this.trainLine(p);
    const correct = (line[this.solvedPlies] ?? '').toLowerCase();
    const played = uci.toLowerCase();
    // Exact: expectedPromotion() has already given the board the line's own
    // promotion piece, so a right move matches outright rather than being
    // forgiven for queening.
    const isMatch = correct !== '' && played === correct;

    if (!isMatch) {
      this.attemptedWrong = true;
      this.setTurnBox('bad', p);
      this.board.setInteractive(false);
      // Tracked and guarded on `revealed` too: pressing Space inside this
      // window finishes the puzzle without setting `solved`, and an untracked
      // timer would then hand the board back and reset the "Solution" box on
      // a puzzle that is already over.
      if (this.retryTimer) clearTimeout(this.retryTimer);
      this.retryTimer = setTimeout(() => {
        this.retryTimer = null;
        if (this.current !== p || this.solved || this.revealed) return;
        this.resetToProgress(p);
        this.board!.setInteractive(true);
        this.setTurnBox('turn', p);
      }, 700);
      return;
    }

    this.solvedPlies++;
    if (this.solvedPlies >= line.length) {
      this.solved = true;
      this.finishPuzzle(this.attemptedWrong || this.revealed ? 'fail' : 'win');
      return;
    }

    // More to find: play the opponent's reply, then hand the board back.
    // A shorter pause than this and the two moves read as one blur.
    this.setTurnBox('good', p);
    this.board.setInteractive(false);
    this.replyTimer = setTimeout(() => {
      this.replyTimer = null;
      if (this.current !== p || this.solved || this.revealed || !this.board) return;
      if (!this.board.playUci(line[this.solvedPlies])) {
        // The line came from a legal PV, so this should not happen — but a
        // stuck board would be worse than a puzzle that ends one move early.
        this.solved = true;
        this.finishPuzzle(this.attemptedWrong || this.revealed ? 'fail' : 'win');
        return;
      }
      this.solvedPlies++;
      this.board.setInteractive(true);
      this.setTurnBox('turn', p);
    }, 900);
  }

  private finishPuzzle(outcome: PuzzleOutcome): void {
    const p = this.current;
    if (!p || !this.board) return;
    // A puzzle that was already failed (or had its solution shown) stays
    // failed — Retry is for practising the move, not for fixing the score.
    if (this.outcomes[this.index] === 'fail') outcome = 'fail';
    this.outcomes[this.index] = outcome;
    this.setTurnBox(outcome === 'win' ? 'win' : this.revealed ? 'revealed' : 'fail', p);
    this.board.setInteractive(false);
    this.renderLine(p, true);
    $('tr-line-nav').hidden = false;
    $<HTMLButtonElement>('btn-solution').disabled = true;
    this.renderSession();
    // Show the rest of the line: opponent reply and our follow-up, as arrows.
    this.reviewPly = Math.max(0, this.solvedPlies - 1);
    this.markReviewPly();
    const nextUci = p.bestLineUci[this.reviewPly + 1];
    this.board.setShapes(nextUci ? [this.board.arrow(nextUci, 'blue')] : []);
    $<HTMLButtonElement>('btn-line-prev').disabled = false;
    $<HTMLButtonElement>('btn-line-next').disabled = this.reviewPly >= p.bestLineUci.length - 1;

    if (outcome === 'win' && this.settings.autoNext && this.index < this.puzzles.length - 1) {
      this.autoNextTimer = setTimeout(() => this.go(this.index + 1), 1400);
    }
  }

  private reveal(): void {
    const p = this.current;
    if (!p || !this.board || this.solved || this.revealed) return;
    this.revealed = true;
    this.clearReply();
    const next = this.trainLine(p)[this.solvedPlies];
    if (next && this.board.playUci(next)) this.solvedPlies++;
    this.finishPuzzle('fail');
  }

  private renderCounter(): void {
    $('tr-counter').textContent = `${this.index + 1} / ${this.puzzles.length}`;
    $<HTMLButtonElement>('btn-prev').disabled = this.index === 0;
    $<HTMLButtonElement>('btn-next').disabled = this.index >= this.puzzles.length - 1;
    this.renderAnalysingBanner();
  }

  /** Lila-style session strip: one cell per puzzle, click to jump. */
  private renderSession(): void {
    const strip = $('tr-session');
    strip.replaceChildren();
    const won = this.outcomes.filter((o) => o === 'win').length;
    const done = this.outcomes.filter((o) => o !== 'pending').length;
    $('tr-session-score').textContent = done ? `${won} / ${done} solved` : '';
    this.puzzles.forEach((p, i) => {
      const cell = document.createElement('button');
      cell.type = 'button';
      cell.className = `session-cell ${this.outcomes[i]}${i === this.index ? ' current' : ''}`;
      cell.title = `${i + 1}. ${p.game.white} – ${p.game.black}, move ${p.moveNumber}`;
      cell.setAttribute('aria-label', `Puzzle ${i + 1}, ${this.outcomes[i]}`);
      cell.addEventListener('click', () => this.go(i));
      strip.appendChild(cell);
    });
  }
}

// Keep the SAN helper reachable for the page's debugging console.
export { lineToSan };
