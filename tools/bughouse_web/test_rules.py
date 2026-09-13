"""Compare the shipped WASM rules with the existing python-chess bughouse model.

Run via scripts/ci.sh with -- python3 tools/bughouse_web/test_rules.py.
Only this development check uses python-chess; deployment does not.
"""

import json
from pathlib import Path
import random
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/mcp/bughouse"))
from board import DualBoard, START_FEN  # noqa: E402
from chess.variant import CrazyhouseBoard  # noqa: E402


def main():
    fixtures = []
    expected = []

    def capture(fen, moves):
        board = DualBoard.from_dual_fen(fen or START_FEN)
        for token in moves:
            which, move = token.split(":", 1)
            board.push(which, move)
        fixtures.append({"fen": fen, "moves": " ".join(moves)})
        expected.append(board)

    capture("", [])
    capture("", ["A:e4", "A:a6", "A:e5", "A:d5", "A:exd6", "B:e4", "B:P@e6"])
    capture(f"r3k2r/8/8/8/8/8/8/R3K2R[] w KQkq - 0 1|{START_FEN}", [])
    capture(f"r3k2r/8/8/8/8/8/8/R3K2R[] w KQkq - 0 1|{START_FEN}", ["A:O-O", "A:O-O-O"])
    # Captured promoted queen becomes a partner pawn, never a queen.
    capture(f"1r5k/P7/8/8/8/8/8/7K[] w - - 0 1|{START_FEN}", ["A:a8=Q", "A:Rxa8"])
    capture(f"7k/8/8/8/8/8/8/K7[PNBRQpnbrq] w - - 0 1|{START_FEN}", [])
    capture(f"k3r3/8/8/8/8/8/8/4K3[N] w - - 0 1|{START_FEN}", [])
    for promotion in "nbrq":
        capture(f"7k/P7/8/8/8/8/8/7K[] w - - 0 1|{START_FEN}", [f"A:a7a8{promotion}"])

    rng = random.Random(613)
    for _ in range(3):
        board = DualBoard()
        moves = []
        for _ in range(80):
            which = rng.randrange(2)
            legal = list(board.boards[which].legal_moves)
            if not legal:
                continue
            move = rng.choice(legal).uci()
            board.push("AB"[which], move)
            moves.append(f"{'AB'[which]}:{move}")
            capture("", moves)

    invalid = [
        "invalid", "8/8/8/8/8/8/8/8[] w - - 0 1",
        "7k/8/8/8/8/8/8/K7[K] w - - 0 1",
        "7k/8/8/8/8/8/8/K7[] w K - 0 1",
        "7k/8/8/8/8/8/8/K7[] w - a6 0 1",  # Phantom en passant.
        "7k/8/8/8/8/8/8/K6P[] w - - 0 1",
        "7k/8/8/8/8/8/8/6K1[] w - - 0 0",
        "7k/8/8/8/8/8/8/6Kk[] w - - 0 1",
        "7k/8/8/8/8/8/8/6K~1[] w - - 0 1",
    ]
    fixtures += [{"fen": fen, "moves": ""} for fen in invalid]
    fixtures.append({"fen": "", "moves": "A:e2e5"})
    js = """
import fs from 'node:fs';
import create from './python/twic-position-finder/frontend/public/bughouse-engine/hivemind.mjs';
const engine = await create();
engine.ccall('bh_init', null, [], []);
const fixtures = JSON.parse(fs.readFileSync(0, 'utf8'));
const answers = fixtures.map(({fen, moves}) => JSON.parse(engine.ccall(
  'bh_position', 'string', ['string', 'string', 'number'], [fen, moves, 0])));
// A rejected position must not corrupt the reusable module.
answers.push(JSON.parse(engine.ccall('bh_position', 'string', ['string', 'string', 'number'], ['', '', 0])));
console.log(JSON.stringify(answers));
"""
    output = subprocess.check_output(["node", "--input-type=module", "-e", js],
                                     input=json.dumps(fixtures), text=True, cwd=ROOT)
    actual = json.loads(output)
    for index, reference in enumerate(expected):
        result = actual[index]
        assert "error" not in result, (fixtures[index], result)
        for which, name in enumerate("AB"):
            wanted = reference.boards[which]
            got = result["boards"][name]
            parsed = CrazyhouseBoard(got["fen"])
            assert parsed.board_fen() == wanted.board_fen(), (index, name, got["fen"], wanted.fen())
            assert parsed.turn == wanted.turn and parsed.castling_rights == wanted.castling_rights
            assert {m["uci"] for m in got["legal_moves"]} == {m.uci() for m in wanted.legal_moves}, (index, name)
            for colour in [True, False]:
                assert sorted(str(parsed.pockets[colour])) == sorted(str(wanted.pockets[colour])), (index, name)
    assert all("error" in result for result in actual[len(expected):-1])
    assert len(actual[-1]["boards"]["A"]["legal_moves"]) == 20
    print(f"WASM rules passed: {len(expected)} two-board positions agree with python-chess; "
          f"{len(invalid) + 1} invalid inputs rejected; recovery passed. "
          "Includes cross-board captures, drops, en passant, castling and promoted captures.")


if __name__ == "__main__":
    main()
