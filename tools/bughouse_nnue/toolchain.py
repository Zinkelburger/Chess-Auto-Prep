"""Build the pinned data tools and fetch the pinned trainer.

Two upstream repositories, both from the Fairy-Stockfish project:

* variant-nnue-tools -- Fairy-Stockfish with the training-data commands
  (`convert_bin`, `generate_training_data`, `validate_training_data`,
  `trainer_config`).  Built here from source, because the releases are built
  for a generic CPU and the convert step runs over hundreds of millions of
  positions.  The binary is also the engine every other step talks UCI to.
* variant-nnue-pytorch -- the trainer.  Cloned so `train.sh` can copy it to
  the GPU box together with the `variant.h`/`variant.py` the tools write for
  pocketknight.  It is not run here: it needs CUDA.

Both are pinned to a commit.  Bump `PINS` deliberately, then rerun `setup`.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

from .paths import (
    VARIANT,
    toolchain_dir,
    tools_binary,
    trainer_config_dir,
    trainer_dir,
)


@dataclass(frozen=True)
class Pin:
    url: str
    sha: str


PINS = {
    "variant-nnue-tools": Pin(
        "https://github.com/fairy-stockfish/variant-nnue-tools.git",
        "445b53c419d03d9167a786140a4d4bbe12ee7426",  # 2026-09-25
    ),
    "variant-nnue-pytorch": Pin(
        "https://github.com/fairy-stockfish/variant-nnue-pytorch.git",
        "b15df38a9aae8ab9b40b2378020b3099c7c5d179",  # 2026-06-30
    ),
}


def cpu_arch() -> str:
    """The Makefile ARCH this machine can run, from /proc/cpuinfo."""
    if platform.machine() not in ("x86_64", "AMD64"):
        return "x86-64"
    try:
        flags = Path("/proc/cpuinfo").read_text().split("flags", 1)[1].split("\n", 1)[0].split()
    except (OSError, IndexError):
        return "x86-64"
    have = set(flags)
    if {"bmi2", "avx2"} <= have:
        return "x86-64-bmi2"
    if "avx2" in have:
        return "x86-64-avx2"
    if {"sse4_1", "popcnt"} <= have:
        return "x86-64-sse41-popcnt"
    return "x86-64"


def _run(cmd: list[str], cwd: Path | None = None, quiet: bool = False) -> None:
    if not quiet:
        print("  $", " ".join(cmd), flush=True)
    subprocess.run(cmd, cwd=cwd, check=True,
                   stdout=subprocess.DEVNULL if quiet else None)


def checkout(name: str, dest: Path) -> None:
    """Put the pinned commit of `name` at `dest`; a no-op when already there."""
    pin = PINS[name]
    head = dest / ".git" / "HEAD"
    if head.exists():
        sha = subprocess.run(["git", "rev-parse", "HEAD"], cwd=dest, check=True,
                             capture_output=True, text=True).stdout.strip()
        if sha == pin.sha:
            return
        print(f"{name}: at {sha[:12]}, moving to pinned {pin.sha[:12]}")
    else:
        dest.mkdir(parents=True, exist_ok=True)
        _run(["git", "init", "-q"], cwd=dest)
        _run(["git", "remote", "add", "origin", pin.url], cwd=dest)
    try:
        _run(["git", "fetch", "-q", "--depth", "1", "origin", pin.sha], cwd=dest)
    except subprocess.CalledProcessError:
        # A server that refuses to serve a bare commit; fall back to history.
        _run(["git", "fetch", "-q", "origin"], cwd=dest)
    _run(["git", "checkout", "-q", "--detach", pin.sha], cwd=dest)


def build_tools(src: Path, arch: str, jobs: int) -> Path:
    env = dict(os.environ)
    env.setdefault("COMP", "gcc")
    print(f"building variant-nnue-tools for {arch} on {jobs} core(s)…", flush=True)
    subprocess.run(["make", f"-j{jobs}", "build", f"ARCH={arch}", f"COMP={env['COMP']}"],
                   cwd=src, check=True, env=env,
                   stdout=subprocess.DEVNULL)
    built = src / "stockfish"
    if not built.exists():
        raise SystemExit(f"build produced no binary at {built}")
    return built


def engine_banner(binary: Path) -> str:
    """The `id name` line, which doubles as a smoke test of the variant."""
    out = subprocess.run(
        [str(binary)],
        input=f"uci\nsetoption name UCI_Variant value {VARIANT}\nisready\nquit\n",
        capture_output=True, text=True, timeout=60, check=True,
    ).stdout
    if "readyok" not in out:
        raise SystemExit(f"{binary} did not answer isready for {VARIANT}:\n{out}")
    for line in out.splitlines():
        if line.startswith("id name"):
            return line[len("id name "):]
    return "unknown"


def write_trainer_config(binary: Path, out: Path) -> dict[str, str]:
    """`trainer_config pocketknight <dir>`: the two files the trainer needs."""
    out.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [str(binary)],
        input=f"trainer_config {VARIANT} {out}\nquit\n",
        capture_output=True, text=True, timeout=60, check=True,
    )
    files = {}
    for name in ("variant.h", "variant.py"):
        path = out / name
        if not path.exists():
            raise SystemExit(f"trainer_config wrote no {name} to {out}")
        files[name] = path.read_text()
    # The whole point is a net that sees the hands.  Without this the trainer
    # would silently learn a board-only eval that can never rate a drop.
    if "POCKETS true" not in files["variant.h"]:
        raise SystemExit(
            f"{VARIANT} is configured without pockets in {out / 'variant.h'}; "
            "the net would not see pieces in hand"
        )
    return files


def setup(jobs: int = 0, arch: str | None = None) -> int:
    root = toolchain_dir()
    root.mkdir(parents=True, exist_ok=True)
    arch = arch or cpu_arch()
    jobs = jobs or os.cpu_count() or 1
    started = time.time()

    tools_src = root / "variant-nnue-tools"
    checkout("variant-nnue-tools", tools_src)
    checkout("variant-nnue-pytorch", trainer_dir())

    binary = tools_binary()
    stamp = root / "toolchain.json"
    previous = json.loads(stamp.read_text()) if stamp.exists() else {}
    if (
        binary.exists()
        and previous.get("tools_sha") == PINS["variant-nnue-tools"].sha
        and previous.get("arch") == arch
    ):
        print(f"tools binary up to date: {binary}")
    else:
        built = build_tools(tools_src / "src", arch, jobs)
        binary.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(built, binary)
        binary.chmod(0o755)

    banner = engine_banner(binary)
    print(f"engine: {banner}")
    config = write_trainer_config(binary, trainer_config_dir())
    print(f"trainer config for {VARIANT} in {trainer_config_dir()}:")
    for line in config["variant.h"].splitlines():
        print(f"  {line}")

    stamp.write_text(json.dumps({
        "tools_sha": PINS["variant-nnue-tools"].sha,
        "trainer_sha": PINS["variant-nnue-pytorch"].sha,
        "arch": arch,
        "engine": banner,
        "built_at": int(time.time()),
    }, indent=2) + "\n")
    print(f"toolchain ready in {time.time() - started:.0f}s: {root}")
    return 0


def status() -> dict[str, object]:
    stamp = toolchain_dir() / "toolchain.json"
    info: dict[str, object] = json.loads(stamp.read_text()) if stamp.exists() else {}
    info["binary"] = str(tools_binary()) if tools_binary().exists() else None
    info["trainer"] = str(trainer_dir()) if (trainer_dir() / "train.py").exists() else None
    info["trainer_config"] = (
        str(trainer_config_dir()) if (trainer_config_dir() / "variant.h").exists() else None
    )
    return info


def require_binary() -> Path:
    binary = tools_binary()
    if not binary.exists():
        print(f"no tools binary at {binary}; run `python3 -m bughouse_nnue setup` first",
              file=sys.stderr)
        raise SystemExit(2)
    return binary
