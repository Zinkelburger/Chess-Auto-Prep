"""
Enhanced PGN processor that correctly handles annotations, variations, and comments.
This implementation uses tree traversal to extract all data from PGN files.

Key improvements over basic chess.pgn iteration:
1. Full tree traversal instead of mainline_moves() to capture all annotations
2. Proper NAG (Numeric Annotation Glyph) symbol mapping for moves like Ne5?
3. Complete comment extraction from each move node
4. Support for variations and alternative lines
5. Structured data extraction for easy UI display
"""
import chess
import chess.pgn
from typing import List, Dict, Any, Optional, Union
from dataclasses import dataclass
import io


# Complete NAG (Numeric Annotation Glyph) mapping
NAG_MAP = {
    1: "!",    # Good move
    2: "?",    # Mistake
    3: "!!",   # Brilliant move
    4: "??",   # Blunder
    5: "!?",   # Interesting move
    6: "?!",   # Dubious move
    7: "□",    # Forced move (only move)
    8: "□",    # Singular move (best)
    9: "??",   # Worst move
    10: "=",   # Equal position
    11: "=",   # Equal position (alternate)
    12: "=",   # Equal position (alternate)
    13: "∞",   # Unclear position
    14: "⩲",   # White has slight advantage
    15: "⩱",   # Black has slight advantage
    16: "±",   # White has advantage
    17: "∓",   # Black has advantage
    18: "+-",  # White is winning
    19: "-+",  # Black is winning
    20: "⨀",   # White has crushing advantage
    21: "⨀",   # Black has crushing advantage
    22: "⨁",   # White is in zugzwang
    23: "⨁",   # Black is in zugzwang
    24: "○",   # White has space advantage
    25: "○",   # Black has space advantage
    26: "○",   # White has time advantage
    27: "○",   # Black has time advantage
    28: "○",   # White has initiative
    29: "○",   # Black has initiative
    30: "○",   # White has attack
    31: "○",   # Black has attack
    32: "→",   # White has better development
    33: "→",   # Black has better development
    34: "→",   # White has weak point
    35: "→",   # Black has weak point
    36: "→",   # White has endgame advantage
    37: "→",   # Black has endgame advantage
    38: "→",   # White has kingside advantage
    39: "→",   # Black has kingside advantage
    40: "→",   # White has queenside advantage
    41: "→",   # Black has queenside advantage
    42: "→",   # White has weak squares
    43: "→",   # Black has weak squares
    44: "→",   # White has strong squares
    45: "→",   # Black has strong squares
    132: "⇆", # Counterplay
    133: "⇆", # Counterplay
    134: "⇆", # Counterplay
    135: "⇆", # Counterplay
    136: "⇆", # Counterplay
    137: "⇆", # Counterplay
    138: "⇆", # Counterplay
    139: "⇆", # Counterplay
    140: "∆",  # With the idea
    141: "∇",  # Aimed against
    142: "⌓",  # Better is
    143: "⌓",  # Worse is
    144: "=",  # Equivalent
    145: "RR", # Editorial comment
    146: "N",  # Novelty
}


@dataclass
class MoveData:
    """Represents a single move with all its annotations."""
    san: str
    uci: str
    nags: List[str]  # NAG symbols like "?", "!", etc.
    comments: List[str]
    variations: List['VariationData']
    move_number: int
    is_white_move: bool
    fen_before: str
    fen_after: str

    @property
    def display_text(self) -> str:
        """Get the complete move text with annotations for display."""
        text = self.san
        if self.nags:
            text += "".join(self.nags)
        return text

    @property
    def comment_text(self) -> str:
        """Get the combined comment text."""
        return " ".join(self.comments) if self.comments else ""


@dataclass
class VariationData:
    """Represents a variation (alternative line of moves)."""
    moves: List[MoveData]
    comment: str = ""


@dataclass
class GameData:
    """Represents a complete game with all annotations and variations."""
    headers: Dict[str, str]
    main_line: List[MoveData]
    result: str
    starting_fen: str


class PGNProcessor:
    """Enhanced PGN processor using tree traversal for complete data extraction."""

    def __init__(self):
        self.current_board = None

    def parse_pgn(self, pgn_text: str) -> Optional[GameData]:
        """
        Parse a PGN string and extract all data including annotations and variations.

        Args:
            pgn_text: PGN string to parse

        Returns:
            GameData object with complete game information, or None if parsing fails
        """
        try:
            game = chess.pgn.read_game(io.StringIO(pgn_text))
            if not game:
                return None

            return self._extract_game_data(game)

        except Exception as e:
            print(f"Error parsing PGN: {e}")
            return None

    def parse_pgn_file(self, file_path: str) -> List[GameData]:
        """
        Parse a PGN file and extract all games.

        Args:
            file_path: Path to PGN file

        Returns:
            List of GameData objects
        """
        games = []
        try:
            with open(file_path, 'r', encoding='utf-8') as f:
                while True:
                    game = chess.pgn.read_game(f)
                    if game is None:
                        break

                    game_data = self._extract_game_data(game)
                    if game_data:
                        games.append(game_data)

        except Exception as e:
            print(f"Error parsing PGN file: {e}")

        return games

    def _extract_game_data(self, game: chess.pgn.Game) -> GameData:
        """Extract complete data from a chess.pgn.Game object."""
        # Extract headers
        headers = dict(game.headers)

        # Get starting position
        starting_fen = game.board().fen()

        # Extract main line using tree traversal
        self.current_board = game.board()
        main_line = self._traverse_variations(game, move_number=1)

        return GameData(
            headers=headers,
            main_line=main_line,
            result=headers.get('Result', '*'),
            starting_fen=starting_fen
        )

    def _traverse_variations(self, node: chess.pgn.GameNode, move_number: int = 1) -> List[MoveData]:
        """
        Recursively traverse the game tree to extract all moves and variations.

        This is the core improvement - instead of using mainline_moves(), we traverse
        the complete tree structure to capture annotations and variations.
        """
        moves = []
        current_move_number = move_number
        board = node.board()
        current_node = node

        # Traverse the main line
        while current_node.variations:
            child = current_node.variations[0]  # Main line
            move = child.move
            san = board.san(move)
            uci = move.uci()

            # Get FEN before move
            fen_before = board.fen()

            # Make the move to get FEN after
            board_copy = board.copy()
            board_copy.push(move)
            fen_after = board_copy.fen()

            # Extract NAGs and convert to symbols
            nag_symbols = []
            for nag in child.nags:
                if nag in NAG_MAP:
                    nag_symbols.append(NAG_MAP[nag])

            # Extract comments (filtered to remove eval/clock data)
            comments = []
            if child.comment:
                filtered_comment = self._filter_comment(child.comment)
                if filtered_comment:
                    comments.append(filtered_comment)

            # Extract variations (alternative lines from current position)
            variations = []
            if len(current_node.variations) > 1:
                # Additional variations are alternatives to the main move
                for var_child in current_node.variations[1:]:
                    var_moves = self._extract_variation(var_child, current_move_number, board.copy())
                    if var_moves:
                        variations.append(VariationData(moves=var_moves))

            # Create move data
            move_data = MoveData(
                san=san,
                uci=uci,
                nags=nag_symbols,
                comments=comments,
                variations=variations,
                move_number=current_move_number,
                is_white_move=board.turn == chess.WHITE,
                fen_before=fen_before,
                fen_after=fen_after
            )

            moves.append(move_data)

            # Update move number
            if board.turn == chess.BLACK:
                current_move_number += 1

            # Advance to next position
            board.push(move)
            current_node = child

        return moves

    def _extract_variation(self, node: chess.pgn.GameNode, start_move_number: int, board: chess.Board) -> List[MoveData]:
        """Extract moves from a variation (alternative line)."""
        moves = []
        current_move_number = start_move_number

        while node.variations:
            child = node.variations[0]  # Follow main line of variation
            move = child.move
            san = board.san(move)
            uci = move.uci()

            # Get FEN before and after
            fen_before = board.fen()
            board.push(move)
            fen_after = board.fen()

            # Extract NAGs and comments
            nag_symbols = [NAG_MAP[nag] for nag in child.nags if nag in NAG_MAP]
            comments = []
            if child.comment:
                filtered_comment = self._filter_comment(child.comment)
                if filtered_comment:
                    comments.append(filtered_comment)

            move_data = MoveData(
                san=san,
                uci=uci,
                nags=nag_symbols,
                comments=comments,
                variations=[],  # Nested variations not supported in this implementation
                move_number=current_move_number,
                is_white_move=not board.turn,  # board.turn changed after push
                fen_before=fen_before,
                fen_after=fen_after
            )

            moves.append(move_data)

            # Update move number
            if not board.turn:  # Black just moved
                current_move_number += 1

            node = child

        return moves

    def _filter_comment(self, comment: str) -> str:
        """Filter out eval and clock comments, keeping only meaningful text."""
        if not comment:
            return ""

        import re

        # Remove eval comments like [%eval 0.17] or [%eval -1.25]
        comment = re.sub(r'\[%eval [^\]]+\]', '', comment)

        # Remove clock comments like [%clk 0:03:00]
        comment = re.sub(r'\[%clk [^\]]+\]', '', comment)

        # Remove engine evaluation text like "(0.62 → 0.01)"
        comment = re.sub(r'\([+-]?\d+\.?\d*\s*[→-]\s*[+-]?\d+\.?\d*\)', '', comment)

        # Remove phrases for inaccuracies, mistakes and blunders (keep only meaningful content)
        comment = re.sub(r'(Inaccuracy|Mistake|Blunder|Good move|Excellent move|Best move)\.[^.]*\.', '', comment)

        # Remove "was best" phrases
        comment = re.sub(r'[A-Za-z0-9+#-]+\s+was best\.?', '', comment)

        # Clean up extra whitespace
        comment = re.sub(r'\s+', ' ', comment).strip()

        # Return empty string if comment is now empty or just punctuation
        if not comment or comment in '.,;!?':
            return ""

        return comment

    def format_moves_with_annotations(self, moves: List[MoveData]) -> str:
        """
        Format moves with annotations for display.
        This demonstrates how to properly display moves with their annotations.
        """
        formatted = []

        for move in moves:
            # Start with the move notation
            move_text = move.san

            # Add NAG symbols
            if move.nags:
                move_text += "".join(move.nags)

            # Add move number for white moves
            if move.is_white_move:
                formatted.append(f"{move.move_number}. {move_text}")
            else:
                formatted.append(move_text)

            # Add comments
            if move.comments:
                for comment in move.comments:
                    formatted.append(f"({comment})")

            # Add variations
            if move.variations:
                for variation in move.variations:
                    var_text = self.format_moves_with_annotations(variation.moves)
                    formatted.append(f"({var_text})")

        return " ".join(formatted)

    def get_position_at_move(self, game_data: GameData, move_index: int) -> chess.Board:
        """
        Get the board position after a specific move in the main line.

        Args:
            game_data: GameData object
            move_index: 0-based index into the main line moves

        Returns:
            chess.Board at the specified position
        """
        board = chess.Board()

        # Apply custom starting position if specified
        if game_data.starting_fen != chess.STARTING_FEN:
            board = chess.Board(game_data.starting_fen)

        # Play moves up to the specified index
        for i, move_data in enumerate(game_data.main_line[:move_index + 1]):
            try:
                move = chess.Move.from_uci(move_data.uci)
                board.push(move)
            except (ValueError, chess.InvalidMoveError):
                break

        return board

    def find_moves_with_annotation(self, game_data: GameData, annotation: str) -> List[tuple]:
        """
        Find all moves in the game with a specific annotation.

        Args:
            game_data: GameData object
            annotation: NAG symbol to search for (e.g., "?", "!", "??")

        Returns:
            List of (move_index, move_data) tuples
        """
        results = []

        for i, move in enumerate(game_data.main_line):
            if annotation in move.nags:
                results.append((i, move))

        return results

    def extract_tactical_positions(self, game_data: GameData) -> List[Dict[str, Any]]:
        """
        Extract positions that might be tactical puzzles based on annotations.

        Returns positions where significant annotations (?, ??) occur.
        Excludes inaccuracies (?!) as they are not suitable for tactical training.
        """
        tactical_positions = []

        # Only include mistakes and blunders, exclude inaccuracies
        significant_nags = ["?", "??"]

        for i, move in enumerate(game_data.main_line):
            # Check if this move has significant annotations (mistakes/blunders only)
            has_significant_nag = any(nag in significant_nags for nag in move.nags)

            if has_significant_nag:
                # Get the position before this move (the puzzle position)
                puzzle_board = chess.Board(move.fen_before)

                tactical_positions.append({
                    'fen': move.fen_before,
                    'move_played': move.san,
                    'move_uci': move.uci,
                    'annotations': move.nags,
                    'comments': move.comments,
                    'move_number': move.move_number,
                    'is_white_to_move': puzzle_board.turn == chess.WHITE,
                    'position_after_move': move.fen_after
                })

        return tactical_positions


# Example usage and testing functions
def demo_enhanced_parsing():
    """Demonstrate the enhanced PGN parsing capabilities."""

    # Example PGN with annotations and variations
    sample_pgn = '''[Event "Demo Game"]
[Site "Example"]
[Date "2023.01.01"]
[Round "1"]
[White "Player A"]
[Black "Player B"]
[Result "1-0"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 Nf6 5. O-O Be7 6. Re1 b5 7. Bb3 d6
8. c3 O-O 9. h3 Nb8?! (9... Na5 10. Bc2 c5 11. d4 Qc7) 10. d4 Nbd7
11. Nbd2 Bb7 12. Bc2 Re8 13. Nf1 Bf8 14. Ng3 g6 15. a4 c5 16. d5 c4
17. axb5 axb5 18. Rxa8 Bxa8 19. Bg5 h6 20. Bd2 Qb6 21. Ra1 Bc5??
(21... Nh5! 22. Nxh5 gxh5 23. Be3 Qc7 =) 22. Rxa8+ Kg7 23. Ra7 1-0'''

    processor = PGNProcessor()
    game_data = processor.parse_pgn(sample_pgn)

    if game_data:
        print("=== Game Headers ===")
        for key, value in game_data.headers.items():
            print(f"{key}: {value}")

        print(f"\n=== Formatted Game ===")
        formatted = processor.format_moves_with_annotations(game_data.main_line)
        print(formatted)

        print(f"\n=== Tactical Positions ===")
        tactical = processor.extract_tactical_positions(game_data)
        for pos in tactical:
            print(f"Move {pos['move_number']}: {pos['move_played']} {pos['annotations']}")
            if pos['comments']:
                print(f"  Comments: {pos['comments']}")
            print(f"  FEN: {pos['fen']}")
            print()


if __name__ == "__main__":
    demo_enhanced_parsing()