#!/usr/bin/env python3
"""Prove the bundled bughouse engine can actually run on this platform.

Two questions, deliberately separated because only one of them can be answered
on a developer machine or on a CI runner that already has everything:

  deps  -- Static. For every platform's assets that are present, read the
           binaries' own import tables and check that nothing they need is
           left to luck. This is the check that catches the Windows failure a
           Windows runner cannot: `onnxruntime.dll` imports MSVCP140.dll and
           friends, which come with the Visual C++ redistributable and are
           installed on every CI image and on no fresh Windows install.
           Runs on any host and audits any platform's assets.

  run   -- Live. Extract this host's engine exactly the way the app does,
           start it, and require the whole handshake: banner, backend line,
           `uciok`, `readyok`, and a real search that returns a joint move.
           This is the answer to "does the network load on Windows".

    python3 tools/test_bughouse_engine.py            # both, host platform
    python3 tools/test_bughouse_engine.py deps       # static audit only
    python3 tools/test_bughouse_engine.py deps --all # every fetched platform
    python3 tools/test_bughouse_engine.py run        # live launch only

Standard library only, and it reads assets/bughouse/ rather than a build, so
it can run before or without a Flutter build.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import os
import platform
import shutil
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS = REPO_ROOT / "assets" / "bughouse"

sys.path.insert(0, str(REPO_ROOT / "tools"))
from fetch_bughouse import TARGETS, host_target, manifest_key  # noqa: E402

NETWORK = "hivemind.onnx"

# The engine's directory is the first place every platform's loader looks, so
# a dependency is "covered" when it is one of these, or when the OS itself
# guarantees it.
BESIDE_THE_ENGINE = {"onnxruntime.dll", "libonnxruntime.so.1", "libonnxruntime.dylib"}

# Deployed beside the engine by BughouseBundle.installWindowsRuntime, copied
# from the app's own directory where windows/CMakeLists.txt puts them. Named
# here so the audit can say "covered, but only because the app copies it" --
# the day that copy is dropped, this list is what the audit is measured
# against and the Dart test in test/features/bughouse/ is what fails.
WINDOWS_APP_DEPLOYED_PREFIXES = ("msvcp140", "vcruntime140", "concrt140")

# Present on a clean Windows 10/11. The Universal CRT (api-ms-win-crt-*) is
# part of the OS since Windows 10; the MSVC C++ runtime (MSVCP140 etc.) is
# emphatically not, which is the whole point of this check.
WINDOWS_SYSTEM_DLLS = {
    "advapi32.dll", "bcrypt.dll", "cfgmgr32.dll", "combase.dll", "crypt32.dll",
    "d3d12.dll", "dbghelp.dll", "dxgi.dll", "gdi32.dll", "kernel32.dll",
    "kernelbase.dll", "ktmw32.dll", "mswsock.dll", "ncrypt.dll", "netapi32.dll",
    "ntdll.dll", "ole32.dll", "oleaut32.dll", "pdh.dll", "powrprof.dll",
    "psapi.dll", "rpcrt4.dll", "setupapi.dll", "shell32.dll", "shlwapi.dll",
    "user32.dll", "userenv.dll", "version.dll", "winmm.dll", "ws2_32.dll",
    "wldap32.dll",
}

# The KnownDLLs list Windows maps from System32 before it searches anywhere,
# so no directory earlier in the search order can shadow one of these. Every
# other system DLL can be, which is what makes it worth diagnosing.
WINDOWS_KNOWN_DLLS = {
    "advapi32.dll", "combase.dll", "crypt32.dll", "gdi32.dll", "kernel32.dll",
    "kernelbase.dll", "ntdll.dll", "ole32.dll", "oleaut32.dll", "psapi.dll",
    "rpcrt4.dll", "shell32.dll", "shlwapi.dll", "user32.dll", "ws2_32.dll",
}

# Present on any glibc Linux desktop the app supports.
LINUX_SYSTEM_LIBS = {
    "libc.so.6", "libm.so.6", "libdl.so.2", "libpthread.so.0", "librt.so.1",
    "libstdc++.so.6", "libgcc_s.so.1", "ld-linux-x86-64.so.2",
    "libatomic.so.1", "libresolv.so.2",
}

# The oldest toolchain the released binaries may require, so a build made on a
# bleeding-edge distro cannot quietly stop running on a supported one.
MAX_GLIBC = (2, 31)      # Ubuntu 20.04 LTS
MAX_GLIBCXX = (3, 4, 28)  # ditto


class Failure(Exception):
    pass


def fail(message: str) -> None:
    raise Failure(message)


# ------------------------------------------------------------------ binaries

def pe_imports(data: bytes) -> list[str]:
    """DLL names in a PE file's import directory."""
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        fail("not a PE file")
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    dirs = opt + (112 if magic == 0x20B else 96)
    imp_rva = struct.unpack_from("<I", data, dirs + 8)[0]

    sections = []
    sec_off = opt + struct.unpack_from("<H", data, pe + 20)[0]
    for i in range(nsec):
        o = sec_off + 40 * i
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, o + 8)
        sections.append((vaddr, max(vsize, rsize), raddr))

    def offset(rva: int) -> int:
        for vaddr, size, raddr in sections:
            if vaddr <= rva < vaddr + size:
                return raddr + (rva - vaddr)
        fail(f"unmapped RVA {rva:#x}")

    names, entry = [], offset(imp_rva)
    while True:
        chunk = data[entry:entry + 20]
        if len(chunk) < 20 or chunk == b"\0" * 20:
            break
        name_rva = struct.unpack_from("<I", chunk, 12)[0]
        if name_rva == 0:
            break
        at = offset(name_rva)
        names.append(data[at:data.index(b"\0", at)].decode())
        entry += 20
    return names


def elf_needed_and_versions(path: Path) -> tuple[list[str], list[str]]:
    """(DT_NEEDED entries, versioned-symbol tags) via objdump."""
    out = subprocess.run(
        ["objdump", "-p", str(path)], capture_output=True, text=True, check=False
    )
    if out.returncode != 0:
        fail(f"objdump failed on {path.name}: {out.stderr.strip()}")
    needed, versions = [], set()
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] == "NEEDED":
            needed.append(parts[1])
        for token in parts:
            if token.startswith(("GLIBC_", "GLIBCXX_", "CXXABI_")):
                versions.add(token.rstrip(":"))
    return needed, sorted(versions)


def macho_dylibs(path: Path) -> list[str]:
    out = subprocess.run(
        ["otool", "-L", str(path)], capture_output=True, text=True, check=False
    )
    if out.returncode != 0:
        fail(f"otool failed on {path.name}: {out.stderr.strip()}")
    return [
        line.split()[0]
        for line in out.stdout.splitlines()[1:]
        if line.strip()
    ]


def version_tuple(tag: str) -> tuple[int, ...]:
    return tuple(int(p) for p in tag.split("_", 1)[1].split(".") if p.isdigit())


# --------------------------------------------------------------------- deps

BUNDLE_DART = REPO_ROOT / "lib/features/bughouse/services/bughouse_bundle.dart"
LOADER_DART = REPO_ROOT / "lib/features/bughouse/services/windows_loader_check.dart"
CMAKE_WINDOWS = REPO_ROOT / "windows/CMakeLists.txt"


def require_diagnosable(dll: str) -> None:
    """Check the app can still say which file went wrong when this one does.

    `WindowsLoaderCheck` walks the loader's search order and reads each
    candidate's PE header, which is how a user finds out that the 32-bit
    MSVCP140.dll some other toolchain left on their PATH is what stopped the
    engine. It can only report a library it knows to look for, so a new
    external import that nobody adds to that list is a new failure that reports
    itself as silence.
    """
    listed = LOADER_DART.read_text().lower()
    if f"'{dll.lower()}'" not in listed:
        fail(
            f"{dll} is resolved by search, so it can be shadowed, but "
            f"{LOADER_DART.relative_to(REPO_ROOT)} does not list it in "
            "engineDependencies — a machine where it goes wrong would get no "
            "diagnosis at all."
        )


def require_app_deploys(dll: str) -> None:
    """Check the app really does put `dll` where the engine will find it.

    Two halves have to hold, in two languages, and neither compiler can see the
    other: windows/CMakeLists.txt deploys the Visual C++ runtime beside
    chess_auto_prep.exe, and BughouseBundle copies it on from there into the
    engine's own directory, because a child process resolves its imports
    against its own directory and not its parent's. Drop either half and the
    engine dies before `main` on any machine without the redistributable --
    silently, with no stderr, which is exactly the bug this file exists for.
    """
    prefix = next(p for p in WINDOWS_APP_DEPLOYED_PREFIXES if dll.startswith(p))
    dart = BUNDLE_DART.read_text().lower()
    if f"'{prefix}" not in dart and f'"{prefix}' not in dart:
        fail(
            f"{dll} has to be copied beside the engine, but "
            f"{BUNDLE_DART.relative_to(REPO_ROOT)} does not mention '{prefix}'. "
            "See BughouseBundle.installWindowsRuntime."
        )
    if "InstallRequiredSystemLibraries" not in CMAKE_WINDOWS.read_text():
        fail(
            f"{dll} has to ship with the app, but "
            f"{CMAKE_WINDOWS.relative_to(REPO_ROOT)} no longer deploys the "
            "Visual C++ runtime."
        )


def audit_target(name: str, workdir: Path) -> list[str]:
    """Check one platform's engine + runtime. Returns human-readable notes."""
    spec = TARGETS[name]
    files = {}
    for role in ("engine", "runtime"):
        member, dest = spec[role]
        gz = REPO_ROOT / dest
        if not gz.exists():
            return [f"skipped: {gz.relative_to(REPO_ROOT)} not fetched"]
        out = workdir / manifest_key(dest)
        out.write_bytes(gzip.decompress(gz.read_bytes()))
        files[role] = out

    notes = []
    deployed = {p.name.lower() for p in files.values()} | {
        n.lower() for n in BESIDE_THE_ENGINE
    }

    if name == "bughouse-windows":
        for role, path in files.items():
            for dll in pe_imports(path.read_bytes()):
                low = dll.lower()
                if low.startswith("api-ms-win-"):
                    continue
                if low in WINDOWS_SYSTEM_DLLS:
                    # KnownDLLs can only ever come from System32; the rest of
                    # System32 can be shadowed by an earlier directory, so the
                    # app has to be able to name them.
                    if low not in WINDOWS_KNOWN_DLLS:
                        require_diagnosable(dll)
                    continue
                if low in deployed:
                    require_diagnosable(dll)
                    continue
                if low.startswith(WINDOWS_APP_DEPLOYED_PREFIXES):
                    require_app_deploys(low)
                    require_diagnosable(dll)
                    notes.append(
                        f"{path.name} needs {dll} — not part of Windows, "
                        "covered only because the app copies it beside the engine"
                    )
                    continue
                fail(
                    f"{path.name} imports {dll}, which is neither guaranteed by "
                    "Windows nor shipped beside the engine. A machine without it "
                    "sees the engine start and never answer."
                )
        return notes

    if name.startswith("bughouse-macos"):
        if platform.system() != "Darwin":
            return ["skipped: needs otool (macOS host)"]
        for role, path in files.items():
            for dylib in macho_dylibs(path):
                base = os.path.basename(dylib)
                if dylib.startswith(("/usr/lib/", "/System/")):
                    continue
                if dylib.startswith(("@rpath/", "@loader_path/", "@executable_path/")):
                    if base.lower() in deployed:
                        continue
                fail(f"{path.name} loads {dylib}, which is not shipped beside it")
        return notes

    # Linux.
    for role, path in files.items():
        needed, versions = elf_needed_and_versions(path)
        for lib in needed:
            if lib in LINUX_SYSTEM_LIBS or lib.lower() in deployed:
                continue
            fail(f"{path.name} needs {lib}, which is not shipped beside it")
        for tag in versions:
            got = version_tuple(tag)
            ceiling = MAX_GLIBC if tag.startswith("GLIBC_") else (
                MAX_GLIBCXX if tag.startswith("GLIBCXX_") else None
            )
            if ceiling and got > ceiling:
                fail(
                    f"{path.name} requires {tag}, newer than the oldest supported "
                    f"distro provides ({'.'.join(map(str, ceiling))}). It was built "
                    "on too new a toolchain to redistribute."
                )
        notes.append(
            f"{path.name}: max "
            + ", ".join(
                sorted(
                    {
                        max((v for v in versions if v.startswith(pre)), default="", key=version_tuple)
                        for pre in ("GLIBC_", "GLIBCXX_", "CXXABI_")
                    }
                    - {""}
                )
            )
        )
    return notes


def cmd_deps(args) -> int:
    names = sorted(TARGETS) if args.all else [host_target()]
    problems = 0
    with tempfile.TemporaryDirectory() as td:
        for name in names:
            print(f"[deps] {name}")
            work = Path(td) / name
            work.mkdir(parents=True, exist_ok=True)
            try:
                notes = audit_target(name, work)
                for note in notes:
                    print(f"       {note}")
                if not any(n.startswith("skipped") for n in notes):
                    print("       ok — every dependency is guaranteed or shipped")
            except Failure as exc:
                print(f"  FAIL {exc}", file=sys.stderr)
                problems += 1
    return 1 if problems else 0


# ---------------------------------------------------------------------- run

def install_like_the_app(target: Path) -> tuple[Path, Path]:
    """Extract the host engine, runtime and network the way BughouseBundle does.

    Same three files, same names, same size check against manifest.json, so a
    manifest that does not describe what actually ships fails here rather than
    on a user's machine.
    """
    name = host_target()
    spec = TARGETS[name]
    manifest = json.loads((ASSETS / "manifest.json").read_text())
    target.mkdir(parents=True, exist_ok=True)

    paths = {}
    sources = [spec["engine"][1], spec["runtime"][1], "assets/bughouse/hivemind.onnx.gz"]
    for dest in sources:
        gz = REPO_ROOT / dest
        if not gz.exists():
            fail(f"{dest} is missing — run: python3 tools/fetch_bughouse.py")
        out = target / manifest_key(dest)
        payload = gzip.decompress(gz.read_bytes())
        out.write_bytes(payload)
        record = manifest.get(out.name)
        if record is None:
            fail(f"manifest.json does not describe {out.name}")
        expected = record["bytes"] if isinstance(record, dict) else record
        if expected != len(payload):
            fail(
                f"{out.name} is {len(payload)} bytes, manifest.json says {expected}. "
                "The app deletes and re-extracts on every launch when these differ."
            )
        if isinstance(record, dict):
            actual_hash = hashlib.sha256(payload).hexdigest()
            if record.get("sha256") != actual_hash:
                fail(
                    f"{out.name} SHA-256 is {actual_hash}, "
                    f"manifest.json says {record.get('sha256')}"
                )
        paths[dest] = out

    engine = paths[spec["engine"][1]]
    if os.name != "nt":
        engine.chmod(0o755)
    return engine, target / NETWORK


def install_windows_runtime(source: Path, target: Path) -> list[str]:
    """Copy the final app bundle's VC++ runtime beside the extracted engine.

    This is deliberately the same prefix contract as
    BughouseBundle.installWindowsRuntime. The pre-build engine check used to
    run against the hosted runner's centrally installed runtime, then merely
    assert that the final app contained some DLLs. Running with these exact
    files after the Flutter build is what proves the portable package users
    receive rather than the unusually well-provisioned CI machine.
    """
    prefixes = WINDOWS_APP_DEPLOYED_PREFIXES
    copied: list[str] = []
    for candidate in source.iterdir():
        lower = candidate.name.lower()
        if not candidate.is_file() or not lower.endswith(".dll"):
            continue
        if not lower.startswith(prefixes):
            continue
        shutil.copy2(candidate, target / candidate.name)
        copied.append(candidate.name)

    required = {
        "msvcp140.dll",
        "msvcp140_1.dll",
        "vcruntime140.dll",
        "vcruntime140_1.dll",
    }
    missing = sorted(required - {name.lower() for name in copied})
    if missing:
        fail(
            f"{source} does not contain the final VC++ runtime: "
            + ", ".join(missing)
        )
    return sorted(copied, key=str.lower)


def cmd_run(args) -> int:
    # `--install-to` leaves the extraction behind so a later step can drive the
    # same three files through the app's own Dart client, which is the only
    # thing that proves the *app* works on this platform rather than the engine.
    with tempfile.TemporaryDirectory() as td:
        work = Path(args.install_to).resolve() if args.install_to else Path(td) / "bughouse"
        engine, network = install_like_the_app(work)
        print(f"[run]  {engine.name} + {network.name} in {work}")

        if args.windows_runtime_from:
            if os.name != "nt":
                fail("--windows-runtime-from is only meaningful on Windows")
            source = Path(args.windows_runtime_from).resolve()
            if not source.is_dir():
                fail(f"Windows runtime directory does not exist: {source}")
            copied = install_windows_runtime(source, work)
            print("       app-local VC++ runtime: " + ", ".join(copied))

        env = dict(os.environ)
        if sys.platform == "darwin":
            env["DYLD_LIBRARY_PATH"] = str(work)
        elif os.name == "nt":
            root = env.get("SystemRoot", r"C:\Windows")
            path_key = next((key for key in env if key.lower() == "path"), "PATH")
            env[path_key] = ";".join(
                [
                    str(work),
                    str(Path(root) / "System32"),
                    root,
                    str(Path(root) / "System32" / "Wbem"),
                ]
            )
        else:
            env["LD_LIBRARY_PATH"] = str(work)

        started = time.time()
        proc = subprocess.Popen(
            [str(engine), "--model", str(network)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, env=env,
        )

        lines: list[str] = []
        errors: list[str] = []
        done = threading.Event()

        def pump(stream, sink):
            for line in stream:
                sink.append(line.rstrip())
            done.set()

        threading.Thread(target=pump, args=(proc.stdout, lines), daemon=True).start()
        threading.Thread(target=pump, args=(proc.stderr, errors), daemon=True).start()

        def send(text: str) -> None:
            proc.stdin.write(text + "\n")
            proc.stdin.flush()

        def wait_for(token: str, seconds: float, what: str) -> float:
            deadline = time.time() + seconds
            while time.time() < deadline:
                if any(line.strip() == token or line.startswith(token) for line in lines):
                    return time.time() - started
                if proc.poll() is not None:
                    fail(
                        f"engine exited ({proc.returncode}) before {what}"
                        + ("\n  " + "\n  ".join(errors) if errors else "")
                    )
                time.sleep(0.05)
            fail(
                f"no {what} within {seconds:.0f}s"
                + ("\n  " + "\n  ".join(errors) if errors else
                   "\n  the engine printed nothing at all" if not lines else "")
            )

        try:
            send("uci")
            at = wait_for("uciok", args.timeout, "uciok")
            print(f"       uciok after {at:.1f}s")

            backend = next(
                (l for l in lines if l.startswith("info string backend")), None
            )
            if backend is None:
                fail("the engine never reported a backend, so the network never loaded")
            if "model" not in backend:
                fail(f"backend line names no model: {backend}")
            print(f"       {backend}")

            send("isready")
            at = wait_for("readyok", args.timeout, "readyok")
            print(f"       readyok after {at:.1f}s")

            send("setoption name Team value white")
            send("position fen " + START_DUAL_FEN)
            send(f"go nodes {args.nodes}")
            wait_for("bestmove", args.search_timeout, "bestmove")
            best = next(l for l in lines if l.startswith("bestmove"))
            print(f"       {best}")
            if "(" not in best or "," not in best:
                fail(f"bestmove is not a joint action: {best}")
            if not any(" nodes " in l for l in lines if l.startswith("info ")):
                fail("the search reported no nodes, so nothing was evaluated")
        except Failure as exc:
            print(f"  FAIL {exc}", file=sys.stderr)
            return 1
        finally:
            try:
                send("quit")
                proc.wait(timeout=5)
            except Exception:
                proc.kill()

    print("\nThe bughouse engine loads its network and searches on this platform.")
    if args.install_to:
        print(f"HIVEMIND_BIN={engine}")
        print(f"HIVEMIND_MODEL={network}")
        print(f"HIVEMIND_LIB={engine.parent}")
    return 0


START_DUAL_FEN = (
    "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1"
    "|rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1"
)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = ap.add_subparsers(dest="command")

    deps = sub.add_parser("deps", help="static dependency audit")
    deps.add_argument("--all", action="store_true",
                      help="audit every platform whose assets are fetched")
    deps.set_defaults(func=cmd_deps)

    run = sub.add_parser("run", help="extract and drive the host engine")
    run.add_argument("--timeout", type=float, default=90.0)
    run.add_argument("--search-timeout", type=float, default=120.0)
    run.add_argument("--nodes", type=int, default=400)
    run.add_argument("--install-to", metavar="DIR",
                     help="extract into DIR and keep it, instead of a temp dir")
    run.add_argument(
        "--windows-runtime-from",
        metavar="DIR",
        help="copy the final app bundle's VC++ DLLs beside the engine before launch",
    )
    run.set_defaults(func=cmd_run)

    args = ap.parse_args()
    if args.command:
        return args.func(args)

    deps_args = ap.parse_args(["deps"])
    rc = cmd_deps(deps_args)
    if rc:
        return rc
    print()
    return cmd_run(ap.parse_args(["run"]))


if __name__ == "__main__":
    raise SystemExit(main())
