"""Export distinct event and player names from the TWIC database to static JSON files.

Run after each weekly ingest so the frontend can validate names
client-side without hitting the API.
"""

import json
import sys
from pathlib import Path

from models import get_db

DEFAULT_DB = Path(__file__).parent / "positions.db"
PUBLIC_DIR = Path(__file__).parent / "frontend" / "public"


def _write_json(data: list, out_path: Path, label: str):
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps(data, ensure_ascii=False), encoding="utf-8")
    print(f"Exported {len(data)} {label} to {out_path} "
          f"({out_path.stat().st_size // 1024} KB)")


def export_events(db_path: Path = DEFAULT_DB,
                  out_path: Path = PUBLIC_DIR / "events.json"):
    db = get_db(db_path)
    rows = db.execute(
        "SELECT DISTINCT event FROM games WHERE event IS NOT NULL ORDER BY event"
    ).fetchall()
    db.close()
    _write_json([r["event"] for r in rows if r["event"]], out_path, "events")


def export_players(db_path: Path = DEFAULT_DB,
                   out_path: Path = PUBLIC_DIR / "players.json"):
    db = get_db(db_path)
    rows = db.execute("""
        SELECT name, cnt FROM (
            SELECT white AS name, COUNT(*) AS cnt FROM games
            WHERE white IS NOT NULL GROUP BY white
            UNION ALL
            SELECT black AS name, COUNT(*) AS cnt FROM games
            WHERE black IS NOT NULL GROUP BY black
        ) GROUP BY name ORDER BY name
    """).fetchall()
    db.close()
    _write_json([r["name"] for r in rows if r["name"]], out_path, "players")


def export_all(db_path: Path = DEFAULT_DB):
    export_events(db_path)
    export_players(db_path)


if __name__ == "__main__":
    db = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_DB
    export_all(db)
