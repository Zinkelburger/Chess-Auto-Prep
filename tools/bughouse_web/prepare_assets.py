#!/usr/bin/env python3
"""Prepare static Pages assets. No compiler, service or credentials at deploy time."""

import gzip
import hashlib
import json
from pathlib import Path
import shutil
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
FRONTEND = ROOT / "python/twic-position-finder/frontend"
PUBLIC = FRONTEND / "public/bughouse-engine"


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    PUBLIC.mkdir(parents=True, exist_ok=True)
    build = json.loads((PUBLIC / "build.json").read_text())
    for name, expected in build["sha256"].items():
        if not (PUBLIC / name).is_file() or digest((PUBLIC / name).read_bytes()) != expected:
            raise SystemExit(f"Missing or changed {name}: run tools/bughouse_web/build.py first.")
    for name, expected in build["bridge_sha256"].items():
        if digest((Path(__file__).parent / name).read_bytes()) != expected:
            raise SystemExit(f"The compiled engine is stale after changes to {name}. Rebuild it first.")
    lock = json.loads((ROOT / "tools/bughouse.lock.json").read_text())["network"]
    asset = ROOT / "assets/bughouse/hivemind.onnx.gz"
    data = asset.read_bytes() if asset.exists() else b""
    if digest(data) != lock["source_sha256"]:
        print("Downloading pinned Hivemind network for the static website…", flush=True)
        with urllib.request.urlopen(lock["url"], timeout=120) as response:
            data = response.read()
        if digest(data) != lock["source_sha256"]:
            raise SystemExit("Hivemind network checksum mismatch.")
        asset.parent.mkdir(parents=True, exist_ok=True)
        asset.write_bytes(data)
    if digest(gzip.decompress(data)) != lock["payload_sha256"]:
        raise SystemExit("Uncompressed network checksum mismatch.")
    chunks = []
    for index, start in enumerate(range(0, len(data), 16 * 1024 * 1024)):
        chunk = data[start:start + 16 * 1024 * 1024]
        name = f"model-{lock['source_sha256'][:12]}-{index}.bin"
        (PUBLIC / name).write_bytes(chunk)
        chunks.append({"file": name, "bytes": len(chunk), "sha256": digest(chunk)})
    manifest = {
        "model_sha256": lock["payload_sha256"], "chunks": chunks,
        "input": "data", "outputs": {"value": "value", "policyA": "pi_a", "policyB": "pi_b",
                                      "wdl": "wdl_out", "movesLeft": "moves_left"},
    }
    (PUBLIC / "model.json").write_text(json.dumps(manifest, indent=2) + "\n")
    runtime = FRONTEND / "node_modules/onnxruntime-web/dist"
    for name in ["ort-wasm-simd-threaded.mjs", "ort-wasm-simd-threaded.wasm"]:
        shutil.copyfile(runtime / name, PUBLIC / name)
    for name in ["HIVEMIND_LICENSE.txt", "ONNXRUNTIME_LICENSE.txt", "ONNXRUNTIME_THIRD_PARTY_NOTICES.txt"]:
        shutil.copyfile(ROOT / "assets/licenses" / name, PUBLIC / name)
    shutil.copyfile(ROOT / "LICENSE", PUBLIC / "CHESS_AUTO_PREP_LICENSE.txt")
    for path in PUBLIC.iterdir():
        if path.is_file() and path.stat().st_size >= 25 * 1024 * 1024:
            raise SystemExit(f"{path.name} exceeds Cloudflare Pages' 25 MiB file limit")
    print("Static Hivemind assets ready; every file is below 25 MiB.")


if __name__ == "__main__":
    main()
