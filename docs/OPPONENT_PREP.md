# Opponent prep for a tournament

Prepare for a whole event with the tools you already use for one opponent.
The field is worked out **outside** the app — a local MCP server an agent can
drive (entry list → who is who online → who you are likely to play) — and the
result is an **opponent list** that Player Analysis imports. From there every
opponent is an ordinary player: opening tree, holes, tricks, engine weakness,
repertoire clash, exactly as for anyone else.

```
entry list ─▶ chess_prep MCP server ─▶ opponents.json ─▶ Player Analysis
              (Python, no app needed)                     Import Opponents
              · roster_import                             · one player per opponent
              · roster_resolve  (bundled directory)       · games from every account
              · identity_propose / confirm  (agent + you) · tagged with the event
              · constraint_add  (siblings, club-mates)
              · pairing_simulate  (Monte Carlo Swiss)
              · opponents_export
```

There is no Tournament mode in the app any more; the earlier one is gone. The
pairing engine, the identity directory and the roster all live in
`tools/mcp/chess_prep/`.

## The MCP server

Identity/pairing tools are zero-dependency, Python 3.10+, and run with the app
shut. Opening-tree tools need `python-chess`:

```
pip install -r tools/mcp/requirements.txt
claude mcp add chess-prep -- python3 /abs/path/to/tools/mcp/chess_prep/__main__.py
```

| Tool | |
|---|---|
| `directory_search` | Look up a player by USCF ID, name, or chess.com username |
| `directory_stats` | Size and provenance of the bundled directory |
| `uscf_member` | US Chess API: OTB **and online** ratings for one player |
| `uscf_coverage_report` | Sweep the field: who is mappable *in principle* |
| `roster_import` | Parse a CSV/TSV or pasted entry list, and save it |
| `roster_get` | Current roster, or just the unresolved work list |
| `roster_resolve` | Match the field against the bundled directory |
| `roster_update` | Withdrawal, attendance probability, byes, rating, "this is me" |
| `identity_propose` | Propose an account **with evidence** (not actionable) |
| `identity_confirm` | Promote a proposal to usable — the human-in-the-loop step |
| `constraint_add` | Two entrants who must never be paired |
| `pairing_simulate` | Monte Carlo → P(face) per entrant, by colour and round |
| `opponents_export` | Write `opponents.json` for Player Analysis |
| `roster_export` | The field as CSV, provenance included |
| `pgn_open` | Load a PGN (course/repertoire/games) as a FEN-keyed opening tree |
| `pgn_position` | Book moves at a FEN, plus one-ply transpositions into book |
| `pgn_walk` | Ply-by-ply: in-book / transposition / novelty, with replies |
| `pgn_eval` | Stockfish MultiPV at a position, compared to book moves |
| `pgn_audit` | Flag book moves Stockfish thinks are mistakes |
| `master_status` | Coverage of the app's local master-games database (TWIC) |
| `master_book` | What titled players play from a position, with a cited game per move |
| `master_game` | One master game by id, as PGN |
| `master_games` | A player's recent master games |
| `my_games_status` | Collections in the user's own games database (Player Analysis, library, tactics) |
| `my_games_at` | The user's / an analysed opponent's games reaching a position |
| `my_games_by_player` | Games in the user's database by player |
| `my_game` | One of those games, as PGN |

Working files live in `~/.local/share/chess-prep/` (macOS: `~/Library/
Application Support/chess-prep/`; override with `CHESS_PREP_DATA_DIR`, or the
roster alone with `CHESS_PREP_ROSTER`).

### PGN opening tree

Positions are keyed by a 4-field FEN (en passant only when a capture is legal),
so move order does not matter:

```
1. d4 Nf6 2. e3 c5    ≡    1. d4 c5 2. e3 Nf6
```

After `1. d4 c5 2. e3` (a position the PGN may never have reached), `pgn_position`
still lists **Nf6** under `transposing_moves` because playing it lands on a
known FEN. The Flutter opening tree (`OpeningTree.continuations`) does the
same; transposing rows are marked `≈`.

Typical agent flow against a White repertoire PGN:

```
pgn_open    {path: "/…/Colle.pgn"}
pgn_walk    {path, moves: "1. d4 Nf6 2. c4 c5 3. d5 b5"}
pgn_position {path, moves: "1. d4 Nf6"}          # what White actually plays
pgn_eval     {path, moves: "1. d4 Nf6 2. Nf3 c5"} # engine vs book
pgn_audit    {path, moves: "…", side: "white"}    # book mistakes along a line
```

`pgn_eval` / `pgn_audit` need a Stockfish binary (`STOCKFISH` or on `PATH`).
Chessable `Z0` dummy mainlines are promoted the same way as in the app.

### Master games (TWIC)

The app downloads The Week in Chess into `master_games.db` (Settings → Master
games database). The `master_*` tools read that file directly — no app
running, no PGN parsing — from the app's support directory
(`~/.local/share/com.example.chess_auto_prep/`; override with
`CHESS_PREP_MASTER_DB`). Positions are keyed the same way as the PGN tree
(4-field FEN), hashed with FNV-1a; `chess_prep.master_games.position_key`
reproduces the app's key.

```
master_status
master_book  {moves: "1. d4 Nf6 2. c4 c5 3. d5 b5"}   # masters' replies + cited games
master_game  {id: 12345}                               # the cited game's PGN
master_games {player: "Carlsen"}                       # recent games by a player
```

The user's own games live next to it in `app_games.db`: everything the app
downloads or imports (Player Analysis downloads as `analysis:<player>`, the
home games library as `library:<platform>_<user>`, the tactics archive as
`tactics`), with an opening position index. `my_games_at {moves: "1. e4 c5",
collection: "analysis:chesscom_hikaru"}` answers "which of this opponent's
games reached this position?" without parsing a PGN.

### Identity resolution

Two tiers, strongest first.

**Bundled directory** (`tools/mcp/chess_prep/data/uscf_chesscom_map.json`) —
3,459 USCF IDs mapped to chess.com accounts. Built by
`scripts/build_player_map.py` from USCF-rated events *hosted on chess.com*: if
USCF player A faced B in round 3, and A's known chess.com account faced
username Y in round 3, then B = Y. The linkage is structural rather than
inferred, which is why those rows carry `exact` confidence.

Coverage is the limit, not precision. ~2,754 events before May 2023 in
`scripts/data/uscf_events_cache.json` are still unprocessed, so a backfill
should raise the hit rate:

```
python scripts/build_player_map.py          # long, rate-limited network job
python scripts/build_directory_assets.py    # regenerate the compact directory
```

**Agent search** — everyone the directory misses. An agent reads profiles and
search results and calls `identity_propose`. A proposal is stored and shown
but is **not actionable**: it will not be exported until `identity_confirm`.
That boundary is what keeps a hallucinated username from becoming prep
against the wrong person. `uscf_coverage_report` is the one to reach for
first on a new field: it separates "the mapping needs a backfill" from "this
player was never online-rated and only web search will find them".

### Pairing simulation

`swiss.py` does not predict the pairing sheet — withdrawals, late entries,
family withholds, half-point byes and TD discretion all move it, and none are
knowable. It samples the whole event thousands of times and counts opponents,
which is robust to exactly that noise. Every source of mess enters as a
parameter:

| Real-world mess | Model |
|---|---|
| Family / club withhold | `constraint_add` — same constraint type as no-repeat |
| Late entry, unconfirmed | `roster_update {attendance_prob: 0.5}` |
| Withdrawal | `roster_update {withdrawn: true}` |
| Half-point bye request | `roster_update {half_point_byes: [2]}` |
| Accelerated pairings | `roster_import {accelerated: true}` (announced by the organizer; never guessed) |

The pairer implements the load-bearing parts of USCF Chapter 29: score
groups, top-half/bottom-half cross-pairing, no-repeat, colour equalization
and alternation, pair-downs, and the odd-field bye. It skips the
transposition/interchange limits and TD discretion — those matter for a
defensible wall chart but do not measurably move a *distribution* over
opponents, because uncertainty about who wins dominates them. Round 1 comes
out near-deterministic; rounds 4+ diffuse toward the players near your
rating, which is the honest answer. `P(face)` is split by the colour you
would hold.

## The opponent list

`opponents_export` writes:

```json
{
  "format": "chess-auto-prep/opponents@1",
  "event": "Spring Open 2026",
  "opponents": [
    {"name": "Jane Doe", "chesscom": "janed", "lichess": "jd_li",
     "rating": 1850, "pairing_prob": 0.42, "most_likely_round": 2}
  ]
}
```

Only `name` and one of `chesscom` / `lichess` are required, and a bare JSON
array is accepted too, so a list typed by hand or produced by any other
script works. Only **confirmed** identities are exported by default;
proposals are listed under `skipped` in the tool result.

## In the app

**Player Analysis → Import Opponents**: choose the file or paste the JSON.
The dialog previews the field (count, odds, skipped rows) before any network
call. Each opponent becomes one player entry:

- games are downloaded from **every** account listed and merged, so a person
  with a chess.com and a lichess account is one tree, not two;
- the entry is tagged with the event (`group`), searchable in the picker, and
  shows the handles under the name;
- re-download works (per account); the games live in the same cache as any
  other player, so nothing else in Player Analysis is different.

Already-saved opponents are skipped unless "Re-download opponents already
saved" is ticked. Failures are reported per person; a renamed account does
not abandon the rest of the field.

## Where the code lives

```
tools/mcp/chess_prep/
  server.py       JSON-RPC stdio loop
  tools.py        tool registry
  opening.py      PGN → FEN-keyed opening tree (pgn_open / position / walk / eval / audit)
  directory.py    USCF → chess.com lookup + name normalization
  roster.py       roster model, entry-list parser, persistence
  swiss.py        Swiss pairer + Monte Carlo simulator
  opponents.py    the opponent-list export
  uscf.py         US Chess ratings API
  paths.py        data + working-file locations
  data/           bundled directory (regenerate with scripts/build_directory_assets.py)
tools/mcp/test_chess_prep.py
tools/mcp/test_opening_tree.py
tools/mcp/requirements.txt   python-chess (opening-tree tools only)

lib/services/opponent_list.dart              parser + OpponentEntry → AnalysisPlayerInfo
lib/widgets/opponent_list_import_dialog.dart Player Analysis import dialog
lib/screens/player_selection_screen.dart     batch download
lib/models/analysis_player_info.dart         accounts / group
```

Tests: `python3 tools/mcp/test_chess_prep.py` (79),
`python3 tools/mcp/test_opening_tree.py` (10),
`flutter test test/services/opponent_list_test.dart
test/services/analysis_games_service_download_test.dart
test/widgets/opponent_list_import_dialog_test.dart`.
