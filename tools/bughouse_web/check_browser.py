"""Static frontend plus an isolated API database for browser verification."""

from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import subprocess
import argparse
import os
import signal
import socket
import sys
import tempfile
import time
import urllib.request
import threading

ROOT = Path(__file__).resolve().parents[2]
FRONTEND = ROOT / "python/twic-position-finder/frontend"
OUTPUT = ROOT / "build/bughouse-web"


class QuietHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--serve-only', action='store_true', help='Keep a disposable preview for interactive browser checks')
    parser.add_argument('--port', type=int, default=0)
    parser.add_argument('--api-port', type=int, default=0)
    args = parser.parse_args()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='bughouse-browser-') as profile, \
         ThreadingHTTPServer(('127.0.0.1', args.port), partial(QuietHandler, directory=FRONTEND / 'dist')) as server:
        origin = f'http://127.0.0.1:{server.server_port}'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', args.api_port)); api_port = sock.getsockname()[1]
        api_origin = f'http://127.0.0.1:{api_port}'
        env = {**os.environ, 'TWIC_FRONTEND_ORIGIN': origin,
               'BUGHOUSEDB_PATH': profile + '/book.db', 'BUGHOUSE_EXPECTIMAX_PATH': profile + '/expectimax.db',
               'BOOKING_DATABASE_PATH': profile + '/booking.db', 'TWIC_DB_PATH': profile + '/twic.db'}
        serving = False
        api = subprocess.Popen([sys.executable, '-m', 'uvicorn', 'server:app', '--host', '127.0.0.1',
                                '--port', str(api_port)], cwd=FRONTEND.parent, env=env)
        try:
            for _ in range(100):
                if api.poll() is not None: raise RuntimeError('The preview API failed to start')
                try:
                    urllib.request.urlopen(api_origin + '/health', timeout=1).close(); break
                except OSError: time.sleep(.1)
            else: raise RuntimeError('The preview API did not become ready')
            subprocess.run(['npm', 'run', 'build'], cwd=FRONTEND,
                           env={**os.environ, 'PUBLIC_API_URL': api_origin}, check=True)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            serving = True
            print(f'Preview: {origin}/bughouse/ | API: {api_origin} | disposable profile: {profile}', flush=True)
            if args.serve_only:
                signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
                while True: signal.pause()
            else:
                subprocess.run(['node', 'scripts/test-bughouse.mjs', origin, str(OUTPUT), api_origin],
                               cwd=FRONTEND, check=True)
        finally:
            if serving: server.shutdown()
            api.terminate()
            try: api.wait(timeout=10)
            except subprocess.TimeoutExpired: api.kill(); api.wait()


if __name__ == "__main__":
    main()
