import os
import argparse

from fen_map_builder import FenMapBuilder
from game_downloader import download_games_for_last_two_months, clear_cache, list_cache
from fen_database_map import FenDatabaseMap

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
    parser.add_argument("--lichess-output", type=str, default="lichess_output.txt",
                        help="Output file for Lichess aggregated stats.")
    parser.add_argument("--top-n", type=int, default=5,
                        help="Show top N worst performing positions (default: 5)")
    parser.add_argument("--detailed-output", action="store_true",
                        help="Output detailed FEN dump instead of user-friendly summary")
    parser.add_argument("--no-cache", action="store_true",
                        help="Skip cache and download fresh games from Chess.com")
    parser.add_argument("--cache-max-age", type=int, default=1,
                        help="Maximum age of cache in days before refreshing (default: 1)")
    parser.add_argument("--clear-cache", action="store_true",
                        help="Clear game cache and exit")
    parser.add_argument("--list-cache", action="store_true",
                        help="List cached games and exit")
    args = parser.parse_args()

    # Handle cache management commands
    if args.clear_cache:
        if args.username and (args.white or args.black):
            user_color = "white" if args.white else "black"
            clear_cache(args.username, user_color)
        else:
            clear_cache()
        return

    if args.list_cache:
        list_cache()
        return

    # Determine if user color is constrained
    if args.white:
        user_is_white = True
        user_color = "white"
    elif args.black:
        user_is_white = False
        user_color = "black"
    else:
        raise ValueError("user_is_white should be defined")

    # 1) Generate or read PGNs.
    pgn_filename = "pgns.pgn"
    if args.generate:
        print("Downloading PGNs...")
        use_cache = not args.no_cache
        pgns = download_games_for_last_two_months(
            args.username,
            user_color=user_color,
            use_cache=use_cache,
            cache_max_age_days=args.cache_max_age
        )
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
    if args.detailed_output:
        fen_builder.output_stats(filename=args.output, min_occurrences=4)
        print(f"FEN stats written to {args.output}.")
    else:
        fen_builder.output_user_friendly_summary(top_n=args.top_n, min_occurrences=4)
        print(f"Top {args.top_n} problematic positions displayed.")

    # 4) Get only the worst performing positions for Lichess query.
    worst_fens = fen_builder.get_worst_performing_positions(top_n=args.top_n, min_occurrences=4)
    if worst_fens:
        print(f"Querying Lichess for {len(worst_fens)} worst performing positions...")

        # 5) Query Lichess and output aggregated stats to a second file.
        fen_db_map = FenDatabaseMap()
        fen_db_map.query_lichess_for_fens(worst_fens, args.lichess_output)
        print(f"Lichess stats written to {args.lichess_output}.")
    else:
        print("No positions found for Lichess query.")

if __name__ == "__main__":
    main()
