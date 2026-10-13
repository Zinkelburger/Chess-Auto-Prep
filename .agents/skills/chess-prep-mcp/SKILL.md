---
name: chess-prep-mcp
description: Use the chess-prep MCP server (mcp__chess-prep__* tools, registered in .mcp.json) for the user's chess data without the app's UI — expectimax opening-tree builds, engine-vs-engine tournaments, the master-games (TWIC) database, the user's own games, searching/extracting games from a PGN or ZIP, a repertoire or Chessable PGN as a tree with Stockfish evals, ChessDB, chess.com/chessgames.com lookups, and roster/opponent prep (USCF, players directory). Use it whenever a task mentions expectimax, a build or run, master games, TWIC, "my games", a roster, opponents, pairings, engine matches or ChessDB, even if the app could show it, and when testing or editing tools/mcp/.
---

# The chess-prep MCP server

`tools/mcp/chess_prep/` is a stdio server registered in `.mcp.json`. Tools
appear as `mcp__chess-prep__<tool>` (some clients normalize to `chess_prep`).
Load a schema before calling, e.g.
`ToolSearch "select:mcp__chess-prep__expectimax_list"`.

Without the MCP attached (a subagent, a fresh clone, or to read a contract
first), the helper spawns the same server for one request:

```
M=.agents/skills/chess-prep-mcp/mcp_tools.py
python3 $M check                     # server starts and lists its tools
python3 $M list [expectimax]         # one line per tool, optional filter
python3 $M describe expectimax_run   # full contract
python3 $M call my_games_at moves="1. d4 Nf6 2. c4 c5" collection=tactics
```

The server needs only stdlib Python; chess-parsing families also need
python-chess (`pip install -r tools/mcp/requirements.txt`; `scripts/doctor.sh`
reports it). It runs from the **working tree**, so another session's
half-finished edit in `tools/mcp/` can break it — `check` prints the
traceback, and that edit is not yours to fix.

## Tool families

| Family | Reads | Writes / starts | python-chess |
|---|---|---|---|
| `expectimax_*`: `run` → `status` → `result`; `list`, `stop`, `resume` | runs in `~/Documents/expectimax_runs/`; a chapter's saved searches | **Stockfish build for tens of minutes** | yes |
| `tournament_*`: `run`, `status`, `list`, `crosstable`, `games`, `game_pgn`, `stop`, `open`, `engines`, `add_engine` | tournaments under `~/Documents` | **engines for minutes**; `open`/`open_app` launch the app | no |
| `master_*`: `status`, `book` (W/D/L, Elo), `game`, `games` | the app's `master_games.db`, read-only | nothing | yes |
| `my_games_*`, `my_game`: collections, games at a position or by player | `app_games.db`, read-only | nothing | no |
| `pgn_collection_open` → `pgn_games_search` → `pgn_selection_report` / `pgn_game_get` / `pgn_selection_export` | a local PGN or ZIP | snapshots in `~/.local/share/chess-prep/pgn-collections/`; export writes the PGN you name | yes |
| `pgn_open` then `pgn_position` / `walk` / `audit` / `eval`: a repertoire as a FEN-keyed tree | the PGN you pass | `pgn_eval`, `pgn_audit` **run Stockfish** | yes |
| `chessdb_query`: chessdb.cn moves, best first | network | nothing | yes |
| `chesscom_*`: `search` → `search_status`; `rating_on`, `profile`, `who_plays` | chess.com API; cache in `~/.local/share/chess-prep/chesscom/` | **`search` starts a detached job of up to `max_requests` HTTP calls (default 1500, ~5 min)** | no |
| `chessgames_*`: `download` → `status`; `stop` | chessgames.com; ≤150 requests/day, none for 24 h after a ban | **detached job, ~30 s per game**; PGNs to `~/Documents/chessgames/` | no |
| `roster_*`, `identity_*`, `constraint_add`, `pairing_simulate`, `opponents_export`, `uscf_*`, `directory_*` | bundled directory, US Chess API | `roster.json` / `opponents.json` in `~/.local/share/chess-prep/` | no |
| `people_*`, `player_lookup`, `master_player_search` | `Documents/opponents/people.json`, directory, USCF, TWIC and broadcast DBs, chess.com/Lichess profiles | **`people.json` and `tournaments/<id>.json`, the app's own files** | no |

Design notes: `docs/OPPONENT_PREP.md` (roster pipeline),
`docs/ENGINE_TOURNAMENT.md`, `docs/ALGORITHM.md` (expectimax).

## Sharing an expectimax search with the app

Pass `chapter` (`~/Documents/repertoires/<repertoire>/<chapter>.pgn`):

1. `expectimax_run {chapter, moves, plies, threads}` builds for the chapter's
   `// Color:` side with the app's settings (depth 14, every own move kept,
   the opponent's likeliest replies to 90%, at most five, renormalized). The
   root may be the opponent's move. On stop or finish the tree is published to
   `.cap-generation/<chapter>.pgn/v2-agent-<run id>/tree.json`; relay the
   result's `app.open_in_app` steps. A running build is invisible to the app
   until `expectimax_stop` publishes it.
2. `expectimax_list {chapter}` lists the app's and the agent's saved searches.
3. `expectimax_resume {chapter, moves, plies}` continues the newest one at that
   root (including an app search) as a new run; the source tree is never
   edited. `plies` is at most 64. A tree or run from before the reply cut
   continues keeping every reply; `expectimax_list` says which (`replies`).

Only the trees are shared; `tree.db` and the app's `eval_cache.db` stay
separate. Never continue the same chapter search in the app and here at once.

## Finding and extracting games from a PGN or ZIP

For "what did Karpov play against the Caro-Kann?" or "extract the Bf5 line",
use the collection tools rather than ad hoc unzip/filter scripts. They need no
engine, network, app or import.

1. `pgn_collection_open {path}`: check player spellings, encoding, parse
   errors and duplicates (kept; report them when material). For a ZIP with
   several PGNs, pick the intended member.
2. `pgn_games_search {collection_id, player, color, moves, match: "prefix"}`;
   use `match: "position"` for a variation reached by several move orders, and
   say which scope the answer covers. Names match whole tokens; pass aliases
   rather than guessing identity.
3. `pgn_selection_report {selection_id}` gives the counts, score, continuations
   and exceptions from the selected player's side (unknown results excluded
   from the percentage). Say "usually" or "always" from those counts, and cite
   games by returned headers/IDs.
4. Narrow with `pgn_games_search {selection_id, opponent}`, fetch with
   `pgn_game_get`, and export the **same selection** you reported with
   `pgn_selection_export {selection_id, path}` — never rebuild its filter.

IDs survive restarts; a selection refers to an immutable snapshot, so reopen
an edited source. Pagination limits displayed evidence only. Date filters need
complete dates (use year filters for `??` dates); an event name does not prove
a time control. Counts are mainlines, once per record; variations are not game
statistics. Keep interpretation separate from measured facts, and use engine
tools only when asked to check moves.

## Rules

- **Long jobs are start-poll-collect.** `expectimax_run` and `tournament_run`
  return once the run exists. Poll `*_status`, then read the result.
  `expectimax_result` stops a running build first (saved, resumable); say so.
- **Start no engine job the user did not ask for.** These run Stockfish on real
  cores outside the `scripts/ci.sh` runner. Leave cores free with `threads`;
  use `*_list` / `*_status` to see what exists.
- **App databases are read-only here.** The app builds and maintains
  `master_games.db` and `app_games.db`.
- **Identity is two steps.** `identity_propose` records evidence;
  `identity_confirm` only for a match the user approved. Run `roster_resolve`
  before any web search.
- **Guesses never become accounts.** Field prep: `roster_import` →
  `roster_update aliases=[…]` → `people_populate`, then report its summary.
  Web finds go in via `people_upsert candidates=[…]`; only `people_confirm`,
  after approval, makes the app download an account. A running app must restart
  to see new rows and could overwrite them if its Players screen saves first.
- **Opening the app is a real window.** `tournament_open` / `open_app=true`
  write a request any running app — including a driver preview — will honour.
- **One chess.com search at a time, only when asked.** Report only
  `complete: true` matches as found. Leave `tz` at `US` unless told.
- **Move lists take any order; FENs are exact.** Trees merge transpositions.
  Evals are from White's side.

## Editing the server

Tests are offline `unittest` files, `tools/mcp/test_*.py` (e.g.
`test_chess_prep.py`, `test_people.py`, `test_pgn_collection.py`,
`test_expectimax.py`, `test_master_games.py`). Run them through
`scripts/ci.sh with -- python3 tools/mcp/test_<family>.py`, then
`python3 $M check`.

Tool descriptions live in the `Registry` in `tools/mcp/chess_prep/tools.py`
and the family modules. Clients find tools by description, so write each as
the contract: what it reads, starts and returns. `server.py` must start with
nothing installed; import `chess` lazily inside the tools, as existing
families do.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No `mcp__chess-prep__*` tools | A fresh clone must approve `.mcp.json` (`/mcp`); meanwhile use `$M call`. |
| `ModuleNotFoundError: chess` | Install `tools/mcp/requirements.txt`; roster, tournament and my-games tools work without it. |
| `server produced no JSON-RPC reply` | Import error in `tools/mcp/`, usually another session mid-edit (`git status tools/mcp`). Do not patch or stash it; wait or use a detached snapshot in a unique disk-backed directory under `~/.local/share/chess-prep/worktrees/`, following `AGENTS.md`. |
| Build process gone, tree small | `expectimax_resume` continues it; `expectimax_result` on a partial tree is still a real answer. |
| `master_status` shows 0 games | The app has not imported TWIC here; the user builds it from the app's Databases page. |
