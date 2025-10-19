"""
Tactics Analyzer - Extracts mistake positions from PGN files for review.
"""
import re
import csv
import chess
import chess.pgn
from pathlib import Path
from datetime import datetime
from typing import List, Dict, Optional, Tuple
import logging

logger = logging.getLogger(__name__)

class TacticsPosition:
    """Represents a tactical position to review."""

    def __init__(self, fen: str, user_move: str, correct_line: List[str],
                 mistake_type: str, game_info: Dict, position_context: str = ""):
        self.fen = fen
        self.user_move = user_move  # The move the user played (mistake)
        self.correct_line = correct_line  # Best continuation (2 moves max)
        self.mistake_type = mistake_type  # "?" or "??"
        self.game_info = game_info  # Game metadata
        self.position_context = position_context  # Brief description

        # Review tracking
        self.difficulty = 0  # 0 = new, 1-5 = difficulty rating
        self.last_reviewed = None
        self.review_count = 0
        self.success_rate = 0.0

class TacticsAnalyzer:
    """Analyzes PGN files to extract tactical positions from mistakes."""

    def __init__(self, username: str = "BigManArkhangelsk"):
        self.username = username.lower()
        self.tactics_file = "tactics_positions.csv"
        self.positions = []

    def analyze_pgn_file(self, pgn_path: str, progress_callback=None) -> int:
        """
        Analyze a PGN file and extract tactical positions.

        Returns:
            Number of positions found
        """
        positions_found = 0

        try:
            with open(pgn_path, 'r', encoding='utf-8') as f:
                game_count = 0

                while True:
                    game = chess.pgn.read_game(f)
                    if game is None:
                        break

                    game_count += 1
                    if progress_callback and game_count % 10 == 0:
                        progress_callback(f"Analyzed {game_count} games, found {positions_found} tactics positions")

                    # Extract positions from this game
                    game_positions = self._extract_positions_from_game(game)
                    positions_found += len(game_positions)
                    self.positions.extend(game_positions)

        except Exception as e:
            logger.error(f"Error analyzing PGN file {pgn_path}: {e}")
            raise

        if progress_callback:
            progress_callback(f"Analysis complete: {positions_found} tactics positions found from {game_count} games")

        return positions_found

    def _extract_positions_from_game(self, game: chess.pgn.Game) -> List[TacticsPosition]:
        """Extract tactical positions from a single game."""
        positions = []

        # Get game info
        headers = game.headers
        white_player = headers.get("White", "").lower()
        black_player = headers.get("Black", "").lower()

        # Determine if this user was playing and what color
        user_color = None
        if self.username in white_player:
            user_color = chess.WHITE
        elif self.username in black_player:
            user_color = chess.BLACK
        else:
            return positions  # User not in this game

        game_info = {
            "white": headers.get("White", ""),
            "black": headers.get("Black", ""),
            "result": headers.get("Result", ""),
            "date": headers.get("Date", ""),
            "site": headers.get("Site", ""),
            "game_id": headers.get("GameId", "")
        }

        # Walk through the game moves
        board = game.board()
        node = game

        while node.variations:
            next_node = node.variations[0]
            move = next_node.move

            # Check if this is the user's move and has mistake annotation
            if board.turn == user_color:
                comment = next_node.comment
                mistake_type = self._extract_mistake_type(comment)

                if mistake_type:
                    # Get the position before the mistake
                    fen_before = board.fen()
                    user_move = move.uci()

                    # Extract the correct line from the comment
                    correct_line = self._extract_correct_line(comment)

                    # Create position context
                    move_number = board.fullmove_number
                    color_str = "White" if user_color == chess.WHITE else "Black"
                    context = f"Move {move_number}, {color_str} to play"

                    position = TacticsPosition(
                        fen=fen_before,
                        user_move=user_move,
                        correct_line=correct_line,
                        mistake_type=mistake_type,
                        game_info=game_info,
                        position_context=context
                    )

                    positions.append(position)

            # Make the move and continue
            board.push(move)
            node = next_node

        return positions

    def _extract_mistake_type(self, comment: str) -> Optional[str]:
        """Extract mistake type from move comment."""
        if not comment:
            return None

        # Look for mistake annotations in the comment
        if "Blunder" in comment:
            return "??"
        elif "Mistake" in comment:
            return "?"
        elif "Inaccuracy" in comment:
            return "?!"

        return None

    def _extract_correct_line(self, comment: str) -> List[str]:
        """Extract the correct line from the comment."""
        correct_line = []

        # Look for patterns like "Best move was Nf3" or parenthetical variations
        best_move_match = re.search(r"(?:Best move was|was best\.)\s*\}\s*\(([^)]+)\)", comment)
        if best_move_match:
            moves_text = best_move_match.group(1)
            # Parse the moves and take first 2
            moves = re.findall(r"[a-h1-8][a-h1-8](?:[qrbn])?", moves_text)
            correct_line = moves[:2]  # Limit to 2 moves
        else:
            # Try to find moves in parentheses
            paren_match = re.search(r"\(([^)]+)\)", comment)
            if paren_match:
                moves_text = paren_match.group(1)
                # Extract actual moves (not move numbers)
                moves = re.findall(r"[NBRQK]?[a-h]?[1-8]?x?[a-h][1-8](?:=[NBRQ])?[+#]?", moves_text)
                correct_line = moves[:2]

        return correct_line

    def save_to_csv(self) -> str:
        """Save extracted positions to CSV file."""
        csv_path = Path(self.tactics_file)

        # Load existing data if file exists
        existing_positions = set()
        if csv_path.exists():
            try:
                with open(csv_path, 'r', newline='', encoding='utf-8') as f:
                    reader = csv.DictReader(f)
                    for row in reader:
                        # Create unique key for position
                        key = f"{row['fen']}:{row['user_move']}"
                        existing_positions.add(key)
            except Exception as e:
                logger.warning(f"Error reading existing CSV: {e}")

        # Write all positions (new + existing)
        new_count = 0
        with open(csv_path, 'w', newline='', encoding='utf-8') as f:
            fieldnames = [
                'fen', 'user_move', 'correct_line', 'mistake_type',
                'position_context', 'game_white', 'game_black', 'game_result',
                'game_date', 'game_id', 'difficulty', 'last_reviewed',
                'review_count', 'success_rate', 'created_date'
            ]
            writer = csv.DictWriter(f, fieldnames=fieldnames)
            writer.writeheader()

            for pos in self.positions:
                key = f"{pos.fen}:{pos.user_move}"
                if key not in existing_positions:
                    new_count += 1

                writer.writerow({
                    'fen': pos.fen,
                    'user_move': pos.user_move,
                    'correct_line': '|'.join(pos.correct_line),
                    'mistake_type': pos.mistake_type,
                    'position_context': pos.position_context,
                    'game_white': pos.game_info.get('white', ''),
                    'game_black': pos.game_info.get('black', ''),
                    'game_result': pos.game_info.get('result', ''),
                    'game_date': pos.game_info.get('date', ''),
                    'game_id': pos.game_info.get('game_id', ''),
                    'difficulty': pos.difficulty,
                    'last_reviewed': pos.last_reviewed,
                    'review_count': pos.review_count,
                    'success_rate': pos.success_rate,
                    'created_date': datetime.now().isoformat()
                })

        logger.info(f"Saved {len(self.positions)} positions to {csv_path} ({new_count} new)")
        return str(csv_path)

def analyze_tactics_from_directory(directory: str = "imported_games",
                                 username: str = "BigManArkhangelsk",
                                 progress_callback=None) -> str:
    """
    Analyze all PGN files in a directory for tactical positions.

    Returns:
        Path to the tactics CSV file
    """
    analyzer = TacticsAnalyzer(username)

    pgn_dir = Path(directory)
    if not pgn_dir.exists():
        raise FileNotFoundError(f"Directory {directory} not found")

    pgn_files = list(pgn_dir.glob("*.pgn"))
    if not pgn_files:
        raise FileNotFoundError(f"No PGN files found in {directory}")

    total_positions = 0

    for i, pgn_file in enumerate(pgn_files):
        if progress_callback:
            progress_callback(f"Analyzing file {i+1}/{len(pgn_files)}: {pgn_file.name}")

        try:
            positions = analyzer.analyze_pgn_file(str(pgn_file), progress_callback)
            total_positions += positions
        except Exception as e:
            logger.error(f"Error analyzing {pgn_file}: {e}")
            if progress_callback:
                progress_callback(f"Error analyzing {pgn_file.name}: {e}")

    # Save to CSV
    csv_path = analyzer.save_to_csv()

    if progress_callback:
        progress_callback(f"Tactics analysis complete! Found {total_positions} positions saved to {csv_path}")

    return csv_path

if __name__ == "__main__":
    # Test the analyzer
    try:
        csv_path = analyze_tactics_from_directory(
            progress_callback=print
        )
        print(f"Success! Tactics saved to: {csv_path}")
    except Exception as e:
        print(f"Error: {e}")