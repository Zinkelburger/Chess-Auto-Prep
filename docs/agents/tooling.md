# Tooling map

These programs have separate responsibilities; read only the relevant row's
skill or README. Commands below run from the repo root unless stated otherwise;
heavy checks/builds use `scripts/ci.sh with -- COMMAND`.

| Area | Responsibility and entrypoint |
|---|---|
| `tools/mcp/chess_prep/` | Chess-data MCP server: use the `chess-prep-mcp` skill; its helper discovers the live tool list |
| `tools/mcp/bughouse/` | Hivemind two-board MCP server: use `bughouse-mcp`; tests in `tools/mcp/test_bughouse.py` (`--engine` for engine checks) |
| `tools/mcp/mcp_stdio.py` | Shared JSON-RPC stdio transport; keep it dependency-free because clients start it from a bare command |
| `tools/fetch_assets.py` | Fetch host Stockfish into gitignored `assets/executables/`; `--check` verifies build assets |
| `tools/fetch_bughouse.py` | Fetch engine, ONNX Runtime and network into gitignored `assets/bughouse/`, pinned by `tools/bughouse.lock.json`; `--hivemind <checkout>` packs a local build |
| `tools/package_bughouse_runtime.py` | Packages and verifies the Windows build’s private VC++ DLL archives and SHA-256 manifest; used by CMake and release checks |
| `tools/test_bughouse_engine.py` | `deps [--all]` checks bundle dependencies; `run` searches with the extracted engine. Bughouse/release CI gates Linux and Windows bundles |
| `tools/diagnose_bughouse_windows.ps1` | Self-contained diagnostic on the failing Windows machine: published hashes, PE headers, loader resolution, mitigations and actual startup |
| `tools/bughouse_db/` | Offline FICS opening book; `python3 -m bughouse_db <command>` from `tools/`, with `fetch`, `index`, `explore` or `status`; test with `tools/test_bughouse_db.py` |
| `tools/run_engine_tournament.dart` | Headless engine matches; see `docs/ENGINE_TOURNAMENT.md` |
| `tools/bench/`, `tools/dart_api_test/`, `tools/experiments/` | Standalone benchmarks/API harnesses; nothing here is imported by `lib/` |
| `tree_builder/` | Standalone C prototype and cdbdirect native build; see its README. The Dart generation pipeline is canonical |
| `python/twic-position-finder/` | Separately deployed web service; follow its README |
| `packaging/`, `install_linux_desktop.sh` | Release-bundle installers, built by release CI |

The app hides Bughouse Lab without the optional bughouse assets. Archive/book
data lives under `~/.local/share/chess-prep/bughouse-db/`, not repo/assets;
the app does not currently read that offline book.

The MCP server and app share files only. The server reads `master_games.db`
and `app_games.db` read-only and writes its own runs under `~/Documents` and
`~/.local/share/chess-prep/`. `expectimax_run`, `tournament_run`, `pgn_eval` and
`pgn_audit` launch long Stockfish jobs outside the Flutter lock: start them only
when the task calls for them. Use the MCP skills instead of parsing the user's
databases or run directories by hand.
