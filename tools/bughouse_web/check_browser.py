"""Test on an ordinary static file server; no engine/API process exists."""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import threading

ROOT = Path(__file__).resolve().parents[2]
FRONTEND = ROOT / "python/twic-position-finder/frontend"
OUTPUT = ROOT / "build/bughouse-web"


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(["npm", "run", "build"], cwd=FRONTEND, check=True)
    with ThreadingHTTPServer(("127.0.0.1", 0), partial(QuietHandler, directory=FRONTEND / "dist")) as server:
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            subprocess.run(["node", "scripts/test-bughouse.mjs",
                            f"http://127.0.0.1:{server.server_port}", str(OUTPUT)], cwd=FRONTEND, check=True)
        finally:
            server.shutdown()


if __name__ == "__main__":
    main()
