"""
Chess engine evaluation using UCI protocol.

Provides position evaluation via Stockfish or other UCI-compatible engines.
"""

import os
import re
import platform
import shutil
import subprocess
from pathlib import Path
from typing import Optional, List

import chess
from dotenv import load_dotenv

load_dotenv()


class UCIEngine:
    """
    Wrapper for UCI-compliant chess engines (Stockfish, etc.)
    """

    def __init__(self, engine_path: str, name: str = "engine"):
        """
        Initialize and start the UCI engine.

        Args:
            engine_path: Path to the engine executable
            name: Display name for the engine
        """
        self.engine_path = engine_path
        self.name = name
        self.process: Optional[subprocess.Popen] = None
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
        self._send_command(f"position fen {board.fen()}")

    def evaluate(
        self,
        board: chess.Board,
        depth: int = 20,
        pov_color: chess.Color = chess.WHITE
    ) -> Optional[float]:
        """
        Evaluate a position and return the score in centipawns.

        The score is from the specified color's perspective:
        - Positive = pov_color is better
        - Negative = opponent is better

        Args:
            board: Position to evaluate
            depth: Search depth
            pov_color: Color to evaluate from

        Returns:
            Score in centipawns, or None if evaluation failed
        """
        self.set_position(board)
        self._send_command(f"go depth {depth}")

        lines = self._wait_for("bestmove")

        # Parse the last info line that contains a score
        score = None
        for line in lines:
            if "score cp" in line:
                match = re.search(r"score cp (-?\d+)", line)
                if match:
                    score = int(match.group(1))
            elif "score mate" in line:
                match = re.search(r"score mate (-?\d+)", line)
                if match:
                    mate_in = int(match.group(1))
                    score = 10000 if mate_in > 0 else -10000

        if score is None:
            return None

        # UCI scores are relative to side to move
        # Convert to POV of the specified color
        if board.turn != pov_color:
            score = -score

        return score

    def quit(self):
        """Shut down the engine."""
        if self.process:
            self._send_command("quit")
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                self.process.kill()
            self.process = None

    def __del__(self):
        """Cleanup on deletion."""
        self.quit()


# === Stockfish Discovery ===

def find_stockfish() -> Optional[str]:
    """
    Try to find Stockfish in various locations.

    Returns:
        Path to stockfish executable, or None if not found
    """
    # Check PATH first
    stockfish_path = shutil.which("stockfish")
    if stockfish_path:
        return stockfish_path

    # Check common installation locations by OS
    system = platform.system()
    common_paths = []

    if system == "Linux":
        common_paths = [
            "/usr/bin/stockfish",
            "/usr/local/bin/stockfish",
            "/usr/games/stockfish",
            Path.home() / ".local/bin/stockfish",
        ]
    elif system == "Darwin":
        common_paths = [
            "/usr/local/bin/stockfish",
            "/opt/homebrew/bin/stockfish",
            Path.home() / ".local/bin/stockfish",
        ]
    elif system == "Windows":
        common_paths = [
            r"C:\Program Files\Stockfish\stockfish.exe",
            Path.home() / "stockfish" / "stockfish.exe",
        ]

    for path in common_paths:
        path = Path(path)
        if path.exists() and path.is_file():
            return str(path)

    return None


def get_stockfish_path(env_path: Optional[str] = None) -> Optional[str]:
    """
    Get Stockfish path, checking env variable and common locations.

    Args:
        env_path: Explicit path from command line or .env

    Returns:
        Path to Stockfish, or None if not found
    """
    # Check explicit path first
    if env_path and Path(env_path).exists():
        return env_path

    # Check environment variable
    env_stockfish = os.getenv("STOCKFISH_PATH")
    if env_stockfish and Path(env_stockfish).exists():
        return env_stockfish

    # Try to find automatically
    return find_stockfish()


def prompt_stockfish_install() -> Optional[str]:
    """
    Prompt user to install Stockfish if not found.

    Returns:
        Path to Stockfish after installation, or None
    """
    system = platform.system()

    print("\n" + "=" * 70)
    print("STOCKFISH NOT FOUND")
    print("=" * 70)
    print("\nStockfish is required for position evaluation in tricks mode.")
    print("\nInstallation commands:")

    if system == "Linux":
        if Path("/etc/fedora-release").exists():
            print("  sudo dnf install stockfish")
        elif Path("/etc/debian_version").exists():
            print("  sudo apt install stockfish")
        elif Path("/etc/arch-release").exists():
            print("  sudo pacman -S stockfish")
        else:
            print("  sudo <package-manager> install stockfish")
    elif system == "Darwin":
        print("  brew install stockfish")
    elif system == "Windows":
        print("  choco install stockfish  (or download from stockfishchess.org)")

    print("\nAlternatively, set STOCKFISH_PATH in your .env file")
    print("=" * 70)

    input("\nPress Enter after installing Stockfish...")

    # Check if it's available now
    stockfish_path = find_stockfish()
    if stockfish_path:
        print(f"✓ Found at: {stockfish_path}")
    return stockfish_path


def create_engine(args) -> Optional[UCIEngine]:
    """
    Factory function to create Stockfish engine if needed.

    Args:
        args: Parsed command-line arguments

    Returns:
        UCIEngine instance, or None if not needed/available
    """
    # Only needed for tricks and pressure modes
    if args.mode not in ("tricks", "pressure"):
        return None

    stockfish_path = get_stockfish_path(args.stockfish)

    if not stockfish_path:
        stockfish_path = prompt_stockfish_install()

    if not stockfish_path:
        print(f"Error: Stockfish is required for {args.mode} mode.")
        return None

    print(f"Loading Stockfish from: {stockfish_path}")
    return UCIEngine(stockfish_path, name="Stockfish")

