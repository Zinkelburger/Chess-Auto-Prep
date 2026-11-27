#!/usr/bin/env python3
# A None here fails the test on its own, so pyright's None checks add nothing.
# pyright: reportOptionalMemberAccess=false, reportOptionalSubscript=false, reportOptionalIterable=false, reportOptionalOperand=false
"""Prove the bundled bughouse engine (HypeBeast) can actually run on this platform.

Two questions, deliberately separated because only one of them can be answered
on a developer machine or on a CI runner that already has everything:

  deps  -- Static. For every platform's binary that is present, read its own
           headers and require that it needs nothing but the operating system:
           a Linux binary is static (no loader, no shared library), a Windows
           binary imports only DLLs every Windows 10/11 has, a macOS binary
           links only /usr/lib and /System. A hosted runner cannot pretend to
           be a clean machine -- every image has the Visual C++ runtime -- but
           it can read what a binary asks for. Pure Python, so it audits any
           platform's binary on any host.

  run   -- Live. Extract this host's engine and network exactly the way the
           app does (manifest size and SHA-256), start it, and require the
           whole conversation: `uciok`, `readyok`, the network loaded (not
           Fairy-Stockfish's classical fallback), a two-board coordinated
           search that answers a joint `bestmove (move,pass)`, and a one-board
           MultiPV search whose every line was really searched.

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
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import NoReturn

REPO_ROOT = Path(__file__).resolve().parent.parent
ASSETS = REPO_ROOT / "assets" / "bughouse"

sys.path.insert(0, str(REPO_ROOT / "tools"))
from fetch_assets import (  # noqa: E402
    BUGHOUSE_NETWORK,
    BUGHOUSE_TARGETS as TARGETS,
    bughouse_host_target as host_target,
    manifest_key,
)

NETWORK = BUGHOUSE_NETWORK["name"]

# Present on a clean Windows 10/11. The Universal CRT (api-ms-win-crt-*) is
# part of the OS since Windows 10; the MSVC C++ runtime (MSVCP140 etc.) and
# MinGW's own DLLs (libstdc++-6, libgcc_s_seh-1, libwinpthread-1) are
# emphatically not, which is the whole point of this check.
WINDOWS_SYSTEM_DLLS = {
    "advapi32.dll", "bcrypt.dll", "cfgmgr32.dll", "combase.dll", "crypt32.dll",
    "dbghelp.dll", "gdi32.dll", "kernel32.dll", "kernelbase.dll", "ntdll.dll",
    "ole32.dll", "oleaut32.dll", "powrprof.dll", "psapi.dll", "rpcrt4.dll",
    "shell32.dll", "shlwapi.dll", "user32.dll", "userenv.dll", "version.dll",
    "winmm.dll", "ws2_32.dll",
}

# What each target's binary must be built for, so a mixed-up asset (the
# Intel Mac binary in the Apple Silicon slot) fails here, not on a user's Mac.
ELF_X86_64 = 62
PE_AMD64 = 0x8664
MACHO_CPU = {0x01000007: "x86_64", 0x0100000C: "arm64"}
TARGET_ARCH = {
    "bughouse-linux": "x86_64",
    "bughouse-windows": "x86_64",
    "bughouse-macos-arm64": "arm64",
    "bughouse-macos-x86_64": "x86_64",
}


class Failure(Exception):
    pass


def fail(message: str) -> NoReturn:
    raise Failure(message)


# ------------------------------------------------------------------ binaries

def _pe_sections(data: bytes) -> tuple[int, list[tuple[int, int, int]]]:
    """(offset of the data directories, [(vaddr, size, raw offset)])."""
    if data[:2] != b"MZ":
        fail("not a PE file")
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if data[pe:pe + 4] != b"PE\0\0":
        fail("not a PE file")
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt = pe + 24
    magic = struct.unpack_from("<H", data, opt)[0]
    dirs = opt + (112 if magic == 0x20B else 96)
    sections = []
    sec_off = opt + struct.unpack_from("<H", data, pe + 20)[0]
    for i in range(nsec):
        o = sec_off + 40 * i
        vsize, vaddr, rsize, raddr = struct.unpack_from("<IIII", data, o + 8)
        sections.append((vaddr, max(vsize, rsize), raddr))
    return dirs, sections


def _pe_names(data: bytes, directory: int, entry_size: int, name_at: int) -> list[str]:
    dirs, sections = _pe_sections(data)
    rva = struct.unpack_from("<I", data, dirs + 8 * directory)[0]
    if rva == 0:
        return []

    def offset(rva: int) -> int:
        for vaddr, size, raddr in sections:
            if vaddr <= rva < vaddr + size:
                return raddr + (rva - vaddr)
        fail(f"unmapped RVA {rva:#x}")

    names, entry = [], offset(rva)
    while True:
        chunk = data[entry:entry + entry_size]
        if len(chunk) < entry_size or chunk == b"\0" * entry_size:
            break
        name_rva = struct.unpack_from("<I", chunk, name_at)[0]
        if name_rva == 0:
            break
        at = offset(name_rva)
        names.append(data[at:data.index(b"\0", at)].decode())
        entry += entry_size
    return names


def pe_imports(data: bytes) -> list[str]:
    """DLL names in a PE file's import directory."""
    return _pe_names(data, directory=1, entry_size=20, name_at=12)


def pe_delay_imports(data: bytes) -> list[str]:
    """DLL names in a PE file's delay-load import directory."""
    return _pe_names(data, directory=13, entry_size=32, name_at=4)


def pe_machine(data: bytes) -> int:
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    return struct.unpack_from("<H", data, pe + 4)[0]


def elf_dependencies(data: bytes) -> tuple[int, str | None, list[str]]:
    """(e_machine, PT_INTERP path or None, DT_NEEDED names) of a 64-bit ELF."""
    if data[:4] != b"\x7fELF":
        fail("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        fail("not a 64-bit little-endian ELF file")
    machine = struct.unpack_from("<H", data, 18)[0]
    phoff = struct.unpack_from("<Q", data, 32)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 54)
    interp, dynamic, loads = None, None, []
    for i in range(phnum):
        p_type, _flags, p_offset, p_vaddr, _paddr, p_filesz = struct.unpack_from(
            "<IIQQQQ", data, phoff + i * phentsize)
        if p_type == 3:  # PT_INTERP
            interp = data[p_offset:p_offset + p_filesz].rstrip(b"\0").decode()
        elif p_type == 2:  # PT_DYNAMIC
            dynamic = (p_offset, p_filesz)
        elif p_type == 1:  # PT_LOAD
            loads.append((p_vaddr, p_filesz, p_offset))
    needed: list[int] = []
    strtab = None
    if dynamic is not None:
        offset, size = dynamic
        for at in range(offset, offset + size, 16):
            tag, value = struct.unpack_from("<qQ", data, at)
            if tag == 0:
                break
            if tag == 1:  # DT_NEEDED
                needed.append(value)
            elif tag == 5:  # DT_STRTAB
                strtab = value
    names = []
    for index in needed:
        file_at = None
        if strtab is not None:
            for vaddr, size, offset in loads:
                if vaddr <= strtab < vaddr + size:
                    file_at = offset + (strtab - vaddr) + index
        names.append(
            data[file_at:data.index(b"\0", file_at)].decode() if file_at is not None
            else f"<library #{index}>"
        )
    return machine, interp, names


MACHO_DYLIB_COMMANDS = {
    0x0C: "LC_LOAD_DYLIB",
    0x20: "LC_LAZY_LOAD_DYLIB",
    0x80000018: "LC_LOAD_WEAK_DYLIB",
    0x8000001F: "LC_REEXPORT_DYLIB",
    0x80000023: "LC_LOAD_UPWARD_DYLIB",
}


def macho_slices(data: bytes) -> list[tuple[str, list[str]]]:
    """[(architecture, linked dylib paths)] for a thin or universal Mach-O."""
    magic = struct.unpack_from(">I", data, 0)[0]
    if magic in (0xCAFEBABE, 0xCAFEBABF):
        count = struct.unpack_from(">I", data, 4)[0]
        wide = magic == 0xCAFEBABF
        slices = []
        for i in range(count):
            if wide:
                _cpu, _sub, offset, size, _align, _res = struct.unpack_from(">IIQQII", data, 8 + 32 * i)
            else:
                _cpu, _sub, offset, size, _align = struct.unpack_from(">IIIII", data, 8 + 20 * i)
            slices += macho_slices(data[offset:offset + size])
        return slices
    if struct.unpack_from("<I", data, 0)[0] != 0xFEEDFACF:
        fail("not a 64-bit Mach-O file")
    cpu, _sub, _filetype, ncmds, _sizeofcmds = struct.unpack_from("<iiIII", data, 4)
    arch = MACHO_CPU.get(cpu & 0xFFFFFFFF, f"cpu {cpu:#x}")
    dylibs, at = [], 32
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from("<II", data, at)
        if cmd in MACHO_DYLIB_COMMANDS:
            name_offset = struct.unpack_from("<I", data, at + 8)[0]
            start = at + name_offset
            dylibs.append(data[start:data.index(b"\0", start)].decode())
        at += cmdsize
    return [(arch, dylibs)]


# --------------------------------------------------------------------- deps

def audit_binary(name: str, data: bytes) -> list[str]:
    """Check one platform's engine needs only the OS. Returns notes."""
    want = TARGET_ARCH[name]
    if name == "bughouse-windows":
        if pe_machine(data) != PE_AMD64:
            fail(f"not an x86-64 Windows binary (machine {pe_machine(data):#x})")
        dlls = pe_imports(data) + pe_delay_imports(data)
        for dll in dlls:
            low = dll.lower()
            if low.startswith("api-ms-win-") or low in WINDOWS_SYSTEM_DLLS:
                continue
            fail(
                f"imports {dll}, which is not part of Windows. A machine without "
                "it sees the engine start and never answer."
            )
        return ["imports only Windows' own DLLs: " + ", ".join(sorted(dlls, key=str.lower))]

    if name.startswith("bughouse-macos"):
        slices = macho_slices(data)
        archs = [arch for arch, _ in slices]
        if want not in archs:
            other = next((t for t, a in TARGET_ARCH.items()
                          if t.startswith("bughouse-macos") and a in archs), None)
            if other:
                return [f"skipped: {TARGETS[name]['dest']} holds the {other} build"]
            fail(f"has no {want} code (has {', '.join(archs)})")
        notes = []
        for arch, dylibs in slices:
            for dylib in dylibs:
                if not dylib.startswith(("/usr/lib/", "/System/Library/")):
                    fail(f"{arch} slice links {dylib}, which is not part of macOS")
            notes.append(f"{arch}: links only " + ", ".join(dylibs))
        return notes

    machine, interp, needed = elf_dependencies(data)
    if machine != ELF_X86_64:
        fail(f"not an x86-64 Linux binary (e_machine {machine})")
    if interp:
        fail(f"is dynamically linked: needs the loader {interp}")
    if needed:
        fail(f"needs shared libraries: {', '.join(needed)}")
    return ["static: no loader, no shared libraries"]


def audit_target(name: str) -> list[str]:
    gz = REPO_ROOT / TARGETS[name]["dest"]
    if not gz.exists():
        return [f"skipped: {gz.relative_to(REPO_ROOT)} not fetched"]
    return audit_binary(name, gzip.decompress(gz.read_bytes()))


def cmd_deps(args) -> int:
    """Without --all the host's platform is asked for, and a binary that is
    not there, or is another architecture's, fails: it was not proven. With
    --all, platforms not fetched are passed over, but at least one must be
    checked."""
    names = sorted(TARGETS) if args.all else [host_target()]
    problems = 0
    checked = 0
    for name in names:
        print(f"[deps] {name}")
        try:
            notes = audit_target(name)
            for note in notes:
                print(f"       {note}")
            if any(n.startswith("skipped") for n in notes):
                if not args.all:
                    raise Failure("the binary for this platform could not be checked")
            else:
                checked += 1
                print("       ok — needs nothing but the operating system")
        except Failure as exc:
            print(f"  FAIL {name}: {exc}", file=sys.stderr)
            problems += 1
    if not problems and not checked:
        print("  FAIL: no platform's binary was fetched to check", file=sys.stderr)
        problems += 1
    return 1 if problems else 0


# ---------------------------------------------------------------------- run

def install_like_the_app(target: Path) -> tuple[Path, Path]:
    """Extract the host engine and the network the way HypeBeastInstall does.

    Same two files, same names, same size and SHA-256 check against
    manifest.json, so a manifest that does not describe what actually ships
    fails here rather than on a user's machine.
    """
    name = host_target()
    manifest = json.loads((ASSETS / "manifest.json").read_text())
    target.mkdir(parents=True, exist_ok=True)

    paths = []
    for dest in (TARGETS[name]["dest"], BUGHOUSE_NETWORK["dest"]):
        gz = REPO_ROOT / dest
        if not gz.exists():
            fail(f"{dest} is missing — run: python3 tools/fetch_assets.py --only bughouse")
        out = target / manifest_key(dest)
        payload = gzip.decompress(gz.read_bytes())
        record = manifest.get(out.name)
        if not isinstance(record, dict):
            fail(f"manifest.json does not describe {out.name}")
        if record.get("bytes") != len(payload):
            fail(
                f"{out.name} is {len(payload)} bytes, manifest.json says {record.get('bytes')}. "
                "The app deletes and re-extracts on every launch when these differ."
            )
        actual_hash = hashlib.sha256(payload).hexdigest()
        if record.get("sha256") != actual_hash:
            fail(f"{out.name} SHA-256 is {actual_hash}, manifest.json says {record.get('sha256')}")
        tmp = out.with_name(out.name + ".part")
        tmp.write_bytes(payload)
        tmp.replace(out)
        paths.append(out)

    engine, network = paths
    if os.name != "nt":
        engine.chmod(0o755)
    return engine, network


START_FEN = "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR[] w KQkq - 0 1"
START_DUAL_FEN = f"{START_FEN}|{START_FEN}"

# Board A after 1.e4 e5 2.Nf3 Nc6 3.Bc4 Nf6 with a pawn in each hand:
# some thirty legal moves and drops, several close in value.
MULTIPV = 3
MULTIPV_DUAL_FEN = (
    "r1bqkb1r/pppp1ppp/2n2n2/4p3/2B1P3/5N2/PPPP1PPP/RNBQK2R[Pp] w KQkq - 4 4"
    f"|{START_FEN}"
)


def info_fields(line: str) -> dict[str, str]:
    """`depth`, `seldepth`, `multipv`, `score` ("cp 72", "mate 3") and `pv`."""
    words = line.split()
    fields: dict[str, str] = {}
    for key in ("depth", "seldepth", "multipv"):
        if key in words[:-1]:
            fields[key] = words[words.index(key) + 1]
    if "score" in words[:-2]:
        at = words.index("score")
        fields["score"] = f"{words[at + 1]} {words[at + 2]}"
        if words[at + 3:at + 4] in (["lowerbound"], ["upperbound"]):
            fields["bound"] = words[at + 3]
    if "pv" in words:
        fields["pv"] = " ".join(words[words.index("pv") + 1:])
    return fields


def multipv_block(lines: list[str]) -> list[str]:
    """The last complete set of lines 1..MULTIPV before the final one.

    A set starts at each `multipv 1` line; bound lines are skipped, and the
    final set is left out because a search stopped by its node limit may
    have cut it short.
    """
    blocks: list[list[str]] = []
    for line in lines:
        if not line.startswith("info depth"):
            continue
        fields = info_fields(line)
        if "multipv" not in fields or "bound" in fields or "pv" not in fields:
            continue
        if fields["multipv"] == "1":
            blocks.append([])
        if blocks:
            blocks[-1].append(line)
    complete = [b for b in blocks[:-1]
                if [info_fields(l)["multipv"] for l in b] == [str(i + 1) for i in range(MULTIPV)]]
    if not complete:
        fail(f"no complete set of {MULTIPV} lines before the last one")
    return complete[-1]


def check_multipv(block: list[str]) -> None:
    """Every line was searched: distinct moves, one depth, real scores."""
    fields = [info_fields(line) for line in block]
    firsts = [f["pv"].split()[0] for f in fields]
    if len(set(firsts)) != MULTIPV:
        fail(f"the {MULTIPV} lines do not start with {MULTIPV} different moves: {firsts}")
    shallow = [f["multipv"] for f in fields if int(f.get("seldepth", "0")) <= 1]
    if shallow:
        fail(f"line(s) {', '.join(shallow)} reached seldepth 1: not searched")
    # Each iteration searches every line to the same depth; a line left at
    # an earlier depth was printed again without being searched.
    stale = [f'{f["multipv"]} (depth {f.get("depth")})' for f in fields[1:]
             if f.get("depth") != fields[0].get("depth")]
    if stale:
        fail(f"line(s) {', '.join(stale)} lag line 1 (depth {fields[0].get('depth')}): "
             "printed from an earlier iteration, not searched (the HypeBeast "
             "v1.1.1 MultiPV bug)")
    if all(f["score"] == "cp 0" for f in fields[1:]):
        fail(f"lines 2..{MULTIPV} all score cp 0: printed but not searched "
             "(the HypeBeast v1.1.1 MultiPV bug)")


# What Fairy-Stockfish prints at the first search when EvalFile did not load:
# an unreadable file ends the process after "info string ERROR: ...", a file
# that is not this net makes HypeBeast fall back to its classical evaluation.
NET_FAILURES = ("info string ERROR", "info string hb_error", "classical evaluation enabled")


def cmd_run(args) -> int:
    # `--install-to` leaves the extraction behind so a later step can drive the
    # same two files through the app's own Dart client, which is the only
    # thing that proves the *app* works on this platform rather than the engine.
    with tempfile.TemporaryDirectory() as td:
        work = Path(args.install_to).resolve() if args.install_to else Path(td) / "bughouse"
        try:
            engine, network = install_like_the_app(work)
        except Failure as exc:
            print(f"  FAIL {exc}", file=sys.stderr)
            return 1
        print(f"[run]  {engine.name} + {network.name} in {work}")

        started = time.time()
        proc = subprocess.Popen(
            [str(engine)],
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            text=True, bufsize=1, cwd=work,
        )

        lines: list[str] = []
        errors: list[str] = []

        def pump(stream, sink):
            for line in stream:
                sink.append(line.rstrip())

        threading.Thread(target=pump, args=(proc.stdout, lines), daemon=True).start()
        threading.Thread(target=pump, args=(proc.stderr, errors), daemon=True).start()

        def send(text: str) -> None:
            proc.stdin.write(text + "\n")
            proc.stdin.flush()

        def tail() -> str:
            shown = [l for l in lines if not l.startswith("option ")][-8:] + errors[-4:]
            return ("\n  " + "\n  ".join(shown)) if shown else "\n  the engine printed nothing at all"

        def wait_for(token: str, seconds: float, what: str, start: int = 0) -> str:
            deadline = time.time() + seconds
            while time.time() < deadline:
                hit = next((l for l in lines[start:] if l.startswith(token)), None)
                if hit is not None:
                    return hit
                if proc.poll() is not None:
                    time.sleep(0.2)  # let the readers drain what it printed
                    fail(f"engine exited ({proc.returncode}) before {what}" + tail())
                time.sleep(0.05)
            fail(f"no {what} within {seconds:.0f}s" + tail())

        try:
            send("uci")
            wait_for("uciok", args.timeout, "uciok")
            print(f"       uciok after {time.time() - started:.1f}s")
            banner = next((l for l in lines if l.startswith("id name")), "")
            if "Fairy-Stockfish" not in banner:
                fail(f"not a Fairy-Stockfish engine: {banner or 'no id name'}")
            if not any(l.startswith("option name HypeBeast ") for l in lines):
                fail("the engine does not offer the HypeBeast option: not a HypeBeast build")
            print(f"       {banner}")

            send("setoption name HypeBeast value true")
            send(f"setoption name EvalFile value {network}")
            send("setoption name Threads value 1")
            send("setoption name Hash value 16")
            send("isready")
            wait_for("readyok", args.timeout, "readyok")

            # The coordinated two-board search the app's two-board view runs.
            send("setoption name Seat value Awhite")
            send("setoption name Team value white")
            send("setoption name Coordination value true")
            send("setoption name MultiPV value 1")
            send("position fen " + START_DUAL_FEN)
            send(f"go nodes {args.nodes}")
            best = wait_for("bestmove", args.search_timeout, "bestmove")
            failed = next((l for l in lines if l.startswith(NET_FAILURES)), None)
            if failed:
                fail(f"the network did not load: {failed}")
            loaded = next((l for l in lines if l.startswith("info string NNUE evaluation using")), None)
            if loaded is None or NETWORK not in loaded:
                fail("the engine never said it is evaluating with the bughouse network" + tail())
            print(f"       {loaded}")
            if not any(l.startswith("info string hb_summary") for l in lines):
                fail("no hb_summary: the two-board coordinator did not run")
            print(f"       {best}")
            joint = best.split()[1] if len(best.split()) > 1 else ""
            halves = joint.strip("()").split(",")
            if not (joint.startswith("(") and joint.endswith(")") and len(halves) == 2):
                fail(f"bestmove is not a joint answer: {best}")
            if halves[1] != "pass" or halves[0] in ("pass", "(none)", ""):
                fail(f"seat Awhite should move on board A and pass on B: {best}")
            if not any(" nodes " in l for l in lines if l.startswith("info depth")):
                fail("the search reported no nodes, so nothing was evaluated")

            # The one-board view's several lines: every line searched, not
            # only the first (v1.1.1 printed lines 2..N without searching them).
            # A cleared hash, so what the first search left cannot fill
            # lines the engine did not search itself.
            mark = len(lines)
            send("ucinewgame")
            send("isready")
            wait_for("readyok", args.timeout, "readyok after ucinewgame", mark)
            start = len(lines)
            send("setoption name Coordination value false")
            send(f"setoption name MultiPV value {MULTIPV}")
            send("position fen " + MULTIPV_DUAL_FEN)
            send(f"go nodes {args.multipv_nodes}")
            best = wait_for("bestmove", args.search_timeout, "the MultiPV bestmove", start)
            block = multipv_block(lines[start:])
            for line in block:
                print(f"       {line[:110]}")
            check_multipv(block)
        except Failure as exc:
            print(f"  FAIL {exc}", file=sys.stderr)
            return 1
        finally:
            try:
                send("quit")
                proc.wait(timeout=5)
            except (OSError, ValueError, subprocess.TimeoutExpired):
                proc.kill()
                proc.wait()

    print("\nThe bughouse engine loads its network and searches both boards on this platform.")
    if args.install_to:
        print(f"HYPEBEAST_BIN={engine}")
        print(f"HYPEBEAST_NET={network}")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    sub = ap.add_subparsers(dest="command")

    deps = sub.add_parser("deps", help="static dependency audit")
    deps.add_argument("--all", action="store_true",
                      help="audit every platform whose binary is fetched")
    deps.set_defaults(func=cmd_deps)

    run = sub.add_parser("run", help="extract and drive the host engine")
    run.add_argument("--timeout", type=float, default=60.0)
    run.add_argument("--search-timeout", type=float, default=120.0)
    run.add_argument("--nodes", type=int, default=50000)
    run.add_argument("--multipv-nodes", type=int, default=100000)
    run.add_argument("--install-to", metavar="DIR",
                     help="extract into DIR and keep it, instead of a temp dir")
    run.set_defaults(func=cmd_run)

    args = ap.parse_args()
    if args.command:
        return args.func(args)

    rc = cmd_deps(ap.parse_args(["deps"]))
    if rc:
        return rc
    print()
    return cmd_run(ap.parse_args(["run"]))


if __name__ == "__main__":
    raise SystemExit(main())
