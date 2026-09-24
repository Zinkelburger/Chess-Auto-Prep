#!/usr/bin/env python3
"""Regression checks against the shipped Windows Hivemind executable.

Native Windows by default. --wine runs on Linux in a disposable prefix;
--runtime-from copies real VC++ DLLs from a supplied redistributable directory.
"""
import argparse
import gzip
import os
from pathlib import Path, PureWindowsPath
import queue
import shutil
import subprocess
import tempfile
import threading
import time

from bughouse_windows import HERE, verified_engine
from test_bughouse_engine import ASSETS, START_DUAL_FEN, pe_imports


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wine", action="store_true")
    parser.add_argument("--wine-template", type=Path,
                        help="Copy this prepared test prefix into a disposable directory; skip wineboot")
    parser.add_argument("--runtime-from", type=Path)
    args = parser.parse_args()
    if args.wine_template and not args.wine:
        parser.error("--wine-template requires --wine")
    if os.name != "nt" and not args.wine:
        raise SystemExit("Run on Windows or explicitly use --wine")
    payload = verified_engine()
    assert "onnxruntime.dll" not in [n.lower() for n in pe_imports(payload)], "Implicit ORT import remains"
    fixture = gzip.decompress((HERE / "incompatible-runtime.dll.gz").read_bytes())
    with tempfile.TemporaryDirectory(prefix="hivemind-loader-") as td:
        root = Path(td)
        # Relative model argument mirrors the app and avoids locale-dependent
        # argv conversion while the loader still handles a Unicode exe path.
        work = root / "Chess Auto Prep é棋" / "bughouse"
        work.mkdir(parents=True)
        exe = work / "hivemind-windows.exe"
        exe.write_bytes(payload)
        private = work / "hivemind_ort.dll"
        generic = work / "onnxruntime.dll"
        generic.write_bytes(fixture)
        (work / "hivemind.onnx").write_bytes(gzip.decompress((ASSETS / "hivemind.onnx.gz").read_bytes()))
        if args.runtime_from:
            for file in args.runtime_from.iterdir():
                if file.suffix.lower() == ".dll" and file.name.lower().startswith(("msvcp140", "vcruntime140", "concrt140")):
                    shutil.copyfile(file, work / file.name)
        env = dict(os.environ)
        prefix = []
        if args.wine:
            prefix = ["wine"]
            env.update(WINEPREFIX=str(root / "wine"), WINEARCH="win64", WINEDEBUG="-all",
                       WINEDLLOVERRIDES="winemenubuilder.exe,mscoree,mshtml=d")
            if args.wine_template:
                shutil.copytree(args.wine_template, root / "wine", symlinks=True)
                env["WINEDLLOVERRIDES"] += ";wineboot.exe=d"
            else:
                try:
                    subprocess.run(["wine", "wineboot.exe", "-u"], env=env, check=True, timeout=90,
                                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                except Exception:
                    subprocess.run(["wineserver", "-k"], env=env, timeout=15, check=False)
                    subprocess.run(["wineserver", "-w"], env=env, timeout=15, check=False)
                    raise
        else:
            # Remove unrelated toolchains from the DLL search environment.
            path_key = next((k for k in env if k.lower() == "path"), "PATH")
            # A copy of os.environ has Windows' names upper-cased.
            root = next((v for k, v in env.items() if k.lower() == "systemroot"), r"C:\Windows")
            env[path_key] = str(Path(root) / "System32")
        command = prefix + [str(exe), "--model", "hivemind.onnx"]
        try:
            # Even though an old basename DLL is present, missing private ORT
            # must fail promptly without falling back to that DLL or System32.
            for label, expected in [("missing", "Cannot load private ONNX Runtime"),
                                    ("incompatible", "Incompatible ONNX Runtime 1.17.1-test; required API 29"),
                                    ("corrupt", "Cannot load private ONNX Runtime")]:
                if label == "incompatible":
                    private.write_bytes(fixture)
                elif label == "corrupt":
                    private.write_bytes(b"not a PE image")
                result = subprocess.run(command, cwd=work, env=env, input="uci\n", text=True,
                                        capture_output=True, encoding="utf-8", errors="replace", timeout=25)
                assert result.returncode == 1, (label, result.returncode, result.stdout, result.stderr)
                assert expected in result.stderr, (label, result.stderr)
                print(f"PASS {label}: clean exit 1 and actionable runtime error", flush=True)

            private.write_bytes(gzip.decompress((ASSETS / "hivemind_ort.dll.gz").read_bytes()))
            proc = subprocess.Popen(command, cwd=work, env=env, stdin=subprocess.PIPE,
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                    text=True, encoding="utf-8", errors="replace", bufsize=1)
            lines = queue.Queue()
            errors = []

            def pump():
                for line in proc.stdout:
                    lines.put(line.strip())

            def pump_errors():
                for line in proc.stderr:
                    errors.append(line)

            reader = threading.Thread(target=pump, daemon=True)
            error_reader = threading.Thread(target=pump_errors, daemon=True)
            reader.start()
            error_reader.start()

            def send(line):
                proc.stdin.write(line + "\n")
                proc.stdin.flush()

            def wait(token):
                deadline = time.monotonic() + 90
                while time.monotonic() < deadline:
                    try:
                        line = lines.get(timeout=0.1)
                        if line.startswith(token):
                            return line
                    except queue.Empty:
                        if proc.poll() is not None:
                            error_reader.join(timeout=2)
                            raise AssertionError(f"Exited {proc.returncode} before {token}: {''.join(errors)}")
                raise AssertionError(f"Timed out waiting for {token}: {''.join(errors)}")

            try:
                send("uci")
                wait("uciok")
                send("isready")
                wait("readyok")
                send("setoption name Team value white")
                send("position fen " + START_DUAL_FEN)
                send("go nodes 16")
                best = wait("bestmove")
                assert "(" in best and "," in best, best
                send("quit")
                proc.wait(timeout=10)
                error_reader.join(timeout=2)
                report = "".join(errors)
                assert proc.returncode == 0, report
                assert "Hivemind ORT version: 1.29.0; required API: 29" in report, report
                loaded = next(line for line in report.splitlines() if line.startswith("Hivemind ORT loaded path:"))
                assert "Chess Auto Prep é棋" in loaded and loaded.endswith("hivemind_ort.dll"), loaded
                print("PASS private runtime: Unicode path, old basename DLL ignored, model loaded, " + best)
                full_model = str(PureWindowsPath(loaded.split(": ", 1)[1]).parent / "hivemind.onnx")
                absolute = subprocess.run(prefix + [str(exe), "--model", full_model],
                    cwd=work, env=env, input="uci\nisready\nquit\n", capture_output=True,
                    text=True, encoding="utf-8", errors="replace", timeout=90)
                assert absolute.returncode == 0, absolute.stderr
                assert "uciok" in absolute.stdout and "readyok" in absolute.stdout, absolute.stdout
                print("PASS absolute Unicode model argument: readyok and clean exit")
            finally:
                if proc.poll() is None:
                    proc.kill()
                    proc.wait(timeout=10)
        finally:
            if args.wine:
                subprocess.run(["wineserver", "-k"], env=env, timeout=15, check=False)
                subprocess.run(["wineserver", "-w"], env=env, timeout=15, check=False)


if __name__ == "__main__":
    main()
