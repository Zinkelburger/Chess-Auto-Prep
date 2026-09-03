#!/usr/bin/env python3
"""Fetch the Hivemind bughouse engine for this machine (not tracked in git).

Same contract as `fetch_assets.py`: these files are bundled by `pubspec.yaml`
and read from the Flutter root bundle at runtime, so they must exist *before*
`flutter build` runs. Unlike Stockfish there is no upstream download to point
at -- the project's own release is a ~2 GB Linux/NVIDIA TensorRT bundle -- so
the portable CPU builds come from a fork that publishes them per platform:

    https://github.com/Zinkelburger/hivemind/releases

    python3 tools/fetch_bughouse.py             # host platform only (~43 MB)
    python3 tools/fetch_bughouse.py --check     # verify; non-zero if missing
    python3 tools/fetch_bughouse.py --force     # re-download and overwrite
    python3 tools/fetch_bughouse.py --only bughouse-windows

Building the engine yourself instead -- what you want while working on the
engine -- stays available:

    python3 tools/fetch_bughouse.py --hivemind ~/Projects/hivemind

Three files land in assets/bughouse/: the engine, the ONNX Runtime it links
against, and the FP32 network, each gzipped, plus a manifest of uncompressed
sizes the app uses to spot a stale extraction.

IMPORTANT: assets/bughouse/.gitkeep is tracked on purpose. pubspec.yaml
declares the directory as an asset, and Flutter treats a *missing* asset
directory as a printed warning rather than a build failure -- so without it a
release builds green and ships with no engine at all.

Standard library only, so CI needs no pip install step.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import os
import pathlib
import json
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
ASSETS = REPO_ROOT / "assets" / "bughouse"
LOCKFILE = REPO_ROOT / "tools" / "bughouse.lock.json"
MANIFEST = ASSETS / "manifest.json"

# Pinned deliberately, for the same reason STOCKFISH_TAG is: tracking "latest"
# would make builds non-reproducible and let a new engine release break the app
# with no commit to point at. To upgrade, bump this, run with --force on each
# platform, and commit the regenerated bughouse.lock.json alongside.
ENGINE_TAG = "engine-v0.1.0"
ENGINE_BASE = (
    f"https://github.com/Zinkelburger/hivemind/releases/download/{ENGINE_TAG}"
)

# The engine archives are flat: the binary and the runtime side by side, which
# is the layout the RPATH baked into the binary ($ORIGIN / @loader_path) and
# Windows' next-to-the-exe DLL search both resolve against.
#
# macOS has two targets writing one pair of destinations, exactly as Stockfish
# does: the app has a single macOS slot, and the release workflow builds two
# apps, each fetching the archive matching its architecture.
TARGETS = {
    "bughouse-linux": {
        "archive": "hivemind-linux-x64.tar.gz",
        "engine": ("hivemind", "assets/bughouse/hivemind-linux.gz"),
        "runtime": ("libonnxruntime.so.1", "assets/bughouse/libonnxruntime.so.1.gz"),
    },
    "bughouse-windows": {
        "archive": "hivemind-windows-x64.zip",
        "engine": ("hivemind.exe", "assets/bughouse/hivemind-windows.exe.gz"),
        "runtime": ("onnxruntime.dll", "assets/bughouse/onnxruntime.dll.gz"),
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

# Architecture independent, so it is one asset shared by every target. Published
# already gzipped: it is the largest single thing here and re-compressing 54 MB
# in four release jobs buys nothing.
NETWORK = {
    "asset": "hivemind-network-fp32.onnx.gz",
    "dest": "assets/bughouse/hivemind.onnx.gz",
}


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


def host_target() -> str:
    plat, machine = sys.platform, platform.machine().lower()
    if plat.startswith("linux"):
        return "bughouse-linux"
    if plat == "darwin":
        return (
            "bughouse-macos-arm64"
            if machine in ("arm64", "aarch64")
            else "bughouse-macos-x86_64"
        )
    if plat == "win32":
        return "bughouse-windows"
    raise SystemExit(f"ERROR: unsupported platform {plat} ({machine})")


def load_lock() -> dict:
    return json.loads(LOCKFILE.read_text()) if LOCKFILE.exists() else {}


def save_lock(lock: dict) -> None:
    LOCKFILE.parent.mkdir(parents=True, exist_ok=True)
    LOCKFILE.write_text(json.dumps(lock, indent=2, sort_keys=True) + "\n")


def download(url: str, dest: Path) -> None:
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
            f"  The engine release {ENGINE_TAG} may not have this asset. See "
            "https://github.com/Zinkelburger/hivemind/releases"
        ) from exc
    if sys.stderr.isatty():
        print(file=sys.stderr)


def read_member(archive: Path, name: str) -> bytes:
    """Read one named member out of the flat engine archive."""
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


def write_gz(payload: bytes, dest: Path) -> None:
    """gzip `payload` to `dest` as the app expects.

    bughouse_bundle.dart calls `gzip.decode` on the raw asset bytes, so this is
    a plain gzip stream of the bare file, never a tar.gz. mtime is pinned to 0
    so repeated runs are byte-identical and the lockfile hash stays meaningful.
    """
    dest.parent.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(payload)
    tmp = dest.with_suffix(dest.suffix + ".tmp")
    tmp.write_bytes(buf.getvalue())
    tmp.replace(dest)


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


def write_manifest(sizes: dict[str, int]) -> None:
    """Record uncompressed sizes by extracted filename, merging with whatever
    is already there.

    The app compares each extracted file against these to notice a half-written
    or superseded extraction. Merging matters because the network is fetched
    independently of the platform pair, and because a checkout may hold several
    platforms at once.
    """
    current: dict[str, int] = {}
    if MANIFEST.exists():
        try:
            current = json.loads(MANIFEST.read_text())
        except json.JSONDecodeError:
            pass
    current.update(sizes)
    # Drop anything that is not an asset we ship, so a manifest left behind by
    # an older, role-keyed version of this script heals itself on the next run
    # instead of carrying two spellings of the same size forever.
    known = {manifest_key(NETWORK["dest"])} | {
        manifest_key(spec[role][1]) for spec in TARGETS.values() for role in ("engine", "runtime")
    }
    current = {k: v for k, v in current.items() if k in known}
    MANIFEST.write_text(json.dumps(current, indent=2, sort_keys=True) + "\n")


def dest_is_current(key: str, dest: Path, lock: dict) -> bool:
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


def fetch_network(lock: dict, force: bool) -> None:
    dest = REPO_ROOT / NETWORK["dest"]
    if dest_is_current("network", dest, lock) and not force:
        print(f"[ok]   network: {NETWORK['dest']} present ({human(dest.stat().st_size)})")
        write_manifest({manifest_key(NETWORK["dest"]): gunzipped_size(dest)})
        return

    url = f"{ENGINE_BASE}/{NETWORK['asset']}"
    print(f"[get]  network -> {NETWORK['dest']}")
    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td) / NETWORK["asset"]
        download(url, tmp)
        digest = sha256_file(tmp)
        expected = lock.get("network", {}).get("source_sha256")
        if expected and digest != expected:
            raise SystemExit(
                f"ERROR: checksum mismatch for the network\n"
                f"  expected {expected}\n  got      {digest}"
            )
        # Already gzipped upstream; pass it through rather than recompressing.
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(tmp, dest)

    size = gunzipped_size(dest)
    write_manifest({manifest_key(NETWORK["dest"]): size})
    lock["network"] = {
        "url": url,
        "source_sha256": digest,
        "output_sha256": sha256_file(dest),
        "payload_sha256": payload_sha256(dest),
        "output_bytes": dest.stat().st_size,
        "uncompressed_bytes": size,
    }
    print(f"       wrote {NETWORK['dest']} ({human(dest.stat().st_size)})")


def fetch(name: str, lock: dict, force: bool) -> None:
    spec = TARGETS[name]
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
        # Still rewrite the manifest. The platform pair and the network are
        # fetched independently, and the two macOS targets share one pair of
        # destinations, so "the files are already right" does not imply the
        # manifest describes *these* files.
        print(f"[ok]   {name}: {engine_dest} + {runtime_dest} present")
        write_manifest(
            {
                manifest_key(engine_dest): lock[f"{name}:engine"]["uncompressed_bytes"],
                manifest_key(runtime_dest): lock[f"{name}:runtime"]["uncompressed_bytes"],
            }
        )
        return

    url = f"{ENGINE_BASE}/{spec['archive']}"
    print(f"[get]  {name} -> {engine_dest} + {runtime_dest}")
    with tempfile.TemporaryDirectory() as td:
        # Keep the upstream filename: read_member dispatches on the suffix, so
        # a generic temp name would send the Windows zip down the tar path.
        tmp = Path(td) / os.path.basename(urllib.parse.urlparse(url).path)
        download(url, tmp)

        digest = sha256_file(tmp)
        expected = lock.get(name, {}).get("source_sha256")
        if expected and digest != expected:
            raise SystemExit(
                f"ERROR: checksum mismatch for {name}\n"
                f"  expected {expected}\n  got      {digest}\n"
                "  Upstream artifact changed. Verify before trusting it, then "
                "re-run with --force to accept."
            )

        engine_bytes = read_member(tmp, engine_member)
        runtime_bytes = read_member(tmp, runtime_member)

    write_gz(engine_bytes, engine_path)
    write_gz(runtime_bytes, runtime_path)
    write_manifest(
        {
            manifest_key(engine_dest): len(engine_bytes),
            manifest_key(runtime_dest): len(runtime_bytes),
        }
    )

    lock[name] = {"url": url, "source_sha256": digest}
    lock[f"{name}:engine"] = {
        "output_sha256": sha256_file(engine_path),
        "payload_sha256": hashlib.sha256(engine_bytes).hexdigest(),
        "output_bytes": engine_path.stat().st_size,
        "uncompressed_bytes": len(engine_bytes),
    }
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

    target = host_target().replace("bughouse-", "")
    slug = {
        "linux": "linux-x64",
        "windows": "windows-x64",
        "macos-arm64": "macos-arm64",
        "macos-x86_64": "macos-x86_64",
    }[target]

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

    name = host_target()
    spec = TARGETS[name]
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
    write_gz(payload, REPO_ROOT / NETWORK["dest"])

    write_manifest(
        {
            manifest_key(engine_dest): len(engine_bytes),
            manifest_key(runtime_dest): len(runtime_bytes),
            manifest_key(NETWORK["dest"]): len(payload),
        }
    )
    total = sum(f.stat().st_size for f in ASSETS.glob("*.gz"))
    print(f"\nInstalled a local build into {ASSETS} ({human(total)})")
    print("Note: a local build is tuned for this machine and is not "
          "redistributable — release builds come from the engine CI.")
    return 0


def check(names: list[str], lock: dict) -> int:
    problems: list[str] = []
    paths: list[tuple[str, Path]] = [("network", REPO_ROOT / NETWORK["dest"])]
    for n in names:
        paths.append((f"{n}:engine", REPO_ROOT / TARGETS[n]["engine"][1]))
        paths.append((f"{n}:runtime", REPO_ROOT / TARGETS[n]["runtime"][1]))

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
                print(f"[HASH] {key}: {rel} is not the file bughouse.lock.json pins")
                problems.append(key)
                continue
        elif entry.get("output_sha256") and sha256_file(path) != entry["output_sha256"]:
            print(f"[HASH] {key}: {rel} does not match bughouse.lock.json")
            problems.append(key)
            continue
        expected_size = entry.get("uncompressed_bytes")
        if expected_size is not None and gunzipped_size(path) != expected_size:
            print(f"[SIZE] {key}: {rel} does not unpack to {expected_size} bytes")
            problems.append(key)
            continue
        print(f"[ok  ] {key}: {rel} ({human(path.stat().st_size)})")

    if not MANIFEST.exists():
        print(f"[MISS] manifest: {MANIFEST.relative_to(REPO_ROOT)}")
        problems.append("manifest")
    else:
        keys = set(json.loads(MANIFEST.read_text()))
        wanted = {manifest_key(NETWORK["dest"])}
        for n in names:
            wanted.add(manifest_key(TARGETS[n]["engine"][1]))
            wanted.add(manifest_key(TARGETS[n]["runtime"][1]))
        missing = wanted - keys
        if missing:
            print(f"[BAD ] manifest: missing {', '.join(sorted(missing))}")
            problems.append("manifest")
        else:
            print(f"[ok  ] manifest: {MANIFEST.relative_to(REPO_ROOT)}")

    if problems:
        print(
            f"\n{len(problems)} bughouse asset(s) missing or stale. "
            f"Run: python3 tools/fetch_bughouse.py"
            f"{'' if names == [host_target()] else ' --only ' + names[0]}",
            file=sys.stderr,
        )
        return 1
    print("\nAll requested bughouse assets present.")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--check", action="store_true", help="verify only, do not download")
    ap.add_argument("--force", action="store_true", help="re-download even if present")
    ap.add_argument("--only", action="append", choices=sorted(TARGETS),
                    help="fetch this target instead of the host's (repeatable)")
    ap.add_argument("--hivemind", type=Path, metavar="CHECKOUT",
                    help="package a local Hivemind build instead of downloading")
    ap.add_argument("--build", default="engine/build-ort",
                    help="build directory inside the checkout (with --hivemind)")
    a = ap.parse_args()

    if a.hivemind:
        return install_from_build(a.hivemind, a.build)

    names = a.only or [host_target()]
    lock = load_lock()

    if a.check:
        return check(names, lock)

    ASSETS.mkdir(parents=True, exist_ok=True)
    for name in names:
        fetch(name, lock, a.force)
    fetch_network(lock, a.force)
    save_lock(lock)

    total = sum(f.stat().st_size for f in ASSETS.glob("*.gz"))
    print(f"\nBundled size: {human(total)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
