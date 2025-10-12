import chess
import requests
import time
import os
from typing import List, Dict, Any, Optional
from dotenv import load_dotenv
from move_selectors import MoveSelector
from pgn_writer import PgnWriter

# Load environment variables
load_dotenv()

LICHESS_API_TOKEN = os.getenv("LICHESS_API_TOKEN")
if not LICHESS_API_TOKEN:
    raise ValueError("Lichess API token not found. Please set it in your .env file.")

BASE_URL = "https://explorer.lichess.ovh/lichess"
HEADERS = {"Authorization": f"Bearer {LICHESS_API_TOKEN}"}

def query_lichess_api(fen: str) -> Optional[Dict[str, Any]]:
    """Queries the Lichess API for a given FEN and handles rate limiting."""
    params = {
        "variant": "standard",
        "fen": fen,
        "ratings": "1800,2000,2200,2500",
        "speeds": "blitz,rapid,classical"
    }
    try:
        # Small delay to be polite to the API
        time.sleep(0.1)
        response = requests.get(BASE_URL, params=params, headers=HEADERS)

        if response.status_code == 429:
            print("    [!] Rate limited (429). Waiting 61 seconds...")
            time.sleep(61)
            return query_lichess_api(fen)  # Retry the request

        response.raise_for_status()
        return response.json()
    except requests.exceptions.RequestException as e:
        print(f"    [!] Request failed: {e}")
        return None

class RepertoireBuilder:
    """
    Builds a chess repertoire by recursively exploring moves from a starting position.
    """

    def __init__(self, my_color: chess.Color, my_move_selector: MoveSelector, pgn_writer: PgnWriter):
        self.my_color = my_color
        self.my_move_selector = my_move_selector
        self.pgn_writer = pgn_writer
        self.completed_lines_count = 0

    def build(self, start_fen: str, initial_moves: List[str], threshold: float):
        """Starts the recursive build process."""
        self._dfs(start_fen, 1.0, threshold, initial_moves)

    def _dfs(self, fen: str, path_probability: float, threshold: float, current_line_san: List[str]):
        """
        Depth-First Search to explore move tree.
        """
        board = chess.Board(fen)
        is_my_turn = board.turn == self.my_color

        # --- API Query ---
        data = query_lichess_api(fen)
        if not data or not data.get("moves"):
            self._save_line_if_valid(current_line_san, path_probability, "End of API data")
            return

        total_games = data['white'] + data['black'] + data['draws']
        if total_games == 0:
            self._save_line_if_valid(current_line_san, path_probability, "No games played from here")
            return

        print(f"\nAnalyzing: {' '.join(current_line_san) or 'Start'}")
        print(f"Turn: {'Me' if is_my_turn else 'Opponent'}. Path Probability: {path_probability:.2%}")

        # --- Move Selection Logic ---
        if is_my_turn:
            # My Turn: Use the selected algorithm to pick ONE move.
            my_move = self.my_move_selector.select_move(data['moves'], board, self.my_color)
            if not my_move:
                self._save_line_if_valid(current_line_san, path_probability, "No valid move found for me")
                return

            print(f"  -> My Move ({type(self.my_move_selector).__name__}): {my_move['san']}")

            # Recurse down this single path. Probability doesn't change on my move.
            board.push_san(my_move['san'])
            self._dfs(board.fen(), path_probability, threshold, current_line_san + [my_move['san']])

        else:
            # Opponent's Turn: Explore all common responses.
            for move in data['moves']:
                move_games = move['white'] + move['black'] + move['draws']
                conditional_prob = move_games / total_games
                new_absolute_prob = path_probability * conditional_prob

                # Prune the search tree if the opponent's line is too rare
                if new_absolute_prob < threshold:
                    print(f"    -- [PRUNED] Line below threshold: {' '.join(current_line_san + [move['san']])} (Prob: {new_absolute_prob:.2%})")
                    continue

                print(f"  -> Opponent's Response: {move['san']} (Prob: {conditional_prob:.1%}, Cumulative: {new_absolute_prob:.2%})")

                board_after_move = chess.Board(fen)
                board_after_move.push_san(move['san'])
                self._dfs(board_after_move.fen(), new_absolute_prob, threshold, current_line_san + [move['san']])

    def _save_line_if_valid(self, moves: List[str], probability: float, reason: str):
        """Helper to save a completed line if it's not too short."""
        if len(moves) > 3:  # Only save lines of a reasonable length
            self.completed_lines_count += 1
            self.pgn_writer.save_line(moves, probability, self.my_color)
            print(f"    [SAVED] Line #{self.completed_lines_count}: {' '.join(moves)} (Reason: {reason})")
        else:
            print(f"    [END] Short line not saved: {' '.join(moves)}")