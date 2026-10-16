# Player analysis, Players & prep

Two modes for preparing against named people — a tournament field, a club
regular, or yourself. **Players & prep** is the directory: people, their
accounts and notes, groups for an event, and each person's prep study.
**Player analysis** loads one person's games onto the shared board and finds
what they play and where they go wrong. The user leaves with the games on disk,
the weak spots found, and their answer saved in a prep study or a prep sheet.

Code: `lib/features/players/` (owners `Players`, `PlayerAnalysis`,
`PlayerHunt`, `PlayerBook`, `SavedGames`; screens `PlayersScreen`,
`AnalysisPanel`, `PlayerTreePane`, `PlayerBookPane`), composed in
`lib/app/player_wiring.dart` (`PlayerModes`) and `lib/app/player_views.dart`.
Shared: `lib/chess/players/` (`Player`, `PlayerGroup`, `readPlayerList`,
`PlayerDownloadRange`), `lib/storage/player_files.dart`,
`lib/storage/player_reports.dart`, `lib/storage/saved_players.dart`,
`lib/storage/my_games_files.dart` (download cache), `lib/net/recent_games.dart`,
`lib/net/player_ratings.dart`, and the Study owner
(`lib/features/study/studies.dart`) for prep studies.

## Screen

### Players & prep

A full page (no board), capped at `playersPageWidth`.

- **`All players` / `Groups`** switch; inside a group, `← Groups`, the group
  name and `2026-10-10 · 5 rounds · 18 players · 5 prepared` instead.
- **Toolbar** — search (`Search name, ID or account` / `Search groups`), the one
  filled button (`Add player`, `Add players` in a group, `New group` over the
  groups), `Paste players`, and in a group `Open group study` and
  `Train group study`. The `⋯` (`More actions`) holds, in a group, `Edit group…`,
  `Copy prep sheet`, `Export prep sheet…`, `Unlink group study`; always
  `Add saved players`, `Update US Chess ratings`, `Reload players and groups`.
- **Notices** — a fixed-height progress line, the rating lookup status with
  `Stop`, unreadable group files, and a failed save with `Retry save` /
  `Discard failed edit and reload` (or `Try again` for a failed load).
- **Person row** — name and rating; accounts by site and `US Chess <id>` (or
  `No online accounts`); notes (two lines); linked studies as chips (× unlinks);
  saved-research suggestions (`PlayerLookup`, see Data); the saved-games line
  (`412 saved games · 2 PGN files · downloaded 3d ago`, `No saved games`) in its
  own column when wide, under the name when narrow; in a group a `Prepared`
  tick. Buttons `Analyze games` and `New prep study` / `Open prep study`; the
  row's `⋯` holds `Edit player…`, `Link study…`, `Unlink prep study`,
  `Delete saved games…` (only when some download can go) and `Remove player…` /
  `Remove from group…`.
- **Group row** — name over the event line; `⋯` with `Edit group…`,
  `Remove group…`. A click opens the group.

### Player analysis

The column (`AnalysisPanel`) beside the shared board; pane tabs
`Player openings` (pinned), `Game`, `My book`, `Explorer`, `Expectimax`.

- **Header** — the player's name and one `⋯` (`Change player…`, `Get games…`
  when they have an account, `Add PGN…`, `Reload saved games`, `Players & prep`).
- **Status** — `412 games · Chess.com (jdoe) · downloaded 3d ago`, plus
  `n unmatched` / `n unreadable or nonstandard`; while busy, the step with
  `Cancel` and a bar; errors with `Try again` and `Details`.
- **`As White` / `As Black`**, `Search games`, the game count beside a
  `Filters` fold (`Filters (n)` when some are on).
- **`Positions` / `Games` / `Findings`** switch, pinned while its list scrolls.
- With nobody chosen: the searchable saved-player list (`PlayerPicker`), or
  `Add player` and `Players & prep` on first run.
- No game yet: `Get games` (with an account) and `Add PGN…`.

Lists:

- **Positions** — up to 100 rows; header `Position`, `Games`, `Score`, and
  `Eval` once a pass has run; the headers sort (Games most first, Score worst
  then best, Eval worst first). A row shows the moves over `+4 =2 −3`.
- **Games** — a row per game naming the opponent, with ECO and event.
- **Findings** — `Analyze with engine` (`Stop · done / total` while running),
  `Analysis settings` fold, progress words, `Dismissed (n)` / `Back to findings`,
  then the finding rows.

Tabs:

- **Player openings** — `<name> as White · n games` with
  `Save line to prep study`, a move table (`Move`, `Games`,
  `White / Draw / Black` bar) for the board position, then the games reaching
  it. Off their games: `None of these games reached the position on the board.`
  with `Go to the first move`.
- **My book** — `Check my book`, `Choose book`, the summary
  `n games against your white book · n reach a gap`, then rows marked
  `Unanswered reply` or `Past the end of the book`.

## Actions

**Add or edit a player** — `Add player` / `Edit player…` → dialog with `Name`,
`Chess.com usernames`, `Lichess usernames` (comma-separated), `Names used in PGN
files` (semicolon-separated), `US Chess ID`, `FIDE ID`, `Rating`, `Prep notes`,
and linked `PGN files` as removable chips → `Save player`. Refusals:
`Enter a player name.`, `Use digits only.`, `Enter usernames, not profile URLs.`
Nothing saves per keystroke.

**Paste players** — `Table or opponents JSON` → `Preview players` → `Add players`
(`Add to group` inside a group). Tables: tab, pipe or comma delimited with a
`Name`/`Player` column; also `USCF ID`/`US Chess ID`, `Chess.com`, `Lichess`,
`Rating`, `Notes`, `FIDE ID`. JSON: a list, or `people` / `opponents` / `players`.
Rows match an existing person by US Chess ID, then account, then exact name or
alias, and fill only empty fields; aliases, PGN files and game sets are unioned.
Refusals: `Include column headings, such as Name, Rating, Chess.com and
Lichess.`, `Include a Name column.`, `Every player needs a name.`

**Add saved players** — imports, the same way, every game set found in the
read-only `Documents/analysis_games/` corpus and the user's own accounts;
`No older player game sets were found.` when there are none.

**Groups** — `New group` / `Edit group…` → `Group name`, `Event date (YYYY-MM-DD,
optional)`, `Rounds` (default 5) → `Save group`. `Add players` picks from the
directory. `Remove group…` moves the group file to `opponents/.removed/`;
players, games and studies stay.

**Update US Chess ratings** — for the visible people with a US Chess ID, one
request at a time (700 ms apart, 20 s timeout) to
`ratings-api.uschess.org/api/v1/members/<id>`; status
`Looking up Jane Doe · 3 / 18`, `Stop`, then `7 ratings updated · 2 unavailable`.

**Prep study** — `New prep study` creates `Documents/studies/Prep – <name>.pgn`
with `As White` and `As Black` chapters (each its own orientation), links it as
`prep_file`, and opens it in Study; `Open prep study` opens the link. A linked
file that is gone is made again; a file already under that name that nobody
links is adopted; an unreadable one is reported, never replaced.
`Link study…` picks a PGN and adds it to `studies`; a chip opens it (at its
chapter when the link names one).

**Save line to prep study** — Player openings button or Actions → the board's
line, with comments, becomes a new chapter `<name> · As <our side>` in the prep
study, which then opens.

**Group study** — `Open group study` / `Train group study` → created once as
`Prep – <group>.pgn` from members' non-empty prep chapters
(`Jane Doe · As White`, keeping orientation; a `Preparation` chapter when none),
linked as the group's `study`. Members whose prep study is missing or unreadable
are left out and named. Train opens it in Study's Train pane with Chapter scope,
each chapter from its own side.

**Prep sheet** — `Copy prep sheet` / `Export prep sheet…` (native Save dialog,
`<group>.md`) → Markdown: group name, event line, a `Player | Rating | US Chess |
Accounts | Prepared` table, then per person the notes and each prep chapter's
movetext (`(no moves yet)`; a missing study is noted, not fatal).

**Delete saved games…** — confirm `Delete <name>'s saved games?` → their
downloads move to the recovery folder and their engine reports are deleted.
Linked PGN files stay, as does a download another reader shares (one of the
user's own accounts, or an account another person holds); the confirm names
each one kept. `Remove player…` offers `Remove and delete games` /
`Remove, keep games`, and removes them from every group.

**Analyze games** — row button or picker → Player analysis reads the person's
corpus: each account's download, linked PGN files, and their games in the
older archive (`app_games.db` analysis collections, copied append-only to
`games_library/player_archives/`). Games are deduplicated; the player's colour
comes from exact name, alias or handle, and unmatched games are excluded and
counted.

**Get games** — `Get <name>'s games` dialog: `Last games` (`Games per account`,
1–10000, default 500) or `Recent months` (1–120), and time controls (Bullet …
Correspondence; default all but bullet) → `New games are added to the ones
already saved.` The choice is stored on the person (`download`). Per-site
failures (`username not found`, `download limit reached; try again later`) show
under `Some games could not be updated. Showing saved games.`

**Filters** — `Dates` (`All dates`, last 30/90/180/365 days), `Time controls`
(none chosen = all; `Other` for an unreadable time control), `Minimum games`
(default 1), `From move` (default 1). They narrow Positions, Games, Findings and
both tabs.

**Analyze with engine** — Findings button or Actions → a finite, cancellable
Stockfish pass over the most played positions: `Depth` (8–30, default 14),
`Positions to check` (1–1000, default 100). A finding is a position at or below
−50 cp for the player, or a strong reply (≤ +30 cp) their games never met,
ranked by games × badness. `Include practical chances` (needs Maia) adds
`Player rating` (default 1800) and `Positions to probe` (default 10): up to
three engine moves within 50 cp of best, each against Maia's five likely
replies. Changing source, colour, filters or settings stops the run; a stopped
run keeps its partial report. Findings can be dismissed and restored.

**Check against my book** — My book tab or Actions → walks the filtered games
through the book in use for our colour; a row opens its game at the gap.
No book: `Choose a white repertoire in Books, then check again.`

## Data

- `Documents/opponents/people.json` (`chess-auto-prep/people@1`): per person
  `id`, `name`, `aliases`, `chesscom`, `lichess`, `uscf_id`, `fide_id`, `rating`,
  `notes`, `prep_file`, `studies` (path + optional chapter), `pgn_files`,
  `game_sets`, `download`, `dismissed_findings`, timestamps, and the MCP
  tooling's `lookup` block. `Documents/opponents/tournaments/<id>.json`
  (`chess-auto-prep/tournament@1`): `name`, `date`, `rounds`, `study`,
  `entries` (`person`, `prepared`). Unknown fields — e.g. MCP pairing data —
  survive every edit. Writes go through `PendingWrites` under a folder lock,
  re-reading first; a row changed elsewhere is refused
  (`This player changed in another window. Reload before editing.`). Bad or
  duplicate person IDs refuse the whole directory; one unreadable group file is
  reported and skipped.
- `lookup` (`status`, `confirmed`, `candidates` with `evidence`, `next_steps`)
  is written by the chess-prep MCP tools; the row shows the candidates and
  `Use account` adds one to the person and marks it `confirmed_by: user`.
  See [OPPONENT_PREP.md](../OPPONENT_PREP.md) for the MCP side.
- Downloads: `Documents/games_library/<site>_<user>.pgn` — the same cache My
  games and Tactics use. Older archive copies: `games_library/player_archives/`.
- Engine reports: `<support>/player-reports/<sha256>.json`, disposable, keyed by
  source fingerprint, colour, filters and engine settings.
- Prep and group studies are ordinary Study files under `Documents/studies/`;
  Study, the Trainer and the PGN Viewer read them.

## Owner decisions

- (2026-09-27) Two modes over one shared directory; groups (events) live inside
  Players & prep, not a mode of their own. Player analysis works on the shared
  board and tabs.
- (2026-10-01) Players & prep is one dense list with one filled button; a row
  shows only `Analyze games` and the prep study button, the rest in `⋯`.
- (2026-10-01) Player analysis has one `⋯`, no settings dialogs: filters and
  engine settings fold open in the column with every control named.
- Edits go through a validated Save dialog; notes do not save per keystroke.
- An unconfirmed account candidate never becomes a download identity until the
  user presses `Use account`.
- A person's games are one corpus across accounts, PGN files and old sets;
  `Get games` only adds.
- Findings say what they are: a reply missing from the games is a coverage gap,
  not a refutation; practical chances are a one-reply-layer Maia estimate with
  unprobed replies assumed to be perfect defence.
- Remote entry lists are not fetched; open the page and paste its table.
- Prep and group studies are trained and edited with the ordinary Study and
  Trainer tools, never player-specific ones. A group study is seeded once and
  never regenerated.
- Deleting a person's games never touches linked PGN files or a download
  another reader shares.
