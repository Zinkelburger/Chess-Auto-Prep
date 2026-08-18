import {
  API,
  authHeaders,
  clearAuthToken,
  errorMessage,
  getAuthToken,
  hideAlert,
  readJson,
  setAuthToken,
  showAlert,
  type MatchedGame,
  type Subscription,
} from './api';
import { FilterBuilder } from './filters';
import {
  readExcludeOnline,
  readResult,
  readTimeControl,
  writeExcludeOnline,
  writeResult,
  writeTimeControl,
} from './form-options';

const PREFIX = 'dash';

export function initDashboard(): void {
  const gate = document.getElementById('auth-gate')!;
  const dash = document.getElementById('dashboard')!;
  const flash = document.getElementById('dash-flash')!;
  const emailEl = document.getElementById('user-email')!;
  const list = document.getElementById('subs-list')!;
  const empty = document.getElementById('empty-state')!;
  const formCard = document.getElementById('add-form')!;
  const form = document.getElementById('sub-form') as HTMLFormElement;
  const formAlert = document.getElementById('add-alert')!;
  const heading = formCard.querySelector('h2')!;
  const submitBtn = form.querySelector('button[type="submit"]') as HTMLButtonElement;

  const filters = new FilterBuilder({
    container: document.getElementById('dash-filters-container')!,
    addBtn: document.getElementById('dash-add-filter-btn')!,
    menu: document.getElementById('dash-filter-menu')!,
    idPrefix: PREFIX,
    enableAutocomplete: true,
  });
  filters.resetDefault();

  let authToken: string | null = null;
  let editingId: number | null = null;
  const gamesCache = new Map<string, MatchedGame[]>();

  function headers(extra: Record<string, string> = {}) {
    return authHeaders(authToken!, extra);
  }

  async function reloadSubs(): Promise<void> {
    gamesCache.clear();
    const res = await fetch(`${API}/api/subscriptions`, { headers: headers() });
    if (!res.ok) throw new Error('reload');
    const data = (await res.json()) as { subscriptions: Subscription[] };
    renderSubscriptions(data.subscriptions);
  }

  function renderSubscriptions(subs: Subscription[]): void {
    list.replaceChildren();
    if (subs.length === 0) {
      empty.hidden = false;
      return;
    }
    empty.hidden = true;
    for (const sub of subs) list.appendChild(buildCard(sub));
  }

  function buildCard(sub: Subscription): HTMLElement {
    const card = document.createElement('article');
    card.className = 'card sub-card';

    const body = document.createElement('div');
    body.className = 'sub-card-body';

    const header = document.createElement('div');
    header.className = 'sub-card-header';

    const title = document.createElement('h2');
    title.className = 'sub-card-title';
    title.textContent = sub.label || 'Untitled alert';

    const actions = document.createElement('div');
    actions.className = 'sub-card-actions';

    const editBtn = document.createElement('button');
    editBtn.type = 'button';
    editBtn.className = 'btn-text';
    editBtn.textContent = 'Edit';
    editBtn.addEventListener('click', () => startEdit(sub));

    const delBtn = document.createElement('button');
    delBtn.type = 'button';
    delBtn.className = 'btn-text btn-text-danger';
    delBtn.textContent = 'Delete';
    delBtn.addEventListener('click', () => void deleteSub(sub.id, delBtn));

    actions.append(editBtn, delBtn);
    header.append(title, actions);
    body.appendChild(header);

    const meta = document.createElement('dl');
    meta.className = 'sub-meta';
    for (const [label, value] of metaEntries(sub)) {
      const dt = document.createElement('dt');
      dt.textContent = label;
      const dd = document.createElement('dd');
      dd.textContent = value;
      if (label.startsWith('FEN')) dd.className = 'mono';
      meta.append(dt, dd);
    }
    body.appendChild(meta);

    const footer = document.createElement('div');
    footer.className = 'sub-card-footer';

    const panel = document.createElement('div');
    panel.className = 'game-panel';
    panel.hidden = true;

    footer.appendChild(matchStatus(sub, panel));
    card.append(body, footer, panel);
    return card;
  }

  function matchStatus(sub: Subscription, panel: HTMLElement): HTMLElement {
    const wrap = document.createElement('div');
    wrap.className = 'sub-matches';
    const recent = sub.recent_issues || [];
    const latest = sub.latest_twic_scanned;

    if (recent.length > 0) {
      for (const issue of recent) {
        const btn = document.createElement('button');
        btn.type = 'button';
        btn.className = 'issue-toggle';
        btn.setAttribute('aria-expanded', 'false');
        const chevron = document.createElement('span');
        chevron.className = 'issue-chevron';
        chevron.textContent = '▸';
        const label = document.createElement('span');
        label.textContent = `TWIC ${issue.twic} · ${issue.games} game${issue.games === 1 ? '' : 's'}`;
        btn.append(chevron, label);
        btn.addEventListener('click', () => void toggleIssue(sub, issue.twic, btn, wrap, panel));
        wrap.appendChild(btn);
      }
      if (latest && recent[0].twic < latest) {
        wrap.appendChild(muted(`None in TWIC ${latest}`));
      }
    } else if (latest) {
      wrap.appendChild(muted(`None in TWIC ${latest}`));
    } else {
      wrap.appendChild(muted('Waiting for the next TWIC issue'));
    }
    return wrap;
  }

  async function toggleIssue(
    sub: Subscription,
    twic: number,
    btn: HTMLButtonElement,
    wrap: HTMLElement,
    panel: HTMLElement,
  ): Promise<void> {
    const opening = btn.getAttribute('aria-expanded') !== 'true';
    wrap.querySelectorAll<HTMLButtonElement>('.issue-toggle').forEach((other) => {
      other.setAttribute('aria-expanded', 'false');
      const ch = other.querySelector('.issue-chevron');
      if (ch) ch.textContent = '▸';
    });
    if (!opening) {
      panel.hidden = true;
      panel.replaceChildren();
      delete panel.dataset.open;
      return;
    }
    btn.setAttribute('aria-expanded', 'true');
    const ch = btn.querySelector('.issue-chevron');
    if (ch) ch.textContent = '▾';
    const token = `${sub.id}:${twic}`;
    panel.dataset.open = token;
    panel.hidden = false;
    panel.replaceChildren();
    panel.appendChild(muted('Loading games…'));

    try {
      let games = gamesCache.get(token);
      if (!games) {
        const res = await fetch(
          `${API}/api/subscriptions/${sub.id}/games?twic=${twic}`,
          { headers: headers() },
        );
        if (panel.dataset.open !== token) return;
        if (!res.ok) {
          const data = await readJson(res);
          panel.replaceChildren();
          panel.appendChild(muted(errorMessage(data, 'Could not load games.')));
          return;
        }
        const data = (await res.json()) as { games: MatchedGame[] };
        games = data.games;
        gamesCache.set(token, games);
      }
      if (panel.dataset.open !== token) return;
      renderGamePanel(panel, sub, twic, games);
    } catch {
      if (panel.dataset.open !== token) return;
      panel.replaceChildren();
      panel.appendChild(muted('Could not reach the server.'));
    }
  }

  function renderGamePanel(
    panel: HTMLElement,
    sub: Subscription,
    twic: number,
    games: MatchedGame[],
  ): void {
    panel.replaceChildren();

    const head = document.createElement('div');
    head.className = 'game-panel-head';
    const title = document.createElement('span');
    title.textContent = `TWIC ${twic}`;
    const dl = document.createElement('button');
    dl.type = 'button';
    dl.className = 'btn-text';
    dl.textContent = 'Download PGN';
    dl.addEventListener('click', () => void downloadPgn(sub, twic));
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

  function startEdit(sub: Subscription): void {
    editingId = sub.id;
    heading.textContent = 'Edit alert';
    submitBtn.textContent = 'Save changes';
    (document.getElementById('dash-label') as HTMLInputElement).value = sub.label || '';
    writeExcludeOnline('dash-exclude-online', sub.exclude_site);
    writeTimeControl(PREFIX, sub.time_control);
    writeResult(PREFIX, sub.result);
    filters.setFromSubscription(sub);
    formCard.hidden = false;
    hideAlert(formAlert);
    formCard.scrollIntoView({ behavior: 'smooth', block: 'start' });
  }

  function resetForm(): void {
    editingId = null;
    heading.textContent = 'New alert';
    submitBtn.textContent = 'Create alert';
    form.reset();
    writeTimeControl(PREFIX, null);
    writeResult(PREFIX, null);
    writeExcludeOnline('dash-exclude-online', 'chess.com');
    filters.resetDefault();
    hideAlert(formAlert);
  }

  async function deleteSub(id: number, btn: HTMLButtonElement): Promise<void> {
    if (!confirm('Delete this alert? Matched games for it will be removed.')) return;
    btn.disabled = true;
    try {
      const res = await fetch(`${API}/api/subscriptions/${id}`, {
        method: 'DELETE',
        headers: headers(),
      });
      if (!res.ok) {
        const data = await readJson(res);
        showAlert(flash, errorMessage(data, 'Could not delete this alert.'), 'error');
        return;
      }
      hideAlert(flash);
      await reloadSubs();
    } catch {
      showAlert(flash, 'Could not reach the server.', 'error');
    } finally {
      btn.disabled = false;
    }
  }

  async function downloadPgn(sub: Subscription, twic: number): Promise<void> {
    try {
      const res = await fetch(
        `${API}/api/subscriptions/${sub.id}/pgn?twic=${twic}`,
        { headers: headers() },
      );
      if (!res.ok) {
        const data = await readJson(res);
        showAlert(flash, errorMessage(data, 'No games available to download yet.'), 'error');
        return;
      }
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url;
      a.download = `${(sub.label || 'subscription').replace(/\s+/g, '_')}_twic${twic}.pgn`;
      a.click();
      URL.revokeObjectURL(url);
    } catch {
      showAlert(flash, 'Could not download PGN. Try again later.', 'error');
    }
  }

  async function logout(): Promise<void> {
    try {
      await fetch(`${API}/api/logout`, { method: 'POST', headers: headers() });
    } catch {
      /* token is cleared locally either way */
    }
    clearAuthToken();
    window.location.href = '/twic-notifications';
  }

  document.getElementById('show-add-form')!.addEventListener('click', () => {
    resetForm();
    formCard.hidden = false;
  });
  document.getElementById('cancel-add')!.addEventListener('click', () => {
    formCard.hidden = true;
    resetForm();
  });
  document.getElementById('logout-btn')!.addEventListener('click', () => void logout());

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const vals = filters.values();
    const body = {
      label: (document.getElementById('dash-label') as HTMLInputElement).value.trim(),
      fen: vals.fens.length > 0 ? vals.fens : undefined,
      player: vals.player,
      eco: vals.eco,
      min_elo: vals.min_elo,
      max_elo: vals.max_elo,
      event: vals.event,
      time_control: readTimeControl(PREFIX),
      result: readResult(PREFIX),
      exclude_site: readExcludeOnline('dash-exclude-online'),
    };

    submitBtn.disabled = true;
    try {
      const updating = editingId !== null;
      const url = updating
        ? `${API}/api/subscriptions/${editingId}`
        : `${API}/api/subscriptions`;
      const res = await fetch(url, {
        method: updating ? 'PUT' : 'POST',
        headers: headers({ 'Content-Type': 'application/json' }),
        body: JSON.stringify(body),
      });
      const data = await readJson(res);
      if (res.ok) {
        showAlert(formAlert, updating ? 'Alert updated.' : 'Alert created.', 'success');
        resetForm();
        setTimeout(() => {
          formCard.hidden = true;
          hideAlert(formAlert);
        }, 1000);
        await reloadSubs();
      } else {
        showAlert(formAlert, errorMessage(data, 'Could not save this alert.'), 'error');
      }
    } catch {
      showAlert(formAlert, 'Could not reach the server.', 'error');
    } finally {
      submitBtn.disabled = false;
    }
  });

  async function boot(): Promise<void> {
    const params = new URLSearchParams(window.location.search);
    const urlToken = params.get('token');

    if (urlToken) {
      try {
        const res = await fetch(`${API}/api/exchange-token`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ token: urlToken }),
        });
        window.history.replaceState({}, '', '/dashboard');
        if (!res.ok) {
          clearAuthToken();
          gate.innerHTML = `
            <h1>Link expired</h1>
            <p class="subtitle">This login link has already been used or has expired.</p>
            <a href="/twic-notifications" class="btn btn-primary">Request a new login link</a>`;
          return;
        }
        const data = (await res.json()) as { auth_token: string };
        setAuthToken(data.auth_token);
        authToken = data.auth_token;
      } catch {
        gate.innerHTML = `<div class="alert alert-error">Could not reach the server. Try refreshing the page.</div>`;
        return;
      }
    } else {
      authToken = getAuthToken();
    }

    if (!authToken) {
      gate.innerHTML = `
        <h1>Sign in</h1>
        <p class="subtitle">Use the login link sent to your email to open the dashboard.</p>
        <a href="/twic-notifications" class="btn btn-primary">Get a login link</a>`;
      return;
    }

    try {
      const [subsRes, meRes] = await Promise.all([
        fetch(`${API}/api/subscriptions`, { headers: headers() }),
        fetch(`${API}/api/me`, { headers: headers() }),
      ]);
      if (!subsRes.ok) {
        clearAuthToken();
        gate.innerHTML = `
          <h1>Session expired</h1>
          <p class="subtitle">Your session has expired. Request a new login link.</p>
          <a href="/twic-notifications" class="btn btn-primary">Get a login link</a>`;
        return;
      }

      gate.hidden = true;
      dash.hidden = false;

      if (meRes.ok) {
        const me = (await meRes.json()) as { email: string };
        emailEl.textContent = me.email;
      }

      const data = (await subsRes.json()) as { subscriptions: Subscription[] };
      renderSubscriptions(data.subscriptions);
    } catch {
      gate.innerHTML = `
        <div class="alert alert-error">Could not reach the server.</div>
        <a href="/" class="btn btn-primary">Go home</a>`;
    }
  }

  void boot();
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

function formatResult(result: string | null | undefined): string {
  if (!result) return '';
  return result.replaceAll('1/2-1/2', '½-½');
}

function resultClass(result: string | null | undefined): string {
  if (result === '1-0') return 'result-white';
  if (result === '0-1') return 'result-black';
  if (result === '1/2-1/2') return 'result-draw';
  return '';
}

function gameRow(game: MatchedGame): HTMLElement {
  const row = document.createElement('div');
  row.className = 'game-row';

  const info = document.createElement('div');
  info.className = 'game-info';

  const players = document.createElement('div');
  players.className = 'game-players';
  const names = document.createElement('span');
  names.textContent = `${playerLabel(game.white, game.white_elo)} vs ${playerLabel(game.black, game.black_elo)}`;
  players.appendChild(names);
  if (game.result) {
    const res = document.createElement('span');
    res.className = `game-result ${resultClass(game.result)}`.trim();
    res.textContent = formatResult(game.result);
    players.append(' ', res);
  }

  const bits = [game.event, game.date, game.eco].filter((x): x is string => Boolean(x));
  if (bits.length > 0) {
    const sub = document.createElement('div');
    sub.className = 'game-sub';
    sub.textContent = bits.join(' · ');
    info.append(players, sub);
  } else {
    info.appendChild(players);
  }

  row.appendChild(info);

  if (game.lichess_url) {
    const link = document.createElement('a');
    link.className = 'lichess-link';
    link.href = game.lichess_url;
    link.target = '_blank';
    link.rel = 'noopener';
    link.textContent = 'View on Lichess ↗';
    row.appendChild(link);
  }

  return row;
}

function metaEntries(sub: Subscription): [string, string][] {
  const rows: [string, string][] = [];
  const fens = sub.fens || (sub.fen ? [sub.fen] : []);
  if (fens.length === 1) rows.push(['FEN', fens[0]]);
  else fens.forEach((fen, i) => rows.push([`FEN ${i + 1}`, fen]));
  if (sub.player) rows.push(['Player', sub.player]);
  if (sub.white) rows.push(['White', sub.white]);
  if (sub.black) rows.push(['Black', sub.black]);
  if (sub.eco) rows.push(['ECO', sub.eco]);
  if (sub.min_elo) rows.push(['Min Elo', String(sub.min_elo)]);
  if (sub.max_elo) rows.push(['Max Elo', String(sub.max_elo)]);
  if (sub.event) rows.push(['Event', sub.event]);
  if (sub.time_control) rows.push(['Time', sub.time_control]);
  if (sub.result) rows.push(['Result', sub.result.replaceAll('1/2-1/2', '½-½')]);
  if (sub.exclude_site) rows.push(['Exclude', sub.exclude_site]);
  return rows;
}
