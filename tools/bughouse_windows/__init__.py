"""Integrity of the committed Windows engine and its corresponding source."""
import gzip
import hashlib
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent


def verified_engine() -> bytes:
    metadata = json.loads((HERE / "build.json").read_text())
    for section in ("sha256", "source_sha256"):
        for name, expected in metadata[section].items():
            if hashlib.sha256((HERE / name).read_bytes()).hexdigest() != expected:
                raise ValueError(f"Windows engine build is stale: {name}; rebuild tools/bughouse_windows")
    payload = gzip.decompress((HERE / "hivemind-windows.exe.gz").read_bytes())
    if (len(payload) != metadata["engine_bytes"] or
            hashlib.sha256(payload).hexdigest() != metadata["engine_payload_sha256"]):
        raise ValueError("Windows engine payload does not match build.json")
    return payload
