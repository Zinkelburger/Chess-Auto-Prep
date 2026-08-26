/**
 * The one TWIC Alerts page. Two states, decided at boot:
 *
 *  - anonymous: create-an-alert form (email + filters) and "email me a login
 *    link";
 *  - signed in: the list of alerts with new/edit/delete, plus sign out.
 *
 * A `?token=` in the URL (from a login email) is exchanged for a session
 * before the state is decided, so the same page serves both the marketing
 * front door and the account view. `/dashboard` forwards here.
 */
import {
  ApiError, clearAuthToken, createSubscription, deleteSubscription, exchangeLoginToken,
  getAuthToken, getMe, hideAlert, listSubscriptions, logout, messageOf, requestLoginLink,
  setAuthToken, showAlert, subscribe, updateSubscription,
  type Subscription,
} from './api';
import { AlertForm } from './alert-form';
import { AlertsList } from './alerts-list';
import { renderStatus } from './status-panel';

interface Turnstile {
  getResponse(): string;
  reset(): void;
}

function turnstile(): Turnstile | undefined {
  return (window as unknown as { turnstile?: Turnstile }).turnstile;
}

function $<T extends HTMLElement = HTMLElement>(id: string): T {
  const el = document.getElementById(id);
  if (!el) throw new Error(`Missing #${id}`);
  return el as T;
}

async function withBusy<T>(btn: HTMLButtonElement, work: () => Promise<T>): Promise<T> {
  btn.disabled = true;
  btn.classList.add('busy');
  try {
    return await work();
  } finally {
    btn.disabled = false;
    btn.classList.remove('busy');
  }
}

/**
 * What the boot step decided. `explained` means the panel already in `#boot`
 * is the whole page — a dead login link — and neither of the two normal
 * states should replace it.
 */
type Session =
  | { state: 'signed-in'; token: string }
  | { state: 'anonymous' }
  | { state: 'explained' };

export function initAlertsPage(): void {
  const boot = $('boot');
  const anon = $('anon');
  const account = $('account');

  void (async () => {
    const session = await resolveSession(boot);
    if (session.state === 'signed-in') {
      await showAccount(session.token, boot, account);
    } else if (session.state === 'anonymous') {
      boot.hidden = true;
      anon.hidden = false;
      initAnonymous();
    }
  })();
}

/** Exchange a login token from the URL if present, else use the stored session. */
async function resolveSession(boot: HTMLElement): Promise<Session> {
  const params = new URLSearchParams(window.location.search);
  const urlToken = params.get('token');
  if (!urlToken) {
    const stored = getAuthToken();
    return stored ? { state: 'signed-in', token: stored } : { state: 'anonymous' };
  }

  window.history.replaceState({}, '', window.location.pathname);
  try {
    const { auth_token } = await exchangeLoginToken(urlToken);
    setAuthToken(auth_token);
    return { state: 'signed-in', token: auth_token };
  } catch (err) {
    const stored = getAuthToken();
    // An already-used link, but we are still signed in: just show the account.
    if (stored) return { state: 'signed-in', token: stored };
    renderStatus(boot, {
      icon: 'bad',
      title: 'Link expired',
      copy: messageOf(err, 'This login link has already been used or has expired.'),
      actions: [{ label: 'Request a new link', href: '/twic-notifications' }],
    });
    return { state: 'explained' };
  }
}

// ── Anonymous ───────────────────────────────────────────────────

function initAnonymous(): void {
  const form = $<HTMLFormElement>('subscribe-form');
  const alertEl = $('subscribe-alert');
  const submitBtn = $<HTMLButtonElement>('subscribe-submit');
  const emailInput = $<HTMLInputElement>('sub-email');
  const alertForm = new AlertForm(form, 'sub');

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    hideAlert(alertEl);
    const read = alertForm.read();
    if (!read.ok) {
      showAlert(alertEl, read.error, 'error');
      return;
    }
    void withBusy(submitBtn, async () => {
      try {
        const res = await subscribe(emailInput.value.trim(), read.payload, turnstile()?.getResponse() ?? '');
        form.reset();
        alertForm.reset();
        showAlert(alertEl, res.message, 'success');
        alertEl.scrollIntoView({ behavior: 'smooth', block: 'center' });
      } catch (err) {
        showAlert(alertEl, messageOf(err), 'error');
      } finally {
        try { turnstile()?.reset(); } catch { /* not loaded */ }
      }
    });
  });

  const loginForm = $<HTMLFormElement>('login-form');
  const loginAlert = $('login-alert');
  const loginBtn = loginForm.querySelector<HTMLButtonElement>('button[type="submit"]')!;
  const loginEmail = $<HTMLInputElement>('login-email');
  loginForm.addEventListener('submit', (e) => {
    e.preventDefault();
    hideAlert(loginAlert);
    void withBusy(loginBtn, async () => {
      try {
        const res = await requestLoginLink(loginEmail.value.trim());
        showAlert(loginAlert, res.message || 'Check your email for a login link.', 'success');
      } catch (err) {
        showAlert(loginAlert, messageOf(err), 'error');
      }
    });
  });
}

// ── Signed in ───────────────────────────────────────────────────

async function showAccount(token: string, boot: HTMLElement, account: HTMLElement): Promise<void> {
  let subs: Subscription[];
  let email = '';
  try {
    const [s, me] = await Promise.all([listSubscriptions(token), getMe(token).catch(() => null)]);
    subs = s;
    email = me?.email ?? '';
  } catch (err) {
    if (err instanceof ApiError && err.unauthorized) {
      clearAuthToken();
      renderStatus(boot, {
        icon: 'bad',
        title: 'Session expired',
        copy: 'Request a new login link to manage your alerts.',
        actions: [{ label: 'Get a login link', href: '/twic-notifications' }],
      });
      return;
    }
    renderStatus(boot, {
      icon: 'bad',
      title: 'Could not load your alerts',
      copy: messageOf(err),
      actions: [{ label: 'Try again', href: '/twic-notifications' }],
    });
    return;
  }

  boot.hidden = true;
  account.hidden = false;
  $('account-email').textContent = email;

  const flash = $('account-flash');
  const formCard = $('alert-form-card');
  const form = $<HTMLFormElement>('alert-form');
  const formAlert = $('alert-form-alert');
  const heading = $('alert-form-title');
  const submitBtn = $<HTMLButtonElement>('alert-form-submit');
  const newBtn = $<HTMLButtonElement>('new-alert');
  const countEl = $('alert-count');
  const alertForm = new AlertForm(form, 'acct');
  let editing: Subscription | null = null;

  const list = new AlertsList($('alerts-list'), $('alerts-empty'), {
    token: () => token,
    onEdit: (sub) => openForm(sub),
    onDelete: (sub, btn) => void remove(sub, btn),
    onError: (msg) => showAlert(flash, msg, 'error'),
  });

  function renderAll(): void {
    list.render(subs);
    countEl.textContent = `${subs.length} alert${subs.length === 1 ? '' : 's'}`;
  }

  async function reload(): Promise<void> {
    subs = await listSubscriptions(token);
    renderAll();
  }

  function openForm(sub: Subscription | null): void {
    editing = sub;
    heading.textContent = sub ? 'Edit alert' : 'New alert';
    submitBtn.textContent = sub ? 'Save changes' : 'Create alert';
    if (sub) alertForm.load(sub);
    else alertForm.reset();
    hideAlert(formAlert);
    hideAlert(flash);
    formCard.hidden = false;
    newBtn.hidden = true;
    formCard.scrollIntoView({ behavior: 'smooth', block: 'start' });
    alertForm.focus();
  }

  function closeForm(): void {
    editing = null;
    formCard.hidden = true;
    newBtn.hidden = false;
    alertForm.reset();
    hideAlert(formAlert);
  }

  async function remove(sub: Subscription, btn: HTMLButtonElement): Promise<void> {
    if (!confirm(`Delete “${sub.label || 'this alert'}”? Its matched games are removed too.`)) return;
    await withBusy(btn, async () => {
      try {
        await deleteSubscription(token, sub.id);
        hideAlert(flash);
        if (editing?.id === sub.id) closeForm();
        await reload();
      } catch (err) {
        showAlert(flash, messageOf(err), 'error');
      }
    });
  }

  newBtn.addEventListener('click', () => openForm(null));
  $('alert-form-cancel').addEventListener('click', closeForm);
  $('logout').addEventListener('click', () => {
    void logout(token).then(() => {
      clearAuthToken();
      window.location.href = '/twic-notifications';
    });
  });

  form.addEventListener('submit', (e) => {
    e.preventDefault();
    hideAlert(formAlert);
    const read = alertForm.read();
    if (!read.ok) {
      showAlert(formAlert, read.error, 'error');
      return;
    }
    void withBusy(submitBtn, async () => {
      const wasEditing = Boolean(editing);
      try {
        if (editing) await updateSubscription(token, editing.id, read.payload);
        else await createSubscription(token, read.payload);
      } catch (err) {
        if (err instanceof ApiError && err.unauthorized) {
          clearAuthToken();
          window.location.href = '/twic-notifications';
          return;
        }
        showAlert(formAlert, messageOf(err), 'error');
        return;
      }
      // Saved. The form is gone from here on, so anything that goes wrong
      // while refreshing the list has to be reported on the page itself.
      closeForm();
      showAlert(flash, wasEditing ? 'Alert updated.' : 'Alert created. You’ll get an email when it matches.', 'success');
      try {
        await reload();
      } catch (err) {
        showAlert(flash, `${messageOf(err)} Reload the page to see the change.`, 'error');
      }
    });
  });

  renderAll();
}
