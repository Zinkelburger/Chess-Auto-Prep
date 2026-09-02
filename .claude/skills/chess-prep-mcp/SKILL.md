---
name: chess-prep-mcp
description: Use the chess-prep MCP server (the mcp__chess-prep__* tools registered in .mcp.json) for anything about the user's chess data that does not need the app's UI — expectimax opening-tree builds, engine-vs-engine tournaments, the local master-games (TWIC) database, the user's own downloaded games, a repertoire or Chessable PGN as an opening tree with Stockfish evals, ChessDB queries, and tournament-roster / opponent-identity prep (USCF, chess.com). Reach for it whenever a task mentions expectimax, a build or run, master games, TWIC, "my games", a roster, opponents, pairings, engine matches or ChessDB — even when the app could show the same thing — and whenever you need to list, call, test or edit the server itself under tools/mcp/.
---

# The chess-prep MCP server

`tools/mcp/chess_prep/` is a stdio MCP server the repo registers in
`.mcp.json` (`python3 tools/mcp/chess_prep/__main__.py`). In a Claude session
its tools show up as deferred tools named `mcp__chess-prep__<tool>`; load the
schema before calling one:

```
ToolSearch "select:mcp__chess-prep__expectimax_list,mcp__chess-prep__expectimax_run"
```

From a shell — a subagent without the MCP attached, a fresh clone, or when
you want to read a tool's contract first — use the bundled helper, which
spawns the same server for one request:

```
M=.claude/skills/chess-prep-mcp/mcp_tools.py
python3 $M check                     # server starts and lists its tools (44 today)
python3 $M list                      # every tool, one line; `list expectimax` filters
python3 $M describe expectimax_run   # full description + every argument
python3 $M call master_status        # call one; k=v args parse as JSON where they can
python3 $M call my_games_at moves="1. d4 Nf6 2. c4 c5" collection=tactics
```

Paths are relative to the repo root. The server is stdlib Python; four tool
families also need **python-chess** (`pip install -r tools/mcp/requirements.txt`,
`scripts/doctor.sh` says whether it is installed). The server runs from the
**working tree**, so another session's half-finished edit in `tools/mcp/` can
break a tool call — `mcp_tools.py check` prints the traceback, and that is
not yours to fix.

## What the tools do

| Family (prefix) | Reads | Writes / starts | Needs python-chess |
|---|---|---|---|
| `expectimax_*` — Maia + Stockfish opening-tree builds; `run` → `status` → `result`; `list`, `stop`, `resume` | saved runs in `~/Documents/expectimax_runs/` | **starts a Stockfish build for tens of minutes** | yes |
| `tournament_*` — engine-vs-engine matches; `run`, `status`, `list`, `crosstable`, `games`, `game_pgn`, `stop`, `open`, `engines`, `add_engine` | saved tournaments under `~/Documents` (`tournament_list` shows paths) | **starts engines for minutes**; `open` / `open_app` launch the desktop app | no |
| `master_*` — the app's TWIC master-games database: `status`, `book` (moves from a position with W/D/L and Elo), `game`, `games` (by player) | `~/.local/share/com.example.chess_auto_prep/master_games.db`, read-only | nothing | yes |
| `my_games_*`, `my_game` — the user's own games database: collections, games at a position, games by player, one game | `app_games.db` beside it, read-only | nothing | no |
| `pgn_*` — a PGN (repertoire, Chessable course, game collection) as a FEN-keyed tree: `open` once, then `position`, `walk`, `audit`, `eval` | the PGN you pass | `pgn_eval` and `pgn_audit` **run Stockfish** | yes |
| `chessdb_query` — chessdb.cn moves from a position, best-first, with reply counts | the network | nothing | yes |
| `roster_*`, `identity_*`, `constraint_add`, `pairing_simulate`, `opponents_export`, `uscf_*`, `directory_*` — tournament entry list → identified online accounts → the opponent list Player Analysis imports | bundled directory in `tools/mcp/chess_prep/data/`, US Chess API (`uscf_*`) | `roster.json` / `opponents.json` in `~/.local/share/chess-prep/` | no |

Full contracts: `mcp_tools.py describe <tool>`. The design notes behind the
families are `docs/OPPONENT_PREP.md` (roster pipeline), `docs/ENGINE_TOURNAMENT.md`
(tournaments, headless and from an agent) and `docs/ALGORITHM.md` (expectimax).

## Habits that keep this safe

- **Long jobs are start-poll-collect.** `expectimax_run` and `tournament_run`
  return as soon as the run directory exists; the work continues in a
  background process. Poll `*_status`, then read `expectimax_result` /
  `tournament_crosstable`. `expectimax_result` stops a running build first
  (saved, resumable) — say so if the user wanted it to finish.
- **Do not start an engine job the user did not ask for.** These run Stockfish
  on real cores for a long time and are *not* behind the Flutter lock that
  `scripts/ci.sh` and the app driver share, so they compete with everyone's
  builds. `expectimax_run` takes `threads`; leave cores for the machine. When
  you only need to know what exists, use `*_list` / `*_status`.
- **App-owned files are read-only here.** `master_*` and `my_games_*` open the
  app's databases; the app imports and maintains them. Nothing in this server
  writes to them.
- **Identity is a two-step gate.** `identity_propose` records evidence;
  `identity_confirm` is the only step that makes an account drive prep, and it
  is reserved for a match the user explicitly approved. Run `roster_resolve`
  before any web search — it is exact where it hits and costs nothing.
- **Opening the app is a real window on the developer's display.**
  `tournament_open` / `open_app=true` write a request the app honours whether
  it is running now or started later. If the app driver
  (`.claude/skills/run-chess-auto-prep/driver.py`) already has an app up, the
  request lands there — fine for a screenshot, surprising if you did not
  expect it.
- **Move lists take any order; FENs are exact.** Trees are FEN-keyed and
  transpositions merge, so `moves="1. d4 Nf6 2. c4 c5"` finds the same node
  as the Benoni move order. Evals are reported from White's point of view.

## Editing the server

Tests are plain `unittest`, offline by default, and the gate hook does not
block Python:

```
python3 tools/mcp/test_chess_prep.py          # roster / USCF / directory (79)
python3 tools/mcp/test_opening_tree.py        # pgn_* (needs python-chess)
python3 tools/mcp/test_expectimax.py
python3 tools/mcp/test_engine_tournament.py
python3 tools/mcp/test_master_games.py
python3 .claude/skills/chess-prep-mcp/mcp_tools.py check   # still starts?
```

Tool descriptions live in the `Registry` in `tools/mcp/chess_prep/tools.py`
and the per-family modules; a Claude session only ever sees the description,
so write it as the contract (what it reads, what it starts, what it returns).
Keep the core dependency-free: `server.py` must start with nothing installed,
so import `chess` lazily inside the tools that need it, as the existing
families do. `scripts/doctor.sh` checks that the server still answers
`tools/list` and that this skill is tracked.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `mcp__chess-prep__*` tools are not in the session | The server is registered per project in `.mcp.json`; a fresh clone must approve it (`/mcp`). Until then use `mcp_tools.py call`. |
| `ModuleNotFoundError: chess` | `pip install -r tools/mcp/requirements.txt`. Roster, tournament and my-games tools work without it. |
| `server produced no JSON-RPC reply` with a traceback | An import-time error in `tools/mcp/` — usually another session mid-edit (`git status tools/mcp`). Do not patch their file; wait or use HEAD (`git stash` is not yours to run either — `git worktree add /tmp/x HEAD` and run the server from there). |
| `expectimax_status` says the process is gone but the tree is small | The build died; `expectimax_resume` continues from the saved tree. `expectimax_result` on a partial tree is still a real answer, scored on what was explored. |
| `master_status` shows 0 games | The app has not imported TWIC on this machine; the DB is the app's to build (Master games mode). |
