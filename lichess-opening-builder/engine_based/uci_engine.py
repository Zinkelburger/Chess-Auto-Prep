import subprocess
import chess
from typing import Optional, Dict, List, Tuple
import re


class UCIEngine:
    """
    Wrapper for UCI-compliant chess engines (Stockfish, Maia, etc.)
    """

    def __init__(self, engine_path: str, name: str = "engine"):
        self.engine_path = engine_path
        self.name = name
        self.process = None
        self._start_engine()

    def _start_engine(self):
        """Start the engine process and initialize UCI."""
        self.process = subprocess.Popen(
            [self.engine_path],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            bufsize=1
        )

        self._send_command("uci")
        self._wait_for("uciok")
        self._send_command("isready")
        self._wait_for("readyok")

    def _send_command(self, command: str):
        """Send a command to the engine."""
        if self.process and self.process.stdin:
            self.process.stdin.write(command + "\n")
            self.process.stdin.flush()

    def _wait_for(self, expected: str) -> List[str]:
        """Wait for a specific response from the engine, returning all lines."""
        lines = []
        while True:
            line = self.process.stdout.readline().strip()
            lines.append(line)
            if expected in line:
                break
        return lines

    def set_position(self, board: chess.Board):
        """Set the position on the engine."""
        fen = board.fen()
        self._send_command(f"position fen {fen}")

    def evaluate(self, board: chess.Board, depth: int = 20, time_ms: int = 1000) -> Optional[float]:
        """
        Evaluate a position and return the score in centipawns from white's perspective.
        Returns None if mate is found or evaluation fails.
        """
        self.set_position(board)
        self._send_command(f"go depth {depth}")

        lines = self._wait_for("bestmove")

        # Parse the last info line that contains a score
        score = None
        for line in lines:
            if "score cp" in line:
                # Extract centipawn score
                match = re.search(r"score cp (-?\d+)", line)
                if match:
                    score = int(match.group(1))
            elif "score mate" in line:
                # Handle mate scores
                match = re.search(r"score mate (-?\d+)", line)
                if match:
                    mate_in = int(match.group(1))
                    # Convert mate to a very high/low score
                    score = 10000 if mate_in > 0 else -10000

        return score

    def get_move_probabilities(self, board: chess.Board, top_n: int = 10) -> List[Tuple[str, float]]:
        """
        Get move probabilities from Maia or similar engines that output policy info.
        Returns list of (move_uci, probability) tuples.

        Note: This assumes the engine outputs move probabilities in UCI info lines.
        Maia outputs this as "info string" with policy information.
        """
        self.set_position(board)
        self._send_command(f"go depth 1")

        lines = self._wait_for("bestmove")

        move_probs = []

        # Look for policy information in the output
        # Maia typically outputs: "info string <move> P: <probability>"
        for line in lines:
            if "info string" in line and " P: " in line:
                # Parse Maia-style policy output
                # Example: "info string e2e4 P: 0.234"
                match = re.search(r"info string (\w+) P: ([\d.]+)", line)
                if match:
                    move_uci = match.group(1)
                    prob = float(match.group(2))
                    move_probs.append((move_uci, prob))

        # If no policy info found, fall back to MultiPV analysis
        if not move_probs:
            move_probs = self._get_multipv_analysis(board, top_n)

        # Sort by probability (descending) and return top_n
        move_probs.sort(key=lambda x: x[1], reverse=True)
        return move_probs[:top_n]

    def _get_multipv_analysis(self, board: chess.Board, num_lines: int = 5) -> List[Tuple[str, float]]:
        """
        Use MultiPV to get multiple best moves and approximate probabilities.
        This is a fallback when the engine doesn't provide policy information.
        """
        self.set_position(board)
        self._send_command(f"setoption name MultiPV value {num_lines}")
        self._send_command("go depth 15")

        lines = self._wait_for("bestmove")

        # Parse all the multipv lines to get moves and scores
        pv_data = []
        for line in lines:
            if "multipv" in line and "pv" in line:
                # Extract multipv number, score, and first move
                multipv_match = re.search(r"multipv (\d+)", line)
                score_match = re.search(r"score cp (-?\d+)", line)
                pv_match = re.search(r"pv (\w+)", line)

                if multipv_match and pv_match:
                    multipv_num = int(multipv_match.group(1))
                    move_uci = pv_match.group(1)
                    score = int(score_match.group(1)) if score_match else 0
                    pv_data.append((move_uci, score))

        # Convert scores to probabilities using softmax-like transformation
        # Higher scores = higher probability
        if not pv_data:
            return []

        # Normalize scores to probabilities (simple approach)
        scores = [score for _, score in pv_data]
        min_score = min(scores)
        # Shift scores to be positive
        shifted = [s - min_score + 1 for s in scores]
        total = sum(shifted)

        move_probs = [(move, shifted[i] / total) for i, (move, _) in enumerate(pv_data)]

        # Reset MultiPV
        self._send_command("setoption name MultiPV value 1")

        return move_probs

    def quit(self):
        """Shut down the engine."""
        if self.process:
            self._send_command("quit")
            self.process.wait(timeout=2)
            self.process = None

    def __del__(self):
        """Cleanup on deletion."""
        self.quit()
