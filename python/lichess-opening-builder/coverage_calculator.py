#!/usr/bin/env python3
"""
Coverage Calculator for Chess Repertoire Analysis

Analyzes a PGN repertoire to calculate how much of the opponent's 
possible responses are covered, using the Lichess Masters/Player database.

Key Metrics:
- Total Coverage %: Positions where opponent responses are adequately analyzed
- Leakage %: Positions where analysis stopped too early (high game count leaves)
- Unaccounted %: Opponent moves not present in the repertoire at all
"""

import chess
import chess.pgn
import requests
import time
import io
import os
from typing import Dict, List, Optional, Set, Tuple, Any
from dataclasses import dataclass, field
from enum import Enum
from dotenv import load_dotenv
from collections import defaultdict

# Load environment variables
load_dotenv()


class DatabaseType(Enum):
    """Lichess explorer database types."""
    LICHESS = "lichess"      # Lichess games database
    MASTERS = "masters"       # Masters database (OTB games)
    PLAYER = "player"         # Specific player's games


@dataclass
class LeafNode:
    """Represents a leaf position in the repertoire tree."""
    fen: str
    moves: List[str]  # Move sequence to reach this position
    game_count: int
    is_sealed: bool   # True if game_count <= target, False if leaking
    reason: str       # Why this is a leaf (game ended, target met, etc.)


@dataclass
class CoverageResult:
    """Results from the coverage analysis."""
    root_fen: str
    root_game_count: int
    target_game_count: int
    
    sealed_leaves: List[LeafNode] = field(default_factory=list)
    leaking_leaves: List[LeafNode] = field(default_factory=list)
    
    total_sealed_games: int = 0
    total_leaking_games: int = 0
    total_unaccounted_games: int = 0
    
    @property
    def coverage_percent(self) -> float:
        """Percentage of games covered by sealed leaves."""
        if self.root_game_count == 0:
            return 0.0
        return (self.total_sealed_games / self.root_game_count) * 100
    
    @property
    def leakage_percent(self) -> float:
        """Percentage of games in leaking leaves (stopped analyzing too early)."""
        if self.root_game_count == 0:
            return 0.0
        return (self.total_leaking_games / self.root_game_count) * 100
    
    @property
    def unaccounted_percent(self) -> float:
        """Percentage of games not covered (opponent moves not in repertoire)."""
        return 100.0 - self.coverage_percent - self.leakage_percent
    
    def summary(self) -> str:
        """Generate a human-readable summary."""
        lines = [
            "=" * 60,
            "REPERTOIRE COVERAGE ANALYSIS",
            "=" * 60,
            f"Root Position Games: {self.root_game_count:,}",
            f"Target Game Count:   {self.target_game_count:,}",
            "",
            f"📊 METRICS:",
            f"   ✅ Coverage:    {self.coverage_percent:6.2f}% ({self.total_sealed_games:,} games in {len(self.sealed_leaves)} sealed leaves)",
            f"   ⚠️  Leakage:     {self.leakage_percent:6.2f}% ({self.total_leaking_games:,} games in {len(self.leaking_leaves)} leaking leaves)",
            f"   ❌ Unaccounted: {self.unaccounted_percent:6.2f}% ({self.total_unaccounted_games:,} games)",
            "",
        ]
        
        if self.leaking_leaves:
            lines.append("🔴 LEAKING LEAVES (need more analysis):")
            for leaf in sorted(self.leaking_leaves, key=lambda x: -x.game_count)[:10]:
                move_str = " ".join(leaf.moves) if leaf.moves else "(root)"
                lines.append(f"   {leaf.game_count:,} games: {move_str}")
            if len(self.leaking_leaves) > 10:
                lines.append(f"   ... and {len(self.leaking_leaves) - 10} more")
        
        lines.append("=" * 60)
        return "\n".join(lines)


class LichessExplorerAPI:
    """
    Lichess Explorer API client with caching and rate limiting.
    
    Supports:
    - Lichess database (online games)
    - Masters database (OTB classical games)
    - Player database (specific player's games)
    """
    
    BASE_URLS = {
        DatabaseType.LICHESS: "https://explorer.lichess.ovh/lichess",
        DatabaseType.MASTERS: "https://explorer.lichess.ovh/masters",
        DatabaseType.PLAYER: "https://explorer.lichess.ovh/player",
    }
    
    def __init__(
        self,
        database: DatabaseType = DatabaseType.LICHESS,
        ratings: str = "1800,2000,2200,2500",
        speeds: str = "blitz,rapid,classical",
        player_name: Optional[str] = None,
        player_color: Optional[str] = None,
        api_token: Optional[str] = None,
        base_delay: float = 0.1,
        max_retries: int = 5,
    ):
        """
        Initialize the API client.
        
        Args:
            database: Which database to query (lichess, masters, or player)
            ratings: Comma-separated rating ranges (for lichess database)
            speeds: Comma-separated time controls (for lichess database)
            player_name: Username for player database queries
            player_color: "white" or "black" for player database
            api_token: Lichess API token (optional but recommended)
            base_delay: Base delay between requests in seconds
            max_retries: Maximum retry attempts for rate limiting
        """
        self.database = database
        self.ratings = ratings
        self.speeds = speeds
        self.player_name = player_name
        self.player_color = player_color
        self.base_delay = base_delay
        self.max_retries = max_retries
        
        # Set up authentication
        self.api_token = api_token or os.getenv("LICHESS") or os.getenv("LICHESS_API_TOKEN")
        self.headers = {"Authorization": f"Bearer {self.api_token}"} if self.api_token else {}
        
        # FEN cache to avoid re-fetching
        self._cache: Dict[str, Dict[str, Any]] = {}
        self._cache_hits = 0
        self._cache_misses = 0
        self._api_calls = 0
    
    def _normalize_fen(self, fen: str) -> str:
        """Normalize FEN by removing move counters (for caching purposes)."""
        # FEN has 6 parts, the last two are halfmove clock and fullmove number
        # We want to cache based on position, not move count
        parts = fen.split()
        if len(parts) >= 4:
            return " ".join(parts[:4])
        return fen
    
    def get_position_data(self, fen: str) -> Optional[Dict[str, Any]]:
        """
        Get position data from the Lichess explorer.
        
        Args:
            fen: FEN string of the position
            
        Returns:
            API response dict or None if request failed
        """
        cache_key = self._normalize_fen(fen)
        
        # Check cache first
        if cache_key in self._cache:
            self._cache_hits += 1
            return self._cache[cache_key]
        
        self._cache_misses += 1
        
        # Build request parameters
        params = {
            "variant": "standard",
            "fen": fen,
        }
        
        if self.database == DatabaseType.LICHESS:
            params["ratings"] = self.ratings
            params["speeds"] = self.speeds
        elif self.database == DatabaseType.PLAYER:
            if not self.player_name:
                raise ValueError("player_name required for player database")
            params["player"] = self.player_name
            if self.player_color:
                params["color"] = self.player_color
        # Masters database doesn't need extra params
        
        base_url = self.BASE_URLS[self.database]
        
        # Request with exponential backoff
        for attempt in range(self.max_retries):
            try:
                # Polite delay
                time.sleep(self.base_delay)
                self._api_calls += 1
                
                response = requests.get(base_url, params=params, headers=self.headers)
                
                if response.status_code == 429:
                    # Rate limited - exponential backoff
                    wait_time = (2 ** attempt) * 30  # 30s, 60s, 120s, 240s, 480s
                    print(f"    [!] Rate limited (429). Attempt {attempt + 1}/{self.max_retries}. "
                          f"Waiting {wait_time}s...")
                    time.sleep(wait_time)
                    continue
                
                if response.status_code == 404:
                    # Position not found (likely very rare position)
                    result = {"white": 0, "black": 0, "draws": 0, "moves": []}
                    self._cache[cache_key] = result
                    return result
                
                response.raise_for_status()
                result = response.json()
                self._cache[cache_key] = result
                return result
                
            except requests.exceptions.RequestException as e:
                if attempt < self.max_retries - 1:
                    wait_time = (2 ** attempt) * 5
                    print(f"    [!] Request failed: {e}. Retrying in {wait_time}s...")
                    time.sleep(wait_time)
                else:
                    print(f"    [!] Request failed after {self.max_retries} attempts: {e}")
                    return None
        
        return None
    
    def get_game_count(self, fen: str) -> int:
        """Get total number of games in a position."""
        data = self.get_position_data(fen)
        if not data:
            return 0
        return data.get("white", 0) + data.get("black", 0) + data.get("draws", 0)
    
    def get_moves_with_counts(self, fen: str) -> List[Dict[str, Any]]:
        """Get all moves from a position with their game counts."""
        data = self.get_position_data(fen)
        if not data:
            return []
        return data.get("moves", [])
    
    def cache_stats(self) -> str:
        """Return cache statistics."""
        total = self._cache_hits + self._cache_misses
        hit_rate = (self._cache_hits / total * 100) if total > 0 else 0
        return (f"Cache: {self._cache_hits} hits, {self._cache_misses} misses "
                f"({hit_rate:.1f}% hit rate), {self._api_calls} API calls")


class RepertoireMoveTree:
    """
    Represents a repertoire as a tree of moves.
    Handles PGN parsing and identification of true leaf nodes.
    """
    
    def __init__(self):
        # Tree structure: dict of FEN -> set of (move_san, resulting_fen)
        self.tree: Dict[str, Set[Tuple[str, str]]] = defaultdict(set)
        self.all_fens: Set[str] = set()
        self.root_fen: Optional[str] = None
    
    def _normalize_fen(self, fen: str) -> str:
        """Normalize FEN for comparison (ignore move counters)."""
        parts = fen.split()
        if len(parts) >= 4:
            return " ".join(parts[:4])
        return fen
    
    def add_line(self, moves: List[str], starting_fen: str = chess.STARTING_FEN):
        """Add a line of moves to the tree."""
        board = chess.Board(starting_fen)
        
        if self.root_fen is None:
            self.root_fen = self._normalize_fen(board.fen())
        
        self.all_fens.add(self._normalize_fen(board.fen()))
        
        for move_san in moves:
            current_fen = self._normalize_fen(board.fen())
            
            try:
                move = board.parse_san(move_san)
                board.push(move)
                resulting_fen = self._normalize_fen(board.fen())
                
                self.tree[current_fen].add((move_san, resulting_fen))
                self.all_fens.add(resulting_fen)
                
            except (ValueError, chess.InvalidMoveError) as e:
                print(f"    [!] Invalid move '{move_san}': {e}")
                break
    
    def load_from_pgn(self, pgn_content: str, starting_moves: Optional[List[str]] = None):
        """
        Load repertoire from PGN content (can contain multiple games/variations).
        
        Args:
            pgn_content: PGN string containing one or more games
            starting_moves: Optional list of moves that define the starting position.
                           If provided, the tree will be rooted at this position.
                           PGN games are expected to start from move 1, and moves
                           before the starting position will be skipped.
        """
        pgn_io = io.StringIO(pgn_content)
        
        # Determine starting position
        start_board = chess.Board()
        skip_moves = 0
        if starting_moves:
            for move_san in starting_moves:
                try:
                    start_board.push_san(move_san)
                    skip_moves += 1
                except ValueError:
                    print(f"    [!] Invalid starting move: {move_san}")
                    return
        
        starting_fen = start_board.fen()
        self.root_fen = self._normalize_fen(starting_fen)
        self.all_fens.add(self.root_fen)
        
        game_count = 0
        while True:
            game = chess.pgn.read_game(pgn_io)
            if game is None:
                break
            
            game_count += 1
            # Process the game, skipping the initial moves if starting_moves provided
            self._process_game_from_root(game, skip_moves, starting_moves or [])
        
        print(f"    Loaded {game_count} games, {len(self.all_fens)} unique positions")
    
    def _process_game_from_root(
        self,
        game: chess.pgn.Game,
        skip_moves: int,
        starting_moves: List[str]
    ):
        """Process a PGN game, potentially skipping initial moves to reach our root."""
        board = chess.Board()
        node = game
        
        # Navigate to the starting position by following the main line
        for _ in range(skip_moves):
            if not node.variations:
                # Game doesn't reach our starting position
                return
            node = node.variations[0]
            board.push(node.move)
        
        # Now process from this node (which is at the starting position)
        self._process_game_node(node, board, starting_moves)
    
    def _process_game_node(
        self,
        node: chess.pgn.GameNode,
        board: chess.Board,
        current_moves: List[str]
    ):
        """Recursively process a PGN game node and its variations."""
        # Add current position to tree
        self.all_fens.add(self._normalize_fen(board.fen()))
        
        # Process main line and all variations
        for child in node.variations:
            move = child.move
            move_san = board.san(move)
            
            current_fen = self._normalize_fen(board.fen())
            
            # Make the move
            board_copy = board.copy()
            board_copy.push(move)
            resulting_fen = self._normalize_fen(board_copy.fen())
            
            # Add to tree
            self.tree[current_fen].add((move_san, resulting_fen))
            
            # Recurse into this variation
            self._process_game_node(child, board_copy, current_moves + [move_san])
    
    def get_leaf_positions(self) -> List[Tuple[str, List[str]]]:
        """
        Find all true leaf positions (positions with no outgoing moves in repertoire).
        
        Returns:
            List of (fen, moves_to_reach) tuples
        """
        # Leaf = a FEN that appears in all_fens but has no entries in tree
        # (or is in tree but has no moves)
        leaves = []
        
        for fen in self.all_fens:
            if fen not in self.tree or len(self.tree[fen]) == 0:
                # This is a leaf - find the path to it
                path = self._find_path_to_fen(fen)
                if path is not None:
                    leaves.append((fen, path))
        
        return leaves
    
    def _find_path_to_fen(self, target_fen: str) -> Optional[List[str]]:
        """Find a path of moves from root to target FEN using BFS."""
        if self.root_fen is None:
            return None
        
        if self._normalize_fen(target_fen) == self.root_fen:
            return []
        
        # BFS to find path
        from collections import deque
        queue = deque([(self.root_fen, [])])
        visited = {self.root_fen}
        
        while queue:
            current_fen, path = queue.popleft()
            
            for move_san, resulting_fen in self.tree.get(current_fen, set()):
                if resulting_fen == target_fen:
                    return path + [move_san]
                
                if resulting_fen not in visited:
                    visited.add(resulting_fen)
                    queue.append((resulting_fen, path + [move_san]))
        
        return None
    
    def get_all_positions_by_depth(self) -> Dict[int, List[Tuple[str, List[str]]]]:
        """Get all positions organized by depth (number of moves from root)."""
        result = defaultdict(list)
        
        from collections import deque
        queue = deque([(self.root_fen, [])])
        visited = {self.root_fen}
        
        result[0].append((self.root_fen, []))
        
        while queue:
            current_fen, path = queue.popleft()
            depth = len(path)
            
            for move_san, resulting_fen in self.tree.get(current_fen, set()):
                if resulting_fen not in visited:
                    visited.add(resulting_fen)
                    new_path = path + [move_san]
                    result[depth + 1].append((resulting_fen, new_path))
                    queue.append((resulting_fen, new_path))
        
        return dict(result)


class CoverageCalculator:
    """
    Calculates coverage metrics for a chess repertoire.
    
    Analyzes how well a repertoire covers potential opponent responses
    using game count data from the Lichess explorer.
    """
    
    def __init__(
        self,
        api: LichessExplorerAPI,
        target_game_count: int = 130_000,
        my_color: chess.Color = chess.WHITE,
    ):
        """
        Initialize the coverage calculator.
        
        Args:
            api: LichessExplorerAPI instance for fetching game data
            target_game_count: Game count threshold for "sealed" vs "leaking"
            my_color: The color the user is playing
        """
        self.api = api
        self.target_game_count = target_game_count
        self.my_color = my_color
    
    def analyze_pgn(
        self,
        pgn_content: str,
        starting_moves: Optional[List[str]] = None,
        progress_callback: Optional[callable] = None,
    ) -> CoverageResult:
        """
        Analyze a PGN repertoire for coverage.
        
        Args:
            pgn_content: PGN string containing the repertoire
            starting_moves: Optional moves defining the starting position
            progress_callback: Optional callback for progress updates
        
        Returns:
            CoverageResult with all metrics
        """
        # Build the move tree
        tree = RepertoireMoveTree()
        if progress_callback:
            progress_callback("Parsing PGN...")
        tree.load_from_pgn(pgn_content, starting_moves)
        
        return self._analyze_tree(tree, progress_callback, starting_moves)
    
    def analyze_moves(
        self,
        moves_list: List[List[str]],
        starting_fen: str = chess.STARTING_FEN,
        starting_moves: Optional[List[str]] = None,
        progress_callback: Optional[callable] = None,
    ) -> CoverageResult:
        """
        Analyze a list of move sequences for coverage.
        
        Args:
            moves_list: List of move sequences (each sequence is a list of SAN moves)
            starting_fen: FEN of the starting position
            starting_moves: Optional moves that define the starting position
            progress_callback: Optional callback for progress updates
        
        Returns:
            CoverageResult with all metrics
        """
        # Build the move tree
        tree = RepertoireMoveTree()
        if progress_callback:
            progress_callback("Building move tree...")
        
        for moves in moves_list:
            tree.add_line(moves, starting_fen)
        
        return self._analyze_tree(tree, progress_callback, starting_moves)
    
    def _analyze_tree(
        self,
        tree: RepertoireMoveTree,
        progress_callback: Optional[callable] = None,
        starting_moves: Optional[List[str]] = None,
    ) -> CoverageResult:
        """Analyze a move tree for coverage."""
        if tree.root_fen is None:
            raise ValueError("Empty repertoire tree")
        
        # Get root game count
        if progress_callback:
            progress_callback("Fetching root position data...")
        
        # Reconstruct the root position board
        root_board = chess.Board()
        if starting_moves:
            for move_san in starting_moves:
                try:
                    root_board.push_san(move_san)
                except ValueError:
                    pass
        
        # Query the API for the root position
        root_game_count = self.api.get_game_count(root_board.fen())
        
        result = CoverageResult(
            root_fen=tree.root_fen,
            root_game_count=root_game_count,
            target_game_count=self.target_game_count,
        )
        
        # Get all leaf positions
        leaves = tree.get_leaf_positions()
        
        if progress_callback:
            progress_callback(f"Analyzing {len(leaves)} leaf positions...")
        
        # Analyze each leaf
        for i, (leaf_fen, moves) in enumerate(leaves):
            if progress_callback and (i + 1) % 10 == 0:
                progress_callback(f"Analyzing leaf {i + 1}/{len(leaves)}...")
            
            # Reconstruct full board position to query API
            # Start from root position (after starting_moves if any)
            board = root_board.copy()
            for move_san in moves:
                try:
                    board.push_san(move_san)
                except ValueError:
                    break
            
            game_count = self.api.get_game_count(board.fen())
            
            # Determine leaf type
            is_game_over = board.is_game_over()
            is_sealed = game_count <= self.target_game_count or is_game_over
            
            reason = self._determine_leaf_reason(board, game_count, is_game_over)
            
            leaf = LeafNode(
                fen=leaf_fen,
                moves=moves,
                game_count=game_count,
                is_sealed=is_sealed,
                reason=reason,
            )
            
            if is_sealed:
                result.sealed_leaves.append(leaf)
                result.total_sealed_games += game_count
            else:
                result.leaking_leaves.append(leaf)
                result.total_leaking_games += game_count
        
        # Calculate unaccounted games
        # These are games where opponent played moves not in our repertoire
        result.total_unaccounted_games = self._calculate_unaccounted(
            tree, result, starting_moves, progress_callback
        )
        
        if progress_callback:
            progress_callback(f"Analysis complete. {self.api.cache_stats()}")
        
        return result
    
    def _determine_leaf_reason(
        self,
        board: chess.Board,
        game_count: int,
        is_game_over: bool
    ) -> str:
        """Determine why a position is a leaf."""
        if is_game_over:
            if board.is_checkmate():
                return "Checkmate"
            elif board.is_stalemate():
                return "Stalemate"
            elif board.is_insufficient_material():
                return "Insufficient material"
            elif board.can_claim_threefold_repetition():
                return "Threefold repetition"
            elif board.can_claim_fifty_moves():
                return "Fifty-move rule"
            else:
                return "Game over"
        elif game_count <= self.target_game_count:
            return f"Target reached ({game_count:,} ≤ {self.target_game_count:,})"
        else:
            return f"Analysis stopped ({game_count:,} > {self.target_game_count:,})"
    
    def _calculate_unaccounted(
        self,
        tree: RepertoireMoveTree,
        result: CoverageResult,
        starting_moves: Optional[List[str]] = None,
        progress_callback: Optional[callable] = None,
    ) -> int:
        """
        Calculate unaccounted games (opponent moves not in repertoire).
        
        For each non-leaf position where it's opponent's turn, sum up
        games from moves that aren't in our repertoire.
        """
        unaccounted_total = 0
        
        # Reconstruct root board
        root_board = chess.Board()
        if starting_moves:
            for move_san in starting_moves:
                try:
                    root_board.push_san(move_san)
                except ValueError:
                    pass
        
        # Get all positions organized by depth
        positions_by_depth = tree.get_all_positions_by_depth()
        
        total_positions = sum(len(v) for v in positions_by_depth.values())
        checked = 0
        
        for depth, positions in positions_by_depth.items():
            for fen, moves in positions:
                checked += 1
                if progress_callback and checked % 20 == 0:
                    progress_callback(f"Checking unaccounted moves ({checked}/{total_positions})...")
                
                # Reconstruct board from root position
                board = root_board.copy()
                for move_san in moves:
                    try:
                        board.push_san(move_san)
                    except ValueError:
                        break
                
                # Only check positions where it's opponent's turn
                is_my_turn = board.turn == self.my_color
                if is_my_turn:
                    continue
                
                # Skip leaf positions
                if fen not in tree.tree or len(tree.tree[fen]) == 0:
                    continue
                
                # Get all moves from this position according to API
                api_moves = self.api.get_moves_with_counts(board.fen())
                
                # Get moves that are in our repertoire
                repertoire_moves = {move_san for move_san, _ in tree.tree[fen]}
                
                # Count games from moves NOT in our repertoire
                for move_data in api_moves:
                    move_san = move_data.get("san", "")
                    if move_san and move_san not in repertoire_moves:
                        move_games = (
                            move_data.get("white", 0) +
                            move_data.get("black", 0) +
                            move_data.get("draws", 0)
                        )
                        unaccounted_total += move_games
        
        return unaccounted_total


def calculate_coverage(
    pgn_or_moves: str | List[List[str]],
    target_game_count: int = 130_000,
    starting_moves: Optional[List[str]] = None,
    my_color: str = "white",
    database: str = "lichess",
    ratings: str = "1800,2000,2200,2500",
    speeds: str = "blitz,rapid,classical",
    player_name: Optional[str] = None,
    verbose: bool = True,
) -> CoverageResult:
    """
    Main entry point for coverage calculation.
    
    Args:
        pgn_or_moves: Either a PGN string or a list of move sequences
        target_game_count: Game count threshold for sealed vs leaking leaves
        starting_moves: Optional moves defining the starting position
        my_color: "white" or "black"
        database: "lichess", "masters", or "player"
        ratings: Rating ranges for lichess database
        speeds: Time controls for lichess database
        player_name: Username for player database
        verbose: Print progress messages
    
    Returns:
        CoverageResult with all metrics
    
    Example:
        >>> result = calculate_coverage(
        ...     open("my_repertoire.pgn").read(),
        ...     target_game_count=50000,
        ...     starting_moves=["e4", "c6", "d4", "d5"],  # Caro-Kann
        ...     my_color="white"
        ... )
        >>> print(result.summary())
    """
    # Set up API
    db_type = DatabaseType[database.upper()]
    api = LichessExplorerAPI(
        database=db_type,
        ratings=ratings,
        speeds=speeds,
        player_name=player_name,
    )
    
    # Set up calculator
    color = chess.WHITE if my_color.lower() == "white" else chess.BLACK
    calculator = CoverageCalculator(
        api=api,
        target_game_count=target_game_count,
        my_color=color,
    )
    
    # Progress callback
    def progress(msg):
        if verbose:
            print(f"  {msg}")
    
    # Analyze
    if isinstance(pgn_or_moves, str):
        # PGN string
        result = calculator.analyze_pgn(
            pgn_or_moves,
            starting_moves=starting_moves,
            progress_callback=progress,
        )
    else:
        # List of move sequences - these should be moves FROM the starting position
        starting_fen = chess.STARTING_FEN
        if starting_moves:
            board = chess.Board()
            for move in starting_moves:
                board.push_san(move)
            starting_fen = board.fen()
        
        result = calculator.analyze_moves(
            pgn_or_moves,
            starting_fen=starting_fen,
            starting_moves=starting_moves,
            progress_callback=progress,
        )
    
    return result


def main():
    """CLI interface for the coverage calculator."""
    import argparse
    
    parser = argparse.ArgumentParser(
        description="Calculate coverage metrics for a chess repertoire.",
        formatter_class=argparse.RawTextHelpFormatter,
    )
    
    parser.add_argument(
        "pgn_file",
        type=str,
        help="Path to PGN file containing the repertoire",
    )
    
    parser.add_argument(
        "--target", "-t",
        type=int,
        default=130_000,
        help="Target game count threshold (default: 130,000)",
    )
    
    parser.add_argument(
        "--color", "-c",
        type=str,
        choices=["white", "black"],
        default="white",
        help="Your color in the repertoire (default: white)",
    )
    
    parser.add_argument(
        "--moves", "-m",
        type=str,
        default="",
        help="Starting moves (space-separated, e.g., 'e4 c6 d4 d5')",
    )
    
    parser.add_argument(
        "--database", "-d",
        type=str,
        choices=["lichess", "masters", "player"],
        default="lichess",
        help="Database to use (default: lichess)",
    )
    
    parser.add_argument(
        "--ratings",
        type=str,
        default="1800,2000,2200,2500",
        help="Rating ranges for lichess database (default: 1800,2000,2200,2500)",
    )
    
    parser.add_argument(
        "--speeds",
        type=str,
        default="blitz,rapid,classical",
        help="Time controls for lichess database (default: blitz,rapid,classical)",
    )
    
    parser.add_argument(
        "--player",
        type=str,
        help="Player username for player database",
    )
    
    parser.add_argument(
        "--quiet", "-q",
        action="store_true",
        help="Suppress progress output",
    )
    
    args = parser.parse_args()
    
    # Read PGN file
    try:
        with open(args.pgn_file, "r") as f:
            pgn_content = f.read()
    except FileNotFoundError:
        print(f"Error: File not found: {args.pgn_file}")
        return 1
    except IOError as e:
        print(f"Error reading file: {e}")
        return 1
    
    # Parse starting moves
    starting_moves = args.moves.split() if args.moves else None
    
    # Run analysis
    print(f"\n🔍 Analyzing repertoire: {args.pgn_file}")
    print(f"   Target game count: {args.target:,}")
    print(f"   Database: {args.database}")
    if starting_moves:
        print(f"   Starting position: {' '.join(starting_moves)}")
    print()
    
    result = calculate_coverage(
        pgn_content,
        target_game_count=args.target,
        starting_moves=starting_moves,
        my_color=args.color,
        database=args.database,
        ratings=args.ratings,
        speeds=args.speeds,
        player_name=args.player,
        verbose=not args.quiet,
    )
    
    print("\n" + result.summary())
    
    return 0


if __name__ == "__main__":
    exit(main())

