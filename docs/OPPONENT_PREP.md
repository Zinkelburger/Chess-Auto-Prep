# Players and groups

Keep one saved record per person, link their online accounts and prep studies,
and include them in any number of groups. A group can be a tournament entry
list, club regulars, or any other list of players to prepare against.

**Library → Players & prep** opens the editable directory; **Groups** opens
your saved preparation lists. The optional MCP tools below can help
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
| `player_lookup` | One person through every source in a fixed order; status, accounts, scored candidates, OTB identity, next steps. Writes nothing |
| `people_populate` | The whole roster into the app's players directory, plus a group for the event |
| `people_list` / `people_get` | Read the players directory (aliases, IDs, accounts, lookup status) |
| `people_upsert` | Add or merge one person; web finds go in as candidates with evidence |
| `people_confirm` | Promote an approved candidate to an account the app downloads from |
| `master_player_search` | A player in the master-games database under any spelling, grouped by FIDE ID |
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
| `chesscom_profile` | One chess.com account: title, country, joined, current/best rating per category; with `months`, its games, busiest hours and an opening count |
| `chesscom_rating_on` | What an account's rating read on a given day, rebuilt from its game archive |
| `chesscom_who_plays` | Who in the local archive index opens with a line, as White or Black |
| `chesscom_search` / `chesscom_search_status` / `chesscom_search_stop` | Background job: find the account that showed these ratings on these days |

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

### Filling the players directory

The agent's hand-off is the app's own directory, `Documents/opponents/`
(`people.json` and `tournaments/<id>.json`), so nobody types the field in:

```
roster_import    {text: "<pasted entry list>", event_name: "Fall Open"}
roster_update    {player_id: "13433622", aliases: ["Denis Shmeliov"]}
people_populate  {}                     # → summary: account / candidates / otb_only / not_found
people_upsert    {name: "Shea Winter", candidates: [{site: "lichess", username: "…", evidence: "<quote>"}]}
people_confirm   {person_id, site: "chesscom", username: "…"}   # only after the user says yes
```

`player_lookup` (and so `people_populate`) asks, in order: the players
directory already on disk; the bundled USCF → chess.com directory; the US
Chess API, whose spelling of the name (`Will Schiminger`) becomes an alias and
which says whether the player was ever online-rated; the TWIC master-games
database under every spelling; and a probe of about eight usernames built from
each spelling on chess.com and Lichess (one Lichess request covers them all).

**Spellings.** A person row carries `aliases`, and every search takes all of
them. Names match when the surnames are within an edit cap (none under five
letters, so Zhou is never Zhu; one to seven letters; two from eight, so
Shmelov finds Shmeliov) and the given names agree: exactly, closely
(`Denys`/`Denis`), or by an initial when one side only has an initial
(`Shmeliov,D`). Two-part names are also read surname-first (`Zhou
Jianchao`), and then the given name must agree in full. TWIC rows are grouped
by FIDE ID, which catches every later spelling; a TWIC identity is taken only
when one fits at the best match grade and its latest Elo is within 300 of the
known rating. Otherwise the rows are listed as ambiguous.

**Trust.** `chesscom` and `lichess` on a person are the accounts the app
downloads games from. Only the directory's USCF-event match, an account the
user confirmed on the roster, or `people_confirm` writes them. A probed
username counts only when its profile's real name, title or listed rating
agrees; closed accounts and bare handle matches are listed as rejected. Those
finds, and anything found by web search, wait in the row's `lookup` block
(`status`, `confirmed`, `candidates` with evidence, `otb`, `next_steps`) until
the user approves one. Several accounts per person are normal; each confirm
adds one. A merge fills blanks and unions lists; it never replaces a name,
rating, note or account the user typed (a different name becomes an alias).

The app keeps `aliases`, `fide_id` and any key it does not model
(`PersonRecord.extra`) when it saves. It loads the directory once per run, so
restart it to see new rows, and do not edit players in an app that was open
during the write: its next save would replace the file.

### Finding a chess.com account from rating clues

"He was 2701 blitz on June 13 and 2724 on June 20, he's in the US, and he
plays the Scotch with 6.Bd3." The public API has no rating history and shows
only the top 50 of a leaderboard, but every monthly game archive records both
players' post-game ratings, so a rating history can be rebuilt for any player
*and every opponent they faced*. The `chesscom_*` tools cache archives under
`~/.local/share/chess-prep/chesscom/archives/` (override the directory with
`CHESS_PREP_CHESSCOM_DIR`; files are `<username>_<YYYY-MM>.json`, so an older
cache can be linked in) and index them into `index.sqlite`: rating events and
the first 20 plies of every game, for the archive owner and the opponent alike.

```
chesscom_search        {clues: [{category: "blitz", rating: 2701, date: "2026-06-13"},
                                {category: "blitz", rating: 2724, date: "2026-06-20"}],
                        country: "US", opening: "1.e4 e5 2.Nf3 Nc6 3.d4 exd4 4.Nxd4 Nf6 5.Nxc6 bxc6 6.Bd3"}
chesscom_search_status {id}            # indexing → leaderboard → scanning → enriching → done
chesscom_rating_on     {username, category: "blitz", date: "2026-06-13", rating: 2701}
chesscom_profile       {username, months: ["2026-06"], opening: "1.e4 e5 2.Nf3 Nc6 3.d4"}
chesscom_who_plays     {opening: "1.e4 e5 2.Nf3 Nc6 3.d4 exd4 4.Nxd4 Nf6 5.Nxc6 bxc6 6.Bd3", side: "white"}
```

The search is a detached process (`python3 -m chess_prep.chesscom --job DIR`,
jobs under `chesscom/searches/`). It indexes any unindexed archive files,
pages the website leaderboard callback (50 per page, far past the API's top
50) for players currently within `band` (default 200) of each clue rating,
downloads their archives for the clue months, and then verifies every
opponent sighted at a clue rating from that opponent's own archive. That
verification step is what finds an account that has since dropped off the
leaderboard: the September 2026 search found its target only as somebody's
opponent. Requests are serial with ~0.15 s spacing and a `max_requests`
budget (default 1500); everything downloaded stays cached, so rerunning the
same clues resumes for free. Dates are the player's local day: `tz: "US"`
(default) spans every US zone, `UTC` is exact, or give an IANA zone. Friend
counts are never visible logged out; followers are not friends.

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
| **Players & prep** | All players in an autosaving table, plus preparation groups: names, USCF IDs, online accounts, ratings, notes, study links and group readiness | Open from Library in the mode menu, or the Players & prep shortcut in analysis. **Analyze games** switches to Player analysis. Return through the mode menu or breadcrumb; the selected group and filters remain. |
| **Player analysis** | Choose a saved game set from the compact cards, download online games or import PGNs, then explore positions and games | Online and PGN are the two Add player sources. Advanced engine and study actions stay in the existing Actions menu. |

Players & prep opens directly to **All players**. Existing saved accounts and PGN
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

**Groups** contains searchable saved lists for tournaments, clubs or practice.
Create a named group, include saved people or paste a player list, and track
prepared status per person. Removing someone from a group keeps their directory
record. Group study, training, rating lookup and notes export remain available
on the sheet. Both tabs and the sheet keep the mode picker and settings visible;
this destination does not start an analysis engine. Game-set links refresh when
you return after importing or analyzing elsewhere.

Analysis keeps its board and advanced tools. Its Players & prep shortcut returns
to the shared directory rather than opening another nested database route.

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
  chesscom.py     chess.com archive cache + rating/opening index, account search job
  paths.py        data + working-file locations
  data/           bundled directory (regenerate with scripts/build_directory_assets.py)
tools/mcp/test_chess_prep.py
tools/mcp/test_chesscom.py
tools/mcp/test_opening_tree.py
tools/mcp/requirements.txt   python-chess (opening-tree tools only)

lib/services/opponent_list.dart              parser + OpponentEntry → AnalysisPlayerInfo
lib/features/opponents/                      tournaments, people, prep files, US Chess lookup,
                                             repertoire check, text export (models/ services/ widgets/)
lib/screens/analysis_screen_prep.dart        Player analysis: personal study context and repertoire check
lib/screens/player_selection_screen.dart     the picker ("Which player?")
lib/models/analysis_player_info.dart         accounts / group
```

Tests: `python3 tools/mcp/test_chess_prep.py` (80),
`python3 tools/mcp/test_chesscom.py` (15),
`python3 tools/mcp/test_opening_tree.py` (10),
`flutter test test/services/opponent_list_test.dart
test/services/analysis_games_service_download_test.dart
test/widgets/opponent_list_import_dialog_test.dart`.
