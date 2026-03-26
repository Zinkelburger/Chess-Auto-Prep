"""SQLite schema and database helpers for TWIC position indexing."""

import hashlib
import secrets
import sqlite3
import time
from pathlib import Path

DEFAULT_DB = Path(__file__).parent / "positions.db"

SCHEMA = """
CREATE TABLE IF NOT EXISTS games (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    event       TEXT,
    site        TEXT,
    date        TEXT,
    round       TEXT,
    white       TEXT,
    black       TEXT,
    result      TEXT,
    white_elo   INTEGER,
    black_elo   INTEGER,
    eco         TEXT,
    opening     TEXT,
    pgn_text    TEXT,
    source_file TEXT,
    twic_number INTEGER,
    lichess_url TEXT
);

CREATE TABLE IF NOT EXISTS positions (
    game_id      INTEGER REFERENCES games(id),
    ply          INTEGER,
    zobrist_hash INTEGER,
    fen          TEXT,
    move_uci     TEXT,
    PRIMARY KEY (game_id, ply)
);

CREATE TABLE IF NOT EXISTS users (
    id                      INTEGER PRIMARY KEY AUTOINCREMENT,
    email                   TEXT UNIQUE NOT NULL,
    verified                INTEGER DEFAULT 0,
    verify_token            TEXT,
    auth_token              TEXT UNIQUE,
    auth_token_expires_at   REAL,
    created_at              REAL,
    verified_at             REAL
);

CREATE TABLE IF NOT EXISTS subscriptions (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    user_id     INTEGER REFERENCES users(id) ON DELETE CASCADE,
    label       TEXT,
    fen         TEXT,
    zobrist_hash INTEGER,
    player      TEXT,
    white       TEXT,
    black       TEXT,
    exclude_site TEXT,
    site        TEXT,
    min_elo     INTEGER,
    eco         TEXT,
    active      INTEGER DEFAULT 1,
    created_at  REAL
);

CREATE TABLE IF NOT EXISTS notifications_sent (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    subscription_id INTEGER REFERENCES subscriptions(id),
    game_id         INTEGER REFERENCES games(id),
    twic_number     INTEGER,
    sent_at         REAL,
    UNIQUE(subscription_id, game_id)
);

CREATE INDEX IF NOT EXISTS idx_zobrist      ON positions(zobrist_hash);
CREATE INDEX IF NOT EXISTS idx_white        ON games(white);
CREATE INDEX IF NOT EXISTS idx_black        ON games(black);
CREATE INDEX IF NOT EXISTS idx_site         ON games(site);
CREATE INDEX IF NOT EXISTS idx_twic         ON games(twic_number);
CREATE INDEX IF NOT EXISTS idx_user_email   ON users(email);
CREATE INDEX IF NOT EXISTS idx_user_auth    ON users(auth_token);
CREATE INDEX IF NOT EXISTS idx_sub_user     ON subscriptions(user_id);
CREATE INDEX IF NOT EXISTS idx_sub_zobrist  ON subscriptions(zobrist_hash);
CREATE TABLE IF NOT EXISTS email_tokens (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    token_hash      TEXT UNIQUE NOT NULL,
    user_id         INTEGER REFERENCES users(id) ON DELETE CASCADE,
    purpose         TEXT NOT NULL,
    subscription_id INTEGER,
    expires_at      REAL NOT NULL,
    used            INTEGER DEFAULT 0,
    created_at      REAL
);

CREATE INDEX IF NOT EXISTS idx_notif_sub    ON notifications_sent(subscription_id);
CREATE INDEX IF NOT EXISTS idx_email_token  ON email_tokens(token_hash);
"""


def signed_zobrist(board) -> int:
    """Polyglot Zobrist hash converted to signed 64-bit int for SQLite."""
    import chess.polyglot
    h = chess.polyglot.zobrist_hash(board)
    return h if h < (1 << 63) else h - (1 << 64)


def validate_fen(fen: str) -> None:
    """Raise ValueError if *fen* is not a legal FEN string."""
    import chess
    chess.Board(fen)


def get_db(path: Path = DEFAULT_DB) -> sqlite3.Connection:
    db = sqlite3.connect(str(path))
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.executescript(SCHEMA)
    _run_migrations(db)
    return db


def _run_migrations(db: sqlite3.Connection):
    """Add columns that may be missing from older databases."""
    cols = {row[1] for row in db.execute("PRAGMA table_info(games)").fetchall()}
    if "lichess_url" not in cols:
        db.execute("ALTER TABLE games ADD COLUMN lichess_url TEXT")
        db.commit()

    user_cols = {row[1] for row in db.execute("PRAGMA table_info(users)").fetchall()}
    if "auth_token_expires_at" not in user_cols:
        db.execute("ALTER TABLE users ADD COLUMN auth_token_expires_at REAL")
        for row in db.execute("SELECT id, auth_token, verify_token FROM users").fetchall():
            if row["auth_token"]:
                db.execute(
                    "UPDATE users SET auth_token = ?, auth_token_expires_at = ? WHERE id = ?",
                    (_hash_token(row["auth_token"]), time.time() + AUTH_TOKEN_TTL, row["id"]),
                )
            if row["verify_token"]:
                db.execute(
                    "UPDATE users SET verify_token = ? WHERE id = ?",
                    (_hash_token(row["verify_token"]), row["id"]),
                )
        db.commit()


def insert_game(db: sqlite3.Connection, headers: dict, pgn_text: str,
                source_file: str, twic_number: int | None = None) -> int:
    def _elo(val):
        try:
            return int(val)
        except (ValueError, TypeError):
            return None

    cur = db.execute(
        """INSERT INTO games
           (event, site, date, round, white, black, result,
            white_elo, black_elo, eco, opening, pgn_text, source_file, twic_number)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (
            headers.get("Event"),
            headers.get("Site"),
            headers.get("Date"),
            headers.get("Round"),
            headers.get("White"),
            headers.get("Black"),
            headers.get("Result"),
            _elo(headers.get("WhiteElo")),
            _elo(headers.get("BlackElo")),
            headers.get("ECO"),
            headers.get("Opening"),
            pgn_text,
            source_file,
            twic_number,
        ),
    )
    return cur.lastrowid


def insert_positions_batch(db: sqlite3.Connection,
                           positions: list[tuple]) -> None:
    """Insert a batch of (game_id, ply, zobrist_hash, fen, move_uci) tuples."""
    db.executemany(
        "INSERT INTO positions (game_id, ply, zobrist_hash, fen, move_uci) "
        "VALUES (?,?,?,?,?)",
        positions,
    )


def highest_twic_number(db: sqlite3.Connection) -> int | None:
    row = db.execute("SELECT MAX(twic_number) FROM games").fetchone()
    return row[0] if row else None


# ── User management ──────────────────────────────────────────────────


def create_user(db: sqlite3.Connection, email: str) -> dict:
    """Create a new user with a verification token. Returns user dict.

    The returned ``verify_token`` is the *raw* (unhashed) value so the
    caller can include it in the verification email.  The database stores
    only the SHA-256 hash.
    """
    verify_token = secrets.token_urlsafe(32)
    auth_token = secrets.token_urlsafe(48)
    now = time.time()
    try:
        db.execute(
            "INSERT INTO users (email, verify_token, auth_token, created_at) "
            "VALUES (?, ?, ?, ?)",
            (email.lower().strip(), _hash_token(verify_token),
             _hash_token(auth_token), now),
        )
        db.commit()
    except sqlite3.IntegrityError:
        row = db.execute("SELECT * FROM users WHERE email = ?",
                         (email.lower().strip(),)).fetchone()
        if row and not row["verified"]:
            verify_token = secrets.token_urlsafe(32)
            db.execute("UPDATE users SET verify_token = ? WHERE id = ?",
                       (_hash_token(verify_token), row["id"]))
            db.commit()
            return {**dict(row), "verify_token": verify_token}
        return dict(row) if row else {}

    row = db.execute("SELECT * FROM users WHERE email = ?",
                     (email.lower().strip(),)).fetchone()
    return {**dict(row), "verify_token": verify_token}


def verify_user(db: sqlite3.Connection, token: str) -> dict | None:
    row = db.execute("SELECT * FROM users WHERE verify_token = ?",
                     (_hash_token(token),)).fetchone()
    if not row:
        return None
    db.execute("UPDATE users SET verified = 1, verified_at = ?, verify_token = NULL "
               "WHERE id = ?", (time.time(), row["id"]))
    activate_user_subscriptions(db, row["id"])
    db.commit()
    return dict(db.execute("SELECT * FROM users WHERE id = ?",
                           (row["id"],)).fetchone())


def get_user_by_auth(db: sqlite3.Connection, auth_token: str) -> dict | None:
    hashed = _hash_token(auth_token)
    row = db.execute(
        "SELECT * FROM users "
        "WHERE auth_token = ? AND verified = 1 AND auth_token_expires_at > ?",
        (hashed, time.time()),
    ).fetchone()
    return dict(row) if row else None


def get_user_by_email(db: sqlite3.Connection, email: str) -> dict | None:
    row = db.execute("SELECT * FROM users WHERE email = ?",
                     (email.lower().strip(),)).fetchone()
    return dict(row) if row else None


def rotate_auth_token(db: sqlite3.Connection, user_id: int) -> str:
    """Generate a fresh auth token for a user, invalidating the old one.

    Returns the raw (unhashed) token to send to the client.
    """
    new_token = secrets.token_urlsafe(48)
    db.execute(
        "UPDATE users SET auth_token = ?, auth_token_expires_at = ? WHERE id = ?",
        (_hash_token(new_token), time.time() + AUTH_TOKEN_TTL, user_id),
    )
    db.commit()
    return new_token


def revoke_auth_token(db: sqlite3.Connection, user_id: int) -> None:
    """Invalidate a user's auth token (logout)."""
    db.execute(
        "UPDATE users SET auth_token = NULL, auth_token_expires_at = NULL WHERE id = ?",
        (user_id,),
    )
    db.commit()


def _hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


AUTH_TOKEN_TTL = 30 * 24 * 3600   # 30 days
EMAIL_TOKEN_TTL = 7 * 24 * 3600  # 7 days


def create_email_token(db: sqlite3.Connection, user_id: int, purpose: str,
                       subscription_id: int | None = None,
                       ttl: int = EMAIL_TOKEN_TTL) -> str:
    """Create a short-lived, single-purpose email token. Returns the raw token."""
    raw = secrets.token_urlsafe(32)
    hashed = _hash_token(raw)
    now = time.time()
    db.execute(
        "INSERT INTO email_tokens "
        "(token_hash, user_id, purpose, subscription_id, expires_at, created_at) "
        "VALUES (?, ?, ?, ?, ?, ?)",
        (hashed, user_id, purpose, subscription_id, now + ttl, now),
    )
    db.commit()
    return raw


def consume_email_token(db: sqlite3.Connection, raw_token: str,
                        purpose: str) -> dict | None:
    """Validate and consume a single-use email token.

    Returns ``{"user_id": …, "subscription_id": …}`` or ``None``.
    """
    hashed = _hash_token(raw_token)
    row = db.execute(
        "SELECT * FROM email_tokens "
        "WHERE token_hash = ? AND purpose = ? AND used = 0 AND expires_at > ?",
        (hashed, purpose, time.time()),
    ).fetchone()
    if not row:
        return None
    db.execute("UPDATE email_tokens SET used = 1 WHERE id = ?", (row["id"],))
    db.commit()
    return {"user_id": row["user_id"], "subscription_id": row["subscription_id"]}


def cleanup_expired_email_tokens(db: sqlite3.Connection) -> int:
    """Delete expired or old consumed email tokens. Returns rows removed."""
    now = time.time()
    cur = db.execute(
        "DELETE FROM email_tokens WHERE expires_at < ? OR (used = 1 AND created_at < ?)",
        (now, now - 30 * 24 * 3600),
    )
    db.commit()
    return cur.rowcount


def count_user_subscriptions(db: sqlite3.Connection, user_id: int) -> int:
    row = db.execute(
        "SELECT COUNT(*) FROM subscriptions WHERE user_id = ? AND active = 1",
        (user_id,),
    ).fetchone()
    return row[0]


# ── Subscription management ──────────────────────────────────────────


def _compute_sub_zobrist(fen: str | None) -> int | None:
    """Compute signed Zobrist hash for a FEN, or None if no FEN."""
    if not fen:
        return None
    import chess
    board = chess.Board(fen)
    return signed_zobrist(board)


def add_subscription(db: sqlite3.Connection, user_id: int, *,
                     label: str = "", fen: str | None = None,
                     player: str | None = None, white: str | None = None,
                     black: str | None = None, exclude_site: str | None = None,
                     site: str | None = None, min_elo: int | None = None,
                     eco: str | None = None, active: bool = True) -> dict:
    zobrist = _compute_sub_zobrist(fen)
    cur = db.execute(
        """INSERT INTO subscriptions
           (user_id, label, fen, zobrist_hash, player, white, black,
            exclude_site, site, min_elo, eco, active, created_at)
           VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)""",
        (user_id, label, fen, zobrist, player, white, black,
         exclude_site, site, min_elo, eco, int(active), time.time()),
    )
    db.commit()
    return dict(db.execute("SELECT * FROM subscriptions WHERE id = ?",
                           (cur.lastrowid,)).fetchone())


def activate_user_subscriptions(db: sqlite3.Connection, user_id: int) -> int:
    """Activate all inactive subscriptions for a user. Returns count updated."""
    cur = db.execute(
        "UPDATE subscriptions SET active = 1 WHERE user_id = ? AND active = 0",
        (user_id,),
    )
    return cur.rowcount


def deactivate_subscription(db: sqlite3.Connection, sub_id: int,
                            user_id: int) -> bool:
    """Set a subscription to inactive. Returns True if updated."""
    cur = db.execute(
        "UPDATE subscriptions SET active = 0 WHERE id = ? AND user_id = ?",
        (sub_id, user_id),
    )
    db.commit()
    return cur.rowcount > 0


def get_subscriptions(db: sqlite3.Connection, user_id: int) -> list[dict]:
    rows = db.execute(
        "SELECT * FROM subscriptions WHERE user_id = ? AND active = 1",
        (user_id,),
    ).fetchall()
    return [dict(r) for r in rows]


def delete_subscription(db: sqlite3.Connection, sub_id: int, user_id: int) -> bool:
    cur = db.execute(
        "DELETE FROM subscriptions WHERE id = ? AND user_id = ?",
        (sub_id, user_id),
    )
    db.commit()
    return cur.rowcount > 0


def get_all_active_subscriptions(db: sqlite3.Connection) -> list[dict]:
    rows = db.execute(
        """SELECT s.*, u.email FROM subscriptions s
           JOIN users u ON u.id = s.user_id
           WHERE s.active = 1 AND u.verified = 1""",
    ).fetchall()
    return [dict(r) for r in rows]


def record_notification(db: sqlite3.Connection, sub_id: int,
                        game_id: int, twic_number: int) -> None:
    db.execute(
        "INSERT OR IGNORE INTO notifications_sent "
        "(subscription_id, game_id, twic_number, sent_at) VALUES (?,?,?,?)",
        (sub_id, game_id, twic_number, time.time()),
    )


def already_notified(db: sqlite3.Connection, sub_id: int, game_id: int) -> bool:
    row = db.execute(
        "SELECT 1 FROM notifications_sent WHERE subscription_id = ? AND game_id = ?",
        (sub_id, game_id),
    ).fetchone()
    return row is not None


def already_notified_batch(db: sqlite3.Connection, sub_id: int,
                           game_ids: list[int]) -> set[int]:
    """Return set of game_ids already notified for this subscription."""
    if not game_ids:
        return set()
    placeholders = ",".join("?" * len(game_ids))
    rows = db.execute(
        f"SELECT game_id FROM notifications_sent "
        f"WHERE subscription_id = ? AND game_id IN ({placeholders})",
        [sub_id, *game_ids],
    ).fetchall()
    return {r[0] for r in rows}


# ── Shared query helpers ─────────────────────────────────────────────


def _escape_like(value: str) -> str:
    """Escape special LIKE characters so they match literally."""
    return value.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def build_game_filters(*, white: str | None = None, black: str | None = None,
                       player: str | None = None, exclude_site: str | None = None,
                       site: str | None = None, min_elo: int | None = None,
                       eco: str | None = None,
                       twic_number: int | None = None) -> tuple[list[str], list]:
    """Build reusable SQL WHERE fragments and params for game filtering.

    Returns (clauses, params) where each clause should be ANDed into a query
    that aliases the games table as ``g``.
    """
    clauses: list[str] = []
    params: list = []
    if white:
        clauses.append("g.white LIKE ? ESCAPE '\\'")
        params.append(f"%{_escape_like(white)}%")
    if black:
        clauses.append("g.black LIKE ? ESCAPE '\\'")
        params.append(f"%{_escape_like(black)}%")
    if player:
        clauses.append("(g.white LIKE ? ESCAPE '\\' OR g.black LIKE ? ESCAPE '\\')")
        params.extend([f"%{_escape_like(player)}%", f"%{_escape_like(player)}%"])
    if exclude_site:
        clauses.append("g.site NOT LIKE ? ESCAPE '\\'")
        params.append(f"%{_escape_like(exclude_site)}%")
    if site:
        clauses.append("g.site LIKE ? ESCAPE '\\'")
        params.append(f"%{_escape_like(site)}%")
    if min_elo:
        clauses.append("(g.white_elo >= ? OR g.black_elo >= ?)")
        params.extend([min_elo, min_elo])
    if eco:
        clauses.append("g.eco LIKE ? ESCAPE '\\'")
        params.append(f"{_escape_like(eco)}%")
    if twic_number is not None:
        clauses.append("g.twic_number = ?")
        params.append(twic_number)
    return clauses, params
