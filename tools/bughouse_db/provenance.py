"""Append-only score history shared with the v2 desktop writer.

Current pick/move tables remain compatible with older readers. Each replacement
keeps a complete snapshot, including calibration and the seat-letter convention.
"""

import hashlib
import json
import uuid


SCHEMA = """
CREATE TABLE IF NOT EXISTS analysis_history(
  id TEXT PRIMARY KEY, pos INTEGER NOT NULL, clock TEXT NOT NULL,
  provenance TEXT NOT NULL, picks TEXT NOT NULL, moves TEXT NOT NULL);
CREATE TABLE IF NOT EXISTS current_analysis(
  pos INTEGER NOT NULL, clock TEXT NOT NULL, id TEXT NOT NULL,
  PRIMARY KEY(pos, clock)) WITHOUT ROWID;
"""


def engine_identity(engine):
    def digest(path):
        with path.open("rb") as source:
            return hashlib.file_digest(source, "sha256").hexdigest()
    return {
        "engine_name": engine.name,
        "engine_sha256": digest(engine.files.binary),
        "network_sha256": digest(engine.files.model),
        "backend": engine.backend_detail,
        "writer": "python-book",
        "score_method": "calibrated-q-v1",
        "require_move_on": "none",
        "root_multipv": 1,
        "child_multipv": 1,
    }


def snapshot(con, pos, clock, provenance):
    def rows(table):
        cursor = con.execute(f"SELECT * FROM {table} WHERE pos=? AND clock=?", (pos, clock))
        names = [column[0] for column in cursor.description]
        return json.dumps([dict(zip(names, row)) for row in cursor])
    seats = con.execute("SELECT value FROM meta WHERE key='seats'").fetchone()
    run = uuid.uuid4().hex
    con.execute("INSERT INTO analysis_history VALUES(?,?,?,?,?,?)", (
        run, pos, clock, json.dumps({**provenance, "seats": seats[0] if seats else "AC/BD"}),
        rows("pick"), rows("move")))
    con.execute("INSERT OR REPLACE INTO current_analysis VALUES(?,?,?)", (pos, clock, run))


def preserve_legacy(con, pos):
    for (clock,) in con.execute("SELECT DISTINCT clock FROM move WHERE pos=?", (pos,)).fetchall():
        if con.execute("SELECT 1 FROM current_analysis WHERE pos=? AND clock=?", (pos, clock)).fetchone():
            continue
        nodes, child_nodes, completed = con.execute(
            "SELECT nodes, child_nodes, done_at FROM position WHERE pos=?", (pos,)).fetchone()
        snapshot(con, pos, clock, {
            "engine_name": "Unknown (legacy analysis)", "nodes": nodes,
            "child_nodes": child_nodes, "completed_at": completed,
            "budget_note": "Legacy position-level budget; individual clock budgets were not recorded.",
        })
