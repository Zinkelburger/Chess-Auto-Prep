-- Frozen schema-v1 fixture. Do not regenerate with the current GameStore.
PRAGMA user_version = 1;
CREATE TABLE games (
 id INTEGER PRIMARY KEY, collection TEXT NOT NULL, game_key TEXT NOT NULL,
 white TEXT NOT NULL DEFAULT '', black TEXT NOT NULL DEFAULT '',
 result TEXT NOT NULL DEFAULT '*', date TEXT NOT NULL DEFAULT '', played_at INTEGER,
 speed TEXT NOT NULL DEFAULT 'unknown', white_elo INTEGER, black_elo INTEGER,
 eco TEXT NOT NULL DEFAULT '', headers_json TEXT NOT NULL, pgn TEXT NOT NULL,
 imported_at INTEGER NOT NULL, UNIQUE(collection, game_key)
);
CREATE TABLE positions (
 pos INTEGER NOT NULL, game_id INTEGER NOT NULL REFERENCES games(id) ON DELETE CASCADE,
 ply INTEGER NOT NULL, PRIMARY KEY(pos, game_id)
) WITHOUT ROWID;
CREATE TABLE collections (
 collection TEXT PRIMARY KEY, updated_at INTEGER NOT NULL, meta_json TEXT NOT NULL DEFAULT '{}'
);
INSERT INTO games VALUES (42, 'my-games', 'old-key', 'Alice', 'Bob', '*', '2025.01.01', 1234, 'classical', 2000, 2100, 'C20', '{"White":"Alice","Black":"Bob","Result":"*"}', '[White "Alice"]
[Black "Bob"]
[Result "*"]

1. e4 e5 {Keep my annotation} (1... c5) *', 1234);
INSERT INTO positions VALUES (123, 42, 1);
INSERT INTO collections VALUES ('my-games', 1234, '{"personal":true}');
