/**
 * The arrows and marks Lichess draws on the analysis board
 * (lila ui/analyse/src/autoShape.ts): best and other engine moves, maneuver
 * arrows, the threat, the variations after this move, a hovered move, and
 * the move's live annotation.
 */
import type { DrawModifiers, DrawShape } from '@lichess-org/chessground/draw';
import type { Key } from '@lichess-org/chessground/types';
import { between, knightAttacks, ray } from 'chessops/attacks';
import type { Color, Role } from 'chessops/types';
import { makeSquare, parseUci } from 'chessops/util';
import type { EngineLine } from './engine';
import { povDiff, type Glyph } from './judge';

const MAX_MANEUVER_ARROWS = 3;

/** A move as arrows: from–to, or a drop's ring plus its piece, with a promotion's piece. */
export function moveShapes(color: Color, uci: string | undefined, brush: string, modifiers?: DrawModifiers): DrawShape[] {
  const move = uci ? parseUci(uci) : undefined;
  if (!move) return [];
  const to = makeSquare(move.to) as Key;
  const piece = (role: Role): DrawShape => ({ orig: to, piece: { color, role, scale: 0.8 }, brush: 'green' });
  if (!('from' in move)) return [{ orig: to, brush, modifiers }, piece(move.role)];
  const shapes: DrawShape[] = [{ orig: makeSquare(move.from) as Key, dest: to, brush, modifiers }];
  if (move.promotion) shapes.push(piece(move.promotion));
  return shapes;
}

/** One piece's moves through the line, while they do not cross: Lichess's maneuver arrows. */
function maneuver(color: Color, moves: string[], brush: string, all: boolean, out: DrawShape[]) {
  if (!all) { out.push(...moveShapes(color, moves[0], brush)); return; }
  const occupied = new Uint8Array(64);
  const pairs = Math.min(moves.length, MAX_MANEUVER_ARROWS * 2);
  for (let i = 0; i < pairs; i += 2) {
    const move = parseUci(moves[i]);
    if (!move) break;
    if (i > 0) {
      const prev = parseUci(moves[i - 2])!;
      if (!('from' in move) || prev.to !== move.from) break;
    }
    if (!('from' in move)) {
      if (occupied[move.to]) break;
      occupied[move.to] = 1;
    } else if (interferes(move.from, move.to, occupied)) break;
    out.push(...moveShapes(color, moves[i], brush));
  }
}

function interferes(from: number, to: number, occupied: Uint8Array): boolean {
  if (from === to) return true;
  occupied[from] = 1;
  if (knightAttacks(from).has(to)) {
    if (occupied[to]) return true;
    occupied[to] = 1;
    return false;
  }
  if (!ray(from, to).has(to)) return true;
  for (const sq of between(from, to)) {
    if (occupied[sq]) return true;
    occupied[sq] = 1;
  }
  if (occupied[to]) return true;
  occupied[to] = 1;
  return false;
}

/** The engine's best move in blue and close alternatives in grey, thinner the worse they are. */
export function engineShapes(turn: Color, lines: EngineLine[], maneuvers: boolean): DrawShape[] {
  const out: DrawShape[] = [];
  const [best, ...others] = lines;
  if (!best?.pv[0]) return out;
  maneuver(turn, best.pv, 'paleBlue', maneuvers, out);
  for (const line of others) {
    if (!line.pv[0] || line.pv[0] === best.pv[0]) continue;
    const shift = povDiff(turn, best, line);
    if (shift >= 0 && shift < 0.2) out.push(...moveShapes(turn, line.pv[0], 'paleGrey', { lineWidth: Math.round(12 - shift * 50) }));
  }
  return out;
}

/** What the side not to move threatens, in red. */
export function threatShapes(threatener: Color, lines: EngineLine[], maneuvers: boolean): DrawShape[] {
  const out: DrawShape[] = [];
  const [best, ...others] = lines;
  if (!best?.pv[0]) return out;
  maneuver(threatener, best.pv, others.length ? 'paleRed' : 'red', maneuvers, out);
  for (const line of others) {
    const shift = povDiff(threatener, best, line);
    if (shift >= 0 && shift < 0.2) out.push(...moveShapes(threatener, line.pv[0], 'paleRed', { lineWidth: Math.round(11 - shift * 45) }));
  }
  return out;
}

/** The moves already in the tree after this position, the selected one picked out. */
export function variationShapes(turn: Color, ucis: string[], selected: number, existing: DrawShape[]): DrawShape[] {
  const out: DrawShape[] = [];
  ucis.forEach((uci, i) => {
    const same = existing.find((s) => s.dest && `${s.orig}${s.dest}` === uci.slice(0, 4));
    if (same) { same.modifiers = { ...same.modifiers, hilite: i === selected ? 'white' : undefined }; return; }
    const drop = uci[1] === '@';
    const hilite = i === selected ? '#3291ff' : drop ? undefined : '#aaa';
    out.push(...moveShapes(turn, uci, 'variation', { hilite }).map((s) => ({ ...s, below: true })));
  });
  return out;
}

// Lichess's glyph badges (chessground src/glyph.ts), drawn at the top right of the square.
const BADGE: Record<Glyph['symbol'], [string, string]> = {
  '?!': ['#56b4e9', 'M37.734 21.947c-3.714 0-7.128.464-10.242 1.393-3.113.928-6.009 2.13-8.685 3.605l4.343 8.766c2.35-1.202 4.644-2.157 6.883-2.867a22.366 22.366 0 0 1 6.799-1.065c2.294 0 4.07.464 5.326 1.393 1.311.874 1.967 2.186 1.967 3.933 0 1.748-.546 3.277-1.639 4.588-1.038 1.257-2.786 2.758-5.244 4.506-2.786 2.021-4.751 3.961-5.898 5.819-1.147 1.857-1.721 4.15-1.721 6.88v2.952h10.568v-2.377c0-1.147.137-2.103.41-2.868.328-.764.93-1.557 1.803-2.376.874-.82 2.104-1.803 3.688-2.95 2.13-1.584 3.906-3.058 5.326-4.424 1.42-1.42 2.485-2.95 3.195-4.59.71-1.638 1.065-3.576 1.065-5.816 0-4.206-1.584-7.675-4.752-10.406-3.114-2.731-7.51-4.096-13.192-4.096zm24.745.819 2.048 39.084h9.75l2.047-39.084zM35.357 68.73c-1.966 0-3.632.52-4.998 1.557-1.365.983-2.047 2.732-2.047 5.244 0 2.404.682 4.152 2.047 5.244 1.366 1.038 3.032 1.557 4.998 1.557 1.912 0 3.55-.519 4.916-1.557 1.366-1.092 2.05-2.84 2.05-5.244 0-2.512-.684-4.26-2.05-5.244-1.365-1.038-3.004-1.557-4.916-1.557zm34.004 0c-1.966 0-3.632.52-4.998 1.557-1.365.983-2.049 2.732-2.049 5.244 0 2.404.684 4.152 2.05 5.244 1.365 1.038 3.03 1.557 4.997 1.557 1.912 0 3.55-.519 4.916-1.557 1.366-1.092 2.047-2.84 2.047-5.244 0-2.512-.681-4.26-2.047-5.244-1.365-1.038-3.004-1.557-4.916-1.557z'],
  '?': ['#e69f00', 'M40.436 60.851q0-4.66 1.957-7.83 1.958-3.17 6.712-6.619 4.195-2.983 5.967-5.127 1.864-2.237 1.864-5.22 0-2.983-2.237-4.475-2.144-1.585-6.06-1.585-3.915 0-7.737 1.212t-7.83 3.263l-4.941-9.975q4.568-2.517 9.881-4.101 5.314-1.585 11.653-1.585 9.695 0 15.008 4.661 5.407 4.661 5.407 11.839 0 3.822-1.212 6.619-1.212 2.796-3.635 5.22-2.424 2.33-6.06 5.034-2.703 1.958-4.195 3.356-1.491 1.398-2.05 2.703-.467 1.305-.467 3.263v2.703H40.436zm-1.492 18.924q0-4.288 2.33-5.966 2.331-1.771 5.687-1.771 3.263 0 5.594 1.771 2.33 1.678 2.33 5.966 0 4.102-2.33 5.966-2.331 1.772-5.594 1.772-3.356 0-5.686-1.772-2.33-1.864-2.33-5.966z'],
  '??': ['#df5353', 'M31.8 22.22c-3.675 0-7.052.46-10.132 1.38-3.08.918-5.945 2.106-8.593 3.565l4.298 8.674c2.323-1.189 4.592-2.136 6.808-2.838a22.138 22.138 0 0 1 6.728-1.053c2.27 0 4.025.46 5.268 1.378 1.297.865 1.946 2.16 1.946 3.89s-.541 3.242-1.622 4.539c-1.027 1.243-2.756 2.73-5.188 4.458-2.756 2-4.7 3.918-5.836 5.755-1.134 1.837-1.702 4.107-1.702 6.808v2.92h10.457v-2.35c0-1.135.135-2.082.406-2.839.324-.756.918-1.54 1.783-2.35.864-.81 2.079-1.784 3.646-2.918 2.107-1.568 3.863-3.026 5.268-4.376 1.405-1.405 2.46-2.92 3.162-4.541.703-1.621 1.054-3.54 1.054-5.755 0-4.161-1.568-7.592-4.702-10.294-3.08-2.702-7.43-4.052-13.05-4.052zm38.664 0c-3.675 0-7.053.46-10.133 1.38-3.08.918-5.944 2.106-8.591 3.565l4.295 8.674c2.324-1.189 4.593-2.136 6.808-2.838a22.138 22.138 0 0 1 6.728-1.053c2.27 0 4.026.46 5.269 1.378 1.297.865 1.946 2.16 1.946 3.89s-.54 3.242-1.62 4.539c-1.027 1.243-2.757 2.73-5.189 4.458-2.756 2-4.7 3.918-5.835 5.755-1.135 1.837-1.703 4.107-1.703 6.808v2.92h10.457v-2.35c0-1.135.134-2.082.404-2.839.324-.756.918-1.54 1.783-2.35.865-.81 2.081-1.784 3.648-2.918 2.108-1.568 3.864-3.026 5.269-4.376 1.405-1.405 2.46-2.92 3.162-4.541.702-1.621 1.053-3.54 1.053-5.755 0-4.161-1.567-7.592-4.702-10.294-3.08-2.702-7.43-4.052-13.05-4.052zM29.449 68.504c-1.945 0-3.593.513-4.944 1.54-1.351.973-2.027 2.703-2.027 5.188 0 2.378.676 4.108 2.027 5.188 1.35 1.027 3 1.54 4.944 1.54 1.892 0 3.512-.513 4.863-1.54 1.35-1.08 2.026-2.81 2.026-5.188 0-2.485-.675-4.215-2.026-5.188-1.351-1.027-2.971-1.54-4.863-1.54zm38.663 0c-1.945 0-3.592.513-4.943 1.54-1.35.973-2.026 2.703-2.026 5.188 0 2.378.675 4.108 2.026 5.188 1.351 1.027 2.998 1.54 4.943 1.54 1.891 0 3.513-.513 4.864-1.54 1.351-1.08 2.027-2.81 2.027-5.188 0-2.485-.676-4.215-2.027-5.188-1.35-1.027-2.973-1.54-4.864-1.54z'],
};

/** The move's annotation as Lichess's badge on the square it went to. */
export function glyphShape(uci: string, san: string, glyph: Glyph): DrawShape {
  const move = parseUci(uci)!;
  let square = makeSquare(move.to);
  if (san.startsWith('O-O')) square = `${san.startsWith('O-O-O') ? 'c' : 'g'}${square[1]}` as typeof square;
  const [fill, path] = BADGE[glyph.symbol];
  return {
    orig: square as Key,
    brush: '',
    customSvg: {
      html: `<defs><filter id="ch-glyph-shadow"><feDropShadow dx="4" dy="7" flood-opacity=".5" stdDeviation="5"/></filter></defs><g transform="matrix(.4 0 0 .4 71 -12)"><circle cx="50" cy="50" r="50" fill="${fill}" filter="url(#ch-glyph-shadow)"/><path fill="#fff" d="${path}"/></g>`,
    },
  };
}
