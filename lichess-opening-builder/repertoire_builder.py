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

LICHESS_API_TOKEN = os.getenv("LICHESS")
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

    def __init__(self, my_color: chess.Color, my_move_selector: MoveSelector, pgn_writer: PgnWriter,
                 min_move_frequency: float = 0.005, min_games: int = 100):
        self.my_color = my_color
        self.my_move_selector = my_move_selector
        self.pgn_writer = pgn_writer
        self.completed_lines_count = 0
        self.min_move_frequency = min_move_frequency  # e.g., 0.05 = 5%
        self.min_games = min_games  # Minimum total games in position

    def build(self, start_fen: str, initial_moves: List[str], threshold: float):
        """Starts the recursive build process."""
        self._dfs(start_fen, 1.0, threshold, initial_moves)

    def _dfs(self, fen: str, path_probability: float, threshold: float, current_line_san: List[str]):
        """
        Depth-First Search to explore move tree.
        Saves a line when we can't explore further (natural endpoint).
        """
        board = chess.Board(fen)
        is_my_turn = board.turn == self.my_color

        # --- Check if game is over ---
        if board.is_game_over():
            self._save_line(current_line_san, path_probability, "Game over (checkmate/stalemate)")
            return

        # --- Query API ---
        data = query_lichess_api(fen)
        if not data or not data.get("moves"):
            self._save_line(current_line_san, path_probability, "No API data available")
            return

        total_games = data['white'] + data['black'] + data['draws']
        if total_games < self.min_games:
            self._save_line(current_line_san, path_probability, f"Insufficient games ({total_games} < {self.min_games})")
            return

        print(f"\nAnalyzing: {' '.join(current_line_san) or 'Start'}")
        print(f"Turn: {'Me' if is_my_turn else 'Opponent'}. Path Probability: {path_probability:.2%}. Total Games: {total_games}")

        # --- Filter moves by frequency ---
        filtered_moves = []
        for move in data['moves']:
            move_games = move['white'] + move['black'] + move['draws']
            conditional_prob = move_games / total_games

            if conditional_prob >= self.min_move_frequency:
                filtered_moves.append(move)
            else:
                print(f"    -- [FILTERED] {move['san']} (Freq: {conditional_prob:.1%} < {self.min_move_frequency:.1%}, Games: {move_games})")

        if not filtered_moves:
            self._save_line(current_line_san, path_probability, f"No moves meet {self.min_move_frequency:.1%} frequency threshold")
            return

        print(f"  Considering {len(filtered_moves)}/{len(data['moves'])} moves (>{self.min_move_frequency:.1%} frequency)")

        # --- Move Selection Logic ---
        if is_my_turn:
            # My Turn: Pick ONE move and continue down that path
            my_move = self.my_move_selector.select_move(filtered_moves, board, self.my_color)
            if not my_move:
                self._save_line(current_line_san, path_probability, "No valid move selected")
                return

            move_games = my_move['white'] + my_move['black'] + my_move['draws']
            move_freq = move_games / total_games
            print(f"  -> My Move ({type(self.my_move_selector).__name__}): {my_move['san']} (Freq: {move_freq:.1%}, Games: {move_games})")

            # Recurse down this single path
            board.push_san(my_move['san'])
            self._dfs(board.fen(), path_probability, threshold, current_line_san + [my_move['san']])

        else:
            # Opponent's Turn: Explore ALL moves that meet the cumulative threshold
            # Filter moves by cumulative probability threshold
            valid_opponent_moves = []
            for move in filtered_moves:
                move_games = move['white'] + move['black'] + move['draws']
                conditional_prob = move_games / total_games
                new_absolute_prob = path_probability * conditional_prob

                if new_absolute_prob >= threshold:
                    valid_opponent_moves.append((move, conditional_prob, new_absolute_prob))
                else:
                    print(f"    -- [PRUNED] {move['san']}: cumulative prob {new_absolute_prob:.2%} < threshold {threshold:.2%}")

            # If NO opponent moves meet the threshold, this is the end of the line
            if not valid_opponent_moves:
                self._save_line(current_line_san, path_probability, "No opponent moves meet cumulative threshold")
                return

            # Explore each valid opponent response
            for move, conditional_prob, new_absolute_prob in valid_opponent_moves:
                move_games = move['white'] + move['black'] + move['draws']
                print(f"  -> Opponent's Response: {move['san']} (Freq: {conditional_prob:.1%}, Cumulative: {new_absolute_prob:.2%}, Games: {move_games})")

                board_after_move = chess.Board(fen)
                board_after_move.push_san(move['san'])
                self._dfs(board_after_move.fen(), new_absolute_prob, threshold, current_line_san + [move['san']])

    def _save_line(self, moves: List[str], probability: float, reason: str):
        """
        Save a completed repertoire line.
        Called when we reach a natural endpoint (can't explore further).
        """
        self.completed_lines_count += 1
        self.pgn_writer.save_line(moves, probability, self.my_color)
        print(f"    ✓ [SAVED LINE #{self.completed_lines_count}] {' '.join(moves) if moves else '(starting position)'}")
        print(f"      Reason: {reason} | Probability: {probability:.2%}")
