"""Parse PGN files and index every position via Zobrist hashing into SQLite."""

import time
from pathlib import Path

import chess
import chess.pgn

from models import get_db, insert_game, insert_positions_batch, highest_twic_number, signed_zobrist
from downloader import download_latest, download_twic, parse_twic_number, DEFAULT_FIRST_TWIC


def _game_to_pgn_text(game: chess.pgn.Game) -> str:
    exporter = chess.pgn.StringExporter(headers=True, variations=False, comments=False)
    return game.accept(exporter)


def ingest_pgn(db, pgn_path: Path, twic_number: int | None = None) -> int:
    """Parse a PGN file and insert all games + positions into the database.

    Returns the number of games ingested.
    """
    source = pgn_path.name
    count = 0
    errors = 0
    t0 = time.time()

    with open(pgn_path, encoding="utf-8", errors="replace") as f:
        while True:
            try:
                game = chess.pgn.read_game(f)
            except Exception as e:
                errors += 1
                if errors <= 5:
                    print(f"  Warning: parse error: {e}")
                continue

            if game is None:
                break

            headers = dict(game.headers)
            pgn_text = _game_to_pgn_text(game)
            game_id = insert_game(db, headers, pgn_text, source, twic_number)

            board = game.board()
            positions = [
                (game_id, 0, signed_zobrist(board), board.fen(), None)
            ]

            for ply, move in enumerate(game.mainline_moves(), start=1):
                board.push(move)
                positions.append((
                    game_id,
                    ply,
                    signed_zobrist(board),
                    board.fen(),
                    move.uci(),
                ))

            insert_positions_batch(db, positions)
            count += 1

            if count % 500 == 0:
                db.commit()
                elapsed = time.time() - t0
                rate = count / elapsed
                print(f"  {count} games indexed ({rate:.0f} games/sec)")

    db.commit()
    elapsed = time.time() - t0
    print(f"  Done: {count} games from {source} in {elapsed:.1f}s"
          + (f" ({errors} parse errors)" if errors else ""))
    return count


def ingest_file(db_path: Path, pgn_path: Path, twic_number: int | None = None):
    """Ingest a single PGN file."""
    if twic_number is None:
        twic_number = parse_twic_number(pgn_path.name)

    db = get_db(db_path)
    if twic_number is not None:
        existing = db.execute(
            "SELECT COUNT(*) FROM games WHERE twic_number = ?", (twic_number,)
        ).fetchone()[0]
        if existing > 0:
            print(f"TWIC #{twic_number} already ingested ({existing} games), skipping.")
            db.close()
            return

    print(f"Ingesting {pgn_path.name} ...")
    ingest_pgn(db, pgn_path, twic_number)
    db.close()


def ingest_latest(db_path: Path, start_from: int | None = None) -> list[int]:
    """Download and ingest all new TWIC issues since the last ingested one.

    Returns the list of TWIC issue numbers that were ingested.
    """
    db = get_db(db_path)
    if start_from is None:
        last = highest_twic_number(db)
        start_from = (last + 1) if last else DEFAULT_FIRST_TWIC
    db.close()

    print(f"Checking for new TWIC issues starting from #{start_from} ...")
    downloaded = download_latest(start_from)

    if not downloaded:
        print("No new issues to ingest.")
        return []

    ingested: list[int] = []
    for twic_num, pgn_path in downloaded:
        ingest_file(db_path, pgn_path, twic_num)
        ingested.append(twic_num)

    print(f"\nIngested {len(ingested)} new TWIC issue(s).")
    return ingested


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Ingest TWIC PGN files into position DB")
    parser.add_argument("pgn", nargs="?", type=Path,
                        help="Path to a PGN file to ingest (omit to auto-download latest)")
    parser.add_argument("--db", type=Path, default=Path(__file__).parent / "positions.db",
                        help="Path to SQLite database")
    parser.add_argument("--twic", type=int, default=None,
                        help="TWIC issue number (auto-detected from filename if omitted)")
    parser.add_argument("--from", dest="start", type=int, default=None,
                        help="Start auto-download from this TWIC number")
    args = parser.parse_args()

    if args.pgn:
        ingest_file(args.db, args.pgn, args.twic)
    else:
        ingest_latest(args.db, args.start)
