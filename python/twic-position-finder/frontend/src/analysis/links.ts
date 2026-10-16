/**
 * The bughouse pages' links, as lila's: the analysis board and the board
 * editor each have their own URL with the position in it, so Back, reload
 * and a copied link all land on the same position.
 */
import type { Color } from 'chessops/types';
import { START_FEN } from './tree';

/** The side the analysis board shows at the bottom unless the link says otherwise: the side to move. */
export function defaultOrientation(fen: string): Color {
  return fen.split(' ')[1] === 'b' ? 'black' : 'white';
}

/** /bughouse/?fen=…, with ?color= only when the board is turned from its default. */
export function analysisUrl(fen: string, orientation: Color): string {
  const params = new URLSearchParams();
  if (fen !== START_FEN) params.set('fen', fen);
  if (orientation !== defaultOrientation(fen)) params.set('color', orientation);
  return withParams('/bughouse/', params);
}

/** /bughouse/editor/?fen=…; the starting position with White below is the plain page, as lila's /editor. */
export function editorUrl(fen: string, orientation: Color): string {
  const params = new URLSearchParams();
  if (fen !== START_FEN) params.set('fen', fen);
  if (orientation === 'black') params.set('color', 'black');
  return withParams('/bughouse/editor/', params);
}

/** The orientation a link asks for, if any. */
export function linkedOrientation(params: URLSearchParams): Color | null {
  const color = params.get('color');
  return color === 'white' || color === 'black' ? color : null;
}

function withParams(path: string, params: URLSearchParams): string {
  const query = params.toString();
  return query ? `${path}?${query}` : path;
}
