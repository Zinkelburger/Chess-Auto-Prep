/** Shared driver for the one-shot token pages (/verify, /unsubscribe). */
import { messageOf, setAuthToken, unsubscribe, verifyEmail } from './api';
import { renderStatus as render } from './status-panel';

const HOME = { label: 'Home', href: '/' };
const ALERTS = { label: 'TWIC Alerts', href: '/twic-notifications' };

export function initVerifyPage(root: HTMLElement): void {
  const token = new URLSearchParams(window.location.search).get('token');
  window.history.replaceState({}, '', '/verify');
  if (!token) {
    render(root, { icon: 'bad', title: 'No verification token', copy: 'Open the link from your email again.', actions: [HOME] });
    return;
  }
  void verifyEmail(token).then(
    (data) => {
      if (data.auth_token) setAuthToken(data.auth_token);
      render(root, {
        icon: 'ok',
        title: 'Email verified',
        copy: data.auth_token
          ? 'Your alert is active. Taking you to your alerts…'
          : data.message || 'Your alert is active.',
        actions: [ALERTS],
        redirect: data.auth_token ? '/twic-notifications' : undefined,
      });
    },
    (err) => render(root, { icon: 'bad', title: 'Verification failed', copy: messageOf(err), actions: [ALERTS, HOME] }),
  );
}

export function initUnsubscribePage(root: HTMLElement): void {
  const params = new URLSearchParams(window.location.search);
  const token = params.get('token');
  const sub = Number.parseInt(params.get('sub') ?? '', 10);
  window.history.replaceState({}, '', '/unsubscribe');
  if (!token || !Number.isFinite(sub)) {
    // Mail clients wrap and clip long query strings, so either half can be
    // the one that went missing — don't name the wrong one.
    render(root, {
      icon: 'bad',
      title: 'Invalid unsubscribe link',
      copy: 'The link is incomplete — it may have been cut short by your mail app. Open it from your email again.',
      actions: [HOME],
    });
    return;
  }
  void unsubscribe(token, sub).then(
    () => render(root, {
      icon: 'ok',
      title: 'Unsubscribed',
      copy: 'You will no longer get emails for this alert. Your other alerts are unchanged.',
      actions: [ALERTS, HOME],
    }),
    (err) => render(root, { icon: 'bad', title: 'Unsubscribe failed', copy: messageOf(err), actions: [ALERTS, HOME] }),
  );
}
