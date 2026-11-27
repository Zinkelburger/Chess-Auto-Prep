#!/usr/bin/env python3
"""Fetch the engines this machine needs to build the app (not tracked in git).

Two engines are bundled by `pubspec.yaml` and loaded from the Flutter root
bundle at runtime, so they must exist *before* `flutter build` runs -- not
just before someone launches the app in development:

* Stockfish, one gzipped binary in `assets/executables/`, from the official
  Stockfish release.
* HypeBeast, the bughouse engine (a Fairy-Stockfish fork,
  https://github.com/Zinkelburger/HypeBeast): one static binary per platform
  from its pinned release, and Fairy-Stockfish's bughouse network
  `bughouse-cd8cceab93fe.nnue`, each gzipped in `assets/bughouse/`, plus a
  manifest of uncompressed sizes and SHA-256 values the app checks before
  every launch. No runtime library ships beside it.

One more family is fetched only when asked for, and never into the app:

* Hivemind (`--only hivemind`), the ONNX engine the bughouse MCP server and
  the arena's `hivemind` player still run, into the git-ignored
  `tools/hivemind-engine/`. The app does not bundle or read it.

Run this from the repo root as a build prerequisite. CMake and the macOS
Assemble script do it for you; Release CI fetches one target per job.

    python3 tools/fetch_assets.py                  # host Stockfish + bughouse (~90 MB)
    python3 tools/fetch_assets.py --check          # verify host assets; non-zero if missing
    python3 tools/fetch_assets.py --force          # re-download and overwrite
    python3 tools/fetch_assets.py --only stockfish # one engine, host platform
    python3 tools/fetch_assets.py --only bughouse-windows
    python3 tools/fetch_assets.py --only hivemind  # tool-only Hivemind, host platform
    python3 tools/fetch_assets.py --hypebeast ~/Projects/HypeBeast  # pack a local engine build

Default is the current OS/arch so a Linux checkout does not pull Windows and
macOS engines. macOS ships two app downloads (Apple Silicon vs Intel); the
Stockfish targets share one universal binary in `stockfish-macos.gz`, and the
two bughouse targets write their own architecture's binary to the same
`hypebeast-macos.gz`.

Everything is pinned in `tools/assets.lock.json`. Tracking "latest" would make
builds non-reproducible and let an upstream release break the app with no
commit to point at. To upgrade HypeBeast: change HYPEBEAST_TAG, run with
--only for each bughouse target (each binary is checked against the release's
own SHA256SUMS.txt), verify the app still starts and commit the regenerated
lockfile together.

IMPORTANT: assets/bughouse/.gitkeep and assets/executables/.gitkeep are
tracked on purpose. pubspec.yaml declares both directories as assets, and
Flutter treats a *missing* asset directory as a printed warning rather than a
build failure -- so without them a release builds green and ships no engine.
pubspec.yaml bundles *everything* in assets/bughouse/, which is why a fetch
removes the Hivemind files older checkouts left there and --check fails while
any remain.

HypeBeast is GPL-3.0-or-later (a Fairy-Stockfish fork); the notice shipped in
the app is under assets/licenses/. The network is credited on
https://fairy-stockfish.github.io/nnue/ to "belzedar_ in discord".

Standard library only, so CI needs no pip install step.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import html
import io
import json
import os
import pathlib
import platform
import re
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LOCKFILE = REPO_ROOT / "tools" / "assets.lock.json"
USER_AGENT = "chess-auto-prep-fetch"

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

# --- Bughouse (HypeBeast) --------------------------------------------------

BUGHOUSE_ASSETS = REPO_ROOT / "assets" / "bughouse"
BUGHOUSE_MANIFEST = BUGHOUSE_ASSETS / "manifest.json"

HYPEBEAST_REPO = "https://github.com/Zinkelburger/HypeBeast"
# The one place the engine release is named; the app's licence notice
# (assets/licenses/HYPEBEAST_LICENSE.txt) points at the same tag, and
# test/app/bundled_licences_test.dart fails when the two disagree.
HYPEBEAST_TAG = "v1.1.2"
HYPEBEAST_BASE = f"{HYPEBEAST_REPO}/releases/download/{HYPEBEAST_TAG}"
HYPEBEAST_RELEASE_PAGE = f"{HYPEBEAST_REPO}/releases/tag/{HYPEBEAST_TAG}"

# Release assets are bare binaries, not archives. `modern` rather than `bmi2`
# so the app runs on any x86-64 CPU it otherwise supports. The Linux binaries
# are static and the Windows ones MinGW builds with only Windows' own DLLs
# imported; tools/test_bughouse_engine.py deps proves both.
BUGHOUSE_TARGETS = {
    "bughouse-linux": {
        "asset": "hypebeast-linux-x86-64-modern",
        "dest": "assets/bughouse/hypebeast-linux.gz",
    },
    "bughouse-windows": {
        "asset": "hypebeast-windows-x86-64-modern.exe",
        "dest": "assets/bughouse/hypebeast-windows.exe.gz",
    },
    "bughouse-macos-arm64": {
        "asset": "hypebeast-macos-apple-silicon",
        "dest": "assets/bughouse/hypebeast-macos.gz",
    },
    "bughouse-macos-x86_64": {
        "asset": "hypebeast-macos-x86-64-modern",
        "dest": "assets/bughouse/hypebeast-macos.gz",
    },
}

# Fairy-Stockfish matches a net to its variant by the file name's prefix, so
# the name is kept exactly. Its official location is a Google Drive link on
# https://fairy-stockfish.github.io/nnue/; the owner's site serves the same
# bytes in gzipped parts (tools/prepare_hypebeast_web.py), used only when the
# Drive download fails. Both are held to the same SHA-256.
BUGHOUSE_NETWORK = {
    "key": "bughouse-network",
    "name": "bughouse-cd8cceab93fe.nnue",
    "sha256": "cd8cceab93fed185b79932414d1a0823f40e15a09ca9776ceab7c9c5272ddc13",
    "url": "https://drive.google.com/u/0/uc?id=1qZVSzm5G_KRc33YCqmsPM6Ayxo3CI4ME&export=download",
    "mirror": "https://chessautoprep.com/hypebeast-engine/",
    "dest": "assets/bughouse/bughouse-cd8cceab93fe.nnue.gz",
}

# What older checkouts left in assets/bughouse/: the Hivemind engine, its ONNX
# Runtime under every name it shipped with, its network and the Windows
# corresponding-source archive. Only these exact names are ever removed.
STALE_BUGHOUSE_FILES = (
    "hivemind-linux.gz",
    "hivemind-macos.gz",
    "hivemind-windows.exe.gz",
    "hivemind-windows-source.tar.gz",
    "hivemind.onnx.gz",
    "hivemind_ort.dll.gz",
    "onnxruntime.dll.gz",
    "libonnxruntime.so.1.gz",
    "libonnxruntime.dylib.gz",
)

# --- Hivemind, for the tools only ------------------------------------------

# Git-ignored, outside assets/ so pubspec.yaml can never bundle it.
# tools/mcp/bughouse/paths.py reads it; so does the arena through that module.
HIVEMIND_ASSETS = REPO_ROOT / "tools" / "hivemind-engine"
HIVEMIND_TAG = "engine-v0.2.0"
HIVEMIND_BASE = (
    f"https://github.com/Zinkelburger/hivemind/releases/download/{HIVEMIND_TAG}"
)
HIVEMIND_RELEASE_PAGE = "https://github.com/Zinkelburger/hivemind/releases"

# The engine archives are flat: the binary and the runtime side by side, which
# is the layout the RPATH baked into the binary ($ORIGIN / @loader_path) and
# Windows' next-to-the-exe DLL search both resolve against.
HIVEMIND_TARGETS = {
    "hivemind-linux": {
        "archive": "hivemind-linux-x64.tar.gz",
        "engine": ("hivemind", "tools/hivemind-engine/hivemind-linux.gz"),
        "runtime": ("libonnxruntime.so.1", "tools/hivemind-engine/libonnxruntime.so.1.gz"),
    },
    "hivemind-windows": {
        "archive": "hivemind-windows-x64.zip",
        "engine": ("hivemind.exe", "tools/hivemind-engine/hivemind-windows.exe.gz"),
        "runtime": ("onnxruntime.dll", "tools/hivemind-engine/onnxruntime.dll.gz"),
    },
    "hivemind-macos-arm64": {
        "archive": "hivemind-macos-arm64.tar.gz",
        "engine": ("hivemind", "tools/hivemind-engine/hivemind-macos.gz"),
        "runtime": ("libonnxruntime.dylib", "tools/hivemind-engine/libonnxruntime.dylib.gz"),
    },
    "hivemind-macos-x86_64": {
        "archive": "hivemind-macos-x86_64.tar.gz",
        "engine": ("hivemind", "tools/hivemind-engine/hivemind-macos.gz"),
        "runtime": ("libonnxruntime.dylib", "tools/hivemind-engine/libonnxruntime.dylib.gz"),
    },
}

# Architecture independent and published already gzipped.
HIVEMIND_NETWORK = {
    "key": "hivemind-network",
    "asset": "hivemind-network-fp32.onnx.gz",
    "dest": "tools/hivemind-engine/hivemind.onnx.gz",
}

# `--only` accepts a concrete target or one of these, meaning "that engine for
# the host platform". The default fetch is stockfish + bughouse; hivemind is
# only fetched when named.
FAMILIES = ("stockfish", "bughouse", "hivemind")


# --- Shared helpers --------------------------------------------------------


class DownloadError(Exception):
    """A download that did not produce the file it was meant to."""


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
    on a developer laptop gives two different container hashes for byte-
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


def hivemind_host_target() -> str:
    return f"hivemind-{_host_suffix()}"


def host_targets() -> list[str]:
    """Everything the app bundles on the machine running this script."""
    return [stockfish_host_target(), bughouse_host_target()]


def resolve_targets(only: list[str] | None) -> list[str]:
    """Expand `--only` values: a family name means that engine for the host."""
    if not only:
        return host_targets()
    family = {
        "stockfish": stockfish_host_target,
        "bughouse": bughouse_host_target,
        "hivemind": hivemind_host_target,
    }
    out: list[str] = []
    for name in only:
        if name in family:
            name = family[name]()
        if name not in out:
            out.append(name)
    return out


def load_lock() -> dict:
    return json.loads(LOCKFILE.read_text()) if LOCKFILE.exists() else {}


def save_lock(lock: dict) -> None:
    LOCKFILE.parent.mkdir(parents=True, exist_ok=True)
    LOCKFILE.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")


# A temporary name older than this was left by a fetch that died.
STALE_TEMP_SECONDS = 3600


def write_replacing(path: Path, data: bytes) -> None:
    """Write `path` through a temporary name and rename it into place.

    The rename also matters in agent worktrees, whose ignored assets are
    symlinks into the main checkout: writing *through* one would change the
    main checkout's file, while a rename replaces only the link.

    The temporary name is this process's own (`.<name>.<random>.tmp`, which
    git ignores), so two fetches never write one file, and one that fails is
    removed. Ones an hour old, left by a fetch that died, are swept first:
    the folders they sit in are bundled into the app whole.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    sweep_stale_temps(path)
    fd, name = tempfile.mkstemp(dir=path.parent, prefix=f".{path.name}.", suffix=".tmp")
    tmp = Path(name)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        tmp.replace(path)
    except BaseException:
        tmp.unlink(missing_ok=True)
        raise


def sweep_stale_temps(path: Path, now: float | None = None) -> list[Path]:
    """Remove the temporary copies of `path` older than STALE_TEMP_SECONDS
    (and the fixed `<name>.tmp` older versions wrote); returns them."""
    now = time.time() if now is None else now
    swept = []
    for old in [*path.parent.glob(f".{path.name}.*.tmp"), path.with_name(path.name + ".tmp")]:
        try:
            if old.is_file() and now - old.stat().st_mtime > STALE_TEMP_SECONDS:
                old.unlink()
                swept.append(old)
        except OSError:
            continue
    return swept


def _stream(url: str, dest: Path) -> str:
    """Stream `url` to `dest`, with progress on a tty. Returns the media type.

    Raises DownloadError for any HTTP or network failure.
    """
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=300) as resp, dest.open("wb") as out:
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
            media_type = resp.headers.get_content_type()
    except urllib.error.HTTPError as exc:
        raise DownloadError(f"{url}: HTTP {exc.code} {exc.reason}") from exc
    except (urllib.error.URLError, OSError) as exc:
        raise DownloadError(f"{url}: {exc}") from exc
    finally:
        if sys.stderr.isatty():
            print(file=sys.stderr)
    return media_type


def download(url: str, dest: Path, release_page: str) -> None:
    """Stream `url` to `dest`; a failure ends the run naming the release page."""
    print(f"  downloading {url}")
    try:
        _stream(url, dest)
    except DownloadError as exc:
        raise SystemExit(
            f"\nERROR: {exc}\n"
            f"  The pinned release may not have this asset. See {release_page}"
        ) from exc


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
    repeated runs on one machine produce byte-identical output.
    """
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(payload)
    write_replacing(dest, buf.getvalue())


def dest_is_current(key: str, dest: Path, lock: dict, url: str | None = None) -> bool:
    """True if `dest` exists and matches the lockfile when it has an entry.

    The pinned payload decides when there is one. A different container is
    not a different file: recompressing on a machine with another zlib
    changes the gzip bytes and nothing else, and treating that as staleness
    re-downloaded 43 MB on every single run. When `url` is given, an entry
    pinned for another URL (a bumped release tag) is stale whatever the file.
    """
    if not dest.exists():
        return False
    entry = lock.get(key, {})
    if url is not None and entry.get("url") not in (None, url):
        print(f"[stale] {key}: assets.lock.json pins {entry.get('url')}")
        return False
    wanted_payload = entry.get("payload_sha256")
    if wanted_payload:
        try:
            actual = payload_sha256(dest)
        except (OSError, EOFError, gzip.BadGzipFile):
            actual = "not a gzip stream"
        if actual == wanted_payload:
            return True
        print(
            f"[stale] {key}: {dest.relative_to(REPO_ROOT)} payload mismatch "
            f"(have {actual[:12]}…, want {wanted_payload[:12]}…)"
        )
        return False
    expected = entry.get("output_sha256")
    if not expected:
        return True
    actual = sha256_file(dest)
    if actual == expected:
        return True
    print(
        f"[stale] {key}: {dest.relative_to(REPO_ROOT)} hash mismatch "
        f"(have {actual[:12]}…, want {expected[:12]}…)"
    )
    return False


def verify_source(name: str, archive: Path, lock: dict, url: str | None = None) -> str:
    """The archive's hash, checked against the lock for the same URL.

    A URL the lock does not pin yet (a bumped release tag) has nothing to be
    checked against: its hash is what the lock records from now on.
    """
    digest = sha256_file(archive)
    entry = lock.get(name, {})
    expected = entry.get("source_sha256")
    if url is not None and entry.get("url") not in (None, url):
        expected = None
    if expected and digest != expected:
        raise SystemExit(
            f"ERROR: checksum mismatch for {name}\n"
            f"  expected {expected}\n  got      {digest}\n"
            "  The pinned upstream artifact changed. Verify it before "
            "trusting it, then remove its source_sha256 from the lock."
        )
    return digest


def check_gz(key: str, path: Path, lock: dict) -> bool:
    """`--check` for one gzipped asset: present, the pinned payload, the size."""
    rel = path.relative_to(REPO_ROOT)
    if not path.exists():
        print(f"[MISS] {key}: {rel}")
        return False
    entry = lock.get(key, {})
    wanted_payload = entry.get("payload_sha256")
    try:
        if wanted_payload:
            # The payload, not the container: this is the only hash here that
            # a fetch in the same job cannot have made true by writing it.
            if payload_sha256(path) != wanted_payload:
                print(f"[HASH] {key}: {rel} is not the file assets.lock.json pins")
                return False
        elif entry.get("output_sha256") and sha256_file(path) != entry["output_sha256"]:
            print(f"[HASH] {key}: {rel} does not match assets.lock.json")
            return False
        expected_size = entry.get("uncompressed_bytes")
        if expected_size is not None and gunzipped_size(path) != expected_size:
            print(f"[SIZE] {key}: {rel} does not unpack to {expected_size} bytes")
            return False
    except (OSError, EOFError, gzip.BadGzipFile):
        print(f"[BAD ] {key}: {rel} is not a gzip stream")
        return False
    print(f"[ok  ] {key}: {rel} ({human(path.stat().st_size)})")
    return True


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
        binary = extract_stockfish_binary(tmp)
        engine = hashlib.sha256(binary).hexdigest()
        pinned = lock.get(name, {}).get("payload_sha256")
        if pinned and engine != pinned:
            raise SystemExit(
                f"ERROR: the engine inside {name} is not the pinned one\n"
                f"  expected {pinned}\n  got      {engine}\n"
                "  Verify the upstream release before trusting it, then "
                "remove payload_sha256 from the lock and re-run."
            )
        write_gz(binary, dest)

    # Only the engine is pinned: the app checks what it unpacks, so the gzip
    # container may differ from machine to machine and the lock stays the
    # same on every one.
    lock[name] = {
        "url": spec["url"],
        "source_sha256": digest,
        "payload_sha256": engine,
        "uncompressed_bytes": len(binary),
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
        if not dest_is_current(n, dest, lock):
            print(f"[HASH] {n}: {rel} does not match assets.lock.json")
            problems.append(n)
            continue
        print(f"[ok  ] {n}: {rel}")
    return problems


# --- Bughouse (HypeBeast) --------------------------------------------------


def manifest_key(dest: str) -> str:
    """The manifest key for an asset: the name it is extracted under.

    Keyed by filename rather than by role ("engine"/"network"), because a
    checkout can hold more than one platform's engine — fetch Linux then
    Windows and a role-keyed manifest describes only whichever ran last, so
    the app's size check deletes and re-extracts the other one on every single
    launch without ever converging.
    """
    name = pathlib.PurePosixPath(dest).name
    return name[:-3] if name.endswith(".gz") else name


def manifest_entry(size: int, sha256: str) -> dict[str, object]:
    return {"bytes": size, "sha256": sha256}


def known_manifest_keys() -> set[str]:
    return {manifest_key(BUGHOUSE_NETWORK["dest"])} | {
        manifest_key(spec["dest"]) for spec in BUGHOUSE_TARGETS.values()
    }


def write_manifest(entries: dict[str, dict[str, object]]) -> None:
    """Record uncompressed sizes and hashes by extracted filename.

    The app compares each extracted file against these to notice a half-written,
    corrupted or superseded extraction. Merging matters because the network is
    fetched independently of the engine, and because a checkout may hold
    several platforms at once.
    """
    current: dict[str, dict[str, object]] = {}
    if BUGHOUSE_MANIFEST.exists():
        try:
            decoded = json.loads(BUGHOUSE_MANIFEST.read_text())
            current = {
                key: value for key, value in decoded.items() if isinstance(value, dict)
            }
        except (json.JSONDecodeError, AttributeError, OSError):
            pass
    current.update(entries)
    # Drop anything that is not an asset we ship, so the Hivemind entries an
    # older checkout's manifest holds heal away on the next run.
    known = known_manifest_keys()
    current = {k: v for k, v in current.items() if k in known}
    write_replacing(
        BUGHOUSE_MANIFEST,
        (json.dumps(current, indent=2, sort_keys=True) + "\n").encode(),
    )


def stale_bughouse_files() -> list[Path]:
    """Hivemind files an older checkout left where the app bundle is made."""
    return [
        BUGHOUSE_ASSETS / name
        for name in STALE_BUGHOUSE_FILES
        if (BUGHOUSE_ASSETS / name).is_symlink() or (BUGHOUSE_ASSETS / name).exists()
    ]


def remove_stale_bughouse() -> None:
    # unlink() removes a worktree's symlink, never the main checkout's file.
    for path in stale_bughouse_files():
        path.unlink()
        print(f"[del]  {path.relative_to(REPO_ROOT)} (Hivemind, no longer bundled)")


_RELEASE_SUMS: dict[str, dict[str, str]] = {}


def release_sums(base: str) -> dict[str, str]:
    """The release's own SHA256SUMS.txt, fetched once per run.

    The lock pins what was fetched before; this is what pins the first fetch
    after a tag bump, when the lock has nothing for the new URLs yet.
    """
    if base not in _RELEASE_SUMS:
        with tempfile.TemporaryDirectory() as td:
            path = Path(td) / "SHA256SUMS.txt"
            download(f"{base}/SHA256SUMS.txt", path, HYPEBEAST_RELEASE_PAGE)
            sums: dict[str, str] = {}
            for line in path.read_text().splitlines():
                parts = line.split()
                if len(parts) == 2 and re.fullmatch(r"[0-9a-f]{64}", parts[0]):
                    sums[parts[1].lstrip("*")] = parts[0]
        _RELEASE_SUMS[base] = sums
    return _RELEASE_SUMS[base]


def fetch_bughouse(name: str, lock: dict, force: bool) -> None:
    """Fetch one platform's HypeBeast binary (the network is separate)."""
    spec = BUGHOUSE_TARGETS[name]
    rel = spec["dest"]
    dest = REPO_ROOT / rel
    url = f"{HYPEBEAST_BASE}/{spec['asset']}"

    if name in lock and dest_is_current(name, dest, lock, url) and not force:
        # Still rewrite the manifest: the two macOS targets share one
        # destination, so "the file is already right" does not imply the
        # manifest describes *this* file.
        print(f"[ok]   {name}: {rel} present ({human(dest.stat().st_size)})")
        write_manifest(
            {
                manifest_key(rel): manifest_entry(
                    lock[name]["uncompressed_bytes"], lock[name]["payload_sha256"]
                )
            }
        )
        return

    print(f"[get]  {name} -> {rel}")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / spec["asset"]
        download(url, tmp, HYPEBEAST_RELEASE_PAGE)
        digest = verify_source(name, tmp, lock, url)
        published = release_sums(HYPEBEAST_BASE).get(spec["asset"])
        if published != digest:
            raise SystemExit(
                f"ERROR: {spec['asset']} does not match the release's SHA256SUMS.txt\n"
                f"  published {published}\n  got       {digest}\n"
                f"  See {HYPEBEAST_RELEASE_PAGE}"
            )
        binary = tmp.read_bytes()

    write_gz(binary, dest)
    write_manifest({manifest_key(rel): manifest_entry(len(binary), digest)})
    # The asset is the bare binary, so what was downloaded is what the app
    # unpacks: the source hash and the payload hash are the same value.
    lock[name] = {
        "url": url,
        "source_sha256": digest,
        "payload_sha256": digest,
        "uncompressed_bytes": len(binary),
    }
    print(f"       wrote {rel} ({human(dest.stat().st_size)})")


def _drive_confirm_url(page: str) -> str | None:
    """The real download URL behind Google Drive's "can't scan" page.

    Drive answers a large file with an HTML page holding a form whose hidden
    fields (id, export, confirm, uuid) make the actual download; submitting it
    is what clicking "Download anyway" does.
    """
    form = re.search(r'<form[^>]*id="download-form"[^>]*>(.*?)</form>', page, re.S)
    if form is None:
        return None
    action = re.search(r'action="([^"]+)"', form.group(0))
    if action is None:
        return None
    fields = {
        html.unescape(n): html.unescape(v)
        for n, v in re.findall(
            r'<input[^>]*type="hidden"[^>]*name="([^"]+)"[^>]*value="([^"]*)"',
            form.group(1),
        )
    }
    if not fields:
        return None
    return f"{html.unescape(action.group(1))}?{urllib.parse.urlencode(fields)}"


def download_from_drive(url: str, dest: Path) -> None:
    """Download a public Google Drive file unattended, through its warning page."""
    for _ in range(3):
        print(f"  downloading {url}")
        media_type = _stream(url, dest)
        if media_type != "text/html":
            return
        page = dest.read_text(errors="replace")
        follow = _drive_confirm_url(page)
        if follow is None:
            raise DownloadError("Google Drive answered with a page that has no download form")
        url = follow
    raise DownloadError("Google Drive kept answering with a page instead of the file")


def download_from_mirror(base: str, dest: Path, td: Path) -> None:
    """Reassemble the net from the site's gzipped parts (net.json + net-*.bin)."""
    print(f"  downloading {base}net.json")
    listing = td / "net.json"
    _stream(f"{base}net.json", listing)
    chunks = read_mirror_listing(listing.read_bytes(), base)
    packed = bytearray()
    for name, sha in chunks:
        part = td / "part.bin"
        print(f"  downloading {base}{name}")
        _stream(f"{base}{name}", part)
        data = part.read_bytes()
        if hashlib.sha256(data).hexdigest() != sha:
            raise DownloadError(f"{name} does not match {base}net.json")
        packed += data
    try:
        dest.write_bytes(gzip.decompress(bytes(packed)))
    except (OSError, EOFError, zlib.error) as exc:
        raise DownloadError(f"the parts at {base} are not one gzip stream") from exc


def read_mirror_listing(raw: bytes, base: str) -> list[tuple[str, str]]:
    """The parts `net.json` lists, as (file name, sha256), or DownloadError
    for anything that is not the pinned net's listing: not JSON, another
    net, or a part without a plain file name and a hash."""
    try:
        manifest = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise DownloadError(f"{base}net.json is not a net manifest") from exc
    if not isinstance(manifest, dict) or not isinstance(manifest.get("chunks"), list):
        raise DownloadError(f"{base}net.json is not a net manifest")
    if manifest.get("name") != BUGHOUSE_NETWORK["name"]:
        raise DownloadError(f"{base}net.json describes {manifest.get('name')!r}")
    chunks = []
    for chunk in manifest["chunks"]:
        name = chunk.get("file") if isinstance(chunk, dict) else None
        sha = chunk.get("sha256") if isinstance(chunk, dict) else None
        if (not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9._-]+", name)
                or name.startswith(".")
                or not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha)):
            raise DownloadError(f"{base}net.json lists a part it does not name or hash")
        chunks.append((name, sha))
    if not chunks:
        raise DownloadError(f"{base}net.json lists no parts")
    return chunks


def fetch_bughouse_network(lock: dict, force: bool) -> None:
    key = BUGHOUSE_NETWORK["key"]
    rel = BUGHOUSE_NETWORK["dest"]
    dest = REPO_ROOT / rel
    pinned = BUGHOUSE_NETWORK["sha256"]
    if key in lock and dest_is_current(key, dest, lock) and not force:
        print(f"[ok]   {key}: {rel} present ({human(dest.stat().st_size)})")
        write_manifest({manifest_key(rel): manifest_entry(gunzipped_size(dest), pinned)})
        return

    print(f"[get]  {key} -> {rel}")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / BUGHOUSE_NETWORK["name"]
        sources = (
            ("Google Drive", lambda: download_from_drive(BUGHOUSE_NETWORK["url"], tmp)),
            ("the chessautoprep.com copy",
             lambda: download_from_mirror(BUGHOUSE_NETWORK["mirror"], tmp, Path(td))),
        )
        failures = []
        for label, fetch in sources:
            try:
                fetch()
            except DownloadError as exc:
                failures.append(f"{label}: {exc}")
                print(f"  {label} failed: {exc}")
                continue
            digest = sha256_file(tmp)
            if digest == pinned:
                break
            failures.append(f"{label}: got {digest}, not the pinned net")
            print(f"  {label} gave a different file ({digest[:12]}…)")
        else:
            raise SystemExit(
                f"ERROR: could not download {BUGHOUSE_NETWORK['name']}\n  "
                + "\n  ".join(failures)
            )
        payload = tmp.read_bytes()

    write_gz(payload, dest)
    write_manifest({manifest_key(rel): manifest_entry(len(payload), pinned)})
    lock[key] = {
        "url": BUGHOUSE_NETWORK["url"],
        "source_sha256": pinned,
        "payload_sha256": pinned,
        "uncompressed_bytes": len(payload),
    }
    print(f"       wrote {rel} ({human(dest.stat().st_size)})")


def install_from_build(checkout: Path) -> int:
    """Pack a local HypeBeast build instead of downloading a release.

    What you want while working on the engine itself: the binary its makefile
    leaves in engine/src/ and the net from its nets/ folder, written where and
    how a downloaded release would be.
    """
    root = checkout.expanduser().resolve()
    candidates = [root / "engine" / "src" / "stockfish.exe", root / "engine" / "src" / "stockfish"]
    binary_path = next((p for p in candidates if p.is_file()), None)
    if binary_path is None:
        raise SystemExit(
            f"ERROR: no engine build in {root / 'engine' / 'src'}.\n"
            "  Build it first: make -j4 build ARCH=x86-64-modern (in engine/src)."
        )
    network = root / "nets" / BUGHOUSE_NETWORK["name"]
    if not network.is_file():
        raise SystemExit(f"ERROR: {network} not found.")
    payload = network.read_bytes()
    if hashlib.sha256(payload).hexdigest() != BUGHOUSE_NETWORK["sha256"]:
        raise SystemExit(f"ERROR: {network} is not the pinned bughouse network.")
    binary = binary_path.read_bytes()

    BUGHOUSE_ASSETS.mkdir(parents=True, exist_ok=True)
    remove_stale_bughouse()
    engine_dest = BUGHOUSE_TARGETS[bughouse_host_target()]["dest"]
    write_gz(binary, REPO_ROOT / engine_dest)
    write_gz(payload, REPO_ROOT / BUGHOUSE_NETWORK["dest"])
    write_manifest(
        {
            manifest_key(engine_dest): manifest_entry(
                len(binary), hashlib.sha256(binary).hexdigest()
            ),
            manifest_key(BUGHOUSE_NETWORK["dest"]): manifest_entry(
                len(payload), BUGHOUSE_NETWORK["sha256"]
            ),
        }
    )
    print(f"Installed {binary_path} and {network.name} into {BUGHOUSE_ASSETS}")
    print("Note: a local build is not the pinned release, so --check reports "
          "it as stale; fetch again to go back to the release.")
    return 0


def check_bughouse(names: list[str], lock: dict) -> list[str]:
    problems: list[str] = []
    paths: list[tuple[str, Path]] = [
        (BUGHOUSE_NETWORK["key"], REPO_ROOT / BUGHOUSE_NETWORK["dest"])
    ]
    paths += [(n, REPO_ROOT / BUGHOUSE_TARGETS[n]["dest"]) for n in names]
    for key, path in paths:
        if not check_gz(key, path, lock):
            problems.append(key)

    for path in stale_bughouse_files():
        print(
            f"[OLD ] {path.relative_to(REPO_ROOT)}: a Hivemind file the app "
            "would bundle; a fetch removes it"
        )
        problems.append(path.name)

    manifest_rel = BUGHOUSE_MANIFEST.relative_to(REPO_ROOT)
    if not BUGHOUSE_MANIFEST.exists():
        print(f"[MISS] manifest: {manifest_rel}")
        problems.append("manifest")
        return problems
    try:
        manifest = json.loads(BUGHOUSE_MANIFEST.read_text())
    except (json.JSONDecodeError, OSError):
        manifest = None
    if not isinstance(manifest, dict):
        print(f"[BAD ] manifest: {manifest_rel} is not a JSON object")
        problems.append("manifest")
        return problems
    wanted = {manifest_key(BUGHOUSE_NETWORK["dest"]): lock.get(BUGHOUSE_NETWORK["key"], {})}
    for n in names:
        wanted[manifest_key(BUGHOUSE_TARGETS[n]["dest"])] = lock.get(n, {})
    missing = set(wanted) - set(manifest)
    if missing:
        print(f"[BAD ] manifest: missing {', '.join(sorted(missing))}")
        problems.append("manifest")
        return problems
    malformed = [
        name
        for name in wanted
        if not isinstance(manifest.get(name), dict)
        or not isinstance(manifest[name].get("bytes"), int)
        or not isinstance(manifest[name].get("sha256"), str)
        or len(manifest[name]["sha256"]) != 64
    ]
    if malformed:
        print(f"[BAD ] manifest: invalid integrity record for {', '.join(sorted(malformed))}")
        problems.append("manifest")
        return problems
    # The app trusts the manifest, not the lock: it must describe the pinned files.
    differs = [
        name
        for name, entry in wanted.items()
        if entry.get("payload_sha256")
        and (manifest[name]["sha256"], manifest[name]["bytes"])
        != (entry["payload_sha256"], entry.get("uncompressed_bytes"))
    ]
    if differs:
        print(f"[BAD ] manifest: does not describe the pinned {', '.join(sorted(differs))}")
        problems.append("manifest")
        return problems
    print(f"[ok  ] manifest: {manifest_rel}")
    return problems


# --- Hivemind, for the tools only ------------------------------------------


def fetch_hivemind_network(lock: dict, force: bool) -> None:
    key = HIVEMIND_NETWORK["key"]
    rel = HIVEMIND_NETWORK["dest"]
    dest = REPO_ROOT / rel
    if dest_is_current(key, dest, lock) and not force:
        print(f"[ok]   {key}: {rel} present ({human(dest.stat().st_size)})")
        return

    url = f"{HIVEMIND_BASE}/{HIVEMIND_NETWORK['asset']}"
    print(f"[get]  {key} -> {rel}")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / HIVEMIND_NETWORK["asset"]
        download(url, tmp, HIVEMIND_RELEASE_PAGE)
        digest = verify_source(key, tmp, lock, url)
        # Already gzipped upstream; pass it through rather than recompressing.
        write_replacing(dest, tmp.read_bytes())

    lock[key] = {
        "url": url,
        "source_sha256": digest,
        "output_sha256": sha256_file(dest),
        "payload_sha256": payload_sha256(dest),
        "output_bytes": dest.stat().st_size,
        "uncompressed_bytes": gunzipped_size(dest),
    }
    print(f"       wrote {rel} ({human(dest.stat().st_size)})")


def fetch_hivemind(name: str, lock: dict, force: bool) -> None:
    """Fetch one platform's Hivemind engine + ONNX Runtime pair."""
    spec = HIVEMIND_TARGETS[name]
    engine_member, engine_dest = spec["engine"]
    runtime_member, runtime_dest = spec["runtime"]
    engine_path = REPO_ROOT / engine_dest
    runtime_path = REPO_ROOT / runtime_dest

    fresh = (
        f"{name}:engine" in lock
        and f"{name}:runtime" in lock
        and dest_is_current(f"{name}:engine", engine_path, lock)
        and dest_is_current(f"{name}:runtime", runtime_path, lock)
    )
    if fresh and not force:
        print(f"[ok]   {name}: {engine_dest} + {runtime_dest} present")
        return

    url = f"{HIVEMIND_BASE}/{spec['archive']}"
    print(f"[get]  {name} -> {engine_dest} + {runtime_dest}")
    with tempfile.TemporaryDirectory() as td:
        # Keep the upstream filename: read_member dispatches on the suffix, so
        # a generic temp name would send the Windows zip down the tar path.
        tmp = Path(td) / os.path.basename(urllib.parse.urlparse(url).path)
        download(url, tmp, HIVEMIND_RELEASE_PAGE)
        digest = verify_source(name, tmp, lock, url)
        engine_bytes = read_member(tmp, engine_member)
        runtime_bytes = read_member(tmp, runtime_member)

    for role, payload in (("engine", engine_bytes), ("runtime", runtime_bytes)):
        pinned = lock.get(f"{name}:{role}", {}).get("payload_sha256")
        if pinned and lock.get(name, {}).get("url") == url \
                and hashlib.sha256(payload).hexdigest() != pinned:
            raise SystemExit(f"ERROR: the {role} inside {spec['archive']} is not the pinned one")

    write_gz(engine_bytes, engine_path)
    write_gz(runtime_bytes, runtime_path)

    lock[name] = {"url": url, "source_sha256": digest}
    for role, path, payload in (
        ("engine", engine_path, engine_bytes),
        ("runtime", runtime_path, runtime_bytes),
    ):
        lock[f"{name}:{role}"] = {
            "output_sha256": sha256_file(path),
            "payload_sha256": hashlib.sha256(payload).hexdigest(),
            "output_bytes": path.stat().st_size,
            "uncompressed_bytes": len(payload),
        }
    print(
        f"       wrote {engine_dest} ({human(engine_path.stat().st_size)})"
        f" + {runtime_dest} ({human(runtime_path.stat().st_size)})"
    )


def check_hivemind(names: list[str], lock: dict) -> list[str]:
    problems: list[str] = []
    paths = [(HIVEMIND_NETWORK["key"], REPO_ROOT / HIVEMIND_NETWORK["dest"])]
    for n in names:
        paths.append((f"{n}:engine", REPO_ROOT / HIVEMIND_TARGETS[n]["engine"][1]))
        paths.append((f"{n}:runtime", REPO_ROOT / HIVEMIND_TARGETS[n]["runtime"][1]))
    for key, path in paths:
        if not check_gz(key, path, lock):
            problems.append(key)
    return problems


# --- Entry point -----------------------------------------------------------


def split_targets(names: list[str]) -> tuple[list[str], list[str], list[str]]:
    stockfish = [n for n in names if n in STOCKFISH_TARGETS]
    bughouse = [n for n in names if n in BUGHOUSE_TARGETS]
    hivemind = [n for n in names if n in HIVEMIND_TARGETS]
    return stockfish, bughouse, hivemind


def check(names: list[str], lock: dict, only: list[str] | None) -> int:
    stockfish, bughouse, hivemind = split_targets(names)
    problems = check_stockfish(stockfish, lock)
    if bughouse:
        problems += check_bughouse(bughouse, lock)
    if hivemind:
        problems += check_hivemind(hivemind, lock)
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
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n")[0])
    ap.add_argument("--check", action="store_true", help="verify only, do not download")
    ap.add_argument("--force", action="store_true", help="re-download even if present")
    ap.add_argument(
        "--only",
        action="append",
        choices=sorted(STOCKFISH_TARGETS)
        + sorted(BUGHOUSE_TARGETS)
        + sorted(HIVEMIND_TARGETS)
        + list(FAMILIES),
        help="a target, or an engine name for the host platform (repeatable; "
        "default: stockfish and bughouse for the host; hivemind only when named)",
    )
    ap.add_argument("--hypebeast", type=Path, metavar="CHECKOUT",
                    help="pack a local HypeBeast build (engine/src, nets/) "
                    "instead of downloading")
    args = ap.parse_args()

    if args.hypebeast:
        return install_from_build(args.hypebeast)

    names = resolve_targets(args.only)
    lock = load_lock()

    if args.check:
        return check(names, lock, args.only)

    before = json.dumps(lock, sort_keys=True)
    stockfish, bughouse, hivemind = split_targets(names)
    for n in stockfish:
        fetch_stockfish(n, lock, args.force)
    if bughouse:
        BUGHOUSE_ASSETS.mkdir(parents=True, exist_ok=True)
        remove_stale_bughouse()
        for n in bughouse:
            fetch_bughouse(n, lock, args.force)
        fetch_bughouse_network(lock, args.force)
    if hivemind:
        HIVEMIND_ASSETS.mkdir(parents=True, exist_ok=True)
        for n in hivemind:
            fetch_hivemind(n, lock, args.force)
        fetch_hivemind_network(lock, args.force)
    if json.dumps(lock, sort_keys=True) != before:
        save_lock(lock)
        print(f"\nUpdated {LOCKFILE.relative_to(REPO_ROOT)} -- commit it.")
    print("\nDone. Assets are gitignored; re-run after a clean checkout.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
