"""Query the position database by FEN, player, site, and other filters."""

import json
from pathlib import Path

import chess

from models import get_db, signed_zobrist, build_game_filters


def _strip_move_counters(fen: str) -> str:
    """Return FEN with halfmove clock and fullmove number removed (for comparison)."""
    parts = fen.split()
    return " ".join(parts[:4])


def find_games(db, fen: str, *, white: str | None = None,
               black: str | None = None, player: str | None = None,
               exclude_site: str | None = None, site: str | None = None,
               min_elo: int | None = None, eco: str | None = None,
               twic_number: int | None = None,
               limit: int = 100) -> list[dict]:
    """Find games whose mainline passes through the given FEN position.

    Returns a list of game dicts with an extra 'match_ply' field.
    """
    board = chess.Board(fen)
    target_hash = signed_zobrist(board)
    target_fen_prefix = _strip_move_counters(board.fen())

    sql = """
        SELECT g.*, p.ply AS match_ply, p.fen AS match_fen
        FROM positions p
        JOIN games g ON g.id = p.game_id
        WHERE p.zobrist_hash = ?
    """
    params: list = [target_hash]

    clauses, filter_params = build_game_filters(
        white=white, black=black, player=player, exclude_site=exclude_site,
        site=site, min_elo=min_elo, eco=eco, twic_number=twic_number,
    )
    for clause in clauses:
        sql += f" AND {clause}"
    params.extend(filter_params)

    # Over-fetch to account for post-query Zobrist collision filtering
    sql += " LIMIT ?"
    params.append(limit * 2)

    rows = db.execute(sql, params).fetchall()

    results = []
    for row in rows:
        if _strip_move_counters(row["match_fen"]) != target_fen_prefix:
            continue
        results.append(dict(row))
        if len(results) >= limit:
            break

    return results


def move_tree(db, fen: str, **filters) -> dict:
    """Build an opening-explorer-style move tree from the given position.

    Returns a dict mapping each continuation move (UCI) to:
      - count: number of games
      - white_wins / draws / black_wins
      - sample_games: list of (white, black, result, game_id)
    """
    board = chess.Board(fen)
    target_hash = signed_zobrist(board)

    sql = """
        SELECT next_p.move_uci,
               g.white, g.black, g.result, g.id AS game_id,
               g.white_elo, g.black_elo
        FROM positions cur_p
        JOIN positions next_p
            ON next_p.game_id = cur_p.game_id
           AND next_p.ply = cur_p.ply + 1
        JOIN games g ON g.id = cur_p.game_id
        WHERE cur_p.zobrist_hash = ?
    """
    params: list = [target_hash]

    clauses, filter_params = build_game_filters(**filters)
    for clause in clauses:
        sql += f" AND {clause}"
    params.extend(filter_params)

    sql += " LIMIT 10000"

    rows = db.execute(sql, params).fetchall()

    tree: dict = {}
    for row in rows:
        move = row["move_uci"]
        if move not in tree:
            tree[move] = {
                "count": 0, "white_wins": 0, "draws": 0, "black_wins": 0,
                "sample_games": [],
            }
        node = tree[move]
        node["count"] += 1
        result = row["result"]
        if result == "1-0":
            node["white_wins"] += 1
        elif result == "0-1":
            node["black_wins"] += 1
        elif result == "1/2-1/2":
            node["draws"] += 1
        if len(node["sample_games"]) < 5:
            node["sample_games"].append({
                "white": row["white"], "black": row["black"],
                "result": result, "game_id": row["game_id"],
            })

    # Convert move UCI to SAN for readability
    for move_uci in list(tree.keys()):
        try:
            move_obj = board.parse_uci(move_uci)
            san = board.san(move_obj)
            tree[move_uci]["san"] = san
        except (ValueError, chess.InvalidMoveError):
            tree[move_uci]["san"] = move_uci

    return dict(sorted(tree.items(), key=lambda x: -x[1]["count"]))


def _print_games(games: list[dict]):
    if not games:
        print("No games found.")
        return
    print(f"\n{'='*70}")
    print(f"Found {len(games)} game(s)\n")
    for g in games:
        elo_w = f" ({g['white_elo']})" if g['white_elo'] else ""
        elo_b = f" ({g['black_elo']})" if g['black_elo'] else ""
        print(f"  {g['white']}{elo_w} vs {g['black']}{elo_b}  {g['result']}")
        print(f"    {g['event']}  |  {g['site']}  |  {g['date']}")
        print(f"    Position reached at ply {g['match_ply']}  |  ECO: {g.get('eco', '?')}")
        print()


def _print_tree(tree: dict, fen: str):
    if not tree:
        print("No continuations found from this position.")
        return

    total = sum(n["count"] for n in tree.values())
    board = chess.Board(fen)
    side = "White" if board.turn == chess.WHITE else "Black"

    print(f"\n{'='*70}")
    print(f"Position: {fen}")
    print(f"{side} to move  |  {total} game(s) reach this position\n")
    print(f"  {'Move':<10} {'Games':>6} {'%':>6}   {'W':>5} {'D':>5} {'B':>5}   Sample")
    print(f"  {'-'*10} {'-'*6} {'-'*6}   {'-'*5} {'-'*5} {'-'*5}   {'-'*20}")

    for move_uci, node in tree.items():
        san = node.get("san", move_uci)
        pct = 100 * node["count"] / total if total else 0
        w_pct = 100 * node["white_wins"] / node["count"] if node["count"] else 0
        d_pct = 100 * node["draws"] / node["count"] if node["count"] else 0
        b_pct = 100 * node["black_wins"] / node["count"] if node["count"] else 0
        sample = node["sample_games"][0] if node["sample_games"] else {}
        sample_str = f"{sample.get('white', '?')} vs {sample.get('black', '?')}" if sample else ""
        print(f"  {san:<10} {node['count']:>6} {pct:>5.1f}%   {w_pct:>4.0f}% {d_pct:>4.0f}% {b_pct:>4.0f}%   {sample_str}")

    print()


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Query TWIC position database")
    parser.add_argument("fen", help="FEN string of the position to search for")
    parser.add_argument("--db", type=Path, default=Path(__file__).parent / "positions.db")
    parser.add_argument("--tree", action="store_true",
                        help="Show opening-explorer-style move tree")
    parser.add_argument("--white", help="Filter by white player name (substring)")
    parser.add_argument("--black", help="Filter by black player name (substring)")
    parser.add_argument("--player", help="Filter by player name on either side")
    parser.add_argument("--exclude-site", help="Exclude games from this site")
    parser.add_argument("--site", help="Only include games from this site")
    parser.add_argument("--min-elo", type=int, help="Minimum Elo of either player")
    parser.add_argument("--eco", help="Filter by ECO code prefix (e.g. 'B90')")
    parser.add_argument("--limit", type=int, default=100)
    parser.add_argument("--json", action="store_true", help="Output JSON")
    args = parser.parse_args()

    db = get_db(args.db)
    filter_kwargs = {
        k: v for k, v in {
            "white": args.white, "black": args.black, "player": args.player,
            "exclude_site": args.exclude_site, "site": args.site,
            "min_elo": args.min_elo, "eco": args.eco,
        }.items() if v is not None
    }

    if args.tree:
        result = move_tree(db, args.fen, **filter_kwargs)
        if args.json:
            print(json.dumps(result, indent=2))
        else:
            _print_tree(result, args.fen)
    else:
        games = find_games(db, args.fen, limit=args.limit, **filter_kwargs)
        if args.json:
            safe = [{k: v for k, v in g.items() if k != "pgn_text"} for g in games]
            print(json.dumps(safe, indent=2))
        else:
            _print_games(games)

    db.close()
