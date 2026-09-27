# Player analysis, Players & prep

Status: draft from the old app
Old code (oracle only): `lib/screens/analysis_screen*.dart`, `lib/screens/player_selection_screen.dart`,
`lib/features/opponents/`, `lib/widgets/position_analysis_widget*.dart`, `lib/widgets/analysis*`,
`lib/services/analysis_games_service.dart`
Plan step: 10

No screenshot: the app driver was not used for this pass.

## Purpose
Someone is about to face a named opponent — a tournament field, a club regular, or themselves — and wants
to know what that person actually plays. They leave with those games on disk, the weak spots in them found,
and their answer written into that person's prep file or exported as one sheet for the event.

## Screen
Two modes. **Player analysis** is reached from the mode menu, from Tactics and by handoff from `Analyze
games` / `Prepare`; **Players & prep** from the mode menu, the picker and either mode's Actions menu.

- **Subtitle and colour toggle** — `412 games · Chess.com (jdoe) · last 6 months · downloaded 30d ago`, a
  refresh icon `Download the latest games…` (absent for a PGN import, disabled while building), and a
  `White` / `Black` toggle; both colours are built together, so switching is instant.
- **`Actions` menu** — *Analyze*: `Analyze with engine…` (`Re-analyze…` once evals exist), `Find holes…`,
  `Check against my repertoire…`; *Study and games*: `Add line to study…`, `Open games in PGN viewer`;
  *Player*: `Choose a player…`, `Players & prep`. Engine entries disable, never hide, while a job runs.
- **Job strip** — a 2px bar plus `Engine evaluation: 84 / 340 positions (25%)` or `Hole hunt: <phase>`.
- **Player picker**, filling the body until a player is chosen — `Which player?`, `Back to analysis`,
  `Players & prep`, `Add player` (`Online…` — *A Chess.com or Lichess username*; `From PGN files…` — *Games
  already saved on this computer*), `Search players` over username, site and group, then a card per saved
  game-set: name, `412 games · Chess.com · last 6 months`, `Downloaded 3d ago · Spring Open · jdoe
  (chess.com)`, `Update games`, `Change range…`, `Remove`. First run lists the two sources instead; failures
  read `Could not load saved players.` + `Try again` or `No players match "xyz"`. With nobody chosen: `No
  player selected`, `Pick whose games to analyze — yours or an opponent’s.`
- **Left column** — `Positions` / `Holes (n)`. Positions: `Min games:`, `Min depth (move #):`, `Sort by:`
  (`Bad Eval`, `Good Eval`, `Lowest Win Rate` — the default, `Highest Win Rate`, `Most Games`, `Most Wins`,
  `Most Losses`), at most 50 rows; an eval sort before any engine pass reads `These games have not been
  analyzed with the engine yet.` with `Analyze with engine…`. Holes is the shared findings panel
  (`checks.md`), driving the board and the finding arrows.
- **Board and right pane** — the shared board (`workspace.md`) beside an engine bar over `Move Tree` (the
  merged opening tree, with `Back`), `Games` (games here, then one game's movetext behind `Back to games`)
  and `Try moves` (a scratch tree: off-book moves and clicked engine lines land there, savable to a study).
- **Prep chrome** — `Players & prep`, or `Groups / Boylston September` with `Back to groups`; an Actions
  menu of one entry, `Player analysis`; tabs `All players (128)` / `Groups (4)`; then `Search name, ID or
  account`, `Add player`, `Add saved accounts` (`Linking…`), `Paste players` / `Close import`, `All players
  · 128`, `Edit cells to save automatically. Use commas for multiple accounts.`
- **Player table**, the same rows in the directory and in a group — `Ready` (a prepared checkbox, group
  only), `Name`, `USCF ID`, `Chess.com accounts`, `Lichess accounts`, `Reference studies`, `Games`,
  `Rating`, `Notes`, a remove button (`Delete player` / `Remove from group`); 1326px wide, scrolled
  horizontally; empty, `Add your first player, or paste a list from a spreadsheet.`
- **Studies and games cells** — the prep file and linked studies as buttons (unlink icon per explicit
  link), `New study`, `Link study` / `Close links` opening `Link a study or chapter` (`Search studies`,
  `Browse PGN files`, `Link study`, `Link file`, `Link chapter`); then `No account linked` / `No saved
  games` / `84 saved` / `2 saved sources`, `Analyze games` (`Prepare` in a group, `Working…`) and a `Saved
  sources` expander: `chess.com: jdoe · 84 games`, `Download latest games`.
- **Groups** — a `New group` field (hint `Boylston September`), `Create group`, `A saved list of players to
  prepare against.`, `Search groups`, then a card per group: editable name, `18 players · 5 prepared`,
  `Open group`, delete; empty, `Create a group to collect players for a tournament or training session.` An
  open group adds `Add players` / `Close add players`, `Paste player list` / `Close import`, `Open group
  study`, `Train group study`, `Look up USCF ratings`, `Export notes`, `Edit cells directly · Saved
  automatically · Separate accounts with commas`, and an add panel with `New player row` and `Or add
  someone from your saved players:` (`Add <name>` each).

## Actions
**Download a player** — `Online…` → `Download a player’s games` asks site (`Chess.com` / `Lichess`),
`Username`, `How many games` (`Recent months`, default 6, or `Last N games`, default 100 — remembered
separately) and `Which time controls` (bullet off by default, remembered and stored with the game-set),
under `Every game they played in the last 6 months, at blitz, rapid or classical.` Refusals: `Please enter
a username`, `Enter 1 or more`, `Enter a number of games (1 or more)`, `… — pick at least one time
control.` A blocking `Downloading <name>` dialog reads `Fetching Chess.com game archives for jdoe…`, `12 /
100 games downloaded so far…`, `84 games downloaded`, `Saving…`; a Lichess 429 backs off 60/120/240 s.
Failures: `No games found for jdoe.`, `Could not reach Chess.com. Check your internet connection and try
again.`, `Could not download from Lichess. Please try again.` `Update games` refetches with the saved
range; `Change range…` and the refresh icon reopen it as `Download <name> again`, site and username fixed;
`Remove` asks `Remove Jane Doe?` — *Deletes the saved games and their analysis.*
**Import from PGN files** — `Open PGN files`: `Choose PGN files…`, a file and game count, `Whose games are
these?` (spellings separated by `;`) → `Matched 61 of 84 games`, `Matching as: …`, `23 games match neither
side — they will count for both colours.` Refusals: `Enter a player name`, `Select PGN files with at least
one game.` A clashing name asks `Replace these games?` — *"jdoe" already has 84 games here. Opening these
files replaces them and clears their cached analysis.*
**Analyse a player** — choosing one builds both colours' stats and opening trees in one isolate pass,
reusing the disk cache when the PGN is unchanged; the subtitle appends `· Analyzing games · 140 / 412
games`. Failures: `No games found. Please re-download games for this player.`, `Player games changed while
the tree was built. Reopen this player.`, `Failed to analyze positions: <e>`.
**Engine pass** — `Analyze with engine…` asks minimum games (3), a White threshold (-50 cp) and a Black
threshold (100 cp) at the shared bulk-analysis depth, then scores the most-played positions, streaming
results in and clearing the old numbers first. Failures: `Player games changed. Reopen this player before
analyzing.`, `Engine analysis failed: <e>`.
**Find holes** — `Find Holes` attacks this player's games from the other side; it offers `Max depth
(half-moves)`, `Maia rating`, `Moves to probe` and a `More thresholds` disclosure, then `Start Hunt`.
Findings stream live, rank by reach probability × gain and save per player and colour, a cancelled hunt
keeping its partial report. Refusals: the engine gate, `Another engine job is running — wait for it to
finish first.`, `Hole hunt failed: <e>`. See `checks.md`.
**Check against my repertoire** — walks their games on the displayed colour through the book designated for
the other colour → `jdoe as Black vs my White book`, `Book: Najdorf (7 chapters) · 412 of their games · 57
reach a gap`, then `Unanswered — the book continues but not against this` and `Past the end of the book`,
rows `1. e4 c5 2. Nf3 d6 · 14 games · 61%` that jump the board. Empty: `Every line they play is answered in
the book.` No book: `No White repertoire is designated. Choose one under My books on the Tactics page.`
**Add a line to a study** — saves the moves leading to the current position, with comments, as one chapter:
by default the person's prep file, chapter `Jane Doe · As Black` for the colour *you* hold, or the group
study when they were opened from a group, which is then linked from their row. A study button opens it in
Study (`This file has moved or is missing: <path>`); `Open games in PGN viewer` hands over the saved PGN.
**Keep the directory** — `Add player` inserts a row called `New player` with the name focused; every cell
saves as you type. Validation: `Enter a name or username.`, `Digits only.`, `Use usernames, separated by
commas.`, `Use a number.`; a failed write leaves `Not saved. Press Enter to retry.` Deleting asks `Delete
Jane Doe?` — *Deletes this player record. Saved games and linked studies stay on disk.* `Add saved
accounts` makes a person per unmatched game-set → `Added 6 players. Existing accounts are linked.`
**Paste a list** — the panel takes a table (tabs, pipes, CSV, markdown or two-space columns; headings
`Name`/`Player`, `USCF ID`, `Rating`, `Chess.com`, `Lichess`), the app's own opponents JSON, or an
entry-list URL reduced to its cells, then `Preview players` and `Add to database` / `Add to group`. Rows
match by USCF ID, then handle, then exact name, and fill only blanks → `12 players added or updated.` or
`Added 9 · 3 already listed · 2 new in the directory · 1 skipped`. Refusals: `Paste a table with Name and
USCF ID columns.`, `Include the column headings, such as Name, Rating, USCF ID.`, `No player rows found.`,
`Could not load the page (404). Copy and paste its table instead.`
**Make a group** — a name plus `Create group` opens it. Refusals: `Enter a group name.`, `That group
already exists.`, `That name is already used.` Deleting asks `Delete Boylston September?` — *Players, saved
games and studies stay in your library.* `Open group study` creates the study once, seeded with every
non-empty chapter of the field's prep files as `Jane Doe · As White`, never regenerated.
**Look up USCF ratings** — asks the public US Chess ratings API for everyone in the field with an ID, one
request at a time, 700 ms apart, 20 s timeout, behind `Asking US Chess` showing `Jane Doe (3 of 18)` and
`Stop` (`Stopping…`); it fills the regular rating, and the name when blank → `Updated 7 · 2 not found`.
Refusals: `Nobody in the field has a US Chess ID.`, `A US Chess ID is 7 to 9 digits.`, `US Chess has no
member with that ID.`, `US Chess answered HTTP 500.`, `Could not reach US Chess (<e>).`
**Export notes** — renders the group as markdown and opens `Save Boylston September as text` (default
`Boylston September.md`, `.md`/`.txt`, in the opponents folder), writes atomically, says `Saved <path>`.
The file is the group name, `2026-09-20 · 5 rounds · 18 opponents · 5 prepared`, `Exported 2026-09-19 by
Chess Auto Prep.`, a table (`# · Name · Rating · USCF ID · Chess.com · Lichess · Odds · Prepared`), then a
section per opponent with facts, notes and each prep chapter's movetext (`(no moves yet)`).

## Data
- `Documents/opponents/people.json` (`chess-auto-prep/people@1`) — per person: id, name, `aliases` (other
  spellings, searched like the name), `uscf_id`, `fide_id`, `chesscom`, `lichess` (comma-separated handles),
  rating, title, notes, `prep_file`, `game_sets` (explicit corpus keys, so a rename does not orphan games),
  `studies` (path + optional chapter), timestamps, and the MCP tooling's `lookup` report (status, confirmed
  accounts, candidates with evidence, OTB identity, next steps), which the app keeps unread; and
  `tournaments/<id>.json` (`chess-auto-prep/tournament@1`) — name, date, rounds, `study`, entries of person
  id, rating, `pairing_prob`, `likely_round`, `prepared`. Files are rewritten atomically per edit; an id is
  minted once and survives a rename.
- `Documents/analysis_games/<platform>_<username>/` — the PGN at `versions/<revision>/games.pgn` published
  by one manifest, with caches keyed by its SHA-256: `white_analysis.json`, `black_analysis.json`,
  `holes_white.json`, `holes_black.json`, `engine_evals.json`. A changed fingerprint invalidates them all;
  a job finishing against a stale one refuses to save.
- Prep files are ordinary studies, `Prep – Jane Doe` with `As White` and `As Black` chapters, a group study
  named after the group; Study, Trainer and PGN Viewer read the same files, and books come from Tactics.
- Fetched: chess.com monthly archives and their `/pgn`, the Lichess user-games stream, the US Chess ratings
  API (`ratings-api.uschess.org/api/v1`, unauthenticated, nothing cached). The pasted opponents JSON is
  what the MCP tooling writes; `people_populate` / `people_upsert` also write `people.json` and
  a group file directly (`docs/OPPONENT_PREP.md`). A v2 directory should show each person's lookup status and
  candidates, so an agent-filled field needs no typing and an unconfirmed account is one click from use.

## Keep / Change / Drop
Keep — Subtitle and colour toggle
Keep — `Actions` menu
Keep — Job strip
Keep — Player picker
Keep — Left column
Keep — Board and right pane
Keep — Prep chrome
Keep — Player table
Keep — Studies and games cells
Keep — Groups
Keep — Download a player
Keep — Import from PGN files
Keep — Analyse a player
Keep — Engine pass
Keep — Find holes
Keep — Check against my repertoire
Keep — Add a line to a study
Keep — Keep the directory
Keep — Paste a list
Keep — Make a group
Keep — Look up USCF ratings
Keep — Export notes

Quirks to rule on: a username that does not exist and one with no games give the same sentence, `No games
found for jdoe.`, and a Lichess 429 pauses for minutes with no message; "group" and "tournament" are one
thing under two names, and a group's date, rounds and pairing odds can only arrive by import; the bulk
"download the whole field" path, the per-person open/train prep-file commands and the opponent-list import
dialog exist but nothing reaches them; cells save on every keystroke; the group study is seeded once only.

## Questions for the owner
- Are Player analysis and Players & prep two modes, or one mode with a directory and a board view?
- Should a person's games be one merged corpus across their accounts, or one set per account?
- Does a group keep date, rounds and pairing odds, and if so what edits them?
- Is the text export the right artifact, or should a group produce a study or a printable sheet?
