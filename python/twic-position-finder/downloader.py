"""Download and extract TWIC PGN files from theweekinchess.com."""

import io
import re
import zipfile
from pathlib import Path

import requests

TWIC_ZIP_URL = "https://theweekinchess.com/zips/twic{number}g.zip"
DEFAULT_DATA_DIR = Path(__file__).parent / "data"
DEFAULT_FIRST_TWIC = 1637


def download_twic(number: int, data_dir: Path = DEFAULT_DATA_DIR) -> Path | None:
    """Download a single TWIC zip and extract the PGN. Returns the PGN path."""
    data_dir.mkdir(parents=True, exist_ok=True)
    pgn_path = data_dir / f"twic{number}.pgn"

    if pgn_path.exists():
        print(f"  Already have twic{number}.pgn, skipping download")
        return pgn_path

    url = TWIC_ZIP_URL.format(number=number)
    print(f"  Downloading {url} ...")
    resp = requests.get(url, timeout=60)

    if resp.status_code in (404, 406, 403):
        return None
    resp.raise_for_status()

    with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
        pgn_names = [n for n in zf.namelist() if n.lower().endswith(".pgn")]
        if not pgn_names:
            raise RuntimeError(f"No PGN found in twic{number}g.zip")
        zf.extract(pgn_names[0], path=data_dir)
        extracted = data_dir / pgn_names[0]
        if extracted != pgn_path:
            extracted.rename(pgn_path)

    print(f"  Extracted {pgn_path.name} ({pgn_path.stat().st_size / 1024:.0f} KB)")
    return pgn_path


def download_latest(start_from: int, data_dir: Path = DEFAULT_DATA_DIR) -> list[Path]:
    """Download TWIC issues starting from `start_from`, stopping at the first 404."""
    downloaded = []
    number = start_from
    while True:
        print(f"Trying TWIC #{number} ...")
        path = download_twic(number, data_dir)
        if path is None:
            print(f"TWIC #{number} not available yet — we're up to date.")
            break
        downloaded.append((number, path))
        number += 1
    return downloaded


def parse_twic_number(filename: str) -> int | None:
    """Extract the TWIC issue number from a filename like 'twic1637.pgn'."""
    m = re.search(r"twic(\d+)", filename, re.IGNORECASE)
    return int(m.group(1)) if m else None


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Download TWIC PGN files")
    parser.add_argument("--number", "-n", type=int,
                        help="Download a specific TWIC number")
    parser.add_argument("--from", dest="start", type=int, default=DEFAULT_FIRST_TWIC,
                        help=f"Start downloading from this number (default: {DEFAULT_FIRST_TWIC})")
    parser.add_argument("--data-dir", type=Path, default=DEFAULT_DATA_DIR)
    args = parser.parse_args()

    if args.number:
        download_twic(args.number, args.data_dir)
    else:
        download_latest(args.start, args.data_dir)
