"""Build and exercise the real website/API on loopback; tear down all children.

Run from repo root under scripts/ci.sh with --. No desktop app or user data.
"""

import os
from pathlib import Path
import socket
import subprocess
import sys
import time
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
FRONTEND = ROOT / "python/twic-position-finder/frontend"
OUTPUT = ROOT / "build/bughouse-web"


def main():
    OUTPUT.mkdir(parents=True, exist_ok=True)
    env = dict(os.environ, PUBLIC_BUGHOUSE_API_URL="",
               BUGHOUSE_STATIC_DIR=str(FRONTEND / "dist"))
    subprocess.run(["npm", "run", "build"], cwd=FRONTEND, env=env, check=True)
    with socket.socket() as sock, (OUTPUT / "server.log").open("w") as log:
        sock.bind(("127.0.0.1", 0))
        sock.listen(128)
        url = f"http://127.0.0.1:{sock.getsockname()[1]}"
        proc = subprocess.Popen(
            [sys.executable, "-m", "uvicorn", "server:app", "--app-dir", str(Path(__file__).parent),
             "--fd", str(sock.fileno()), "--workers", "1", "--no-proxy-headers"],
            env=env, pass_fds=(sock.fileno(),), stdout=log, stderr=log)
        try:
            for _ in range(100):
                if proc.poll() is not None:
                    raise RuntimeError("Preview exited; see build/bughouse-web/server.log")
                try:
                    with urllib.request.urlopen(url + "/api/bughouse/health", timeout=.2):
                        break
                except OSError:
                    time.sleep(.1)
            else:
                raise RuntimeError("Preview did not become ready")
            subprocess.run(["node", "scripts/test-bughouse.mjs", url, str(OUTPUT)],
                           cwd=FRONTEND, env=env, check=True)
        finally:
            proc.terminate()
            try:
                proc.wait(timeout=45)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


if __name__ == "__main__":
    main()
