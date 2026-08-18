/** Shared API helpers for the TWIC notifications site. */

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
  recent_issues?: TwicIssue[];
  latest_twic_scanned?: number | null;
}

export function getAuthToken(): string | null {
  return localStorage.getItem(AUTH_KEY);
}

export function setAuthToken(token: string): void {
  localStorage.setItem(AUTH_KEY, token);
}

export function clearAuthToken(): void {
  localStorage.removeItem(AUTH_KEY);
}

export function authHeaders(token: string, extra: Record<string, string> = {}): Record<string, string> {
  return { Authorization: `Bearer ${token}`, ...extra };
}

export function errorMessage(data: unknown, fallback: string): string {
  if (data && typeof data === 'object' && 'detail' in data) {
    const detail = (data as { detail: unknown }).detail;
    if (typeof detail === 'string') return detail;
    if (Array.isArray(detail) && detail[0] && typeof detail[0] === 'object' && detail[0] !== null
        && 'msg' in detail[0] && typeof (detail[0] as { msg: unknown }).msg === 'string') {
      return (detail[0] as { msg: string }).msg;
    }
  }
  return fallback;
}

export async function readJson(res: Response): Promise<unknown> {
  try {
    return await res.json();
  } catch {
    return {};
  }
}

export function previewBoard(fen: string, board: HTMLElement, error: HTMLElement | null): void {
  const fn = (window as unknown as {
    renderBoardPreview?: (fen: string, board: HTMLElement, error: HTMLElement | null) => void;
  }).renderBoardPreview;
  fn?.(fen, board, error);
}

export function showAlert(el: HTMLElement, message: string, kind: 'success' | 'error'): void {
  el.classList.add('alert');
  el.classList.toggle('alert-success', kind === 'success');
  el.classList.toggle('alert-error', kind === 'error');
  el.textContent = message;
  el.hidden = false;
}

export function hideAlert(el: HTMLElement): void {
  el.hidden = true;
  el.textContent = '';
}
