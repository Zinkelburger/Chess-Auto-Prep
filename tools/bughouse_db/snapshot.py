"""Consistent, compressed Git backups of the two local bughouse databases.

python3 -m bughouse_db.snapshot export --source DATA_HOME --destination BACKUP
python3 -m bughouse_db.snapshot restore --source BACKUP --destination EMPTY_DIR

SQLite backup includes committed WAL data without modifying the live database.
Chunks stay below Git hosting file limits. Restore refuses existing files.
"""

import argparse
import datetime
import gzip
import hashlib
import json
import shutil
import sqlite3
import tempfile
from pathlib import Path

NAMES = ("bughouse_book.db", "hivemind_book.db")
CHUNK = 20 * 1024 * 1024


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def export(source, destination):
    destination.mkdir(parents=True, exist_ok=False)
    manifest = {"format": 1, "created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(), "databases": []}
    with tempfile.TemporaryDirectory() as temporary:
        for name in NAMES:
            clean = Path(temporary) / name
            original = sqlite3.connect((source / name).resolve().as_uri() + "?mode=ro", uri=True)
            backup = sqlite3.connect(clean)
            try:
                original.backup(backup)
                if backup.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                    raise ValueError(f"{name}: database integrity check failed")
            finally:
                backup.close()
                original.close()
            compressed = clean.with_suffix(".db.gz")
            with clean.open("rb") as src, compressed.open("wb") as dst:
                with gzip.GzipFile(fileobj=dst, mode="wb", filename="", mtime=0) as zipped:
                    shutil.copyfileobj(src, zipped)
            record = {"name": name, "bytes": clean.stat().st_size, "sha256": sha(clean), "chunks": []}
            with compressed.open("rb") as stream:
                while data := stream.read(CHUNK):
                    part = destination / f"{name}.gz.{len(record['chunks']):03d}"
                    part.write_bytes(data)
                    record["chunks"].append({"name": part.name, "sha256": sha(part)})
            manifest["databases"].append(record)
    (destination / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")


def restore(source, destination):
    manifest = json.loads((source / "manifest.json").read_text())
    if manifest["format"] != 1:
        raise ValueError("Unsupported snapshot format")
    destination.mkdir(parents=True, exist_ok=True)
    for record in manifest["databases"]:
        if record["name"] not in NAMES or (destination / record["name"]).exists():
            raise ValueError("Restore needs an empty destination; never overwrite a live database")
    with tempfile.TemporaryDirectory(dir=destination) as temporary:
        verified = []
        for record in manifest["databases"]:
            packed = Path(temporary) / "packed.gz"
            with packed.open("wb") as stream:
                for chunk in record["chunks"]:
                    if Path(chunk["name"]).name != chunk["name"]:
                        raise ValueError("Invalid chunk path")
                    part = source / chunk["name"]
                    if sha(part) != chunk["sha256"]:
                        raise ValueError(f"Checksum mismatch: {part.name}")
                    with part.open("rb") as src:
                        shutil.copyfileobj(src, stream)
            clean = Path(temporary) / record["name"]
            with gzip.open(packed, "rb") as src, clean.open("wb") as dst:
                shutil.copyfileobj(src, dst)
            if clean.stat().st_size != record["bytes"] or sha(clean) != record["sha256"]:
                raise ValueError(f"Database checksum mismatch: {clean.name}")
            verified.append(clean)
        for clean in verified:
            # Exclusive creation also protects against a file appearing during restore.
            with clean.open("rb") as src, (destination / clean.name).open("xb") as dst:
                shutil.copyfileobj(src, dst)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("operation", choices=("export", "restore"))
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    {"export": export, "restore": restore}[args.operation](args.source, args.destination)


if __name__ == "__main__":
    main()
