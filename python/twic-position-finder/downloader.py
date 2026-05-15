"""Download and extract TWIC PGN files from theweekinchess.com."""

import io
import logging
import re
import time
import zipfile
from pathlib import Path

import requests

log = logging.getLogger("twic.downloader")

TWIC_ZIP_URL = "https://theweekinchess.com/zips/twic{number}g.zip"
DEFAULT_DATA_DIR = Path(__file__).parent / "data"
DEFAULT_FIRST_TWIC = 1637
_HEADERS = {"User-Agent": "TWIC-Position-Finder/1.0 (chess prep tool)"}
_MAX_RETRIES = 3


def download_twic(number: int, data_dir: Path = DEFAULT_DATA_DIR) -> Path | None:
    """Download a single TWIC zip and extract the PGN. Returns the PGN path."""
    data_dir.mkdir(parents=True, exist_ok=True)
    pgn_path = data_dir / f"twic{number}.pgn"

    if pgn_path.exists():
        log.info("  Already have twic%d.pgn, skipping download", number)
        return pgn_path

    url = TWIC_ZIP_URL.format(number=number)
    log.info("  Downloading %s ...", url)

    for attempt in range(1, _MAX_RETRIES + 1):
        try:
            resp = requests.get(url, timeout=(10, 60), headers=_HEADERS)

            if resp.status_code in (404, 406, 403):
                return None
            resp.raise_for_status()

            try:
                with zipfile.ZipFile(io.BytesIO(resp.content)) as zf:
                    pgn_names = [n for n in zf.namelist() if n.lower().endswith(".pgn")]
                    if not pgn_names:
                        log.error("No PGN found in twic%dg.zip", number)
                        return None
                    zf.extract(pgn_names[0], path=data_dir)
                    extracted = data_dir / pgn_names[0]
                    if extracted != pgn_path:
                        extracted.rename(pgn_path)
            except zipfile.BadZipFile:
                log.error("Corrupt zip for TWIC #%d, skipping", number)
                return None

            log.info("  Extracted %s (%d KB)",
                     pgn_path.name, pgn_path.stat().st_size // 1024)
            return pgn_path

        except requests.RequestException as e:
            if attempt < _MAX_RETRIES:
                wait = 5 * attempt
                log.warning("  Download error (attempt %d/%d): %s — retrying in %ds",
                            attempt, _MAX_RETRIES, e, wait)
                time.sleep(wait)
            else:
                log.error("  Download failed after %d attempts: %s", _MAX_RETRIES, e)
                raise

    return None


def download_latest(start_from: int,
                    data_dir: Path = DEFAULT_DATA_DIR) -> list[tuple[int, Path]]:
    """Download TWIC issues starting from `start_from`, stopping at the first 404."""
    downloaded: list[tuple[int, Path]] = []
    number = start_from
    while True:
        log.info("Trying TWIC #%d ...", number)
        path = download_twic(number, data_dir)
        if path is None:
            log.info("TWIC #%d not available yet — we're up to date.", number)
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

    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s [%(levelname)s] %(message)s")

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
