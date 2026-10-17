# Backlog

What is planned or known missing in the app, each row checked against the
code on 2026-10-16. For what exists, read [the mode specs](features/README.md)
and [the component map](COMPONENT_MAP.md). A row is not a request to build it:
the owner's current instruction sets scope.

| Status | Meaning |
|---|---|
| **Not started** | Nothing in `lib/` (or the release pipeline) does it |
| **Partial** | It works with the stated gap |
| **Deferred** | The owner postponed it or has not decided it is worth building |

When a row is built, delete it here and remove it from its spec's *Not built*
list. When a spec gains a *Not built* item, add a row here.

## Workspace, viewer and builder

| Item | Status | Notes |
|---|---|---|
| Panes follow the free board | **Partial** | The explorer's `Book` source follows the board past the end of the file (`RepertoireTree.fen`); Replies, Expectimax and the other explorer sources read `DocumentSession.fen` and stay on the file's last position (`workspace/replies.dart`, `workspace/explorer.dart`) |
| Right-click ▸ Comment on a move | **Not started** | The move menu in `workspace/move_tree_view.dart` has no Comment entry; comments are edited through the edit strip |
| Autoplay speed and rolling into the next game | **Not started** | `AutoPlay` (`features/pgn_viewer/auto_play.dart`) steps every 1 s and stops at the end of the line |
| Solitaire timer and sidelines | **Not started** | `workspace/solitaire.dart` follows the main line only, with no reveal timer |
| Game review of existing variations | **Not started** | `GameReview` (`workspace/game_review.dart`) reviews the main line at depth 14 |
| `Include variations` in the `This file` explorer | **Not started** | The file index reads main lines only |
| Richer game filters | **Not started** | One position per filter (`GameFilter.position` in `chess/game_filter.dart`); a `Moves` gap matches any number of plies (`chess/move_sequence.dart`) |
| Ultrawide layout | **Partial** | Above 1,480 px the library and outline sit side by side (`navigationSideBySideMinWidth`), and tool panes split by hand up to four (`ActionLayout`); no default layout uses extra width beyond that |
| MCP resume of app searches | **Not started** | `expectimax_resume` refuses the app's algorithm-version-4 trees (`tools/mcp/chess_prep/expectimax_chapters.py`) |

## Training, tactics and your games

| Item | Status | Notes |
|---|---|---|
| Per-move scheduling | **Not started** | `chess/training/schedule.dart` schedules whole lines, so one slip makes the whole line Again (the main gap against Chessable) |
| Trainer drill options | **Deferred** | Partial-line depth or skip to the first comment (`chess/training/training_line.dart`), a choice of review order (`dueNow` in `chess/training/sitting.dart` is always most overdue first), automatic walkthrough advance, per-move streak thresholds, custom chapter grouping: none are in `TrainingOptions`; the owner has not chosen which to keep |
| My games moments | **Not started** | Per-game mistake counts are shown; a strip of small boards at each deviation and mistake, and board thumbnails on rows, are not (`MyGamesPanel` rows are text only) |
| Commentary lines in the book check | **Not started** | Import marks our-side brackets with `[BranchPlies]`, but `chess/book/book_check.dart` treats those lines as ordinary book moves |
| Check for new games at launch | **Not started** | Downloads start only when asked (`MyGames`, `TacticsView` in `app/training_views.dart`) |
| Puzzle editing and bulk management | **Not started** | No edit, custom puzzle, multi-select or bulk delete; `TacticsPanel`'s row menu has five entries |
| Puzzle hints and flaw tags | **Not started** | `PuzzleTrainer.showSolution` records no `HintsUsed`; flaw tags are neither mined (`chess/tactics/mining.dart`) nor shown |
| Study as a puzzle set | **Not started** | Nothing opens a study's chapters as a puzzle/flashcard set with stats |

## Databases, tournaments and bughouse

| Item | Status | Notes |
|---|---|---|
| Offline evaluation stores | **Deferred** | Lichess evaluation database and ChessDB dump: no code in `lib/` (owner unsure they are worth building, 2026-09-28) |
| Classical index rebuild | **Deferred** | The explorer says `The classical index for this database is not built.` (`workspace/explorer.dart`); nothing builds it (owner, 2026-09-28) |
| TWIC auto-update and first-run prompt | **Deferred** | `TwicDownload` (`features/databases/twic_download.dart`) runs only when started (owner, 2026-09-28) |
| Broadcast collections in the app | **Deferred** | Collected by `tools/lichess_broadcasts.py` and `tools/chesscom_events.py` ([BROADCAST_GAMES.md](BROADCAST_GAMES.md)); no Databases UI (owner, 2026-09-28) |
| Scid export | **Deferred** | No writer in `lib/`; the specification and C++ oracle are in [SCID_FORMAT_FINDINGS.md](SCID_FORMAT_FINDINGS.md) and `tools/scid_reference/` |
| Resume a stopped tournament | **Not started** | `TournamentRun` has no resume; `Run again` starts a new folder |
| Tournament setup gaps | **Not started** | No opening-label field (`setup_dialog.dart`; only the headless `--opening`), no pondering (always `ponder: false`), history rows lack time control, start time and duration (`history_list.dart`) |
| Bughouse match extras | **Not started** | No crosstable (`match_panel.dart` shows the opening score); no start from a typed line (`new_match_dialog.dart`) |

## Settings, accounts and release

| Item | Status | Notes |
|---|---|---|
| OS credential vault | **Not started** | Lichess tokens and account names live in SharedPreferences (`storage/lichess_token.dart`, `storage/my_accounts.dart`). Migrate and verify one account before removing its key |
| `Reset settings` | **Not started** | No reset action in `features/settings/setting_rows.dart` or `SettingsStore` |
| Self-update for every format | **Partial** | Windows Setup, deb, rpm, AppImage and marked portable Linux zips install themselves (`storage/update_install.dart`); Flatpak, the Windows zip and macOS are `InstallKind.manual` and open the release page |
| Native updater acceptance | **Partial** | Helper tests run in release CI; an actual Windows Setup and macOS update on a clean machine has not been verified |
| macOS signing and notarization | **Not started** | The release build verifies an ad-hoc signature (`codesign --verify` in `.github/workflows/release.yml`); no Developer ID signing, notarization or stapling |
| Windows Authenticode signing | **Not started** | No `signtool` step for the app binaries or Setup |
| Immutable release publication | **Not started** | `softprops/action-gh-release` publishes directly; no draft-then-verify step or release immutability |
| Engine cleanup proof off Linux | **Partial** | Engines exit when the app is killed because their pipes close (`engines/uci_process.dart`); `test/engines/stockfish_exit_test.dart` proves it on Linux only |
| Performance budgets | **Not started** | `scripts/ci.sh profile` and `test_driver/renewal_profile_driver.dart` remain, but no integration target measures the current app; no corpus sizes or latency/memory budgets are defined |

## Known defects

Shipped behaviour that contradicts a rule; fix when touching the area.

| Defect | Where |
|---|---|
| One bad record in `people.json` refuses the whole players directory, against the fail-open rule | `storage/player_files.dart` `PlayerFiles.read` |
