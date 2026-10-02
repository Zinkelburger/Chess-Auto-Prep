import { bughouseExpectimax, type BughouseExpectimaxTables } from '../lib/api';
import type { BoardName } from './boards';

/** Same display transform as the desktop lab: average Q before transforming. */
export function expectedScore(q: number): string {
  const value = 1.8 * Math.tan(1.56 * Math.max(-.9, Math.min(.9, q)));
  return `${value > .005 ? '+' : ''}${Math.abs(value) < .005 ? '0.00' : value.toFixed(2)}`;
}

export class ExpectimaxTables {
  private generation = 0;
  constructor(private readonly container: HTMLElement,
    private readonly play: (board: BoardName, uci: string) => void) {}

  async load(fen: string): Promise<void> {
    const generation = ++this.generation;
    this.container.textContent = 'Loading saved expectimax…';
    try {
      const tables = await bughouseExpectimax(fen);
      if (generation === this.generation) this.render(tables, fen);
    } catch {
      if (generation === this.generation) this.container.textContent = 'Saved expectimax is unavailable. Try again when connected.';
    }
  }

  render(tables: BughouseExpectimaxTables, fen: string): void {
    this.container.replaceChildren();
    const note = document.createElement('p');
    note.className = 'dim';
    note.textContent = 'Expectimax White / Black · no clocks or sitting. Scores from White’s side on each board; partner board fixed.';
    this.container.append(note);
    for (const board of ['A', 'B'] as const) {
      const data = tables[board];
      const title = document.createElement('h3');
      title.textContent = `Board ${board === 'A' ? 1 : 2}`;
      this.container.append(title);
      if (!data) {
        const missing = document.createElement('p'); missing.className = 'dim';
        missing.textContent = 'Not yet in the expectimax database.';
        this.container.append(missing); continue;
      }
      const table = document.createElement('table'); table.className = 'bh-expectimax-table';
      table.setAttribute('aria-label', `Board ${board} expectimax`);
      const header = table.createTHead().insertRow();
      for (const [name, hint] of [
        ['Move', 'Click to play'], ['Played', 'Calibrated CrazyAra policy: a proxy for human moves, not a human-trained model'],
        ['Eval', 'Searched Hivemind evaluation'],
        ['Exp White', 'White chooses best moves; Black follows human probabilities. Higher favours White.'],
        ['Exp Black', 'Black chooses best moves; White follows human probabilities. Lower favours Black.'],
      ]) {
        const th = document.createElement('th'); th.scope = 'col'; th.textContent = name; th.title = hint; header.append(th);
      }
      const body = table.createTBody();
      const white = fen.split('|')[board === 'A' ? 0 : 1].trim().split(/\s+/)[1] === 'w';
      const rows = [...data.rows].sort((a, b) => white ? b.white - a.white : a.black - b.black);
      for (const move of rows) {
        const tr = body.insertRow(); tr.tabIndex = 0;
        tr.title = `${(100 * move.coverage).toFixed(1)}% reply mass expanded · depth ${move.depth ?? 'mate'} · ${move.nodes} nodes`;
        for (const text of [move.san, `${(100 * move.probability).toFixed(1)}%`, expectedScore(move.eval), expectedScore(move.white), expectedScore(move.black)]) {
          tr.insertCell().textContent = text;
        }
        tr.onclick = () => this.play(board, move.uci);
        tr.onkeydown = (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); this.play(board, move.uci); } };
      }
      this.container.append(table);
      const provenance = document.createElement('p'); provenance.className = 'dim';
      provenance.textContent = `${data.plies} plies · ${data.nodes.toLocaleString()} Hivemind nodes per position · best engine move + top 4 policy moves above 1%. CrazyAra is a proxy for human play. Remaining probability keeps the searched value.`;
      this.container.append(provenance);
    }
  }
}
