"""
Application configuration.
"""
import os
from pathlib import Path

# Load .env file
try:
    from dotenv import load_dotenv
    load_dotenv()
except ImportError:
    # If python-dotenv is not installed, try to load manually
    env_file = Path(__file__).parent / ".env"
    if env_file.exists():
        with open(env_file) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#') and '=' in line:
                    key, value = line.split('=', 1)
                    os.environ[key] = value

# Application info
APP_NAME = "Chess Auto Prep"
APP_VERSION = "2.0.0"

# Default user
DEFAULT_USERNAME = "BigManArkhangelsk"

# Directories
PROJECT_ROOT = Path(__file__).parent
DATA_DIR = PROJECT_ROOT / "data"
CACHE_DIR = PROJECT_ROOT / "cache"
PIECES_DIR = PROJECT_ROOT / "pieces"

# Ensure directories exist
DATA_DIR.mkdir(exist_ok=True)
CACHE_DIR.mkdir(exist_ok=True)

# Lichess API
LICHESS_API_TOKEN = os.getenv("LICHESS_API_TOKEN")
LICHESS_USERNAME = os.getenv("LICHESS_USERNAME", DEFAULT_USERNAME)

# UI Settings
DEFAULT_BOARD_SIZE = 400
LIGHT_SQUARE_COLOR = (240, 217, 181)
DARK_SQUARE_COLOR = (181, 136, 99)
SELECTED_SQUARE_COLOR = (255, 255, 0, 180)
HIGHLIGHT_COLOR = (100, 150, 255, 80)