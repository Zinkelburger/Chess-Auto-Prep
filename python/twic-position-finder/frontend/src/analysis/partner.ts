/**
 * The partner panel, under the engine lines. It shows what HypeBeast knows
 * about the other board without searching anything itself:
 *
 * - One more piece in hand: for each colour, how much better its position is
 *   with one more pawn, knight, bishop, rook or queen, or Mate when the piece
 *   makes a mate possible. With both boards shown, the first table comes from
 *   the other board's search, which measures it to price captures; then the
 *   page measures it deeper on this board while the engine is free. Clicking
 *   a cell adds that piece to that hand.
 * - With both boards: what may arrive from the other board in its next two
 *   moves, and why HypeBeast chose its move.
 */
import type { Color } from 'chessops/types';
import type { EngineResult, HandRole, PieceGain, PieceValues } from './engine';
import { el } from './moves';
import { pieceSrc } from './board';

const ROLES: HandRole[] = ['pawn', 'knight', 'bishop', 'rook', 'queen'];
const LETTER_ROLE: Record<string, HandRole> = { P: 'pawn', N: 'knight', B: 'bishop', R: 'rook', Q: 'queen' };
const ARTICLE: Record<HandRole, string> = { pawn: 'a pawn', knight: 'a knight', bishop: 'a bishop', rook: 'a rook', queen: 'a queen' };
const capital = (s: string) => s[0].toUpperCase() + s.slice(1);
const other = (c: Color): Color => (c === 'white' ? 'black' : 'white');

export interface PartnerHost {
  /** The engine is on and the board is in analysis (not the editor or practice). */
  readonly active: boolean;
  /** The engine failed or waits for the player: nothing more will come. */
  readonly engineStopped: boolean;
  readonly twoBoards: boolean;
  /** "board 1" or "board 2": the board shown large. */
  readonly boardName: string;
  readonly partnerName: string;
  /** Side to move on the board shown. */
  readonly turn: Color;
  /** Piece values for the board shown, the deepest so far. */
  values(): PieceValues | undefined;
  /** More values are being measured for it. */
  measuring(): boolean;
  /** HypeBeast's analysis of the board shown. */
  result(): EngineResult | undefined;
  /** A partner-board move as SAN. */
  partnerSan(uci: string): string;
  /** A move on the board shown as SAN. */
  moveSan(uci: string): string;
  give(color: Color, role: HandRole): void;
}

/** Centipawns as pawns, signed: +2.3. */
function pawns(cp: number): string {
  const p = cp / 100;
  return `${p >= 0 ? '+' : '−'}${Math.abs(p).toFixed(1)}`;
}

/** What a forecast package sends, in words: "a pawn for White, a bishop for Black". */
export function arrivalText(arrival: string, mover: Color): string {
  if (arrival === 'none' || !arrival) return 'Nothing';
  const parts = [...arrival.matchAll(/([+-])([PNBRQ])/g)].map(([, sign, letter]) => {
    const to = sign === '+' ? mover : other(mover);
    return `${ARTICLE[LETTER_ROLE[letter]]} for ${capital(to)}`;
  });
  return parts.length ? capital(parts.join(', ')) : 'Nothing';
}

/** Why HypeBeast chose its move, from its coordinator's reason. */
export function reasonText(result: EngineResult, partnerName: string, moveSan: string): string {
  const reason = result.reason ?? '';
  const sent = result.coordination?.candidates.find((c) => c.move === result.decision)?.delivery;
  const sends = sent && LETTER_ROLE[sent] ? `, which sends ${partnerName} ${ARTICLE[LETTER_ROLE[sent]]}` : '';
  if (result.decision === 'pass') return 'Sits: every move hands the other team a mating piece.';
  switch (reason) {
    case 'override': return `${moveSan} over its best move on this board for what it sends: the capture is worth more on ${partnerName}${sends}.`;
    case 'world_switch': return `${moveSan} because of what may arrive from ${partnerName}: it scores best over the likely arrivals.`;
    case 'no_arrivals': return `Nothing is likely to arrive from ${partnerName} soon, so ${moveSan} is its best move here${sends}.`;
    case 'kept_main': return `${moveSan} is its best move here, and stays best with what may arrive from ${partnerName}${sends}.`;
    case 'team_win_main': case 'team_win_override': return `${moveSan} wins the game for the team.`;
    case 'delivery_win': case 'delivery_win_main': return `${moveSan} captures a piece that lets ${partnerName} mate at once.`;
    case 'only_move': return `${moveSan} is the only move.`;
    case 'exposed': case 'veto': case 'no_safe_candidate': return `${moveSan} avoids handing the other team a piece that mates.`;
    case 'voluntary_wait': return `Waits for a piece ${partnerName} is about to capture.`;
    default: return `${moveSan} is its best move here; there was no time left to compare others.`;
  }
}

export class PartnerPanel {
  constructor(private readonly host: PartnerHost, private readonly box: HTMLElement) {
    box.addEventListener('click', (e) => {
      const cell = (e.target as HTMLElement).closest<HTMLElement>('[data-give]');
      if (!cell) return;
      const [color, role] = cell.dataset.give!.split('-') as [Color, HandRole];
      host.give(color, role);
    });
  }

  update() {
    const { host } = this;
    this.box.hidden = !host.active;
    if (!host.active) { this.box.replaceChildren(); return; }
    const parts: HTMLElement[] = [this.valuesTable()];
    if (host.twoBoards) parts.push(...this.partnerNotes());
    this.box.replaceChildren(...parts);
  }

  private valuesTable(): HTMLElement {
    const { host } = this;
    const values = host.values();
    const section = el('div', 'bs-values');
    const head = el('div', 'bs-values-head');
    head.append(el('span', 'bs-values-title', 'One more piece in hand'));
    const note = el('span', 'bs-values-note num');
    if (values) {
      note.textContent = `depth ${values.depth}${values.source === 'partner' ? ` · from ${host.partnerName}’s search` : ''}`;
      note.title = values.source === 'partner'
        ? `Measured by HypeBeast while it searched ${host.partnerName}, to price what captures there send here. The page measures it deeper once the engine is free.`
        : `Measured on ${host.boardName}: the position searched with and without the piece, to depth ${values.depth}.`;
    } else if (host.measuring()) note.append(el('span', 'ch-spinner', ''));
    head.append(note);

    const table = el('table', 'bs-values-table');
    table.title = 'How much better each side stands with one more of the piece in hand, in pawns. Click to add the piece.';
    const header = el('tr', '');
    header.append(el('th', '', ''));
    for (const role of ROLES) {
      const th = el('th', '', role === 'knight' ? 'N' : role[0].toUpperCase());
      th.setAttribute('scope', 'col');
      th.title = capital(role);
      header.append(th);
    }
    const thead = el('thead', '');
    thead.append(header);
    const body = el('tbody', '');
    for (const color of ['white', 'black'] as Color[]) {
      const row = el('tr', color === host.turn ? 'bs-values-turn' : '');
      const label = el('th', 'bs-values-side', capital(color));
      label.setAttribute('scope', 'row');
      if (color === host.turn) label.title = `${capital(color)} to move`;
      row.append(label);
      for (const role of ROLES) row.append(this.cell(color, role, values?.gains[color][role] ?? null, values));
      body.append(row);
    }
    table.append(thead, body);
    section.append(head, table);
    return section;
  }

  private cell(color: Color, role: HandRole, gain: PieceGain, values: PieceValues | undefined): HTMLElement {
    const td = el('td', 'bs-values-cell');
    const button = el('button', 'bs-values-give') as HTMLButtonElement;
    button.type = 'button';
    button.dataset.give = `${color}-${role}`;
    const img = document.createElement('img');
    img.src = pieceSrc(color, role);
    img.alt = '';
    const text = el('span', 'num');
    if (gain === 'mate') { text.textContent = 'Mate'; td.classList.add('bs-values-mate'); }
    else if (gain !== null) text.textContent = pawns(gain);
    else if (!values && this.host.measuring()) text.textContent = '…';
    else text.textContent = '—';
    const worth = gain === 'mate' ? 'mates' : gain === null ? 'not measured' : `${pawns(gain)} for ${color}`;
    button.title = `Give ${color} ${ARTICLE[role]} (${worth})`;
    button.setAttribute('aria-label', button.title);
    button.append(img, text);
    td.append(button);
    return td;
  }

  /** What may arrive from the other board, and why HypeBeast chose its move. */
  private partnerNotes(): HTMLElement[] {
    const { host } = this;
    const result = host.result();
    const out: HTMLElement[] = [];
    if (!result?.done) return out;
    const forecast = result.forecast;
    if (forecast?.worlds.length) {
      const arrives = el('div', 'bs-arrivals');
      arrives.append(el('span', 'bs-values-title', `May arrive from ${host.partnerName}`));
      const list = el('div', 'bs-arrival-list');
      for (const world of forecast.worlds) {
        const chip = el('span', 'bs-arrival');
        chip.append(el('span', '', arrivalText(world.arrival, host.turn)), el('span', 'num', ` ${Math.round(world.p * 100)}%`));
        list.append(chip);
      }
      arrives.append(list);
      const likely = forecast.lines.slice().sort((a, b) => b.weight - a.weight).slice(0, 3)
        .map((l) => `${host.partnerSan(l.move)} ${Math.round(l.weight * 100)}%`);
      if (likely.length) {
        const moves = el('p', 'bs-arrival-moves dim', `Likely next on ${host.partnerName}: ${likely.join(' · ')}`);
        arrives.append(moves);
      }
      out.push(arrives);
    }
    if (result.decision)
      out.push(el('p', 'bs-why', reasonText(result, host.partnerName, result.decision === 'pass' ? '' : host.moveSan(result.decision))));
    return out;
  }
}
