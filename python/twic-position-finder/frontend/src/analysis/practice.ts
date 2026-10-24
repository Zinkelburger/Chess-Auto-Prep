/**
 * Lichess's "Practice with computer" (lila ui/analyse/src/practice): you
 * play the side at the bottom of the board, the engine answers after about
 * 600,000 nodes, and each of your moves gets a verdict with the move the
 * engine preferred. Hands can still be edited: the engine plays on from
 * whatever position is on the board.
 */
import type { DrawShape } from '@lichess-org/chessground/draw';
import type { Key } from '@lichess-org/chessground/types';
import type { Color } from 'chessops/types';
import { makeUci } from 'chessops/util';
import type { EngineResult } from './engine';
import { VERDICT_TEXT, verdict, type Verdict } from './judge';
import { el } from './moves';
import { moveShapes } from './shapes';
import { positionOf, readMove, sanLine, type Tree, type TreeNode } from './tree';

/** Lichess's casual practice strength. */
export const PRACTICE_NODES = 600_000;

export interface PracticeHost {
  readonly tree: Tree;
  readonly current: TreeNode;
  evalOf(fen: string): EngineResult | undefined;
  playUci(uci: string): void;
  goTo(node: TreeNode): void;
  /** Redraw the board's arrows and the practice box. */
  changed(): void;
  /** Redraw the board's arrows only. */
  shapesChanged(): void;
  stop(): void;
}

interface Comment { node: TreeNode; parent: TreeNode; verdict: Verdict; best?: { uci: string; san: string } }

export class Practice {
  running = true;
  private comment: Comment | null = null;
  private hinting: { mode: 'piece' | 'move'; uci: string } | null = null;
  private hoverBest = false;
  private played = false;

  constructor(private readonly host: PracticeHost, readonly player: Color, private readonly box: HTMLElement) {}

  private turn(): Color { return positionOf(this.host.current.fen).turn; }
  isMyTurn(): boolean { return this.turn() === this.player; }

  private commentable(result: EngineResult | undefined): boolean {
    return !!result && (result.done || result.nodes >= PRACTICE_NODES / 2);
  }

  private playable(result: EngineResult | undefined): boolean {
    return !!result && (result.done || result.nodes >= PRACTICE_NODES);
  }

  /** The engine reported on the current position, or the position changed. */
  check() {
    const node = this.host.current;
    if (!this.running) { this.comment = null; this.host.changed(); return; }
    const pos = positionOf(node.fen);
    if (pos.isEnd()) { this.host.changed(); return; }
    const result = this.host.evalOf(node.fen);
    if (this.isMyTurn()) {
      if (this.hinting && result?.lines[0]?.pv[0]) this.hinting.uci = result.lines[0].pv[0];
      this.host.changed();
      return;
    }
    this.comment = null;
    const parent = this.host.tree.parent(node.id);
    if (node.uci && parent && this.commentable(result)) {
      const before = this.commentable(this.host.evalOf(parent.fen)) ? parent : this.host.tree.parent(parent.id);
      if (before && this.commentable(this.host.evalOf(before.fen))) this.comment = this.makeComment(before, node, parent);
    }
    if (!this.played && this.playable(result)) {
      this.played = true;
      this.host.playUci(result!.lines[0].pv[0]);
      return;
    }
    this.host.changed();
  }

  private makeComment(before: TreeNode, node: TreeNode, parent: TreeNode): Comment {
    const prior = this.host.evalOf(before.fen)!.lines[0];
    const after = this.host.evalOf(node.fen)!.lines[0];
    const outcome = positionOf(node.fen);
    if (outcome.isCheckmate()) return { node, parent, verdict: 'goodMove' };
    const scoreAfter = outcome.isEnd() ? { cp: 0 } : after;
    // Lichess compares with the position before the move; when that was not searched long enough, with the one before it.
    const bestMove = prior.pv[0] ? readMove(positionOf(before.fen), prior.pv[0]) : undefined;
    if (!bestMove || makeUci(bestMove) === node.uci) return { node, parent, verdict: 'goodMove' };
    const best = before === parent ? { uci: prior.pv[0], san: sanLine(before.fen, [prior.pv[0]])[0] } : undefined;
    return { node, parent, verdict: verdict(this.player, prior, scoreAfter), best };
  }

  /** The position changed by a move or by browsing. */
  jumped(byUser: boolean, from: TreeNode, to: TreeNode) {
    this.played = false;
    this.hinting = null;
    if (byUser && from !== to) {
      this.running = false;
      this.comment = null;
      if (this.isMyTurn()) this.running = true;
    }
    this.check();
  }

  /** A move made on the board. */
  userMoved() { this.running = true; }

  resume() { this.running = true; this.check(); }

  shapes(): DrawShape[] {
    const color = this.turn();
    if (this.hoverBest && this.comment?.best) return moveShapes(positionOf(this.comment.parent.fen).turn, this.comment.best.uci, 'green');
    const hint = this.hinting;
    if (!hint) return [];
    if (hint.mode === 'move') return moveShapes(color, hint.uci, 'paleBlue');
    return [{ orig: (hint.uci[1] === '@' ? hint.uci.slice(2, 4) : hint.uci.slice(0, 2)) as Key, brush: 'paleBlue' }];
  }

  private hint() {
    const best = this.host.evalOf(this.host.current.fen)?.lines[0]?.pv[0];
    const prev = this.hinting;
    this.hinting = !best || prev?.mode === 'move' ? null : { mode: prev ? 'move' : 'piece', uci: best };
    this.host.changed();
  }

  private playBest() {
    const c = this.comment;
    if (!c?.best) return;
    this.hoverBest = false;
    this.host.goTo(c.parent);
    this.running = true;
    this.host.playUci(c.best.uci);
  }

  render() {
    const node = this.host.current;
    const pos = positionOf(node.fen);
    const head = el('div', 'ch-practice-head');
    const close = el('button', 'ch-icon ch-practice-close', '×') as HTMLButtonElement;
    close.type = 'button';
    close.title = 'Stop practising';
    close.setAttribute('aria-label', 'Stop practising');
    close.onclick = () => this.host.stop();
    head.append(el('strong', '', 'Practice with computer'), el('span', 'ch-practice-strength', 'Casual · 600k nodes'), close);

    const feedback = el('div', 'ch-practice-feedback');
    const king = (color: Color) => { const i = document.createElement('img'); i.src = `/piece/${color === 'white' ? 'w' : 'b'}K.svg`; i.alt = ''; i.className = 'ch-practice-king'; return i; };
    const action = (text: string, onClick: () => void) => { const b = el('button', 'ch-link', text) as HTMLButtonElement; b.type = 'button'; b.onclick = onClick; return b; };
    if (pos.isEnd()) {
      const mate = pos.isCheckmate();
      const winner: Color = pos.turn === 'white' ? 'black' : 'white';
      feedback.append(mate ? king(winner) : el('span', 'ch-practice-icon', '½'),
        el('div', 'ch-practice-text', mate ? `Checkmate. ${winner === 'white' ? 'White' : 'Black'} wins.` : 'Stalemate. The game is a draw.'));
    } else if (!this.running) {
      const text = el('div', 'ch-practice-text');
      text.append(el('strong', '', 'You browsed away'), action('Resume practice', () => this.resume()));
      feedback.append(el('span', 'ch-practice-icon', '!'), text);
    } else {
      const text = el('div', 'ch-practice-text');
      if (this.isMyTurn()) {
        text.append(el('strong', '', 'Your turn'));
        text.append(action(this.hinting ? (this.hinting.mode === 'piece' ? 'See best move' : 'Hide best move') : 'Get a hint', () => this.hint()));
      } else text.append(el('strong', '', 'Computer thinking…'));
      feedback.append(king(pos.turn), text);
    }

    const comment = el('div', 'ch-practice-comment');
    const c = this.running ? this.comment : null;
    if (c) {
      comment.classList.add(`ch-verdict-${c.verdict}`);
      comment.append(el('span', 'ch-verdict', VERDICT_TEXT[c.verdict] + (c.best ? '. ' : '')));
      if (c.best) {
        comment.append(document.createTextNode(c.verdict === 'goodMove' ? 'Another was ' : 'Best was '));
        const b = el('button', 'ch-link ch-practice-best', c.best.san) as HTMLButtonElement;
        b.type = 'button';
        b.onclick = () => this.playBest();
        b.onmouseenter = () => { this.hoverBest = true; this.host.shapesChanged(); };
        b.onmouseleave = () => { this.hoverBest = false; this.host.shapesChanged(); };
        comment.append(b);
      }
    }
    this.box.replaceChildren(head, feedback, comment);
  }
}
