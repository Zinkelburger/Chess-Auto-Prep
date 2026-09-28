---
name: chess-prep-mcp
description: Use the chess-prep MCP server (the mcp__chess-prep__* tools registered in .mcp.json) for anything about the user's chess data that does not need the app's UI — expectimax opening-tree builds, engine-vs-engine tournaments, the local master-games (TWIC) database, the user's own downloaded games, downloaded PGN/ZIP game collections (player/opening search, statistics and verified export), a repertoire or Chessable PGN as an opening tree with Stockfish evals, ChessDB queries, and tournament-roster / opponent-identity prep (USCF, chess.com). Reach for it whenever a task mentions expectimax, a build or run, master games, TWIC, "my games", finding/extracting games from a PGN/ZIP, a roster, opponents, pairings, engine matches or ChessDB — even when the app could show the same thing — and whenever you need to list, call, test or edit the server itself under tools/mcp/.
---

# The chess-prep MCP server

`tools/mcp/chess_prep/` is a stdio MCP server the repo registers in
`.mcp.json` (`python3 tools/mcp/chess_prep/__main__.py`). Clients expose these as `mcp__chess-prep__<tool>` (some normalize the
server name to `chess_prep`). Discover the schema before calling one; for
example, in Claude Code:

```
ToolSearch "select:mcp__chess-prep__expectimax_list,mcp__chess-prep__expectimax_run"
```

From a shell — a subagent without the MCP attached, a fresh clone, or when
you want to read a tool's contract first — use the bundled helper, which
spawns the same server for one request:

```
M=.agents/skills/chess-prep-mcp/mcp_tools.py
python3 $M check                     # server starts and lists its current tools
python3 $M list                      # every tool, one line; `list expectimax` filters
python3 $M describe expectimax_run   # full description + every argument
python3 $M call master_status        # call one; k=v args parse as JSON where they can
python3 $M call my_games_at moves="1. d4 Nf6 2. c4 c5" collection=tactics
```

Paths are relative to the repo root. The server starts with stdlib Python; chess-parsing tool
families also need **python-chess** (`pip install -r tools/mcp/requirements.txt`,
`scripts/doctor.sh` says whether it is installed). The server runs from the
**working tree**, so another session's half-finished edit in `tools/mcp/` can
break a tool call — `mcp_tools.py check` prints the traceback, and that is
not yours to fix.

## What the tools do

| Family (prefix) | Reads | Writes / starts | Needs python-chess |
|---|---|---|---|
| `expectimax_*` — Maia + Stockfish opening-tree builds; `run` → `status` → `result`; `list`, `stop`, `resume`; `chapter` shares a search with the app's Search tab | saved runs in `~/Documents/expectimax_runs/`; a chapter's saved searches | **starts a Stockfish build for tens of minutes** | yes |
| `tournament_*` — engine-vs-engine matches; `run`, `status`, `list`, `crosstable`, `games`, `game_pgn`, `stop`, `open`, `engines`, `add_engine` | saved tournaments under `~/Documents` (`tournament_list` shows paths) | **starts engines for minutes**; `open` / `open_app` launch the desktop app | no |
| `master_*` — the app's TWIC master-games database: `status`, `book` (moves from a position with W/D/L and Elo), `game`, `games` (by player) | `~/.local/share/com.example.chess_auto_prep/master_games.db`, read-only | nothing | yes |
| `my_games_*`, `my_game` — the user's own games database: collections, games at a position, games by player, one game | `app_games.db` beside it, read-only | nothing | no |
| `pgn_collection_open`, `pgn_games_search`, `pgn_selection_report`, `pgn_game_get`, `pgn_selection_export` — downloaded games: open → search → report/get/export | a local PGN or ZIP | immutable snapshots/selections in `~/.local/share/chess-prep/pgn-collections/` (`CHESS_PREP_PGN_DIR` overrides); export writes the requested PGN | yes |
| `pgn_open` / `position` / `walk` / `audit` / `eval` — a repertoire or Chessable course as a FEN-keyed tree: `open` once, then `position`, `walk`, `audit`, `eval` | the PGN you pass | `pgn_eval` and `pgn_audit` **run Stockfish** | yes |
| `chessdb_query` — chessdb.cn moves from a position, best-first, with reply counts | the network | nothing | yes |
| `chesscom_*` — find a chess.com account from rating clues ("blitz 2701 on June 13"): `search` → `search_status` → results; `rating_on`, `profile`, `who_plays` (opening line, cache only) | chess.com public API + website leaderboard; archive cache and SQLite index in `~/.local/share/chess-prep/chesscom/` | **`chesscom_search` starts a detached job making up to `max_requests` serial HTTP requests** (default 1500, ~5 min) | no |
| `chessgames_*` — chessgames.com collections as PGN: `download` → `status`; `stop` | the collection pages, then one game per 30 s; at most 150 requests a day and none for 24 h after a ban; games cached in `~/.local/share/chess-prep/chessgames/games/` | **`chessgames_download` starts a detached job (~30 s per game, so 60 games ≈ 30 min); a ban ends it with state `banned`**; writes one PGN per collection to `~/Documents/chessgames/` | no |
| `roster_*`, `identity_*`, `constraint_add`, `pairing_simulate`, `opponents_export`, `uscf_*`, `directory_*` — tournament entry list → identified online accounts → the opponent list Player Analysis imports | bundled directory in `tools/mcp/chess_prep/data/`, US Chess API (`uscf_*`) | `roster.json` / `opponents.json` in `~/.local/share/chess-prep/` | no |
| `people_*`, `player_lookup`, `master_player_search` — the app's players directory: `people_populate` looks up a whole roster and writes one person each (aliases, USCF/FIDE ID, trusted accounts, a `lookup` block of candidates and next steps) plus the event's group; `player_lookup` does one person without writing; `people_upsert` / `people_confirm` record web finds and user approvals | `Documents/opponents/people.json`, the bundled directory, US Chess API, TWIC and broadcast collections (`Documents/lichess_broadcasts/*/*.db`), chess.com/Lichess profiles | **`Documents/opponents/people.json` and `tournaments/<id>.json` — the app's own files** | no |

Full contracts: `mcp_tools.py describe <tool>`. The design notes behind the
families are `docs/OPPONENT_PREP.md` (roster pipeline), `docs/ENGINE_TOURNAMENT.md`
(tournaments, headless and from an agent) and `docs/ALGORITHM.md` (expectimax).

## Sharing an expectimax search with the app

Pass `chapter` (a repertoire chapter file,
`~/Documents/repertoires/<repertoire>/<chapter>.pgn`) to share a search with
the v2 app's Search tab, in either direction:

1. `expectimax_run {chapter, moves: "1. e4 g6 2. d4 c6 3. Nc3 d5", plies, threads}`
   builds for the chapter's side (its `// Color:` heading) with the app's
   settings: engine depth 14, every move kept, pure search. The root may be
   the opponent's move (the result is then `replies` with our answers). When
   the build stops or finishes, its tree is published to
   `.cap-generation/<chapter>.pgn/v2-agent-<run id>/tree.json`. The result's
   `app.open_in_app` tells the user what to do next: open the chapter, put
   the board on the root, set Opponent to the same rating, then Search ▸
   Resume. A running build is not visible in the app yet; stop it
   (`expectimax_stop`) to publish what it has.
2. `expectimax_list {chapter}` lists the searches saved beside the chapter,
   the app's and the agent's.
3. `expectimax_resume {chapter, moves, plies}` continues the newest one at
   that root, including one the app ran, as a new run. The source tree is
   never edited. An app search without a depth limit continues to its
   deepest ply unless `plies` asks for more (at most 64).

Evaluations are shared only through the trees; the builder's `tree.db` and
the app's `eval_cache.db` stay separate. Do not continue the same chapter
search in the app and the agent at once. Each writes its own tree, and the
app's Resume picks the newest.

## Finding and extracting games from a PGN or ZIP

Use the collection tools for requests such as “what did Karpov play as White
against the Caro-Kann?”, “give me the Petrosian game”, or “extract the Bf5
line”. They replace ad hoc unzip/filter/count/export scripts. They need no
Stockfish, network, app launch, or database import.

1. `pgn_collection_open {path}` accepts the archive directly. Check player
   spellings, encoding, excluded parse errors and duplicate candidates. It
   keeps duplicates; report this when material. If a ZIP has several PGNs,
   use the returned member names to choose the intended one.
2. `pgn_games_search {collection_id, player: "Karpov", color: "white",
   moves: "1.e4 c6", match: "prefix"}` selects games starting that way.
   For a variation reached by different move orders, use `match: "position"`
   with its full line/FEN. State which scope the answer covers. Name matching
   uses complete tokens; supply explicit aliases instead of guessing identity.
3. `pgn_selection_report {selection_id}` supplies all counts, score percentage,
   continuation evidence and exceptions. Results use the selected player's
   perspective; unknown results are excluded from the percentage denominator.
   Report “usually” versus “always” from these counts and exceptions. Cite
   individual games by their returned headers/IDs, not remembered labels.
4. Narrow the selection with `pgn_games_search {selection_id, player:
   "Karpov", opponent: "Petrosian"}`, then retrieve the returned `game_id`
   with `pgn_game_get`. Export with `pgn_selection_export {selection_id, path}`
   using the **same selection** as the report. Do not rebuild its filter.

IDs survive MCP restarts and one-shot helper calls. Selections refer to an
immutable source snapshot; reopen an edited source to get a new collection.
Pagination limits only the displayed evidence, never the counted/exported
set. Date filters require complete dates; use year filters for older games
with `??` month/day. Missing time controls stay unknown; an event name alone
is not proof of classical/rapid/blitz. The collection tools count actual
mainlines once per source record, including only the first position match;
repertoire-tree visits and annotation variations are not game statistics.
Keep strategic interpretation separate from measured facts. Use engine tools
only when the task calls for checking moves, not to count or extract games.

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
- **Players go into the directory, guesses do not become accounts.** For a
  field to prepare against: `roster_import` → `roster_update aliases=[…]` for
  known respellings → `people_populate`. Report the `summary` (found /
  candidates / OTB only / not found) to the user. Web finds go in with
  `people_upsert candidates=[{site, username, evidence}]`; only
  `people_confirm`, after the user approves, puts an account where the app
  downloads games. The app loads `people.json` once per run, so an open app
  must be restarted to see new rows (and would overwrite them if its Players
  screen saves first).
- **Opening the app is a real window on the developer's display.**
  `tournament_open` / `open_app=true` write a request the app honours whether
  it is running now or started later. If the app driver
  (`scripts/app_driver.py`) already has an app up, the
  request lands there — fine for a screenshot, surprising if you did not
  expect it.
- **One chess.com search at a time, and only when asked.** `chesscom_search`
  refuses to start while another job runs. Matches show in `search_status`
  as `complete: false` (an opponent-derived sighting) before the job verifies
  them from the player's own archive; report only `complete: true` hits as
  found. Rating clues are local dates — leave `tz` at `US` unless told.
- **Move lists take any order; FENs are exact.** Trees are FEN-keyed and
  transpositions merge, so `moves="1. d4 Nf6 2. c4 c5"` finds the same node
  as the Benoni move order. Evals are reported from White's point of view.

## Editing the server

Tests are plain `unittest`, offline by default. Run relevant commands below
through `scripts/ci.sh with --` as required by the repository workflow:

```
python3 tools/mcp/test_chess_prep.py          # roster / USCF / directory (80)
python3 tools/mcp/test_people.py              # spellings, players directory, lookup (offline)
python3 tools/mcp/test_chesscom.py            # chess.com account search (15, offline)
python3 tools/mcp/test_chessgames.py          # chessgames.com download job (offline)
python3 tools/mcp/test_pgn_collection.py      # collection search/report/export (offline)
python3 tools/mcp/test_opening_tree.py        # repertoire trees (needs python-chess)
python3 tools/mcp/test_expectimax.py
python3 tools/mcp/test_engine_tournament.py
python3 tools/mcp/test_master_games.py
python3 .agents/skills/chess-prep-mcp/mcp_tools.py check   # still starts?
```

Tool descriptions live in the `Registry` in `tools/mcp/chess_prep/tools.py`
and the per-family modules; a client discovers the tool through its description,
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
| `server produced no JSON-RPC reply` with a traceback | An import-time error in `tools/mcp/` — usually another session mid-edit (`git status tools/mcp`). Do not patch their file; wait or use a detached HEAD snapshot (`git worktree add --detach /tmp/chess-prep-check HEAD`); never stash another task’s changes. |
| `expectimax_status` says the process is gone but the tree is small | The build died; `expectimax_resume` continues from the saved tree. `expectimax_result` on a partial tree is still a real answer, scored on what was explored. |
| `master_status` shows 0 games | The app has not imported TWIC on this machine; the DB is the app's to build (Master games mode). |
