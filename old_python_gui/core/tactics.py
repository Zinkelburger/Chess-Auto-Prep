"""
Core tactics system - handles tactical positions and review logic.
"""
import csv
import random
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from pathlib import Path
from typing import List, Optional, Dict, Any

import chess
import chess.pgn

from config import DATA_DIR


class MistakeType(Enum):
    """Types of tactical mistakes."""
    BLUNDER = "??"
    MISTAKE = "?"
    INACCURACY = "?!"
    MISSED_WIN = "missed_win"
    UNCLEAR = "unclear"


@dataclass
class GameInfo:
    """Information about the game where the position occurred."""
    white: str = ""
    black: str = ""
    result: str = ""
    date: str = ""
    game_id: str = ""
    url: str = ""


@dataclass
class TacticsPosition:
    """A tactical position for training."""
    fen: str
    game_info: GameInfo
    context: str
    user_move: str
    correct_line: List[str]
    mistake_type: MistakeType
    mistake_analysis: str = ""  # Full mistake description from Lichess (e.g., "(−0.31 → 0.83) Mistake. e6 was best.")
    difficulty: int = 1  # 1-5 scale

    # Review tracking
    review_count: int = 0
    success_count: int = 0
    last_reviewed: Optional[datetime] = None

    # Learning statistics
    time_to_solve: float = 0.0
    hints_used: int = 0

    @property
    def success_rate(self) -> float:
        """Calculate success rate for this position."""
        if self.review_count == 0:
            return 0.0
        return self.success_count / self.review_count

    @property
    def board(self) -> chess.Board:
        """Get a chess.Board object for this position."""
        return chess.Board(self.fen)


class TacticsResult(Enum):
    """Result of attempting a tactical position."""
    CORRECT = "correct"
    INCORRECT = "incorrect"
    PARTIAL = "partial"
    HINT_USED = "hint"
    TIMEOUT = "timeout"


@dataclass
class ReviewSession:
    """Statistics for a review session."""
    positions_attempted: int = 0
    positions_correct: int = 0
    positions_incorrect: int = 0
    hints_used: int = 0
    total_time: float = 0.0
    start_time: datetime = field(default_factory=datetime.now)


class TacticsDatabase:
    """Manages tactical positions and review data."""

    def __init__(self, csv_path: Optional[Path] = None):
        self.csv_path = csv_path or DATA_DIR / "tactics_positions.csv"
        self.positions: List[TacticsPosition] = []
        self.current_session = ReviewSession()
        self.session_position_index = 0  # Track current position in linear review

    def load_positions(self) -> int:
        """Load positions from CSV file."""
        self.positions.clear()

        if not self.csv_path.exists():
            return 0

        try:
            with open(self.csv_path, 'r', newline='', encoding='utf-8') as f:
                reader = csv.DictReader(f)
                for row in reader:
                    position = self._create_position_from_row(row)
                    if position:
                        self.positions.append(position)
        except Exception as e:
            print(f"Error loading positions: {e}")
            return 0

        return len(self.positions)

    def _create_position_from_row(self, row: Dict[str, str]) -> Optional[TacticsPosition]:
        """Create a TacticsPosition from a CSV row."""
        try:
            game_info = GameInfo(
                white=row.get('game_white', ''),
                black=row.get('game_black', ''),
                result=row.get('game_result', ''),
                date=row.get('game_date', ''),
                game_id=row.get('game_id', ''),
                url=row.get('game_url', '')
            )

            # Parse mistake type
            mistake_str = row.get('mistake_type', '?')
            try:
                mistake_type = MistakeType(mistake_str)
            except ValueError:
                mistake_type = MistakeType.UNCLEAR

            # Parse correct line
            correct_line = row.get('correct_line', '').split('|') if row.get('correct_line') else []

            # Parse review data
            last_reviewed = None
            if row.get('last_reviewed'):
                try:
                    last_reviewed = datetime.fromisoformat(row['last_reviewed'])
                except ValueError:
                    pass

            return TacticsPosition(
                fen=row['fen'],
                game_info=game_info,
                context=row.get('position_context', ''),
                user_move=row['user_move'],
                correct_line=correct_line,
                mistake_type=mistake_type,
                mistake_analysis=row.get('mistake_analysis', ''),
                difficulty=int(row.get('difficulty', 1)),
                review_count=int(row.get('review_count', 0)),
                success_count=int(row.get('success_count', 0)),
                last_reviewed=last_reviewed,
                time_to_solve=float(row.get('time_to_solve', 0.0)),
                hints_used=int(row.get('hints_used', 0))
            )
        except (KeyError, ValueError) as e:
            print(f"Error parsing position row: {e}")
            return None

    def save_positions(self):
        """Save positions back to CSV file."""
        fieldnames = [
            'fen', 'game_white', 'game_black', 'game_result', 'game_date', 'game_id', 'game_url',
            'position_context', 'user_move', 'correct_line', 'mistake_type', 'mistake_analysis', 'difficulty',
            'review_count', 'success_count', 'last_reviewed', 'time_to_solve', 'hints_used'
        ]

        try:
            with open(self.csv_path, 'w', newline='', encoding='utf-8') as f:
                writer = csv.DictWriter(f, fieldnames=fieldnames)
                writer.writeheader()

                for pos in self.positions:
                    row = {
                        'fen': pos.fen,
                        'game_white': pos.game_info.white,
                        'game_black': pos.game_info.black,
                        'game_result': pos.game_info.result,
                        'game_date': pos.game_info.date,
                        'game_id': pos.game_info.game_id,
                        'game_url': pos.game_info.url,
                        'position_context': pos.context,
                        'user_move': pos.user_move,
                        'correct_line': '|'.join(pos.correct_line),
                        'mistake_type': pos.mistake_type.value,
                        'mistake_analysis': pos.mistake_analysis,
                        'difficulty': pos.difficulty,
                        'review_count': pos.review_count,
                        'success_count': pos.success_count,
                        'last_reviewed': pos.last_reviewed.isoformat() if pos.last_reviewed else '',
                        'time_to_solve': pos.time_to_solve,
                        'hints_used': pos.hints_used
                    }
                    writer.writerow(row)
        except Exception as e:
            print(f"Error saving positions: {e}")

    def get_positions_for_review(self, limit: int = 1) -> List[TacticsPosition]:
        """Get positions for linear review - find first position with fewer reviews."""
        if not self.positions:
            return []

        # Sort positions by original order (maintain CSV order)
        sorted_positions = self.positions[:]

        # Find the first position where review count drops
        # If all have same count, start from the beginning
        if self.session_position_index >= len(sorted_positions):
            self.session_position_index = 0

        # Find starting point - first position with fewer reviews than max
        max_reviews = max(pos.review_count for pos in sorted_positions)

        # Start from current index and find first position with < max reviews
        starting_index = self.session_position_index
        for i in range(len(sorted_positions)):
            index = (starting_index + i) % len(sorted_positions)
            if sorted_positions[index].review_count < max_reviews:
                self.session_position_index = index
                return [sorted_positions[index]]

        # If all have max reviews, start from current index
        if self.session_position_index >= len(sorted_positions):
            self.session_position_index = 0

        position = sorted_positions[self.session_position_index]
        return [position]

    def start_session(self):
        """Start a new review session."""
        self.current_session = ReviewSession()

    def record_attempt(self, position: TacticsPosition, result: TacticsResult,
                      time_taken: float = 0.0, hints_used: int = 0):
        """Record an attempt at a position."""
        position.review_count += 1
        position.last_reviewed = datetime.now()
        position.time_to_solve = time_taken
        position.hints_used += hints_used

        if result == TacticsResult.CORRECT:
            position.success_count += 1
            self.current_session.positions_correct += 1
        elif result == TacticsResult.INCORRECT:
            self.current_session.positions_incorrect += 1
        elif result == TacticsResult.HINT_USED:
            self.current_session.hints_used += 1

        self.current_session.positions_attempted += 1
        self.current_session.total_time += time_taken

        # Advance to next position in linear sequence
        if result == TacticsResult.CORRECT:
            self.session_position_index = (self.session_position_index + 1) % len(self.positions)

        # Save updated review counts immediately
        self.save_positions()



class TacticsEngine:
    """Engine for checking tactical solutions."""

    def __init__(self):
        pass

    def check_move(self, position: TacticsPosition, move_uci: str) -> TacticsResult:
        """Check if a move is correct for the given position."""
        try:
            board = chess.Board(position.fen)
            move = chess.Move.from_uci(move_uci)

            if move not in board.legal_moves:
                return TacticsResult.INCORRECT

            # Check if move matches the correct line
            move_san = board.san(move)

            if position.correct_line and move_san == position.correct_line[0]:
                return TacticsResult.CORRECT
            elif position.correct_line and move_san in position.correct_line:
                return TacticsResult.PARTIAL
            else:
                return TacticsResult.INCORRECT

        except (ValueError, chess.InvalidMoveError):
            return TacticsResult.INCORRECT

    def get_hint(self, position: TacticsPosition) -> Optional[str]:
        """Get a hint for the position."""
        if not position.correct_line:
            return None

        # Return the first move of the correct line as a hint
        return f"Try: {position.correct_line[0]}"

    def get_solution(self, position: TacticsPosition) -> str:
        """Get the full solution for the position."""
        if not position.correct_line:
            return "No solution available"

        return " ".join(position.correct_line)