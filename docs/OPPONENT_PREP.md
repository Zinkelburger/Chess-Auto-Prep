# Players and groups

Keep one saved record per person, link their online accounts and prep studies,
and include them in any number of groups. A group can be a tournament entry
list, club regulars, or any other list of players to prepare against.

**Player analysis → Choose a player → Players & groups** opens Groups; **All
players** opens the editable directory. The optional MCP tools below can help
identify accounts before importing, but ordinary editing and prep run in the app.

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
| `pgn_audit` | Flag book moves Stockfish thinks are mistakes, and opponent replies ChessDB rates strong that the file never answers |
| `chessdb_query` | ChessDB's scored move list for a position, with how many good replies each good move leaves the opponent |
| `master_status` | Coverage of the app's local master-games database (TWIC) |
| `master_book` | What titled players play from a position, with a cited game per move |
| `master_game` | One master game by id, as PGN |
| `master_games` | A player's recent master games |
| `my_games_status` | Collections in the user's own games database (Player Analysis, library, tactics) |
| `my_games_at` | The user's / an analysed opponent's games reaching a position |
| `my_games_by_player` | Games in the user's database by player |
| `my_game` | One of those games, as PGN |
| `tournament_run` | Play engine vs engine from a position, and open the app on it |
| `tournament_status` | Progress, results and endings so far, still running? |
| `tournament_list` | Every saved tournament, newest first |
| `tournament_crosstable` | Standings, Elo ± interval, LOS, head-to-head grid |
| `tournament_games` / `tournament_game_pgn` | The games, and one game's PGN |
| `tournament_stop` | Stop cleanly after the game in flight |
| `tournament_open` | Open the app on a tournament |
| `tournament_engines` / `tournament_add_engine` | List engines; verify and register a UCI binary |

Working files live in `~/.local/share/chess-prep/` (macOS: `~/Library/
Application Support/chess-prep/`; override with `CHESS_PREP_DATA_DIR`, or the
roster alone with `CHESS_PREP_ROSTER`).

The tournament tools need the Flutter SDK's `dart` on PATH (or
`CHESS_PREP_DART`), because they run the app's own tournament code rather than
a second copy of it. See [ENGINE_TOURNAMENT.md](ENGINE_TOURNAMENT.md).

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
pgn_audit    {path, moves: "…", side: "white"}    # book mistakes + uncovered strong replies along a line
chessdb_query {moves: "1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d4 exd4 5. e5 Ng4 6. O-O"}  # which reply leaves White fewest good moves?
```

`pgn_eval` and the mistake half of `pgn_audit` need a Stockfish binary (`STOCKFISH` or on `PATH`); `chessdb_query` and the reply-gap half of `pgn_audit` need only the network.
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

The player workflow has two destinations:

| View | Purpose | Navigation |
|---|---|---|
| **Player database** | All players in an autosaving table: names, USCF IDs, online accounts, ratings, notes and reference studies/chapters/PGN files | Open the filled **Player database** button on the player picker, or the entry in analysis's Actions menu. **Analyze games** pushes analysis; its labelled back button returns to the same table and search. |
| **Player analysis** | Choose a saved game set from the compact cards, download online games or import PGNs, then explore positions and games | Online and PGN are the two Add player sources. Advanced engine and study actions stay in the existing Actions menu. |

The database opens directly to **All players**. Existing saved accounts and PGN
sets are linked on first opening; **Add saved accounts** can refresh those links.
**Add player** inserts an editable row. Valid edits save automatically; failed
saves show an error on the cell and Enter retries. Use commas, semicolons or
whitespace for multiple accounts. Stable game-set keys preserve saved games
when a player's display name or account fields change.

**Paste players** accepts headed CSV/TSV, Markdown, aligned text, opponent JSON
or a URL with an HTML table. Preview, then **Add to database**. USCF IDs and
known handles reuse directory records and imports fill blanks without
replacing edited information. Importing does not create a group.

**Reference studies** keeps links with the person. **New study** creates a
personal study; **Link study** opens the study/chapter browser with a PGN file
picker. Links open their target; unlinking removes only the association.
Missing files report their path. **Analyze games** reuses saved games before
downloading accounts and deduplicates games across saved sources.

Within analysis, the left column selects **Positions** or the advanced **Holes**
report; the centre is the board. The right panel has three tabs: **Move Tree**
for aggregate continuations, **Games** for matching games and their reader
(with **Back to games**), and **Try moves** for scratch variations. There is
no separate PGN tab or ambiguously named Analysis tab inside Player analysis.

Groups are deferred from this navigation. The legacy group files and code
remain compatible, but there is no group landing page or tournament/prepared
controls in the player workflow. Analysis no longer has a second prep toolbar
with duplicated study, repertoire and save-line buttons. The existing Actions
menu retains advanced tools and the player's personal study as a save target.

Files remain backward compatible: `Documents/opponents/people.json` and
`Documents/opponents/tournaments/<id>.json` retain their original format IDs.
The people file records whether saved-account onboarding has completed, so deleting a record is respected on reopening. People optionally carry `game_sets` (stable cached-corpus keys) and `studies`
(path plus optional chapter name); groups optionally carry `study` (PGN path).
Existing personal `prep_file` paths, dates, rounds and pairing data are retained.
Writes are ordered so quick edits cannot leave an older snapshot on disk.

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
lib/features/opponents/                      tournaments, people, prep files, US Chess lookup,
                                             repertoire check, text export (models/ services/ widgets/)
lib/screens/analysis_screen_prep.dart        Player analysis: personal study context and repertoire check
lib/screens/player_selection_screen.dart     the picker ("Which player?")
lib/models/analysis_player_info.dart         accounts / group
```

Tests: `python3 tools/mcp/test_chess_prep.py` (79),
`python3 tools/mcp/test_opening_tree.py` (10),
`flutter test test/services/opponent_list_test.dart
test/services/analysis_games_service_download_test.dart
test/widgets/opponent_list_import_dialog_test.dart`.
