"""
Helper to find or install Stockfish automatically.
"""

import platform
import shutil
from pathlib import Path
from typing import Optional


def find_stockfish() -> Optional[str]:
    """
    Try to find Stockfish in various locations.

    Returns:
        Path to stockfish executable, or None if not found
    """
    # 1. Check if it's in PATH
    stockfish_path = shutil.which("stockfish")
    if stockfish_path:
        return stockfish_path

    # 2. Check common installation locations by OS
    system = platform.system()

    common_paths = []
    if system == "Linux":
        common_paths = [
            "/usr/bin/stockfish",
            "/usr/local/bin/stockfish",
            "/usr/games/stockfish",
            Path.home() / ".local/bin/stockfish",
        ]
    elif system == "Darwin":  # macOS
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


def install_stockfish_prompt() -> Optional[str]:
    """
    Prompt user to install stockfish and guide them through it.

    Returns:
        Path to stockfish after installation, or None if cancelled
    """
    print("\n" + "=" * 70)
    print("STOCKFISH NOT FOUND")
    print("=" * 70)
    print("\nStockfish is required for position evaluation.")
    print("\nOptions:")
    print("  1. Install via system package manager (recommended)")
    print("  2. Download manually from https://stockfishchess.org/")
    print("  3. Cancel")

    choice = input("\nChoose an option (1-3): ").strip()

    if choice == "1":
        return install_via_system_package_manager()
    elif choice == "2":
        print_manual_instructions()
        return None
    else:
        print("Cancelled.")
        return None


def install_via_system_package_manager() -> Optional[str]:
    """
    Guide user through system package manager installation.

    Note: This function NEVER runs sudo commands itself - it only
    instructs the user to run them in their own terminal for security.

    Returns:
        Path to stockfish if found after installation
    """
    system = platform.system()

    print("\n" + "=" * 70)
    print("INSTALL STOCKFISH")
    print("=" * 70)
    print("\nPlease run the following command in a new terminal:")
    print("(We don't run sudo commands for security reasons)\n")

    if system == "Linux":
        # Try to detect distro
        distro = None
        if Path("/etc/fedora-release").exists():
            distro = "fedora"
        elif Path("/etc/debian_version").exists():
            distro = "debian"
        elif Path("/etc/arch-release").exists():
            distro = "arch"

        if distro == "fedora":
            cmd = "sudo dnf install stockfish"
        elif distro == "debian":
            cmd = "sudo apt install stockfish"
        elif distro == "arch":
            cmd = "sudo pacman -S stockfish"
        else:
            cmd = "sudo <package-manager> install stockfish"

        print(f"    {cmd}")
        print("\nThis command needs to be run in your terminal with sudo privileges.")

    elif system == "Darwin":
        print("\nIf you have Homebrew:")
        print("  brew install stockfish")
        print("\nIf you have MacPorts:")
        print("  sudo port install stockfish")

    elif system == "Windows":
        print("\nIf you have Chocolatey:")
        print("  choco install stockfish")
        print("\nIf you have Scoop:")
        print("  scoop install stockfish")

    print("\n" + "=" * 70)
    input("Press Enter AFTER you've installed stockfish in another terminal...")

    # Check if it's available now
    stockfish_path = find_stockfish()
    if stockfish_path:
        print(f"✓ Found at: {stockfish_path}")
        return stockfish_path
    else:
        print("⚠ Still not found. You may need to add it to your PATH.")
        return None


def print_manual_instructions():
    """Print manual download instructions."""
    system = platform.system()

    print("\nManual installation:")
    print("1. Go to: https://stockfishchess.org/download/")
    print("2. Download Stockfish for your platform")
    print("3. Extract the binary")

    if system == "Linux" or system == "Darwin":
        print("4. Move it: sudo mv stockfish /usr/local/bin/")
        print("5. Make executable: sudo chmod +x /usr/local/bin/stockfish")
    elif system == "Windows":
        print("4. Add the folder to your PATH environment variable")

    print("\nOr set STOCKFISH_PATH in your .env file")


def get_or_install_stockfish(env_path: Optional[str] = None) -> Optional[str]:
    """
    Main function: Get stockfish path or help user install it.

    Args:
        env_path: Path from .env file if available

    Returns:
        Path to stockfish, or None if unavailable
    """
    # 1. Check env_path first
    if env_path and Path(env_path).exists():
        return env_path

    # 2. Try to find it automatically
    stockfish_path = find_stockfish()
    if stockfish_path:
        return stockfish_path

    # 3. Not found - prompt user
    print("\n⚠ Stockfish not found in PATH or common locations.")
    return install_stockfish_prompt()


if __name__ == "__main__":
    # Test the finder
    path = get_or_install_stockfish()
    if path:
        print(f"\n✓ Stockfish available at: {path}")
    else:
        print("\n✗ Stockfish not available")
