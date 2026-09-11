"""One disposable search. The HTTP supervisor owns this process group."""

import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/mcp"))

from bughouse.analysis import analyse
from bughouse.engine import HivemindEngine


def main():
    request = json.load(sys.stdin)
    # Never use the MCP singleton: public searches must not share mutable state.
    with HivemindEngine(hash_mb=128, batch_size=8) as engine:
        result = analyse(**request, engine=engine)
    json.dump(result, sys.stdout)


if __name__ == "__main__":
    main()
