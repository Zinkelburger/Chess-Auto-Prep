import os
import argparse

from fen_map_builder import FenMapBuilder
from game_downloader import download_games_for_last_two_months


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

    # Determine if user color is constrained
    if args.white:
        user_is_white = True
    elif args.black:
        user_is_white = False
    else:
        raise ValueError("user_is_white should be defined")

    # 1) Generate or read PGNs.
    pgn_filename = "pgns.pgn"
    if args.generate:
        print("Downloading PGNs...")
        pgns = download_games_for_last_two_months(args.username)
        with open(pgn_filename, "w", encoding="utf-8") as f:
            for pgn_text in pgns:
                f.write(pgn_text + "\n\n")
        print(f"PGNs downloaded and saved to {pgn_filename}.")
    else:
        print(f"Reading existing {pgn_filename} file...")
        if not os.path.exists(pgn_filename):
            parser.error(f"No {pgn_filename} found. Use --generate first or place PGNs locally.")
        with open(pgn_filename, "r", encoding="utf-8") as f:
            raw_data = f.read().strip()
            # Split the file into separate PGN strings.
            if "[Event " in raw_data:
                pgns = raw_data.split("\n\n[Event ")
                # Reconstruct PGN strings if needed
                if len(pgns) > 1:
                    pgns = [pgns[0]] + ["[Event " + chunk for chunk in pgns[1:]]
            else:
                # In case there's no "[Event " at all
                pgns = [raw_data]

    # 2) Build the FEN map.
    fen_builder = FenMapBuilder()
    fen_builder.process_pgns(pgns, args.username, user_is_white)
    
    # 3) Output the stats.
    fen_builder.output_stats(filename=args.output, min_occurrences=4)
    print(f"FEN stats written to {args.output}.")


if __name__ == "__main__":
    main()
