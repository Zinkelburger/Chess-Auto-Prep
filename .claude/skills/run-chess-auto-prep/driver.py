#!/usr/bin/env python3
"""Drive the running Chess Auto Prep desktop app from a shell.

    driver.py start [--src DIR] [--worktree]   build + launch (queues on the
                                               shared Flutter lock), daemonised
    driver.py dump [kinds=text,key,tooltip,field]
    driver.py tap text=Play | tooltip=… | key=… | x=10 y=20 [index=N] [count=2]
    driver.py type text="hello" [key=…|text_target=…] [submit=true] [append=true]
    driver.py scroll text=… [dy=300] [dx=0]
    driver.py ss [name]                         screenshot → SHOTS/<name>.png
    driver.py settle | reload | restart | log [n=80] | status | stop

Stdlib only. Talks to `flutter run --machine` over its JSON-RPC stdio, and to
the app through the `ext.chessprep.*` service extensions registered by
lib/debug/agent_driver.dart (only with --dart-define=AGENT_DRIVER=true).

State lives in /tmp/chess-auto-prep-driver/ (override with CHESS_PREP_DRIVER_DIR):
  app.log      everything flutter/the app printed        state.json  pid, appId…
  driver.sock  unix socket the daemon listens on          shots/      screenshots
"""
from __future__ import annotations

import fcntl
import json
import os
import shlex
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]  # .claude/skills/run-chess-auto-prep → repo root
STATE_DIR = Path(os.environ.get("CHESS_PREP_DRIVER_DIR", "/tmp/chess-auto-prep-driver"))
SOCK = STATE_DIR / "driver.sock"
STATE = STATE_DIR / "state.json"
APP_LOG = STATE_DIR / "app.log"
SHOTS = STATE_DIR / "shots"
LOCK = Path(os.environ.get("CHESS_PREP_LOCK", "/tmp/chess-auto-prep-flutter.lock"))
BUILD_TIMEOUT = int(os.environ.get("CHESS_PREP_BUILD_TIMEOUT", "900"))


def flutter_bin() -> str:
    env = os.environ.get("FLUTTER")
    if env:
        return env
    home = Path.home() / "sdk/flutter/bin/flutter"
    if home.exists():
        return str(home)
    return "flutter"


def read_state() -> dict:
    try:
        return json.loads(STATE.read_text())
    except (OSError, ValueError):
        return {}


def write_state(**kw) -> None:
    st = read_state()
    st.update(kw)
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    tmp = STATE.with_suffix(".tmp")
    tmp.write_text(json.dumps(st, indent=1))
    tmp.replace(STATE)


def pid_alive(pid: int | None) -> bool:
    if not pid:
        return False
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


# ---------------------------------------------------------------------------
# Daemon: owns the `flutter run --machine` process and the unix socket
# ---------------------------------------------------------------------------
class Daemon:
    def __init__(self, src: Path):
        self.src = src
        self.proc: subprocess.Popen | None = None
        self.app_id: str | None = None
        self.started = threading.Event()
        self.exited = threading.Event()
        self.next_id = 1
        self.pending: dict[int, dict] = {}
        self.lock = threading.Lock()
        self.log = open(APP_LOG, "a", buffering=1)

    def logline(self, s: str) -> None:
        self.log.write(f"[{time.strftime('%H:%M:%S')}] {s.rstrip()}\n")

    # -- flutter daemon protocol -------------------------------------------
    def send(self, method: str, params: dict | None = None, timeout: float = 60) -> dict:
        with self.lock:
            rid = self.next_id
            self.next_id += 1
            slot = {"event": threading.Event()}
            self.pending[rid] = slot
            msg = json.dumps([{"id": rid, "method": method, "params": params or {}}])
            assert self.proc and self.proc.stdin
            self.proc.stdin.write(msg + "\n")
            self.proc.stdin.flush()
        if not slot["event"].wait(timeout):
            self.pending.pop(rid, None)
            raise TimeoutError(f"{method} timed out after {timeout}s")
        if "error" in slot:
            raise RuntimeError(str(slot["error"]))
        return slot.get("result")

    def reader(self) -> None:
        assert self.proc and self.proc.stdout
        for line in self.proc.stdout:
            line = line.rstrip("\n")
            if not (line.startswith("[{") and line.endswith("}]")):
                self.logline(line)
                continue
            try:
                msgs = json.loads(line)
            except ValueError:
                self.logline(line)
                continue
            for m in msgs:
                self.handle(m)
        self.exited.set()
        self.started.set()

    def handle(self, m: dict) -> None:
        if "id" in m:
            slot = self.pending.pop(m["id"], None)
            if slot is not None:
                if "error" in m:
                    slot["error"] = m["error"]
                else:
                    slot["result"] = m.get("result")
                slot["event"].set()
            return
        ev = m.get("event")
        p = m.get("params") or {}
        if ev == "app.start":
            self.app_id = p.get("appId")
            write_state(appId=self.app_id)
        elif ev == "app.debugPort":
            write_state(vmService=p.get("wsUri"))
            self.logline(f"vm service: {p.get('wsUri')}")
        elif ev == "app.started":
            write_state(status="running", startedAt=time.time())
            self.logline("app started")
            self.started.set()
        elif ev == "app.log":
            self.logline(("ERR " if p.get("error") else "") + str(p.get("log", "")))
        elif ev == "app.progress":
            if p.get("finished"):
                self.logline(f"progress: {p.get('message', '')} (done)")
            elif p.get("message"):
                self.logline(f"progress: {p.get('message')}")
        elif ev == "app.stop":
            self.logline("app stopped")
            self.exited.set()
        elif ev == "daemon.logMessage":
            self.logline(f"{p.get('level')}: {p.get('message')}")

    # -- lifecycle ----------------------------------------------------------
    def launch(self) -> None:
        env = dict(os.environ)
        # Keep the run's own Dart/analysis noise out of the interesting log.
        cmd = [
            flutter_bin(), "run", "-d", "linux", "--machine",
            "--dart-define=AGENT_DRIVER=true",
        ]
        self.logline(f"launch: {shlex.join(cmd)} (cwd {self.src})")
        write_state(status="building", pid=os.getpid(), src=str(self.src),
                    appId=None, vmService=None)
        # The build is the heavy part — hold the machine-wide Flutter lock
        # (shared with scripts/ci.sh) until the app is up, then release it so
        # CI can run while the app just sits there.
        lock_fd = os.open(LOCK, os.O_WRONLY | os.O_CREAT, 0o644)
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            holder = Path(str(LOCK) + ".holder")
            who = holder.read_text().strip() if holder.exists() else "another Flutter job"
            self.logline(f"waiting for the Flutter lock (held by: {who})")
            write_state(status="queued")
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
        Path(str(LOCK) + ".holder").write_text(
            f"pid {os.getpid()} · driver.py start · {time.strftime('%H:%M:%S')}\n")
        write_state(status="building")
        self.proc = subprocess.Popen(
            cmd, cwd=self.src, env=env, text=True, bufsize=1,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log,
        )
        threading.Thread(target=self.reader, daemon=True).start()
        self.started.wait(BUILD_TIMEOUT)
        try:
            Path(str(LOCK) + ".holder").unlink()
        except OSError:
            pass
        fcntl.flock(lock_fd, fcntl.LOCK_UN)
        os.close(lock_fd)
        if self.exited.is_set() or not self.app_id:
            write_state(status="failed")
            raise SystemExit("flutter run exited before the app started — see app.log")

    def ext(self, name: str, params: dict, timeout: float = 30) -> dict:
        # Right after a hot restart main() has not re-registered the
        # extensions yet; give it a few seconds instead of failing.
        for attempt in range(20):
            try:
                return self.send("app.callServiceExtension", {
                    "appId": self.app_id, "methodName": f"ext.chessprep.{name}",
                    "params": params,
                }, timeout=timeout)
            except RuntimeError as e:
                if "method not available" in str(e) and attempt < 19:
                    time.sleep(0.5)
                    continue
                raise
        raise RuntimeError("unreachable")

    def serve(self) -> None:
        if SOCK.exists():
            SOCK.unlink()
        srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        srv.bind(str(SOCK))
        srv.listen(8)
        srv.settimeout(1.0)
        while not self.exited.is_set():
            try:
                conn, _ = srv.accept()
            except socket.timeout:
                continue
            with conn:
                data = b""
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                try:
                    req = json.loads(data or b"{}")
                    resp = self.dispatch(req)
                except Exception as e:  # noqa: BLE001 — report to the client
                    resp = {"error": f"{type(e).__name__}: {e}"}
                conn.sendall((json.dumps(resp) + "\n").encode())
                if req.get("cmd") == "stop":
                    break
        srv.close()
        try:
            SOCK.unlink()
        except OSError:
            pass
        write_state(status="stopped")

    def dispatch(self, req: dict) -> dict:
        cmd = req.get("cmd")
        args = req.get("args", {})
        if cmd == "stop":
            try:
                self.send("app.stop", {"appId": self.app_id}, timeout=15)
            except Exception:  # noqa: BLE001
                pass
            if self.proc and self.proc.poll() is None:
                try:
                    self.proc.wait(10)
                except subprocess.TimeoutExpired:
                    self.proc.kill()
            self.exited.set()
            return {"ok": True}
        if cmd in ("reload", "restart"):
            if self.src != REPO:
                # Driver tooling follows the repo copy even when the app was
                # built from a worktree; the rest of the tree is left alone.
                dst = self.src / "lib/debug/agent_driver.dart"
                dst.write_bytes((REPO / "lib/debug/agent_driver.dart").read_bytes())
            r = self.send("app.restart", {
                "appId": self.app_id, "fullRestart": cmd == "restart",
                "reason": "driver", "pause": False,
            }, timeout=120)
            return {"result": r}
        if cmd == "status":
            return {"state": read_state(), "alive": self.proc is not None and self.proc.poll() is None}
        if cmd == "ss":
            SHOTS.mkdir(parents=True, exist_ok=True)
            name = args.get("name") or time.strftime("%H%M%S")
            path = SHOTS / (name if name.endswith(".png") else f"{name}.png")
            r = self.ext("screenshot", {"path": str(path)})
            return {"result": r}
        if cmd in ("dump", "tap", "type", "scroll", "settle", "ping"):
            return {"result": self.ext(cmd, args)}
        return {"error": f"unknown command {cmd!r}"}


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------
def _gone(why: str) -> None:
    """The app is not there any more. Say so once, actionably, and stop.

    Several agents share this driver dir, so the app can vanish mid-command
    when someone else runs `stop` (or it crashes). Without this an agent gets
    a raw ConnectionResetError traceback and usually mistakes a dead app for a
    broken driver.
    """
    st = read_state()
    SOCK.unlink(missing_ok=True)
    sys.exit(
        f"driver not running ({why}); last state={st.get('status') or 'none'} "
        f"src={st.get('src') or '?'}. Someone may have stopped the app, or it "
        f"crashed — check `driver.py log n=40`, then `driver.py start`."
    )


def client(cmd: str, args: dict) -> dict:
    if not SOCK.exists():
        _gone("no socket")
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(180)
    try:
        s.connect(str(SOCK))
        s.sendall((json.dumps({"cmd": cmd, "args": args}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            buf += chunk
    except (ConnectionError, FileNotFoundError) as e:
        _gone(f"{type(e).__name__} talking to the daemon")
    except socket.timeout:
        sys.exit(f"timed out after 180s on `{cmd}` — the app is wedged; `driver.py log n=40`")
    finally:
        s.close()
    if not buf:
        _gone("daemon closed the connection without answering")
    return json.loads(buf)


def parse_args(argv: list[str]) -> tuple[dict, list[str]]:
    kv, rest = {}, []
    for a in argv:
        if "=" in a and not a.startswith("-"):
            k, v = a.split("=", 1)
            kv[k] = v
        else:
            rest.append(a)
    return kv, rest


def print_dump(result: dict) -> None:
    w, h = result.get("size", [0, 0])
    print(f"window {w}x{h}; {len(result.get('items', []))} visible items")
    for it in result.get("items", []):
        x, y, rw, rh = it["rect"]
        print(f"  {it['kind']:<8} {json.dumps(it['value']):<50} @ {x},{y} {rw}x{rh}")


def tail(path: Path, n: int) -> str:
    try:
        lines = path.read_text(errors="replace").splitlines()
    except OSError:
        return ""
    return "\n".join(lines[-n:])


def cmd_start(argv: list[str]) -> None:
    kv, rest = parse_args(argv)
    src = REPO
    if "--src" in rest:
        src = Path(rest[rest.index("--src") + 1]).resolve()
    elif "--worktree" in rest:
        # Build from a clean snapshot of HEAD plus the driver files, so a
        # half-edited shared working tree cannot break the launch.
        src = make_worktree()
    st = read_state()
    if SOCK.exists() and pid_alive(st.get("pid")):
        print(f"already running (pid {st['pid']}, src {st.get('src')}); use it or `driver.py stop`")
        return
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    for f in (SOCK, STATE):
        try:
            f.unlink()
        except OSError:
            pass
    APP_LOG.write_text("")
    child = subprocess.Popen(
        [sys.executable, str(Path(__file__).resolve()), "_serve", str(src)],
        start_new_session=True, stdin=subprocess.DEVNULL,
        stdout=open(STATE_DIR / "daemon.out", "w"), stderr=subprocess.STDOUT,
    )
    print(f"building + launching from {src} (daemon pid {child.pid}); log: {APP_LOG}")
    deadline = time.time() + BUILD_TIMEOUT
    last = ""
    while time.time() < deadline:
        st = read_state()
        status = st.get("status")
        if status != last:
            print(f"  {status}")
            last = status or ""
        if status == "running" and SOCK.exists():
            print(f"ready: appId={st.get('appId')} vm={st.get('vmService')}")
            return
        if status in ("failed", "stopped") or child.poll() is not None:
            print(tail(APP_LOG, 40))
            print(tail(STATE_DIR / "daemon.out", 20))
            sys.exit("launch failed — see above")
        time.sleep(1)
    sys.exit(f"gave up after {BUILD_TIMEOUT}s; see {APP_LOG}")


def make_worktree() -> Path:
    wt = Path(os.environ.get("CHESS_PREP_WORKTREE", "/tmp/chess-auto-prep-worktree"))
    subprocess.run(["git", "-C", str(REPO), "worktree", "prune"], check=False)
    if not (wt / ".git").exists():
        subprocess.run(["git", "-C", str(REPO), "worktree", "add", "--detach", str(wt), "HEAD"], check=True)
    else:
        subprocess.run(["git", "-C", str(wt), "checkout", "--detach", "-f", "HEAD"], check=False)
        subprocess.run(["git", "-C", str(wt), "reset", "--hard", subprocess.check_output(
            ["git", "-C", str(REPO), "rev-parse", "HEAD"], text=True).strip()], check=True)
    # The extension file may be newer than HEAD: overlay it, and splice the
    # two-line hook into HEAD's main.dart (copying the working main.dart
    # would drag in whatever else is half-edited there).
    (wt / "lib/debug").mkdir(parents=True, exist_ok=True)
    (wt / "lib/debug/agent_driver.dart").write_bytes((REPO / "lib/debug/agent_driver.dart").read_bytes())
    main_dart = wt / "lib/main.dart"
    src = main_dart.read_text()
    if "installAgentDriver" not in src:
        src = src.replace("import 'core/study_controller.dart';\n",
                          "import 'core/study_controller.dart';\nimport 'debug/agent_driver.dart';\n", 1)
        src = src.replace("        WidgetsFlutterBinding.ensureInitialized();\n",
                          "        WidgetsFlutterBinding.ensureInitialized();\n        installAgentDriver();\n", 1)
        assert "installAgentDriver();" in src, "could not splice installAgentDriver into main.dart"
        main_dart.write_text(src)
    return wt


def main(argv: list[str]) -> None:
    if not argv or argv[0] in ("-h", "--help"):
        print(__doc__)
        return
    cmd, rest = argv[0], argv[1:]
    if cmd == "_serve":
        src = Path(rest[0])
        d = Daemon(src)
        d.launch()
        d.serve()
        return
    if cmd == "start":
        cmd_start(rest)
        return
    if cmd == "log":
        kv, _ = parse_args(rest)
        print(tail(APP_LOG, int(kv.get("n", "80"))))
        return
    if cmd == "status":
        st = read_state()
        alive = pid_alive(st.get("pid"))
        # Trust the pid, not the state file: a daemon killed mid-run leaves
        # `status: running` behind, and an agent that believes it waits forever.
        print(json.dumps({
            "state": st,
            "alive": alive,
            "socket": SOCK.exists(),
            "usable": alive and SOCK.exists(),
        }, indent=1))
        return
    kv, positional = parse_args(rest)
    if cmd == "ss" and positional:
        kv["name"] = positional[0]
    resp = client(cmd, kv)
    if "error" in resp:
        sys.exit(f"error: {resp['error']}")
    result = resp.get("result", resp)
    if cmd == "dump":
        print_dump(result)
    else:
        print(json.dumps(result, indent=1) if isinstance(result, (dict, list)) else result)


if __name__ == "__main__":
    main(sys.argv[1:])
