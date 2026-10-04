# Tooling map

These programs have separate responsibilities; read only the relevant row's
skill or README. Commands below run from the repo root unless stated otherwise;
heavy checks/builds use `scripts/ci.sh with -- COMMAND`. Each job gets its
own disk-backed `TMPDIR`/`TMP`/`TEMP`, deleted when the job ends. Temporary
build files and disposable app profiles live under `~/.cache/chess-prep-jobs`
(override with `CHESS_PREP_JOB_CACHE`, an absolute, owned mode-0700 directory).
The runner rejects RAM-backed checkouts and caches: moving only `TMPDIR`
does not move a checkout's `.dart_tool` and `build` outputs off RAM.
Small admission locks and driver control files retain their existing `/tmp`
paths so old and new runners still share the same limits. Never delete these
locks while jobs may be running. The next job sweeps abandoned temporary
directories only after their worker and service children have exited.
App profiles persist across runs for fixtures; the driver reports the current
profile path. Existing driver sessions retain their old profile until restarted.

| Area | Responsibility and entrypoint |
|---|---|
| `tools/mcp/chess_prep/` | Chess-data MCP server: use the `chess-prep-mcp` skill; its helper discovers the live tool list |
| `tools/mcp/bughouse/` | Hivemind two-board MCP server: use `bughouse-mcp`; needs `python-chess` on the `python3` that `.mcp.json` launches; tests in `tools/mcp/test_bughouse.py` (`--engine` for engine checks). The engine itself is [Hivemind, end to end](../HIVEMIND.md) |
| `tools/mcp/mcp_stdio.py` | Shared JSON-RPC stdio transport; keep it dependency-free because clients start it from a bare command |
| `tools/fetch_assets.py` | Fetch the host engines, pinned by `tools/assets.lock.json`: Stockfish into gitignored `assets/executables/` and the bughouse engine, ONNX Runtime and network into gitignored `assets/bughouse/`. `--only stockfish`/`--only bughouse` or a platform target narrows it; `--check` verifies; `--hivemind <checkout>` packs a local bughouse build |
| `tools/package_bughouse_runtime.py` | Packages and verifies the Windows build’s private VC++ DLL archives and SHA-256 manifest; used by CMake and release checks |
| `tools/test_bughouse_engine.py` | `deps [--all]` checks bundle dependencies; `run` searches with the extracted engine. Bughouse/release CI gates Linux and Windows bundles |
| `tools/diagnose_bughouse_windows.ps1` | Self-contained diagnostic on the failing Windows machine: published hashes, PE headers, loader resolution, mitigations and actual startup |
| `tools/bughouse_web/` | The WASM bughouse engine for the web: `build.py` compiles the Emscripten bridge, `prepare_assets.py` chunks the network and copies ONNX Runtime on every frontend build |
| `tools/bughouse_db/` | Offline FICS opening book, plus `hivemind_book.py`, the engine-eval book behind `/bughousedb`; `python3 -m bughouse_db <command>` from `tools/`, with `fetch`, `index`, `explore` or `status`; test with `tools/test_bughouse_db.py` |
| `tools/lichess_broadcasts.py` | Collect over-the-board games from Lichess broadcasts into `Documents/lichess_broadcasts/<collection>/` (per-broadcast PGNs, manifest, merged PGN); `by USER`, `tour ID`, `search`, `status`. Community broadcasts are found by owner or tour id, not `search`; tests in `tools/test_lichess_broadcasts.py`. Method, APIs and the committed Massachusetts collection (`scripts/data/broadcasts/`): [docs/BROADCAST_GAMES.md](../BROADCAST_GAMES.md) |
| `tools/chesscom_events.py` | Same collection from chess.com Events (`search`, `event <slug>`, `status`); moves come over the events websocket, spoken with a stdlib Socket.IO client. A game on both sites is kept once; tests in `tools/test_chesscom_events.py` |
| `tools/master_import_pgn.dart` | Turn PGN files into a master-format database (`games` + `book`) with the app's importer: `MASTER_IMPORT_ARGS="out.db in.pgn" scripts/ci.sh test tools/master_import_pgn.dart`; query it with the chess-prep MCP `db` parameter |
| `tools/run_engine_tournament.dart` | Headless engine matches; see `docs/ENGINE_TOURNAMENT.md` |
| `tools/dart_api_test/`, `tools/experiments/` | Standalone API harnesses and research scripts; nothing here is imported by `lib/` |
| `tools/scid_reference/` | C++ harness linking Scid's codec: the oracle for a future Scid export (the old exporter was removed) |
| `tree_builder/` | Standalone C prototype and cdbdirect native build; see its README. The Dart generation pipeline is canonical |
| `python/twic-position-finder/` | Separately deployed web service; follow its README |
| (external) [Chessable-PGN-Download](https://github.com/Zinkelburger/Chessable-PGN-Download) | Browser extension that saves a Chessable course as the course-shaped PGN this app reads (chapter in `[White]`, line in `[Black]`); lives in its own repository |
| `packaging/`, `install_linux_desktop.sh` | Release-bundle installers, built by release CI |

Manual overnight population: `python3 tools/bughouse_db/overnight.py start`
(default 800 nodes, eight cores, eight hours), with `status` and `stop` controls.
See [the web guide](../../python/twic-position-finder/frontend/README.md#shared-analysis-and-manual-overnight-population).

The app hides Bughouse Lab without the optional bughouse assets. Archive/book
data lives under `~/.local/share/chess-prep/bughouse-db/`, not repo/assets;
the lab reads `hivemind_book.db` and `bughouse_book.db` there read only
(`$BUGHOUSE_DB_HOME` overrides; the headless driver points it into its profile).

The MCP server and app share files only. The server reads `master_games.db`
and `app_games.db` read-only and writes its own runs under `~/Documents` and
`~/.local/share/chess-prep/`. `expectimax_run`, `tournament_run`, `pgn_eval` and
`pgn_audit` launch long Stockfish jobs outside the Flutter lock: start them only
when the task calls for them. Use the MCP skills instead of parsing the user's
databases or run directories by hand.
