# Bughouse database snapshot

Consistent SQLite backups taken on 2026-09-24 from the local FICS and Hivemind books.
The manifest records the time, full database sizes, SHA-256 hashes and chunk hashes.
The live databases remain outside the repository. Committed WAL transactions are included;
engine identities missing from the original analysis have not been guessed or backfilled.
The snapshots total about 90 MiB compressed; each chunk is at most 20 MiB.
The raw FICS game corpus is not included.

Restore from the repository root into a **new directory**:

```sh
python3 tools/bughouse_db/snapshot.py restore --source data/bughouse-books --destination /path/to/new/bughouse-db
```

Point `BUGHOUSE_DB_HOME` at that directory to use it. Restore verifies every chunk and both
uncompressed databases before installing them, and refuses to overwrite existing databases.
This is also the way to seed an isolated app-driver profile for UI verification.

To capture a later checkpoint, export into a new directory, review its manifest, then replace
this snapshot in a deliberate Git commit:

```sh
python3 tools/bughouse_db/snapshot.py export --source ~/.local/share/chess-prep/bughouse-db --destination /path/to/new/snapshot
```

Use `scripts/ci.sh with --` before these commands for repository development checks. Export uses
SQLite’s backup API through a read-only source connection, so it does not stop a running builder
or copy an incomplete WAL file. Backups are explicit checkpoints, not automatic commits on every move.
