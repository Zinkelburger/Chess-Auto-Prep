/** API client for the TWIC alerts backend (server.py). */

export const API = import.meta.env.PUBLIC_API_URL || 'http://localhost:8000';
export const AUTH_KEY = 'twic_auth_token';

export interface MatchedGame {
  id: number;
  white?: string | null;
  black?: string | null;
  white_elo?: number | null;
  black_elo?: number | null;
  result?: string | null;
  event?: string | null;
  site?: string | null;
  date?: string | null;
  eco?: string | null;
  opening?: string | null;
  lichess_url?: string | null;
}

export interface TwicIssue {
  twic: number;
  games: number;
}

export interface Subscription {
  id: number;
  label: string;
  fen?: string | null;
  fens?: string[];
  player?: string | null;
  white?: string | null;
  black?: string | null;
  eco?: string | null;
  min_elo?: number | null;
  max_elo?: number | null;
  event?: string | null;
  time_control?: string | null;
  result?: string | null;
  exclude_site?: string | null;
  site?: string | null;
  recent_issues?: TwicIssue[];
  latest_twic_scanned?: number | null;
}

/** Body of POST/PUT /api/subscriptions and the alert part of /api/subscribe. */
export interface AlertPayload {
  label: string;
  fen?: string[];
  player?: string;
  /** Not offered by the form; carried through an edit so a PUT cannot drop it. */
  white?: string;
  /** Not offered by the form; carried through an edit so a PUT cannot drop it. */
  black?: string;
  eco?: string;
  min_elo?: number;
  max_elo?: number;
  event?: string;
  time_control?: string;
  result?: string;
  exclude_site?: string;
  /** Not offered by the form; carried through an edit so a PUT cannot drop it. */
  site?: string;
}

export interface Me {
  email: string;
  subscription_count?: number;
}

/** Thrown for any non-2xx response; [message] is safe to show to the user. */
export class ApiError extends Error {
  constructor(public readonly status: number, message: string) {
    super(message);
    this.name = 'ApiError';
  }
  get unauthorized(): boolean {
    return this.status === 401 || this.status === 403;
  }
}

export const NETWORK_ERROR = 'Could not reach the server. Check your connection and try again.';

// ── Auth token ─────────────────────────────────────────────────────

export function getAuthToken(): string | null {
  try {
    return localStorage.getItem(AUTH_KEY);
  } catch {
    return null;
  }
}

export function setAuthToken(token: string): void {
  try {
    localStorage.setItem(AUTH_KEY, token);
  } catch {
    /* private mode: the session simply won't persist */
  }
}

export function clearAuthToken(): void {
  try {
    localStorage.removeItem(AUTH_KEY);
  } catch {
    /* ignore */
  }
}

// ── Transport ──────────────────────────────────────────────────────

function detailMessage(data: unknown, fallback: string): string {
  if (data && typeof data === 'object' && 'detail' in data) {
    const detail = (data as { detail: unknown }).detail;
    if (typeof detail === 'string') return detail;
    if (Array.isArray(detail)) {
      const first = detail[0];
      if (first && typeof first === 'object' && 'msg' in first && typeof first.msg === 'string') {
        return first.msg;
      }
    }
  }
  return fallback;
}

interface RequestOptions {
  method?: 'GET' | 'POST' | 'PUT' | 'DELETE';
  body?: unknown;
  token?: string | null;
  /** Message for a non-2xx response that carries no usable detail. */
  fallback?: string;
}

async function request<T>(path: string, opts: RequestOptions = {}): Promise<T> {
  const headers: Record<string, string> = {};
  if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
  if (opts.token) headers.Authorization = `Bearer ${opts.token}`;
  let res: Response;
  try {
    res = await fetch(`${API}${path}`, {
      method: opts.method ?? 'GET',
      headers,
      body: opts.body === undefined ? undefined : JSON.stringify(opts.body),
    });
  } catch {
    throw new ApiError(0, NETWORK_ERROR);
  }
  let data: unknown = null;
  try {
    data = await res.json();
  } catch {
    /* empty or non-JSON body */
  }
  if (!res.ok) {
    throw new ApiError(res.status, detailMessage(data, opts.fallback ?? `Request failed (${res.status}).`));
  }
  return data as T;
}

// ── Public endpoints ──────────────────────────────────────────────

export interface SubscribeResponse {
  status: 'verification_sent' | 'subscription_added';
  message: string;
}

export function subscribe(
  email: string,
  alert: AlertPayload,
  turnstileToken: string,
): Promise<SubscribeResponse> {
  return request('/api/subscribe', {
    method: 'POST',
    body: { email, cf_turnstile_token: turnstileToken, ...alert },
    fallback: 'Could not create this alert.',
  });
}

export function requestLoginLink(email: string): Promise<{ message: string }> {
  return request('/api/login', {
    method: 'POST',
    body: { email },
    fallback: 'Could not send a login link.',
  });
}

export function verifyEmail(token: string): Promise<{ auth_token?: string; message?: string }> {
  return request('/api/verify', { method: 'POST', body: { token }, fallback: 'Verification failed.' });
}

export function exchangeLoginToken(token: string): Promise<{ auth_token: string }> {
  return request('/api/exchange-token', {
    method: 'POST',
    body: { token },
    fallback: 'This login link has already been used or has expired.',
  });
}

export function unsubscribe(token: string, sub: number): Promise<{ message?: string }> {
  return request('/api/unsubscribe', { method: 'POST', body: { token, sub }, fallback: 'Unsubscribe failed.' });
}

// ── Authenticated endpoints ───────────────────────────────────────

export function getMe(token: string): Promise<Me> {
  return request('/api/me', { token });
}

export async function listSubscriptions(token: string): Promise<Subscription[]> {
  const data = await request<{ subscriptions: Subscription[] }>('/api/subscriptions', {
    token,
    fallback: 'Could not load your alerts.',
  });
  return data.subscriptions ?? [];
}

export function createSubscription(token: string, alert: AlertPayload): Promise<unknown> {
  return request('/api/subscriptions', {
    method: 'POST', token, body: alert, fallback: 'Could not save this alert.',
  });
}

export function updateSubscription(token: string, id: number, alert: AlertPayload): Promise<unknown> {
  return request(`/api/subscriptions/${id}`, {
    method: 'PUT', token, body: alert, fallback: 'Could not save this alert.',
  });
}

export function deleteSubscription(token: string, id: number): Promise<unknown> {
  return request(`/api/subscriptions/${id}`, {
    method: 'DELETE', token, fallback: 'Could not delete this alert.',
  });
}

export async function listMatchedGames(token: string, id: number, twic: number): Promise<MatchedGame[]> {
  const data = await request<{ games: MatchedGame[] }>(`/api/subscriptions/${id}/games?twic=${twic}`, {
    token,
    fallback: 'Could not load games.',
  });
  return data.games ?? [];
}

export async function fetchPgn(token: string, id: number, twic: number): Promise<Blob> {
  let res: Response;
  try {
    res = await fetch(`${API}/api/subscriptions/${id}/pgn?twic=${twic}`, {
      headers: { Authorization: `Bearer ${token}` },
    });
  } catch {
    throw new ApiError(0, NETWORK_ERROR);
  }
  if (!res.ok) {
    let data: unknown = null;
    try { data = await res.json(); } catch { /* ignore */ }
    throw new ApiError(res.status, detailMessage(data, 'No games available to download yet.'));
  }
  return res.blob();
}

export async function logout(token: string): Promise<void> {
  try {
    await request('/api/logout', { method: 'POST', token });
  } catch {
    /* the token is cleared locally either way */
  }
}

// ── Small DOM helpers shared by the alert pages ───────────────────

export type AlertKind = 'success' | 'error' | 'info' | 'warn';

export function showAlert(el: HTMLElement, message: string, kind: AlertKind): void {
  el.className = `alert alert-${kind}`;
  el.setAttribute('role', kind === 'error' ? 'alert' : 'status');
  el.textContent = message;
  el.hidden = false;
}

export function hideAlert(el: HTMLElement): void {
  el.hidden = true;
  el.textContent = '';
}

export function messageOf(err: unknown, fallback = 'Something went wrong.'): string {
  if (err instanceof ApiError) return err.message;
  return fallback;
}
