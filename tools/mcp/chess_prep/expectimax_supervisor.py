"""Runs one chapter build and publishes its tree to the app when it exits.

    python3 expectimax_supervisor.py RUN_DIR CHAPTER RUN_ID -- BUILDER ARGV...

The builder saves its tree only on the way out — finished, or interrupted by
SIGINT — so publication belongs to whoever outlives it, and the MCP server
that started the build may be gone by then. This process is what `run.json`
records as the build's pid: SIGINT and SIGTERM are passed to the builder, and
once it has exited the tree is published and `publish.json` says where (or
why not).
"""

from __future__ import annotations

import signal
import subprocess
import sys
import time
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
    from chess_prep import expectimax_chapters as chapters
    from chess_prep.tools import ToolError
else:
    from . import expectimax_chapters as chapters
    from .tools import ToolError


def main(argv: list[str]) -> int:
    if len(argv) < 5 or argv[3] != "--":
        print("usage: RUN_DIR CHAPTER RUN_ID -- BUILDER ARGV...", file=sys.stderr)
        return 2
    directory, chapter, run_id = Path(argv[0]), Path(argv[1]), argv[2]
    command = argv[4:]
    builder = subprocess.Popen(command, stdin=subprocess.DEVNULL)  # noqa: S603

    def forward(signum, _frame):
        try:
            builder.send_signal(signum)
        except OSError:
            pass

    signal.signal(signal.SIGINT, forward)
    signal.signal(signal.SIGTERM, forward)
    code = builder.wait()

    tree = Path(command[-1] + ".tree.json")
    record: dict = {"exit_code": code, "at": time.strftime("%Y-%m-%dT%H:%M:%S")}
    if not tree.is_file():
        record["error"] = "The build saved no tree."
    else:
        try:
            record["published"] = str(chapters.publish(tree, chapter, run_id))
        except (ToolError, OSError) as e:
            record["error"] = str(e)
    chapters.write_publish_record(directory, record)
    print(
        f"Published to {record['published']}" if "published" in record
        else f"Not published: {record['error']}",
        flush=True,
    )
    return code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
