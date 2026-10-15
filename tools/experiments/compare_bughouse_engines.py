#!/usr/bin/env python3
"""Fairy-Stockfish pocketknight (the website's /bughouse engine) against Hivemind.

Walks the FICS bughouse book's most-played lines on board A (board B still at
the start) and, for each position, asks three sources for White's or Black's
move on board A:

* FICS: what players chose most often (book play rate and the mover's score).
* Fairy-Stockfish: the site's setup, `pocketknight` with its hand-written
  evaluation, MultiPV 3. It also scores Hivemind's choice with `searchmoves`,
  so a disagreement has a price in centipawns.
* Hivemind: the two-board engine the Bughouse Lab uses, with the move forced
  onto board A (`require_move_on=A`), so it cannot answer by sitting.

The two engines model different games: pocketknight holds the partner board
still (nothing arrives), while Hivemind sees a real partner who may send
pieces. Agreement is expected on ordinary moves, not on everything.

  python3 tools/experiments/compare_bughouse_engines.py --positions 12
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path[:0] = [str(ROOT / 'tools/mcp'), str(ROOT / 'tools')]
import chess  # noqa: E402
from bughouse import analysis  # noqa: E402
from bughouse_db import book  # noqa: E402

START = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1'
FSF = Path(os.environ.get('FAIRY_STOCKFISH', Path.home() / '.local/share/chess-prep/fairy-stockfish/fsf'))


class Fsf:
    """One Fairy-Stockfish process playing pocketknight without a net, as the website does."""

    def __init__(self, path: Path, threads: int):
        self.proc = subprocess.Popen([str(path)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        for line in ['uci', 'setoption name UCI_Variant value pocketknight', 'setoption name Use NNUE value false',
                     f'setoption name Threads value {threads}', 'setoption name Hash value 256']:
            self.send(line)
        self.wait('uciok')
        self.version = self.id

    def send(self, line: str):
        self.proc.stdin.write(line + '\n')

    def wait(self, prefix: str) -> list[str]:
        lines = []
        for line in self.proc.stdout:
            line = line.strip()
            if line.startswith('id name'):
                self.id = line[8:]
            lines.append(line)
            if line.startswith(prefix):
                return lines
        raise RuntimeError('Fairy-Stockfish exited')

    def search(self, fen: str, movetime_ms: int, multipv: int = 1, only: str | None = None) -> list[dict]:
        """Lines best first: uci move, cp (or mate) for the side to move, depth."""
        self.send(f'setoption name MultiPV value {multipv}')
        self.send('ucinewgame')
        self.send(f'position fen {fen}')
        self.send(f'go movetime {movetime_ms}' + (f' searchmoves {only}' if only else ''))
        lines: dict[int, dict] = {}
        for line in self.wait('bestmove'):
            parts = line.split()
            if not line.startswith('info ') or ' pv ' not in line or 'bound' in parts:
                continue
            k = parts.index('multipv') + 1 if 'multipv' in parts else None
            pv = int(parts[k]) if k else 1
            s = parts.index('score')
            kind, value = parts[s + 1], int(parts[s + 2])
            lines[pv] = {'move': parts[parts.index('pv') + 1], 'depth': int(parts[parts.index('depth') + 1]),
                         'cp': value if kind == 'cp' else None, 'mate': value if kind == 'mate' else None}
        return [lines[k] for k in sorted(lines)]

    def close(self):
        self.send('quit')
        self.proc.wait(timeout=10)


def san(fen: str, uci: str) -> str:
    board = chess.variant.CrazyhouseBoard(fen)
    return board.san(chess.Move.from_uci(uci))


def walk(con, count: int, plies: int, width: int, min_games: int) -> list[list[str]]:
    """Lines (SAN on board A) in breadth-first order, the most played first."""
    lines, queue = [], [[]]
    while queue and len(lines) < count:
        line = queue.pop(0)
        dual = analysis.position_from(moves=' '.join(line))
        found = book.explore(con, dual.board('A').fen(), START)
        if found['games'] < min_games:
            continue
        lines.append(line)
        if len(line) < plies:
            moves = [m for m in found['moves'] if m['board'].upper() == 'A'][:width]
            queue.extend(line + [m['san']] for m in moves)
    return lines


def fics_moves(con, fen: str, white: bool) -> tuple[int, list[dict]]:
    found = book.explore(con, fen, START)
    out = []
    # The book tags a move by board and mover: 'A' White on board A, 'a' Black.
    for m in [m for m in found['moves'] if m['board'].upper() == 'A'][:3]:
        decided = m['team_a'] + m['team_b'] + m['draws']
        mine = m['team_a'] if white else m['team_b']
        out.append({'san': m['san'], 'play': m['play_rate'], 'score': 100 * (mine + m['draws'] / 2) / decided if decided else None})
    return found['games'], out


def pawns(line: dict | None) -> str:
    if not line:
        return '?'
    return f"#{line['mate']}" if line['mate'] is not None else f"{line['cp'] / 100:+.2f}"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--positions', type=int, default=12)
    parser.add_argument('--plies', type=int, default=4, help='deepest line, in moves on board A')
    parser.add_argument('--width', type=int, default=2, help='book moves followed from each position')
    parser.add_argument('--min-games', type=int, default=500)
    parser.add_argument('--fsf-ms', type=int, default=3000, help='Fairy-Stockfish time per search')
    parser.add_argument('--fsf-threads', type=int, default=4)
    parser.add_argument('--hm-nodes', type=int, default=3000, help='Hivemind nodes per search')
    parser.add_argument('--json', type=Path, help='also write the rows here')
    args = parser.parse_args()

    con = book.open_book()
    fsf = Fsf(FSF, args.fsf_threads)
    rows = []
    print(f'{fsf.version}, pocketknight, no net, {args.fsf_ms} ms · Hivemind {args.hm_nodes} nodes, move forced on board A\n')
    try:
        for line in walk(con, args.positions, args.plies, args.width, args.min_games):
            dual = analysis.position_from(moves=' '.join(line))
            fen = dual.board('A').fen()
            white = fen.split()[1] == 'w'
            games, fics = fics_moves(con, fen, white)
            started = time.time()
            fsf_lines = fsf.search(fen, args.fsf_ms, multipv=3)
            hm = analysis.analyse(moves=' '.join(line), team='white' if white else 'black', require_move_on='A',
                                  multipv=3, nodes=args.hm_nodes, calibrate=False)
            hm_san = (hm['best'] or {}).get('A')
            hm_uci = None
            if hm_san:
                hm_uci = chess.variant.CrazyhouseBoard(fen).parse_san(hm_san).uci()
            fsf_best = fsf_lines[0] if fsf_lines else None
            # Hivemind's move as Fairy-Stockfish scores it: from the same MultiPV search when it is
            # in the shortlist, else from a search of that move alone.
            priced = next((l for l in fsf_lines if l['move'] == hm_uci), None)
            if hm_uci and priced is None:
                priced = fsf.search(fen, args.fsf_ms, only=hm_uci)[0]
            loss = None
            if fsf_best and priced and fsf_best['cp'] is not None and priced['cp'] is not None:
                loss = fsf_best['cp'] - priced['cp']
            row = {
                'line': ' '.join(line) or '(start)', 'games': games, 'fics': fics,
                'fsf': [{'san': san(fen, l['move']), 'eval': pawns(l), 'depth': l['depth']} for l in fsf_lines],
                'hivemind': hm_san, 'hivemind_lines': list(dict.fromkeys((l['best'] or {}).get('A') for l in hm['lines'])),
                'fsf_on_hivemind': pawns(priced), 'loss_cp': loss, 'seconds': round(time.time() - started, 1),
            }
            rows.append(row)
            agree = '=' if row['fsf'] and row['fsf'][0]['san'] == hm_san else '≠'
            fics_text = '  '.join(f"{m['san']} {m['play']:.0f}%" for m in fics)
            fsf_text = '  '.join(f"{m['san']} {m['eval']}" for m in row['fsf'])
            print(f"{row['line']}  ({games:,} FICS games)")
            print(f"  FICS        {fics_text}")
            print(f"  Fairy-SF    {fsf_text}")
            print(f"  Hivemind {agree}  {hm_san}   (its shortlist: {', '.join(m for m in row['hivemind_lines'] if m)})"
                  f"   Fairy-SF scores it {row['fsf_on_hivemind']}" + (f", {loss / 100:.2f} below its best" if loss and loss > 0 else ''))
            print()
    finally:
        fsf.close()

    same = sum(1 for r in rows if r['fsf'] and r['fsf'][0]['san'] == r['hivemind'])
    fsf_book = sum(1 for r in rows if r['fsf'] and r['fsf'][0]['san'] in {m['san'] for m in r['fics']})
    hm_book = sum(1 for r in rows if r['hivemind'] in {m['san'] for m in r['fics']})
    losses = [max(0, r['loss_cp']) for r in rows if r['loss_cp'] is not None]
    print(f'{len(rows)} positions: same best move {same}; Fairy-SF best in FICS top 3: {fsf_book}; Hivemind best in FICS top 3: {hm_book}')
    if losses:
        print(f'Fairy-SF rates Hivemind\'s move on average {sum(losses) / len(losses) / 100:.2f} below its own (largest {max(losses) / 100:.2f})')
    if args.json:
        args.json.write_text(json.dumps(rows, indent=2) + '\n')
    return 0


if __name__ == '__main__':
    sys.exit(main())
