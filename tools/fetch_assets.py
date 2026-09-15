#!/usr/bin/env python3
"""Fetch the engines this machine needs to build the app (not tracked in git).

Two engines are bundled by `pubspec.yaml` and loaded from the Flutter root
bundle at runtime, so they must exist *before* `flutter build` runs -- not
just before someone launches the app in development:

* Stockfish, one gzipped binary in `assets/executables/`, from the official
  Stockfish release.
* Hivemind, the bughouse engine: the binary, the ONNX Runtime it links
  against and the FP32 network, each gzipped in `assets/bughouse/`, plus a
  manifest of uncompressed sizes and SHA-256 values the app uses to spot a
  stale or corrupt extraction. Hivemind's own release is a ~2 GB Linux/NVIDIA
  TensorRT bundle, so the portable CPU builds come from a fork that publishes
  them per platform: https://github.com/Zinkelburger/hivemind/releases

Run this from the repo root as a build prerequisite. CMake and the macOS
Assemble script do it for you; Release CI fetches one target per job.

    python3 tools/fetch_assets.py                  # host Stockfish + bughouse (~120 MB)
    python3 tools/fetch_assets.py --check          # verify host assets; non-zero if missing
    python3 tools/fetch_assets.py --force          # re-download and overwrite
    python3 tools/fetch_assets.py --only stockfish # one engine, host platform
    python3 tools/fetch_assets.py --only bughouse-windows
    python3 tools/fetch_assets.py --hivemind ~/Projects/hivemind   # pack a local engine build

Default is the current OS/arch so a Linux checkout does not pull Windows and
macOS engines. macOS ships two app downloads (Apple Silicon vs Intel); the
Stockfish targets share one universal binary in `stockfish-macos.gz`, and the
two bughouse targets write the same pair of destinations from their own
architecture's archive.

Everything is pinned in `tools/assets.lock.json`. Tracking "latest" would make
builds non-reproducible and let an upstream release break the app with no
commit to point at. To upgrade: bump the tag, run with --force on each
platform, verify the app still starts and commit the regenerated lockfile
together.

IMPORTANT: assets/bughouse/.gitkeep and assets/executables/.gitkeep are
tracked on purpose. pubspec.yaml declares both directories as assets, and
Flutter treats a *missing* asset directory as a printed warning rather than a
build failure -- so without them a release builds green and ships no engine.

Hivemind is Copyright (c) 2026 aminwoo and distributed under the MIT License.
The complete notice shipped in the app is assets/licenses/HIVEMIND_LICENSE.txt.
Upstream source: https://github.com/aminwoo/hivemind

Standard library only, so CI needs no pip install step.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
import pathlib
import platform
import shutil
import sys
import tarfile
import tempfile
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LOCKFILE = REPO_ROOT / "tools" / "assets.lock.json"

# --- Stockfish -------------------------------------------------------------

STOCKFISH_TAG = "sf_19"
STOCKFISH_BASE = (
    f"https://github.com/official-stockfish/Stockfish/releases/download/{STOCKFISH_TAG}"
)

# Stockfish 19 universal binaries select the best supported CPU instructions
# at runtime. The macOS archive supports both Apple Silicon and Intel; retain
# the existing lock keys and shared asset slot for the two app build targets.
STOCKFISH_TARGETS = {
    "stockfish-linux": {
        "dest": "assets/executables/stockfish-linux.gz",
        "url": f"{STOCKFISH_BASE}/stockfish-linux-x86-64-universal.tar.gz",
    },
    "stockfish-macos-arm64": {
        "dest": "assets/executables/stockfish-macos.gz",
        "url": f"{STOCKFISH_BASE}/stockfish-macos-universal.tar.gz",
    },
    "stockfish-macos-x86_64": {
        "dest": "assets/executables/stockfish-macos.gz",
        "url": f"{STOCKFISH_BASE}/stockfish-macos-universal.tar.gz",
    },
    "stockfish-windows": {
        "dest": "assets/executables/stockfish-windows.exe.gz",
        "url": f"{STOCKFISH_BASE}/stockfish-windows-x86-64-universal.zip",
    },
}

# Maia is NOT fetched. `assets/maia3_simplified.onnx` is a local torch.onnx.export
# artifact with no upstream equivalent -- CSSLab/maia3 publishes PyTorch
# checkpoints on Hugging Face and ships no ONNX at all -- so there is nothing to
# download and no release asset behind it. It stays tracked in git; its checksum,
# tensor contract, and known provenance live in tools/maia_model.lock.json. See
# "Regenerating the Maia model" in README.md.

# --- Bughouse (Hivemind) ---------------------------------------------------

BUGHOUSE_ASSETS = REPO_ROOT / "assets" / "bughouse"
BUGHOUSE_MANIFEST = BUGHOUSE_ASSETS / "manifest.json"

BUGHOUSE_TAG = "engine-v0.1.0"
BUGHOUSE_BASE = (
    f"https://github.com/Zinkelburger/hivemind/releases/download/{BUGHOUSE_TAG}"
)

# The engine archives are flat: the binary and the runtime side by side, which
# is the layout the RPATH baked into the binary ($ORIGIN / @loader_path) and
# Windows' next-to-the-exe DLL search both resolve against.
BUGHOUSE_TARGETS = {
    "bughouse-linux": {
        "archive": "hivemind-linux-x64.tar.gz",
        "engine": ("hivemind", "assets/bughouse/hivemind-linux.gz"),
        "runtime": ("libonnxruntime.so.1", "assets/bughouse/libonnxruntime.so.1.gz"),
    },
    "bughouse-windows": {
        "archive": "hivemind-windows-x64.zip",
        "engine": ("hivemind.exe", "assets/bughouse/hivemind-windows.exe.gz"),
        "runtime": ("onnxruntime.dll", "assets/bughouse/hivemind_ort.dll.gz"),
    },
    "bughouse-macos-arm64": {
        "archive": "hivemind-macos-arm64.tar.gz",
        "engine": ("hivemind", "assets/bughouse/hivemind-macos.gz"),
        "runtime": ("libonnxruntime.dylib", "assets/bughouse/libonnxruntime.dylib.gz"),
    },
    "bughouse-macos-x86_64": {
        "archive": "hivemind-macos-x86_64.tar.gz",
        "engine": ("hivemind", "assets/bughouse/hivemind-macos.gz"),
        "runtime": ("libonnxruntime.dylib", "assets/bughouse/libonnxruntime.dylib.gz"),
    },
}

# Architecture independent, so it is one asset shared by every bughouse target.
# Published already gzipped: it is the largest single thing here and
# re-compressing 54 MB in four release jobs buys nothing.
BUGHOUSE_NETWORK = {
    "key": "bughouse-network",
    "asset": "hivemind-network-fp32.onnx.gz",
    "dest": "assets/bughouse/hivemind.onnx.gz",
}

# `--only` accepts a concrete target or one of these, meaning "that engine for
# the host platform".
FAMILIES = ("stockfish", "bughouse")


# --- Shared helpers --------------------------------------------------------


def human(n: int) -> str:
    return f"{n / 1e6:.1f} MB"


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def payload_sha256(path: Path) -> str:
    """Hash of what comes *out* of a gzip file, not of the container.

    The container is not reproducible: gzip output depends on the zlib the
    machine happens to have, so the same upstream binary recompressed on CI and
    on a developer laptop gives two different `output_sha256` values for byte-
    identical contents. Hashing the payload is the check that actually answers
    "is this the file we pinned", and it is the one `--check` can be trusted
    on after a fetch has rewritten the lock in the same run.
    """
    h = hashlib.sha256()
    with gzip.open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def gunzipped_size(path: Path) -> int:
    """Uncompressed size of a gzip file, by streaming it.

    Not the ISIZE trailer: that is only the low 32 bits of the length, and
    reading it would quietly go wrong the day a network crosses 4 GB.
    """
    total = 0
    with gzip.open(path, "rb") as fh:
        while chunk := fh.read(1 << 20):
            total += len(chunk)
    return total


def _host_suffix() -> str:
    plat, machine = sys.platform, platform.machine().lower()
    if plat.startswith("linux"):
        return "linux"
    if plat == "darwin":
        return "macos-arm64" if machine in ("arm64", "aarch64") else "macos-x86_64"
    if plat == "win32":
        return "windows"
    raise SystemExit(f"ERROR: unsupported platform {plat} ({machine})")


def stockfish_host_target() -> str:
    return f"stockfish-{_host_suffix()}"


def bughouse_host_target() -> str:
    return f"bughouse-{_host_suffix()}"


def host_targets() -> list[str]:
    """Everything the app bundles on the machine running this script."""
    return [stockfish_host_target(), bughouse_host_target()]


def resolve_targets(only: list[str] | None) -> list[str]:
    """Expand `--only` values: a family name means that engine for the host."""
    if not only:
        return host_targets()
    out: list[str] = []
    for name in only:
        if name == "stockfish":
            name = stockfish_host_target()
        elif name == "bughouse":
            name = bughouse_host_target()
        if name not in out:
            out.append(name)
    return out


def load_lock() -> dict:
    return json.loads(LOCKFILE.read_text()) if LOCKFILE.exists() else {}


def save_lock(lock: dict) -> None:
    LOCKFILE.parent.mkdir(parents=True, exist_ok=True)
    LOCKFILE.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")


def download(url: str, dest: Path, release_page: str) -> None:
    """Stream `url` to `dest`, with progress on a tty."""
    print(f"  downloading {url}")
    req = urllib.request.Request(url, headers={"User-Agent": "chess-auto-prep-fetch"})
    try:
        with urllib.request.urlopen(req) as resp, dest.open("wb") as out:
            total = int(resp.headers.get("Content-Length") or 0)
            got = 0
            while chunk := resp.read(1 << 20):
                out.write(chunk)
                got += len(chunk)
                if sys.stderr.isatty() and total:
                    print(
                        f"\r  {human(got)} / {human(total)} "
                        f"({100 * got / total:.0f}%)",
                        end="",
                        file=sys.stderr,
                    )
    except urllib.error.HTTPError as exc:
        raise SystemExit(
            f"\nERROR: {url}\n  HTTP {exc.code} {exc.reason}\n"
            f"  The pinned release may not have this asset. See {release_page}"
        ) from exc
    if sys.stderr.isatty():
        print(file=sys.stderr)


def read_member(archive: Path, name: str) -> bytes:
    """Read one named member out of a flat tar/zip archive."""
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as zf:
            names = [m.filename for m in zf.infolist() if not m.is_dir()]
            if name not in names:
                raise SystemExit(f"ERROR: {archive.name} has no {name} (has {names})")
            return zf.read(name)
    with tarfile.open(archive) as tf:
        names = [m.name for m in tf.getmembers() if m.isfile()]
        if name not in names:
            raise SystemExit(f"ERROR: {archive.name} has no {name} (has {names})")
        fh = tf.extractfile(name)
        if fh is None:
            raise SystemExit(f"ERROR: could not read {name} from {archive.name}")
        return fh.read()


def extract_stockfish_binary(archive: Path) -> bytes:
    """Pull the engine binary out of an upstream Stockfish tar/zip.

    The archives hold a `stockfish/` directory of docs, scripts and the engine.
    The engine is by far the largest member (~90 MB vs a few KB), so picking the
    largest regular file is robust across the tar and zip layouts without
    hardcoding the per-variant filename.
    """
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as zf:
            members = [m for m in zf.infolist() if not m.is_dir()]
            if not members:
                raise SystemExit(f"ERROR: {archive.name} is empty")
            biggest = max(members, key=lambda m: m.file_size)
            print(f"  extracting {biggest.filename} ({human(biggest.file_size)})")
            return zf.read(biggest)

    with tarfile.open(archive) as tf:
        members = [m for m in tf.getmembers() if m.isfile()]
        if not members:
            raise SystemExit(f"ERROR: {archive.name} is empty")
        biggest = max(members, key=lambda m: m.size)
        print(f"  extracting {biggest.name} ({human(biggest.size)})")
        fh = tf.extractfile(biggest)
        if fh is None:
            raise SystemExit(f"ERROR: could not read {biggest.name}")
        return fh.read()


def write_gz(payload: bytes, dest: Path) -> None:
    """gzip `payload` to `dest` as the app expects.

    The app calls `gzip.decode` on the raw asset bytes, so this must be a plain
    gzip stream of the bare file -- never a tar.gz. mtime is pinned to 0 so
    repeated runs produce byte-identical output and the lockfile hash stays
    meaningful.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(payload)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    tmp.write_bytes(buf.getvalue())
    tmp.replace(dest)


def dest_is_current(key: str, dest: Path, lock: dict) -> bool:
    """True if `dest` exists and matches the lockfile when it has an entry."""
    if not dest.exists():
        return False
    entry = lock.get(key, {})
    expected = entry.get("output_sha256")
    if not expected:
        return True
    actual = sha256_file(dest)
    if actual == expected:
        return True
    # A different container is not yet a different file. Recompressing on a
    # machine with another zlib changes these bytes and nothing else, and
    # treating that as staleness re-downloaded 43 MB on every single run.
    wanted_payload = entry.get("payload_sha256")
    if wanted_payload and payload_sha256(dest) == wanted_payload:
        return True
    print(
        f"[stale] {key}: {dest.relative_to(REPO_ROOT)} hash mismatch "
        f"(have {actual[:12]}…, want {expected[:12]}…) — re-fetching"
    )
    return False


def verify_source(name: str, archive: Path, lock: dict) -> str:
    digest = sha256_file(archive)
    expected = lock.get(name, {}).get("source_sha256")
    if expected and digest != expected:
        raise SystemExit(
            f"ERROR: checksum mismatch for {name}\n"
            f"  expected {expected}\n  got      {digest}\n"
            "  Upstream artifact changed. Verify before trusting it, then "
            "re-run with --force to accept."
        )
    return digest


# --- Stockfish -------------------------------------------------------------


def fetch_stockfish(name: str, lock: dict, force: bool) -> None:
    spec = STOCKFISH_TARGETS[name]
    dest = REPO_ROOT / spec["dest"]
    if dest_is_current(name, dest, lock) and not force:
        print(f"[ok]   {name}: {spec['dest']} present ({human(dest.stat().st_size)})")
        return

    print(f"[get]  {name} -> {spec['dest']}")
    with tempfile.TemporaryDirectory() as td:
        # Keep the upstream filename: extract_stockfish_binary() dispatches on
        # the .zip/.tar suffix, so a generic temp name would send the Windows
        # zip down the tarfile path.
        tmp = Path(td) / os.path.basename(urllib.parse.urlparse(spec["url"]).path)
        download(spec["url"], tmp, "https://github.com/official-stockfish/Stockfish/releases")
        digest = verify_source(name, tmp, lock)
        write_gz(extract_stockfish_binary(tmp), dest)

    lock[name] = {
        "url": spec["url"],
        "source_sha256": digest,
        "output_sha256": sha256_file(dest),
        "output_bytes": dest.stat().st_size,
    }
    print(f"       wrote {spec['dest']} ({human(dest.stat().st_size)})")


def check_stockfish(names: list[str], lock: dict) -> list[str]:
    problems: list[str] = []
    for n in names:
        rel = STOCKFISH_TARGETS[n]["dest"]
        dest = REPO_ROOT / rel
        if not dest.exists():
            print(f"[MISS] {n}: {rel}")
            problems.append(n)
            continue
        expected = lock.get(n, {}).get("output_sha256")
        if expected and sha256_file(dest) != expected:
            print(f"[HASH] {n}: {rel} does not match assets.lock.json")
            problems.append(n)
            continue
        print(f"[ok  ] {n}: {rel}")
    return problems


# --- Bughouse (Hivemind) ---------------------------------------------------


def manifest_key(dest: str) -> str:
    """The manifest key for an asset: the name it is extracted under.

    Keyed by filename rather than by role ("engine"/"runtime"), because a
    checkout can hold more than one platform's pair — fetch Linux then Windows
    and a role-keyed manifest describes only whichever ran last, so the app's
    size check deletes and re-extracts the other one on every single launch
    without ever converging.
    """
    name = pathlib.PurePosixPath(dest).name
    return name[:-3] if name.endswith(".gz") else name


def manifest_entry(size: int, sha256: str) -> dict[str, object]:
    return {"bytes": size, "sha256": sha256}


def write_manifest(entries: dict[str, dict[str, object]]) -> None:
    """Record uncompressed sizes and hashes by extracted filename.

    The app compares each extracted file against these to notice a half-written,
    corrupted or superseded extraction. Merging matters because the network is
    fetched independently of the platform pair, and because a checkout may hold
    several platforms at once.
    """
    current: dict[str, dict[str, object]] = {}
    if BUGHOUSE_MANIFEST.exists():
        try:
            decoded = json.loads(BUGHOUSE_MANIFEST.read_text())
            current = {
                key: value for key, value in decoded.items() if isinstance(value, dict)
            }
        except (json.JSONDecodeError, AttributeError):
            pass
    current.update(entries)
    # Drop anything that is not an asset we ship, so a manifest left behind by
    # an older, role-keyed version of this script heals itself on the next run
    # instead of carrying two spellings of the same size forever.
    known = {manifest_key(BUGHOUSE_NETWORK["dest"])} | {
        manifest_key(spec[role][1])
        for spec in BUGHOUSE_TARGETS.values()
        for role in ("engine", "runtime")
    }
    current = {k: v for k, v in current.items() if k in known}
    BUGHOUSE_MANIFEST.parent.mkdir(parents=True, exist_ok=True)
    BUGHOUSE_MANIFEST.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")


def fetch_bughouse_network(lock: dict, force: bool) -> None:
    key = BUGHOUSE_NETWORK["key"]
    rel = BUGHOUSE_NETWORK["dest"]
    dest = REPO_ROOT / rel
    if dest_is_current(key, dest, lock) and not force:
        print(f"[ok]   {key}: {rel} present ({human(dest.stat().st_size)})")
        write_manifest(
            {manifest_key(rel): manifest_entry(gunzipped_size(dest), payload_sha256(dest))}
        )
        return

    url = f"{BUGHOUSE_BASE}/{BUGHOUSE_NETWORK['asset']}"
    print(f"[get]  {key} -> {rel}")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / BUGHOUSE_NETWORK["asset"]
        download(url, tmp, "https://github.com/Zinkelburger/hivemind/releases")
        digest = verify_source(key, tmp, lock)
        # Already gzipped upstream; pass it through rather than recompressing.
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(tmp, dest)

    size = gunzipped_size(dest)
    write_manifest({manifest_key(rel): manifest_entry(size, payload_sha256(dest))})
    lock[key] = {
        "url": url,
        "source_sha256": digest,
        "output_sha256": sha256_file(dest),
        "payload_sha256": payload_sha256(dest),
        "output_bytes": dest.stat().st_size,
        "uncompressed_bytes": size,
    }
    print(f"       wrote {rel} ({human(dest.stat().st_size)})")


def fetch_bughouse(name: str, lock: dict, force: bool) -> None:
    """Fetch one platform's engine + runtime pair (the network is separate)."""
    windows_engine = None
    if name == "bughouse-windows":
        from bughouse_windows import HERE, verified_engine
        windows_engine = verified_engine()
        BUGHOUSE_ASSETS.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(
            HERE / "hivemind-source.tar.gz",
            BUGHOUSE_ASSETS / "hivemind-windows-source.tar.gz",
        )
    spec = BUGHOUSE_TARGETS[name]
    engine_member, engine_dest = spec["engine"]
    runtime_member, runtime_dest = spec["runtime"]
    engine_path = REPO_ROOT / engine_dest
    runtime_path = REPO_ROOT / runtime_dest

    fresh = (
        f"{name}:engine" in lock
        and f"{name}:runtime" in lock
        and dest_is_current(f"{name}:engine", engine_path, lock)
        and dest_is_current(f"{name}:runtime", runtime_path, lock)
        and (windows_engine is None or lock[f"{name}:engine"].get("payload_sha256")
             == hashlib.sha256(windows_engine).hexdigest())
    )
    if fresh and not force:
        # Still rewrite the manifest. The platform pair and the network are
        # fetched independently, and the two macOS targets share one pair of
        # destinations, so "the files are already right" does not imply the
        # manifest describes *these* files.
        print(f"[ok]   {name}: {engine_dest} + {runtime_dest} present")
        write_manifest(
            {
                manifest_key(engine_dest): manifest_entry(
                    lock[f"{name}:engine"]["uncompressed_bytes"],
                    lock[f"{name}:engine"]["payload_sha256"],
                ),
                manifest_key(runtime_dest): manifest_entry(
                    lock[f"{name}:runtime"]["uncompressed_bytes"],
                    lock[f"{name}:runtime"]["payload_sha256"],
                ),
            }
        )
        return

    url = f"{BUGHOUSE_BASE}/{spec['archive']}"
    print(f"[get]  {name} -> {engine_dest} + {runtime_dest}")
    with tempfile.TemporaryDirectory() as td:
        # Keep the upstream filename: read_member dispatches on the suffix, so
        # a generic temp name would send the Windows zip down the tar path.
        tmp = Path(td) / os.path.basename(urllib.parse.urlparse(url).path)
        download(url, tmp, "https://github.com/Zinkelburger/hivemind/releases")
        digest = verify_source(name, tmp, lock)
        engine_bytes = read_member(tmp, engine_member)
        runtime_bytes = read_member(tmp, runtime_member)

    if windows_engine is not None:
        engine_bytes = windows_engine

    write_gz(engine_bytes, engine_path)
    write_gz(runtime_bytes, runtime_path)
    write_manifest(
        {
            manifest_key(engine_dest): manifest_entry(
                len(engine_bytes), hashlib.sha256(engine_bytes).hexdigest()
            ),
            manifest_key(runtime_dest): manifest_entry(
                len(runtime_bytes), hashlib.sha256(runtime_bytes).hexdigest()
            ),
        }
    )

    lock[name] = {"url": url, "source_sha256": digest}
    lock[f"{name}:engine"] = {
        "output_sha256": sha256_file(engine_path),
        "payload_sha256": hashlib.sha256(engine_bytes).hexdigest(),
        "output_bytes": engine_path.stat().st_size,
        "uncompressed_bytes": len(engine_bytes),
    }
    if windows_engine is not None:
        lock[f"{name}:engine"]["build_manifest"] = "tools/bughouse_windows/build.json"
    lock[f"{name}:runtime"] = {
        "output_sha256": sha256_file(runtime_path),
        "payload_sha256": hashlib.sha256(runtime_bytes).hexdigest(),
        "output_bytes": runtime_path.stat().st_size,
        "uncompressed_bytes": len(runtime_bytes),
    }
    print(
        f"       wrote {engine_dest} ({human(engine_path.stat().st_size)})"
        f" + {runtime_dest} ({human(runtime_path.stat().st_size)})"
    )


def install_from_build(checkout: Path, build: str) -> int:
    """Package a local Hivemind build instead of downloading a release.

    What you want while working on the engine itself. Delegates the staging to
    the engine repo's own tools/package_engine.py so the layout can only be
    defined in one place, then feeds the result through the same extraction
    path a downloaded archive takes.
    """
    import subprocess

    root = checkout.expanduser()
    packer = root / "tools" / "package_engine.py"
    if not packer.is_file():
        raise SystemExit(
            f"ERROR: {packer} not found.\n"
            "  Needs a Hivemind checkout with the portable build support "
            "(the portable-desktop-builds work)."
        )

    slug = {
        "linux": "linux-x64",
        "windows": "windows-x64",
        "macos-arm64": "macos-arm64",
        "macos-x86_64": "macos-x86_64",
    }[_host_suffix()]

    print(f"Packaging local build in {root} as {slug}")
    result = subprocess.run(
        [sys.executable, str(packer), "--build", build, "--target", slug],
        cwd=root,
    )
    if result.returncode != 0:
        return result.returncode

    suffix = ".zip" if slug == "windows-x64" else ".tar.gz"
    archive = root / "dist" / f"hivemind-{slug}{suffix}"
    if not archive.is_file():
        raise SystemExit(f"ERROR: {archive} was not produced")

    spec = BUGHOUSE_TARGETS[bughouse_host_target()]
    engine_member, engine_dest = spec["engine"]
    runtime_member, runtime_dest = spec["runtime"]

    engine_bytes = read_member(archive, engine_member)
    runtime_bytes = read_member(archive, runtime_member)
    write_gz(engine_bytes, REPO_ROOT / engine_dest)
    write_gz(runtime_bytes, REPO_ROOT / runtime_dest)

    network = root / "engine" / "models" / "hivemind-fp32.onnx"
    if not network.is_file():
        raise SystemExit(
            f"ERROR: {network} not found. Convert one first:\n"
            "  python3 engine/scripts/convert_onnx_fp32.py "
            "engine/models/hivemind.onnx engine/models/hivemind-fp32.onnx"
        )
    payload = network.read_bytes()
    write_gz(payload, REPO_ROOT / BUGHOUSE_NETWORK["dest"])

    write_manifest(
        {
            manifest_key(engine_dest): manifest_entry(
                len(engine_bytes), hashlib.sha256(engine_bytes).hexdigest()
            ),
            manifest_key(runtime_dest): manifest_entry(
                len(runtime_bytes), hashlib.sha256(runtime_bytes).hexdigest()
            ),
            manifest_key(BUGHOUSE_NETWORK["dest"]): manifest_entry(
                len(payload), hashlib.sha256(payload).hexdigest()
            ),
        }
    )
    total = sum(f.stat().st_size for f in BUGHOUSE_ASSETS.glob("*.gz"))
    print(f"\nInstalled a local build into {BUGHOUSE_ASSETS} ({human(total)})")
    print("Note: a local build is tuned for this machine and is not "
          "redistributable — release builds come from the engine CI.")
    return 0


def check_bughouse(names: list[str], lock: dict) -> list[str]:
    problems: list[str] = []
    if "bughouse-windows" in names:
        from bughouse_windows import HERE, verified_engine
        engine = verified_engine()
        if hashlib.sha256(engine).hexdigest() != lock.get(
            "bughouse-windows:engine", {}
        ).get("payload_sha256"):
            problems.append("Windows engine lock is stale; fetch the rebuilt engine")
        source = BUGHOUSE_ASSETS / "hivemind-windows-source.tar.gz"
        if not source.exists() or sha256_file(source) != sha256_file(HERE / "hivemind-source.tar.gz"):
            problems.append("Windows corresponding-source archive missing or stale")
    paths: list[tuple[str, Path]] = [
        (BUGHOUSE_NETWORK["key"], REPO_ROOT / BUGHOUSE_NETWORK["dest"])
    ]
    for n in names:
        paths.append((f"{n}:engine", REPO_ROOT / BUGHOUSE_TARGETS[n]["engine"][1]))
        paths.append((f"{n}:runtime", REPO_ROOT / BUGHOUSE_TARGETS[n]["runtime"][1]))

    for key, path in paths:
        rel = path.relative_to(REPO_ROOT)
        if not path.exists():
            print(f"[MISS] {key}: {rel}")
            problems.append(key)
            continue
        entry = lock.get(key, {})
        wanted_payload = entry.get("payload_sha256")
        if wanted_payload:
            # The payload, not the container: this is the only hash here that
            # a fetch in the same job cannot have made true by writing it.
            if payload_sha256(path) != wanted_payload:
                print(f"[HASH] {key}: {rel} is not the file assets.lock.json pins")
                problems.append(key)
                continue
        elif entry.get("output_sha256") and sha256_file(path) != entry["output_sha256"]:
            print(f"[HASH] {key}: {rel} does not match assets.lock.json")
            problems.append(key)
            continue
        expected_size = entry.get("uncompressed_bytes")
        if expected_size is not None and gunzipped_size(path) != expected_size:
            print(f"[SIZE] {key}: {rel} does not unpack to {expected_size} bytes")
            problems.append(key)
            continue
        print(f"[ok  ] {key}: {rel} ({human(path.stat().st_size)})")

    manifest_rel = BUGHOUSE_MANIFEST.relative_to(REPO_ROOT)
    if not BUGHOUSE_MANIFEST.exists():
        print(f"[MISS] manifest: {manifest_rel}")
        problems.append("manifest")
    else:
        manifest = json.loads(BUGHOUSE_MANIFEST.read_text())
        wanted = {manifest_key(BUGHOUSE_NETWORK["dest"])}
        for n in names:
            wanted.add(manifest_key(BUGHOUSE_TARGETS[n]["engine"][1]))
            wanted.add(manifest_key(BUGHOUSE_TARGETS[n]["runtime"][1]))
        missing = wanted - set(manifest)
        if missing:
            print(f"[BAD ] manifest: missing {', '.join(sorted(missing))}")
            problems.append("manifest")
        else:
            malformed = [
                name
                for name in wanted
                if not isinstance(manifest.get(name), dict)
                or not isinstance(manifest[name].get("bytes"), int)
                or not isinstance(manifest[name].get("sha256"), str)
                or len(manifest[name]["sha256"]) != 64
            ]
            if malformed:
                print(
                    f"[BAD ] manifest: invalid integrity record for "
                    f"{', '.join(sorted(malformed))}"
                )
                problems.append("manifest")
            else:
                print(f"[ok  ] manifest: {manifest_rel}")
    return problems


# --- Entry point -----------------------------------------------------------


def split_targets(names: list[str]) -> tuple[list[str], list[str]]:
    stockfish = [n for n in names if n in STOCKFISH_TARGETS]
    bughouse = [n for n in names if n in BUGHOUSE_TARGETS]
    return stockfish, bughouse


def check(names: list[str], lock: dict, only: list[str] | None) -> int:
    stockfish, bughouse = split_targets(names)
    problems = check_stockfish(stockfish, lock)
    if bughouse:
        problems += check_bughouse(bughouse, lock)
    if problems:
        rerun = "python3 tools/fetch_assets.py"
        if only:
            rerun += "".join(f" --only {n}" for n in only)
        print(
            f"\n{len(problems)} asset(s) missing or stale. Run: {rerun}\n"
            "Re-run with --force if the lockfile was updated.",
            file=sys.stderr,
        )
        return 1
    print("\nAll requested assets present.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="verify only, do not download")
    ap.add_argument("--force", action="store_true", help="re-download even if present")
    ap.add_argument(
        "--only",
        action="append",
        choices=sorted(STOCKFISH_TARGETS) + sorted(BUGHOUSE_TARGETS) + list(FAMILIES),
        help="a target, or an engine name for the host platform (repeatable; "
        "default: both engines for the host)",
    )
    ap.add_argument("--hivemind", type=Path, metavar="CHECKOUT",
                    help="package a local Hivemind build instead of downloading")
    ap.add_argument("--build", default="engine/build-ort",
                    help="build directory inside the checkout (with --hivemind)")
    args = ap.parse_args()

    if args.hivemind:
        return install_from_build(args.hivemind, args.build)

    names = resolve_targets(args.only)
    lock = load_lock()

    if args.check:
        return check(names, lock, args.only)

    before = json.dumps(lock, sort_keys=True)
    stockfish, bughouse = split_targets(names)
    for n in stockfish:
        fetch_stockfish(n, lock, args.force)
    if bughouse:
        BUGHOUSE_ASSETS.mkdir(parents=True, exist_ok=True)
        for n in bughouse:
            fetch_bughouse(n, lock, args.force)
        fetch_bughouse_network(lock, args.force)
    if json.dumps(lock, sort_keys=True) != before:
        save_lock(lock)
        print(f"\nUpdated {LOCKFILE.relative_to(REPO_ROOT)} -- commit it.")
    print("\nDone. Assets are gitignored; re-run after a clean checkout.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
