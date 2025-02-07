import argparse
import chess.pgn
import io
import os
import re
import requests
from datetime import datetime, timedelta
from collections import defaultdict
from dotenv import load_dotenv

# =========== Classes for FenNode and FenMapBuilder ==========

class FenNode:
    def __init__(self):
        self.games = 0
        self.wins = 0
        self.losses = 0
        self.draws = 0

class FenMapBuilder:
    def __init__(self):
        self.fen_map = defaultdict(FenNode)
    
    def process_pgns(self, pgn_list, username, user_is_white):
        """
        Process each PGN from pgn_list and update the FEN statistics.
        If user_is_white is not None, then only games matching that color (as determined
        from the PGN header) are processed.
        """
        for pgn_text in pgn_list:
            game = chess.pgn.read_game(io.StringIO(pgn_text))
            if not game:
                continue

            final_result = game.headers.get("Result", "")
            # Determine the user color for THIS game from the headers.
            game_user_white = (game.headers.get("White", "").lower() == username.lower())
            # If the command-line specified a filter, skip games that don't match.
            if user_is_white is not None and game_user_white != user_is_white:
                continue

            board = game.board()
            positions_seen = set()  # to avoid double counting within the same game

            for move in game.mainline_moves():
                board.push(move)
                fen_full = board.fen()
                piece_placement, side_to_move, castling, en_passant, *_ = fen_full.split()
                fen_key = f"{piece_placement} {side_to_move} {castling} {en_passant}"

                # Only count this position once per game.
                if fen_key not in positions_seen:
                    positions_seen.add(fen_key)
                    self._update_result_for_fen(
                        fen_key,
                        final_result,
                        is_user_white=game_user_white,
                        username=username
                    )

    def _update_result_for_fen(self, fen_key, final_result, is_user_white, username):
        node = self.fen_map[fen_key]
        node.games += 1
        
        # final_result can be '1-0', '0-1', or '1/2-1/2'
        if final_result == "1-0":
            if is_user_white:
                node.wins += 1
            else:
                node.losses += 1
        elif final_result == "0-1":
            if is_user_white:
                node.losses += 1
            else:
                node.wins += 1
        elif final_result == "1/2-1/2":
            node.draws += 1
    
    def output_stats(self, filename):
        with open(filename, "w") as f:
            for fen, stats in self.fen_map.items():
                f.write((
                    f"FEN: {fen}, "
                    f"Games: {stats.games}, "
                    f"Wins: {stats.wins}, "
                    f"Losses: {stats.losses}, "
                    f"Draws: {stats.draws}\n"
                ))

# =========== Download function ==========

def download_games_for_last_two_months(username):
    """
    Downloads games for the last two months from Chess.com (example implementation).
    Excludes bullet games (< 3 minutes main time) and returns a list of PGN strings.
    """
    load_dotenv()
    email = os.getenv('EMAIL') or "my-default-email@example.com"
    
    current_date = datetime.now()
    last_month = current_date - timedelta(days=current_date.day)
    two_months_ago = last_month - timedelta(days=last_month.day)

    headers = {'User-Agent': email}
    collected_pgns = []

    for year, month in [
        (two_months_ago.year, two_months_ago.month),
        (last_month.year, last_month.month),
        (current_date.year, current_date.month)
    ]:
        url = f"https://api.chess.com/pub/player/{username}/games/{year}/{month:02d}/pgn"
        try:
            r = requests.get(url, headers=headers)
            r.raise_for_status()
            raw_pgn = r.text
            
            # Split the PGN file on '[Event ' (keeping the delimiter for each game)
            games = re.split(r'(?=\[Event )', raw_pgn)[1:]
            for g in games:
                # Filter out bullet games using the TimeControl tag.
                time_control_match = re.search(r'\[TimeControl "(\d+)\+(\d+)"\]', g)
                if time_control_match:
                    main_time, inc = map(int, time_control_match.groups())
                    if main_time < 180:
                        continue
                
                # Optionally remove clock times from moves.
                g = re.sub(r' \{\[%clk [^\]]+\]\}', '', g)
                
                collected_pgns.append(g)
        except Exception as e:
            print(f"Error fetching {url}: {e}")

    return collected_pgns

# =========== Main with argparse ==========

def main():
    parser = argparse.ArgumentParser(description="Build FEN stats from PGNs.")
    parser.add_argument("--generate", action="store_true",
                        help="Download the last two months of PGNs from Chess.com.")
    parser.add_argument("--username", type=str, default="BigManArkhangelsk",
                        help="Chess.com username.")
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--white", action="store_true", 
                       help="Filter PGNs: Only process games where the user is White")
    group.add_argument("--black", action="store_true", 
                       help="Filter PGNs: Only process games where the user is Black")
    parser.add_argument("--output", type=str, default="output.txt",
                        help="Output file for FEN stats.")
    args = parser.parse_args()

    # Set user_is_white based on the command-line flag; if neither is specified, no filter is applied.
    user_is_white = None
    if args.white:
        user_is_white = True
    elif args.black:
        user_is_white = False

    # 1) Generate or read PGNs.
    if args.generate:
        print("Downloading PGNs...")
        pgns = download_games_for_last_two_months(args.username)
        with open("pgns.pgn", "w") as f:
            for pgn_text in pgns:
                f.write(pgn_text + "\n\n")
        print("PGNs downloaded and saved to pgns.pgn.")
    else:
        # Read local pgns.pgn file.
        print("Reading existing pgns.pgn file...")
        if not os.path.exists("pgns.pgn"):
            parser.error("No pgns.pgn found. Use --generate first or place PGNs locally.")
        with open("pgns.pgn", "r") as f:
            # Split the file into separate PGN strings.
            pgns = f.read().strip().split("\n\n[Event ")
            if len(pgns) > 1:
                # Reconstruct PGN strings if needed.
                pgns = [pgns[0]] + ["[Event " + chunk for chunk in pgns[1:]]
    
    # 2) Build the FEN map.
    fen_builder = FenMapBuilder()
    fen_builder.process_pgns(pgns, args.username, user_is_white)
    
    # 3) Output the stats.
    fen_builder.output_stats(args.output)
    print(f"FEN stats written to {args.output}.")

if __name__ == "__main__":
    main()
