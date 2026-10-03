import { Chess } from 'chess.js';
import type { Key } from 'chessground/types';
import { TrainerBoard } from '../tactics/board';
import { MAX_PGN_BYTES, moveLabel, readPgn, writePgn } from './pgn';
import { parsePgnAsync } from './pgn-client';
import { workspaceStore } from './storage';
import type { SearchOptions, SearchResult, SearchNode } from './search';
const $ = <T extends HTMLElement = HTMLElement>(id: string) => document.getElementById(id)! as T;
const example = '[Event "Example: Italian and Ruy Lopez"]\n[White "White"]\n[Black "Black"]\n[Result "*"]\n\n1. e4 e5 2. Nf3 Nc6 3. Bc4 {The Italian Game.} (3. Bb5 {The Ruy Lopez.} a6 4. Ba4 Nf6) 3... Bc5 4. c3 Nf6 *';
interface Saved { version: number; pgn: string; game: number; cursor: number; path?: string[]; result?: SearchResult; orientation: 'white' | 'black' }
const errorText = (error: unknown) => error instanceof Error ? error.message : String(error);
export class PrepApp {
  private games = readPgn('*');
  private gameIndex = 0;
  private cursor = 0;
  private orientation: 'white' | 'black' = 'white';
  private board: TrainerBoard;
  private worker: Worker | null = null;
  private busy = false;
  private id = 0;
  private result?: SearchResult;
  private shown = 2000;
  private importId = 0;
  private revision = 0;
  private savedRevision = 0;
  private saveQueue: Promise<void> = Promise.resolve();
  private saveTimer: ReturnType<typeof setTimeout> | undefined;
  constructor() {
    this.board = new TrainerBoard($('prep-board'), { onMove: uci => this.play(uci) });
    this.bind(); this.render(); void this.restore();
    window.addEventListener('beforeunload', event => { if (this.savedRevision !== this.revision || this.busy) { event.preventDefault(); } });
    window.addEventListener('pagehide', () => { this.worker?.terminate(); });
    window.addEventListener('pageshow', event => { if (event.persisted) { this.worker = null; this.setBusy(false); } });
  }
  private get game() { return this.games[this.gameIndex]; }
  private get node() { return this.game.nodes[this.cursor]; }
  private fail(error: unknown) { $('prep-error').textContent = errorText(error); $('prep-error').hidden = false; }
  private clearError() { $('prep-error').hidden = true; }
  private async restore() {
    const revision = this.revision, importId = this.importId;
    try {
      const saved = await workspaceStore('read') as Saved | undefined;
      if (revision !== this.revision || importId !== this.importId) return;
      if (saved?.version === 1) {
        const games = await parsePgnAsync(saved.pgn);
        if (revision !== this.revision || importId !== this.importId) return;
        this.games = games; this.gameIndex = Math.max(0, Math.min(games.length - 1, saved.game || 0));
        this.cursor = Math.max(0, Math.min(this.game.nodes.length - 1, saved.cursor || 0));
        if (saved.path) { this.cursor = 0; for (const uci of saved.path) { const next = this.node.children.find(id => this.game.nodes[id].uci === uci); if (next === undefined) break; this.cursor = next; } }
        this.orientation = saved.orientation === 'black' ? 'black' : 'white';
        if (saved.result?.root && saved.result.options) { this.result = saved.result; this.applyOptions(saved.result.options); }
        $('save-status').textContent = 'Restored from this browser.';
      } else $('save-status').textContent = 'Open a PGN or play moves to begin. No account needed.';
      const fen = new URL(location.href).searchParams.get('fen');
      if (fen) { new Chess(fen); this.games = readPgn(`[SetUp "1"]\n[FEN "${fen}"]\n*`); this.gameIndex = this.cursor = 0; this.changed(); }
      this.render();
    } catch (error) { this.fail(error); $('save-status').textContent = 'Work in this tab; export PGN to keep a copy.'; }
  }
  private async open(text: string) {
    const id = ++this.importId;
    this.clearError();
    try {
      if (new Blob([text]).size > MAX_PGN_BYTES) throw new Error('Open a PGN smaller than 10 MB.');
      const games = await parsePgnAsync(text);
      if (id !== this.importId) return;
      // Accepted imports replace the workspace only after a durable write of the prior one.
      await this.saveNow();
      this.stop(); this.games = games; this.gameIndex = this.cursor = 0; this.shown = 2000;
      this.result = undefined; $('import-panel').removeAttribute('open'); this.changed(); this.render();
    } catch (error) { this.fail(error); }
  }
  private changed() {
    this.revision++; $('save-status').textContent = 'Saving in this browser…';
    clearTimeout(this.saveTimer); this.saveTimer = setTimeout(() => void this.saveNow(), 300);
  }
  private saveNow(): Promise<void> {
    clearTimeout(this.saveTimer);
    const revision = this.revision;
    const path: string[] = [];
    for (let n = this.node; n.parent !== null; n = this.game.nodes[n.parent]) path.unshift(n.uci);
    const saved: Saved = { path, version: 1, pgn: writePgn(this.games), game: this.gameIndex, cursor: this.cursor, orientation: this.orientation, result: this.result };
    this.saveQueue = this.saveQueue.then(async () => {
      try {
        await workspaceStore('write', saved); this.savedRevision = revision;
        if (revision === this.revision) $('save-status').textContent = 'Saved in this browser.';
      } catch (error) { if (revision === this.revision) $('save-status').textContent = errorText(error); }
    });
    return this.saveQueue;
  }
  private bind() {
    $('pgn-file').addEventListener('change', async () => {
      const input = $<HTMLInputElement>('pgn-file'), file = input.files?.[0];
      try { if (file) { if (file.size > MAX_PGN_BYTES) throw new Error('Open a PGN smaller than 10 MB.'); await this.open(await file.text()); } } catch (error) { this.fail(error); }
      input.value = '';
    });
    $('import-pgn').onclick = () => void this.open($<HTMLTextAreaElement>('pgn-text').value);
    $('example-pgn').onclick = () => void this.open(example);
    $('export-pgn').onclick = () => this.download('chess-auto-prep.pgn', writePgn(this.games), 'application/x-chess-pgn');
    $('export-search').onclick = () => this.download('expectimax.json', JSON.stringify(this.result, null, 2), 'application/json');
    $('fen-form').onsubmit = event => {
      event.preventDefault();
      try { const fen = new Chess($<HTMLInputElement>('fen-input').value.trim()).fen(); void this.open(`[SetUp "1"]\n[FEN "${fen}"]\n*`); } catch { this.fail('Invalid FEN. Check the pieces, turn, castling rights and move counters.'); }
    };
    $('move-form').onsubmit = event => { event.preventDefault(); this.play($<HTMLInputElement>('move-input').value.trim()); };
    $('first-move').onclick = () => this.go(0);
    $('previous-move').onclick = () => this.go(this.node.parent ?? 0);
    $('next-move').onclick = () => this.go(this.node.children[0] ?? this.cursor);
    $('last-move').onclick = () => { let id = this.cursor; while (this.game.nodes[id].children.length) id = this.game.nodes[id].children[0]; this.go(id); };
    $('flip-board').onclick = () => { this.orientation = this.orientation === 'white' ? 'black' : 'white'; this.changed(); this.renderPosition(); };
    $('game-filter').oninput = () => this.renderGames();
    $('more-moves').onclick = () => { this.shown += 2000; this.renderMoves(); };
    $('moves-tab').onclick = () => this.tab('moves'); $('search-tab').onclick = () => this.tab('search');
    for (const [i, name] of ['moves', 'search'].entries()) $(name + '-tab').onkeydown = event => {
      if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') { event.preventDefault(); const next = i === 0 ? 'search' : 'moves'; this.tab(next); $(next + '-tab').focus(); }
    };
    $('search-form').onsubmit = event => { event.preventDefault(); void this.run(false); };
    $('resume-search').onclick = () => void this.run(true);
    $('stop-search').onclick = () => this.stop();
    $('analyse-position').onclick = () => void this.run(false, true);
    $('train-pgn').onclick = event => { try { sessionStorage.setItem('cap-tactics-import', writePgn(this.games)); } catch { event.preventDefault(); this.fail('Could not send this PGN to Tactics. Export it and open the file in Tactics instead.'); } };
    window.addEventListener('keydown', event => {
      if ((event.target as HTMLElement).closest('input,textarea,select,button,[contenteditable=true]') || event.ctrlKey || event.metaKey || event.altKey) return;
      const targets: Record<string, string> = { ArrowLeft: 'previous-move', ArrowRight: 'next-move', Home: 'first-move', End: 'last-move' };
      if (targets[event.key]) { event.preventDefault(); $(targets[event.key]).click(); }
    });
    this.tab($('prep').dataset.mode === 'search' ? 'search' : 'moves');
  }
  private download(name: string, text: string, type: string) { const url = URL.createObjectURL(new Blob([text], { type })); const a = document.createElement('a'); a.href = url; a.download = name; a.click(); setTimeout(() => URL.revokeObjectURL(url), 1000); }
  private tab(name: string) {
    for (const panel of ['moves', 'search']) { $(panel + '-panel').hidden = panel !== name; $(panel + '-tab').setAttribute('aria-selected', String(panel === name)); $(panel + '-tab').tabIndex = panel === name ? 0 : -1; }
  }
  private go(id: number) { if (this.busy) this.stop(); this.cursor = id; this.changed(); this.renderPosition(); this.renderMoves(); this.renderResults(); }
  private play(text: string) {
    if (this.busy) { this.renderPosition(); return; }
    try {
      const chess = new Chess(this.node.fen);
      const move = /^[a-h][1-8][a-h][1-8][qrbn]?$/.test(text) ? chess.move({ from: text.slice(0, 2), to: text.slice(2, 4), promotion: text[4] }) : chess.move(text);
      const uci = move.from + move.to + (move.promotion || '');
      let id = this.node.children.find(n => this.game.nodes[n].uci === uci);
      if (id === undefined) {
        if (this.game.nodes.length >= 40000) throw new Error('This game is too large. Start a new PGN.');
        id = this.game.nodes.length;
        this.game.nodes.push({ id, parent: this.cursor, fen: chess.fen(), san: move.san, uci, comments: [], nags: [], children: [] }); this.node.children.push(id);
      }
      this.clearError(); $<HTMLInputElement>('move-input').value = ''; this.go(id);
    } catch { this.fail('That move is not legal here. Use SAN (Nf3, O-O, a8=N) or UCI (g1f3).'); this.renderPosition(); }
  }
  private render() { this.renderGames(); this.renderPosition(); this.renderMoves(); this.renderResults(); }
  private renderGames() {
    const container = $('game-list'); container.replaceChildren();
    const filter = $<HTMLInputElement>('game-filter').value.toLowerCase();
    this.games.forEach((game, i) => {
      if (!Object.values(game.headers).join(' ').toLowerCase().includes(filter)) return;
      const button = document.createElement('button'); button.textContent = `${i + 1}. ${game.headers.White || 'White'} – ${game.headers.Black || 'Black'} · ${game.headers.Event || 'Analysis'}`;
      button.setAttribute('aria-current', String(i === this.gameIndex));
      button.onclick = () => { this.stop(); this.gameIndex = i; this.cursor = 0; this.shown = 2000; this.changed(); this.render(); }; container.append(button);
    });
    if (!container.children.length) container.textContent = 'No games match your search.';
    const h = this.game.headers;
    $('game-title').textContent = `${h.White || 'White'} – ${h.Black || 'Black'}`;
    $('game-details').textContent = [h.Event, h.Date, this.game.result].filter(Boolean).join(' · ');
  }
  private renderPosition() {
    const n = this.node;
    this.board.setPosition(n.fen, n.uci ? [n.uci.slice(0, 2) as Key, n.uci.slice(2, 4) as Key] : undefined);
    this.board.setOrientation(this.orientation); this.board.setInteractive(!this.busy);
    const chess = new Chess(n.fen);
    $('prep-board').setAttribute('aria-label', `Chess position: ${n.fen}`);
    $('position-description').textContent = chess.isCheckmate() ? 'Checkmate.' : chess.isDraw() ? 'Drawn position.' : `${chess.turn() === 'w' ? 'White' : 'Black'} to move${chess.inCheck() ? ' · Check' : ''}`;
    $('position-comment').textContent = n.comments.join('\n');
    $('position-score').textContent = '';
    for (const id of ['first-move', 'previous-move']) $<HTMLButtonElement>(id).disabled = this.cursor === 0;
    for (const id of ['next-move', 'last-move']) $<HTMLButtonElement>(id).disabled = n.children.length === 0;
  }
  private renderMoves() {
    const el = $('move-tree'); el.replaceChildren();
    const pending: (number | string)[] = this.game.nodes[0].children.length ? [this.game.nodes[0].children[0]] : [];
    let count = 0;
    while (pending.length && count < this.shown) {
      const item = pending.pop()!;
      if (typeof item === 'string') { const span = document.createElement('span'); span.className = 'prep-variation'; span.textContent = item; el.append(span); continue; }
      const n = this.game.nodes[item], button = document.createElement('button'); count++;
      button.className = 'move-button'; button.textContent = moveLabel(n, this.game) + (n.nags.length ? ' ' + n.nags.join(' ') : ''); button.dataset.node = String(item);
      button.setAttribute('aria-current', String(item === this.cursor)); button.onclick = () => this.go(item); el.append(button);
      if (n.comments.length) { const text = document.createElement('span'); text.className = 'prep-move-comment'; text.textContent = ' ' + n.comments.join(' ').slice(0, 160) + ' '; el.append(text); }
      if (n.children.length) pending.push(n.children[0]);
      const siblings = this.game.nodes[n.parent!].children;
      if (siblings[0] === item) for (let i = siblings.length - 1; i > 0; i--) pending.push(' ) ', siblings[i], ' ( ');
    }
    if (!el.children.length) el.textContent = 'Play a move on the board, or open a PGN to explore its lines.';
    $('more-moves').hidden = !pending.length;
  }
  private options(): SearchOptions {
    const n = (id: string) => Number($<HTMLInputElement>(id).value);
    return { side: document.querySelector<HTMLInputElement>('input[name=side]:checked')!.value as 'w' | 'b', plies: n('search-plies'), depth: n('search-depth'), elo: n('search-elo'), maxNodes: n('search-nodes'), maxReplies: n('search-replies'), replyMass: n('search-mass') / 100 };
  }
  private applyOptions(o: SearchOptions) {
    for (const [id, value] of Object.entries({ 'search-plies': o.plies, 'search-depth': o.depth, 'search-elo': o.elo, 'search-nodes': o.maxNodes, 'search-replies': o.maxReplies, 'search-mass': o.replyMass * 100 })) $<HTMLInputElement>(id).value = String(value);
    document.querySelector<HTMLInputElement>(`input[name=side][value=${o.side}]`)!.checked = true;
  }
  private setBusy(value: boolean) {
    this.busy = value; $<HTMLFieldSetElement>('search-fields').disabled = value;
    for (const id of ['start-search', 'analyse-position', 'resume-search']) $<HTMLButtonElement>(id).disabled = value;
    $<HTMLButtonElement>('stop-search').disabled = !value;
    $<HTMLInputElement>('move-input').disabled = value; this.board.setInteractive(!value);
  }
  private stop() { if (this.busy) { this.worker?.postMessage({ action: 'stop' }); $('search-status').textContent = 'Stopping after the current operation…'; } }
  private async run(resume: boolean, evaluation = false) {
    if (this.busy || !$<HTMLFormElement>('search-form').reportValidity()) return;
    this.clearError();
    if (!this.worker) {
      this.worker = new Worker(new URL('./analysis.worker.ts', import.meta.url), { type: 'module' });
      this.worker.onmessage = event => {
        const data = event.data; if (data.id !== this.id) return;
        if (data.status) $('search-status').textContent = data.status;
        if (data.progress || data.result) { this.result = data.result || { ...data.progress, reason: 'stopped' }; this.changed(); this.renderResults(); }
        if (data.evaluation && data.evaluation.fen === this.node.fen) {
          const cp = data.evaluation.cp * (this.node.fen.split(' ')[1] === 'w' ? 1 : -1);
          $('position-score').textContent = `${Math.abs(cp) > 9000 ? (cp > 0 ? 'White has mate' : 'Black has mate') : (cp >= 0 ? '+' : '') + (cp / 100).toFixed(2)} · depth ${data.evaluation.depth}`;
          $('search-status').textContent = 'Position analysis complete. Scores are from White’s perspective.';
        }
        if (data.error) { this.fail(data.error); $('search-status').textContent = data.error; }
        if (data.done) { this.setBusy(false); if (this.result) this.renderResults(); void this.saveNow(); }
      };
      this.worker.onerror = () => { this.fail('Analysis stopped unexpectedly. Your PGN is kept. Retry the search.'); this.worker?.terminate(); this.worker = null; this.setBusy(false); };
    }
    const options = this.options();
    if (!resume && !evaluation) this.result = undefined;
    this.setBusy(true); this.renderResults();
    this.worker.postMessage({ action: evaluation ? 'evaluate' : 'search', id: ++this.id, fen: this.node.fen, options, seed: resume ? this.result : undefined });
  }
  private renderResults() {
    const el = $('search-results'); el.replaceChildren();
    $('resume-search').hidden = !this.result || this.result.reason === 'complete' || this.result.root.fen !== this.node.fen;
    $('export-search').hidden = !this.result;
    if (!this.result) return;
    const r = this.result;
    $('search-status').textContent = `${this.busy ? 'Searching' : r.reason === 'complete' ? 'Complete within the selected limits' : r.reason === 'budget' ? 'Position budget reached · partial result' : 'Stopped · partial result'} · ${r.nodes} positions · ${r.expanded} expanded`;
    if (r.root.fen !== this.node.fen) {
      const p = document.createElement('p'); p.className = 'dim'; p.textContent = 'Saved results belong to another position.';
      const button = document.createElement('button'); button.className = 'btn btn-text'; button.textContent = 'Return to search position';
      button.onclick = () => {
        for (let i = 0; i < this.games.length; i++) { const n = this.games[i].nodes.find(n => n.fen === r.root.fen); if (n) { this.gameIndex = i; this.go(n.id); this.renderGames(); return; } }
        this.fail('This search belongs to a previously opened PGN. Export its JSON to keep it.');
      }; el.append(p, button); return;
    }
    const table = document.createElement('table'); table.className = 'prep-results-table';
    const caption = table.createCaption(); caption.textContent = `Expected score for ${r.options.side === 'w' ? 'White' : 'Black'}: ${r.root.value.toFixed(3)} · ${r.options.plies} plies · depth ${r.options.depth} · Maia ${r.options.elo}`;
    const row = table.createTHead().insertRow();
    for (const title of ['Move', 'Expected', 'Engine', 'Reply share']) { const th = document.createElement('th'); th.textContent = title; th.scope = 'col'; row.append(th); }
    const body = table.createTBody(), ours = r.root.fen.split(' ')[1] === r.options.side;
    const children = [...r.root.children].sort((a, b) => ours ? b.value - a.value : b.probability - a.probability);
    for (const child of children) {
      const tr = body.insertRow(), button = document.createElement('button'); button.className = 'move-button'; button.textContent = child.san; button.disabled = this.busy; button.onclick = () => this.play(child.uci); tr.insertCell().append(button);
      tr.insertCell().textContent = child.value.toFixed(3); tr.insertCell().textContent = this.cp(child);
      tr.insertCell().textContent = ours ? '—' : `${(child.probability * 100).toFixed(1)}%`;
    }
    el.append(table);
    if (r.reason === 'budget') { const p = document.createElement('p'); p.className = 'prep-help'; p.textContent = 'Increase the position budget and resume, or reduce the look-ahead and start a new search.'; el.append(p); }
  }
  private cp(node: SearchNode) { return Math.abs(node.cp) > 9000 ? (node.cp > 0 ? 'Mate' : '−Mate') : `${node.cp >= 0 ? '+' : ''}${(node.cp / 100).toFixed(2)}`; }
}
