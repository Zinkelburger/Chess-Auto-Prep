import io
import chess.pgn
import chess
import re
from collections import defaultdict
from typing import Optional, List, Set, Tuple

from scripts.fen_node import FenNode


class FenMapBuilder:
    """
    Builds a mapping of FEN positions (key) to FenNode (aggregate stats).
    """

    def __init__(self):
        self.fen_map = defaultdict(FenNode)
    
    def process_pgns(self, pgn_list: List[str], username: str, user_is_white: bool = True) -> None:
        """
        Process each PGN in pgn_list and update the FEN statistics.
        If user_is_white is True/False, then only process games where the user color
        matches that filter. (True=White, False=Black). If None, process all.
        """
        username_lower = username.lower()

        for pgn_text in pgn_list:
            game = chess.pgn.read_game(io.StringIO(pgn_text))
            if not game:
                continue

            final_result = game.headers.get("Result", "")
            # Determine the user color for this game from the headers.
            game_user_white = (game.headers.get("White", "").lower() == username_lower)

            if user_is_white != game_user_white:
                continue

            # Extract game URL from headers
            game_url = game.headers.get("Site", "")
            self._update_fen_map_for_game(game, final_result, game_user_white, game_url)

    def _update_fen_map_for_game(self, game, final_result: str, is_user_white: bool, game_url: str) -> None:
        """
        Update the FenMap for all positions in a single game (only once per position).
        """
        board = game.board()
        positions_seen: Set[str] = set()  # to avoid double-counting within the same game

        for ply_index, move in enumerate(game.mainline_moves()):
            # Stop if we've passed 40 half-moves (15 full moves)
            if ply_index >= 30:
                break

            board.push(move)
            fen_key = self._fen_key_from_board(board)

            if fen_key not in positions_seen:
                positions_seen.add(fen_key)
                self._update_fen_stats(fen_key, final_result, is_user_white, game_url)

    @staticmethod
    def _fen_key_from_board(board) -> str:
        """
        Convert the full FEN into a shortened FEN key, omitting halfmove and fullmove counters.
        """
        fen_full = board.fen()
        piece_placement, side_to_move, castling, en_passant, *_ = fen_full.split()
        return f"{piece_placement} {side_to_move} {castling} {en_passant}"

    def _update_fen_stats(self, fen_key: str, final_result: str, is_user_white: bool, game_url: str) -> None:
        """
        Update the stats for a single FEN position based on the game result and user color.
        """
        node = self.fen_map[fen_key]
        node.games += 1

        # Add game URL if it's not already there
        if game_url and game_url not in node.game_urls:
            node.game_urls.append(game_url)

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
    
    def output_stats(self, filename: str, min_occurrences: int = 4) -> None:
        """
        Write out the FEN stats to a given file, but only if a position appears
        at least `min_occurrences` times (defaults to 4).
        """
        with open(filename, "w", encoding="utf-8") as f:
            for fen, stats in self.fen_map.items():
                if stats.games >= min_occurrences:
                    f.write(
                        f"FEN: {fen}, "
                        f"Games: {stats.games}, "
                        f"Wins: {stats.wins}, "
                        f"Losses: {stats.losses}, "
                        f"Draws: {stats.draws}\n"
                    )

    def output_user_friendly_summary(self, top_n: int = 5, min_occurrences: int = 4) -> None:
        """
        Display a user-friendly summary of the top N worst performing positions.
        """
        # Filter positions with enough games
        qualifying_positions = [
            (fen, stats) for fen, stats in self.fen_map.items()
            if stats.games >= min_occurrences
        ]

        if not qualifying_positions:
            print(f"No positions found with at least {min_occurrences} games.")
            return

        # Calculate performance metrics and sort by worst performing
        position_analysis = []
        for fen, stats in qualifying_positions:
            win_rate = (stats.wins + 0.5 * stats.draws) / stats.games
            expected_score = stats.wins + 0.5 * stats.draws
            position_analysis.append((fen, stats, win_rate, expected_score))

        # Sort by win rate (ascending - worst first)
        position_analysis.sort(key=lambda x: x[2])

        for i, (fen, stats, win_rate, expected_score) in enumerate(position_analysis[:top_n]):
            print(f"{i+1}. {win_rate:.1%} ({stats.wins}-{stats.losses}-{stats.draws} in {stats.games} games)")
            print(f"    {fen}")
            if stats.game_urls:
                print(f"    Games: {', '.join(stats.game_urls[:5])}")  # Show up to 5 game URLs
                if len(stats.game_urls) > 5:
                    print(f"    ({len(stats.game_urls) - 5} more games...)")
            print()

    def get_worst_performing_positions(self, top_n: int = 5, min_occurrences: int = 4) -> List[str]:
        """
        Return the FENs of the top N worst performing positions.
        """
        # Filter positions with enough games
        qualifying_positions = [
            (fen, stats) for fen, stats in self.fen_map.items()
            if stats.games >= min_occurrences
        ]

        if not qualifying_positions:
            return []

        # Calculate performance metrics and sort by worst performing
        position_analysis = []
        for fen, stats in qualifying_positions:
            win_rate = (stats.wins + 0.5 * stats.draws) / stats.games
            position_analysis.append((fen, stats, win_rate))

        # Sort by win rate (ascending - worst first)
        position_analysis.sort(key=lambda x: x[2])

        # Return just the FENs of the worst positions
        return [fen for fen, stats, win_rate in position_analysis[:top_n]]
