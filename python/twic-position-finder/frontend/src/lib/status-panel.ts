/**
 * The full-page outcome panel — a tick or a cross, a headline, a line of copy
 * and one or two links. Used by /verify and /unsubscribe for their one-shot
 * token results, and by the alerts page when a login link is dead or the
 * session cannot be loaded.
 *
 * It renders *into* an element that already carries `.status-panel` rather
 * than appending its own, so the chrome is not drawn twice.
 */
export interface StatusAction {
  label: string;
  href: string;
}

export interface StatusOutcome {
  icon: 'ok' | 'bad';
  title: string;
  copy: string;
  actions: StatusAction[];
  /** Send the reader on after a beat, once they have had time to read it. */
  redirect?: string;
}

export function renderStatus(root: HTMLElement, o: StatusOutcome): void {
  root.innerHTML = `
    <div class="status-icon ${o.icon === 'ok' ? 'ok' : 'bad'}" aria-hidden="true">${o.icon === 'ok' ? '✓' : '✕'}</div>
    <h1></h1><p class="lede"></p><div class="btn-row"></div>`;
  root.querySelector('h1')!.textContent = o.title;
  root.querySelector('p')!.textContent = o.copy;
  const row = root.querySelector('.btn-row')!;
  o.actions.forEach((a, i) => {
    const link = document.createElement('a');
    link.className = i === 0 ? 'btn btn-primary' : 'btn btn-outline';
    link.href = a.href;
    link.textContent = a.label;
    row.appendChild(link);
  });
  const to = o.redirect;
  if (to) setTimeout(() => { window.location.href = to; }, 1200);
}
