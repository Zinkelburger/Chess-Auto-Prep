/**
 * The signed-in list of alerts: one card per subscription with its filters,
 * the recent TWIC issues it matched, and an expandable game list per issue.
 */
import {
  fetchPgn, listMatchedGames, messageOf,
  type MatchedGame, type Subscription,
} from './api';
import { renderBoard, HoverBoard } from './board-preview';

export interface AlertsListHandlers {
  token: () => string;
  onEdit: (sub: Subscription) => void;
  onDelete: (sub: Subscription, button: HTMLButtonElement) => void;
  onError: (message: string) => void;
}

const TIME_LABEL: Record<string, string> = { classical: 'Classical', rapid: 'Rapid', blitz: 'Blitz' };

export class AlertsList {
  private readonly gamesCache = new Map<string, MatchedGame[]>();
  private hover: HoverBoard | null = null;

  constructor(
    private readonly root: HTMLElement,
    private readonly empty: HTMLElement,
    private readonly handlers: AlertsListHandlers,
  ) {}

  render(subs: Subscription[]): void {
    this.gamesCache.clear();
    // Chips under the pointer are about to be discarded; a preview
    // pinned to one would outlive its anchor.
    this.hover?.hide();
    this.root.replaceChildren();
    this.empty.hidden = subs.length > 0;
    for (const sub of subs) this.root.appendChild(this.card(sub));
  }

  private hoverBoard(): HoverBoard {
    return (this.hover ??= new HoverBoard());
  }

  private card(sub: Subscription): HTMLElement {
    const card = document.createElement('article');
    card.className = 'card sub-card';
    card.setAttribute('aria-label', sub.label || 'Untitled alert');

    const body = document.createElement('div');
    body.className = 'sub-card-body';

    const header = document.createElement('div');
    header.className = 'sub-card-header';
    const title = document.createElement('h2');
    title.className = 'sub-card-title';
    title.textContent = sub.label || 'Untitled alert';
    const actions = document.createElement('div');
    actions.className = 'sub-card-actions';
    const editBtn = button('Edit', 'btn btn-text', () => this.handlers.onEdit(sub));
    const delBtn = button('Delete', 'btn btn-text btn-text-danger', () => this.handlers.onDelete(sub, delBtn));
    actions.append(editBtn, delBtn);
    header.append(title, actions);
    body.appendChild(header);

    body.appendChild(this.filterChips(sub));

    const footer = document.createElement('div');
    footer.className = 'sub-card-footer';
    const panel = document.createElement('div');
    panel.className = 'game-panel';
    panel.hidden = true;
    footer.appendChild(this.matchStatus(sub, panel));

    card.append(body, footer, panel);
    return card;
  }

  /** The alert's filters as a compact chip row; FEN chips preview on hover. */
  private filterChips(sub: Subscription): HTMLElement {
    const row = document.createElement('div');
    row.className = 'sub-filters';
    const fens = sub.fens ?? (sub.fen ? [sub.fen] : []);
    fens.forEach((fen, i) => {
      const chip = filterChip('Position', fens.length > 1 ? `#${i + 1}` : 'FEN');
      chip.classList.add('sub-filter-fen');
      chip.tabIndex = 0;
      chip.setAttribute('aria-label', `Position ${fen}`);
      const show = () => this.hoverBoard().show(chip, fen, { caption: fen.split(' ')[0] });
      const hide = () => this.hoverBoard().hide();
      chip.addEventListener('pointerenter', show);
      chip.addEventListener('pointerleave', hide);
      chip.addEventListener('focus', show);
      chip.addEventListener('blur', hide);
      chip.addEventListener('click', () => {
        // Tap-to-toggle for touch: a static board under the chips.
        const existing = row.querySelector<HTMLElement>('.sub-filter-board');
        if (existing?.dataset.fen === fen) {
          existing.remove();
          return;
        }
        existing?.remove();
        const board = document.createElement('div');
        board.className = 'board-preview board-preview-sm sub-filter-board';
        board.dataset.fen = fen;
        renderBoard(fen, board);
        row.appendChild(board);
      });
      row.appendChild(chip);
    });
    if (sub.player) row.appendChild(filterChip('Player', sub.player));
    if (sub.white) row.appendChild(filterChip('White', sub.white));
    if (sub.black) row.appendChild(filterChip('Black', sub.black));
    if (sub.eco) row.appendChild(filterChip('ECO', sub.eco));
    if (sub.min_elo) row.appendChild(filterChip('Elo', `≥ ${sub.min_elo}`));
    if (sub.max_elo) row.appendChild(filterChip('Elo', `≤ ${sub.max_elo}`));
    if (sub.event) row.appendChild(filterChip('Event', sub.event));
    if (sub.time_control) {
      row.appendChild(filterChip('Time', sub.time_control.split(',').map((t) => TIME_LABEL[t] ?? t).join(' / ')));
    }
    if (sub.result) row.appendChild(filterChip('Result', formatResult(sub.result).replaceAll(',', ' / ')));
    if (sub.exclude_site) row.appendChild(filterChip('Excludes', sub.exclude_site));
    return row;
  }

  private matchStatus(sub: Subscription, panel: HTMLElement): HTMLElement {
    const wrap = document.createElement('div');
    wrap.className = 'sub-matches';
    const recent = sub.recent_issues ?? [];
    const latest = sub.latest_twic_scanned;

    if (recent.length > 0) {
      for (const issue of recent) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'issue-toggle';
        btn.setAttribute('aria-expanded', 'false');
        btn.innerHTML = `<span class="issue-chevron" aria-hidden="true">▸</span><span></span>`;
        btn.lastElementChild!.textContent = `TWIC ${issue.twic} · ${issue.games} game${issue.games === 1 ? '' : 's'}`;
        btn.addEventListener('click', () => void this.toggleIssue(sub, issue.twic, btn, wrap, panel));
        wrap.appendChild(btn);
      }
      if (latest && recent[0].twic < latest) wrap.appendChild(muted(`Nothing new in TWIC ${latest}`));
    } else if (latest) {
      wrap.appendChild(muted(`No matches yet · scanned through TWIC ${latest}`));
    } else {
      wrap.appendChild(muted('Waiting for the next TWIC issue'));
    }
    return wrap;
  }

  private async toggleIssue(
    sub: Subscription, twic: number, btn: HTMLButtonElement, wrap: HTMLElement, panel: HTMLElement,
  ): Promise<void> {
    const opening = btn.getAttribute('aria-expanded') !== 'true';
    wrap.querySelectorAll<HTMLButtonElement>('.issue-toggle').forEach((other) => {
      other.setAttribute('aria-expanded', 'false');
      other.querySelector('.issue-chevron')!.textContent = '▸';
    });
    if (!opening) {
      panel.hidden = true;
      panel.replaceChildren();
      delete panel.dataset.open;
      return;
    }
    btn.setAttribute('aria-expanded', 'true');
    btn.querySelector('.issue-chevron')!.textContent = '▾';
    const key = `${sub.id}:${twic}`;
    panel.dataset.open = key;
    panel.hidden = false;
    panel.replaceChildren(muted('Loading games…'));

    try {
      let games = this.gamesCache.get(key);
      if (!games) {
        games = await listMatchedGames(this.handlers.token(), sub.id, twic);
        this.gamesCache.set(key, games);
      }
      if (panel.dataset.open !== key) return;
      this.renderGamePanel(panel, sub, twic, games);
    } catch (err) {
      if (panel.dataset.open !== key) return;
      panel.replaceChildren(muted(messageOf(err, 'Could not load games.')));
    }
  }

  private renderGamePanel(panel: HTMLElement, sub: Subscription, twic: number, games: MatchedGame[]): void {
    panel.replaceChildren();
    const head = document.createElement('div');
    head.className = 'game-panel-head';
    const title = document.createElement('span');
    title.textContent = `TWIC ${twic} · ${games.length} game${games.length === 1 ? '' : 's'}`;
    const dl = button('Download PGN', 'btn btn-text', () => void this.downloadPgn(sub, twic, dl));
    head.append(title, dl);
    panel.appendChild(head);

    if (games.length === 0) {
      panel.appendChild(muted('No games in this issue.'));
      return;
    }
    const list = document.createElement('div');
    list.className = 'game-list';
    for (const game of games) list.appendChild(gameRow(game));
    panel.appendChild(list);
  }

  private async downloadPgn(sub: Subscription, twic: number, btn: HTMLButtonElement): Promise<void> {
    btn.classList.add('busy');
    btn.disabled = true;
    try {
      const blob = await fetchPgn(this.handlers.token(), sub.id, twic);
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${(sub.label || 'alert').replace(/[^\w.-]+/g, '_')}_twic${twic}.pgn`;
      a.click();
      setTimeout(() => URL.revokeObjectURL(url), 1000);
    } catch (err) {
      this.handlers.onError(messageOf(err, 'Could not download PGN. Try again later.'));
    } finally {
      btn.classList.remove('busy');
      btn.disabled = false;
    }
  }
}

// ── Small builders ───────────────────────────────────────────────

function button(label: string, className: string, onClick: () => void): HTMLButtonElement {
  const b = document.createElement('button');
  b.type = 'button';
  b.className = className;
  b.textContent = label;
  b.addEventListener('click', onClick);
  return b;
}

function filterChip(kind: string, value: string): HTMLElement {
  const chip = document.createElement('span');
  chip.className = 'sub-filter';
  const k = document.createElement('span');
  k.className = 'sub-filter-kind';
  k.textContent = kind;
  const v = document.createElement('span');
  v.className = 'sub-filter-value';
  v.textContent = value;
  chip.append(k, v);
  return chip;
}

function muted(text: string): HTMLElement {
  const span = document.createElement('span');
  span.className = 'sub-no-match';
  span.textContent = text;
  return span;
}

function playerLabel(name: string | null | undefined, elo: number | null | undefined): string {
  const n = name?.trim() || '?';
  return elo ? `${n} (${elo})` : n;
}

function formatResult(result: string): string {
  return result.replaceAll('1/2-1/2', '½–½').replaceAll('1-0', '1–0').replaceAll('0-1', '0–1');
}

function resultClass(result: string | null | undefined): string {
  return result === '1/2-1/2' ? 'result-draw' : '';
}

function gameRow(game: MatchedGame): HTMLElement {
  const row = document.createElement('div');
  row.className = 'game-row';

  const info = document.createElement('div');
  info.className = 'game-info';
  const players = document.createElement('div');
  players.className = 'game-players';
  const names = document.createElement('span');
  names.textContent = `${playerLabel(game.white, game.white_elo)} – ${playerLabel(game.black, game.black_elo)}`;
  players.appendChild(names);
  if (game.result) {
    const res = document.createElement('span');
    res.className = `game-result num ${resultClass(game.result)}`.trim();
    res.textContent = formatResult(game.result);
    players.append(' ', res);
  }
  info.appendChild(players);

  const bits = [game.event, game.date, game.eco && game.opening ? `${game.eco} ${game.opening}` : game.eco]
    .filter((x): x is string => Boolean(x));
  if (bits.length > 0) {
    const sub = document.createElement('div');
    sub.className = 'game-sub';
    sub.textContent = bits.join(' · ');
    info.appendChild(sub);
  }
  row.appendChild(info);

  if (game.lichess_url) {
    const link = document.createElement('a');
    link.className = 'btn btn-outline btn-sm';
    link.href = game.lichess_url;
    link.target = '_blank';
    link.rel = 'noopener';
    link.textContent = 'View on Lichess ↗';
    row.appendChild(link);
  }
  return row;
}
