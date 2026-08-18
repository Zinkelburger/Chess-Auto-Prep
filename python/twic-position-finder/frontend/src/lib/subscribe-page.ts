import { API, errorMessage, readJson, showAlert } from './api';
import { FilterBuilder } from './filters';
import { readExcludeOnline, readResult, readTimeControl } from './form-options';

const PREFIX = 'sub';

export function initSubscribePage(): void {
  const filters = new FilterBuilder({
    container: document.getElementById('filters-container')!,
    addBtn: document.getElementById('add-filter-btn')!,
    menu: document.getElementById('filter-menu')!,
    idPrefix: PREFIX,
    enableAutocomplete: true,
  });
  filters.resetDefault();

  const form = document.getElementById('subscribe-form') as HTMLFormElement;
  const alertEl = document.getElementById('subscribe-alert')!;
  const submitBtn = document.getElementById('submit-btn') as HTMLButtonElement;

  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const vals = filters.values();
    let turnstileResponse = '';
    try {
      turnstileResponse = (window as unknown as { turnstile?: { getResponse: () => string } })
        .turnstile?.getResponse() || '';
    } catch {
      /* turnstile not loaded */
    }

    const body = {
      email: (document.getElementById('sub-email') as HTMLInputElement).value.trim(),
      cf_turnstile_token: turnstileResponse,
      label: (document.getElementById('sub-label') as HTMLInputElement).value.trim(),
      fen: vals.fens.length > 0 ? vals.fens : undefined,
      player: vals.player,
      eco: vals.eco,
      min_elo: vals.min_elo,
      max_elo: vals.max_elo,
      event: vals.event,
      time_control: readTimeControl(PREFIX),
      result: readResult(PREFIX),
      exclude_site: readExcludeOnline('sub-exclude-online'),
    };

    submitBtn.disabled = true;
    submitBtn.textContent = 'Submitting…';

    try {
      const res = await fetch(`${API}/api/subscribe`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(body),
      });
      const data = await readJson(res);
      if (res.ok) {
        showAlert(alertEl, (data as { message?: string }).message || 'Check your email.', 'success');
        form.reset();
        filters.resetDefault();
        try {
          (window as unknown as { turnstile?: { reset: () => void } }).turnstile?.reset();
        } catch {
          /* ignore */
        }
      } else {
        showAlert(alertEl, errorMessage(data, 'Something went wrong.'), 'error');
        try {
          (window as unknown as { turnstile?: { reset: () => void } }).turnstile?.reset();
        } catch {
          /* ignore */
        }
      }
    } catch {
      showAlert(alertEl, 'Could not reach the server.', 'error');
    } finally {
      submitBtn.disabled = false;
      submitBtn.textContent = 'Subscribe';
    }
  });

  const loginForm = document.getElementById('login-form') as HTMLFormElement;
  const loginAlert = document.getElementById('login-alert')!;
  loginForm.addEventListener('submit', async (e) => {
    e.preventDefault();
    const email = (document.getElementById('login-email') as HTMLInputElement).value.trim();
    const btn = loginForm.querySelector('button[type="submit"]') as HTMLButtonElement;
    btn.disabled = true;
    try {
      const res = await fetch(`${API}/api/login`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email }),
      });
      const data = await readJson(res);
      if (res.ok) {
        showAlert(loginAlert, (data as { message?: string }).message || 'Check your email.', 'success');
      } else {
        showAlert(loginAlert, errorMessage(data, 'Something went wrong.'), 'error');
      }
    } catch {
      showAlert(loginAlert, 'Could not reach the server.', 'error');
    } finally {
      btn.disabled = false;
    }
  });
}
