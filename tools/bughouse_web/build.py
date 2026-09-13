#!/usr/bin/env python3
"""Rebuild committed browser engine from pinned Hivemind + local bridge.

Run through scripts/ci.sh with --. Deployment only runs prepare_assets.py.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parents[2]
REVISION = "5508ba9daf4164e48a8a8a9b39e101efdc60e97a"
REPOSITORY = "https://github.com/Zinkelburger/hivemind.git"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, help="Existing clean checkout at the pinned engine revision")
    parser.add_argument("--emsdk", type=Path, default=Path(os.environ.get(
        "EMSDK", str(Path.home() / ".local/share/chess-prep/emsdk"))))
    args = parser.parse_args()
    source = args.source or ROOT / "build/bughouse-web-source"
    if not source.exists():
        source.parent.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "clone", "--no-checkout", "--filter=blob:none", REPOSITORY, str(source)], check=True)
        subprocess.run(["git", "-C", str(source), "checkout", "--detach", REVISION], check=True)
    actual = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=no"], text=True).strip()
    if actual != REVISION or dirty:
        raise SystemExit(f"Need a clean Hivemind checkout at {REVISION}; supplied source is untouched.")
    emcmake = args.emsdk / "upstream/emscripten/emcmake"
    if not emcmake.is_file():
        raise SystemExit("Install and activate Emscripten SDK 4.0.15, or set --emsdk/EMSDK.")
    compiler = subprocess.check_output([str(emcmake.parent / "emcc"), "--version"], text=True).splitlines()[0]
    if " 4.0.15 " not in compiler:
        raise SystemExit(f"This browser build pins Emscripten 4.0.15; found {compiler}")
    build = ROOT / "build/bughouse-wasm"
    subprocess.run([str(emcmake), "cmake", "-S", str(Path(__file__).parent), "-B", str(build),
                    f"-DHIVEMIND_SOURCE={source.resolve()}", "-DCMAKE_BUILD_TYPE=Release"], check=True)
    subprocess.run(["cmake", "--build", str(build), "--parallel", "2"], check=True)
    public = ROOT / "python/twic-position-finder/frontend/public/bughouse-engine"
    public.mkdir(parents=True, exist_ok=True)
    hashes = {}
    for name in ["hivemind.mjs", "hivemind.wasm"]:
        shutil.copyfile(build / name, public / name)
        hashes[name] = hashlib.sha256((public / name).read_bytes()).hexdigest()
    sources = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
               for p in Path(__file__).parent.iterdir() if p.suffix in (".cc", ".txt")}
    # Ship corresponding source beside the WASM, including the exact upstream
    # revision and adapters. Downloading the running engine's source must not
    # depend on a moving GitHub branch or a future app publication.
    archive = io.BytesIO(subprocess.check_output([
        "git", "-C", str(source), "archive", "--format=tar", "--prefix=hivemind/",
        REVISION, "engine", "LICENSE",
    ]))
    with tarfile.open(fileobj=archive, mode="a") as bundle:
        def add(name, data):
            entry = tarfile.TarInfo(name)
            entry.size = len(data)
            entry.mode = 0o644
            bundle.addfile(entry, io.BytesIO(data))
        for name in sorted(sources):
            add("browser/" + name, (Path(__file__).parent / name).read_bytes())
        add("README.txt", (
            f"Hivemind browser source at {REVISION}\n{REPOSITORY}\n\n"
            "Install and activate Emscripten 4.0.15. From this extracted directory:\n"
            "emcmake cmake -S browser -B build -DHIVEMIND_SOURCE=\"$PWD/hivemind\" -DCMAKE_BUILD_TYPE=Release\n"
            "cmake --build build --parallel 2\n\n"
            "Outputs: build/hivemind.mjs and build/hivemind.wasm.\n"
            "Browser adapters are part of Chess Auto Prep, under AGPL-3.0.\n"
        ).encode())
        add("browser/LICENSE", (ROOT / "LICENSE").read_bytes())
    name = "hivemind-source.tar.gz"
    (public / name).write_bytes(gzip.compress(archive.getvalue(), mtime=0))
    hashes[name] = hashlib.sha256((public / name).read_bytes()).hexdigest()
    (public / "build.json").write_text(json.dumps({"source": REPOSITORY, "revision": REVISION,
                                                 "emscripten": "4.0.15", "sha256": hashes,
                                                 "bridge_sha256": sources}, indent=2) + "\n")
    print("Rebuilt the static engine from", REVISION)


if __name__ == "__main__":
    main()
