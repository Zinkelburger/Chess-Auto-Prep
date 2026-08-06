"""Entry point: `python -m chess_prep`, or run this file directly.

Adding the parent directory to sys.path lets an MCP client invoke it as
`python /abs/path/to/tools/mcp/chess_prep/__main__.py` without any install
step or PYTHONPATH fiddling.
"""

import sys
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from chess_prep.server import main
else:
    from .server import main

if __name__ == "__main__":
    main()
