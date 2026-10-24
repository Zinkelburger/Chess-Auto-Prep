# Settings

The player opens Settings to change something that applies across the app
(coordinates, figurines, engine cores and memory, the opponent rating replies
are predicted for), to log in to Lichess, to take an update, or to find the log
after something went wrong. They leave with the change already on disk; there
is no Save or Cancel.

Code: `lib/features/settings/` (`settingGroups` in `setting_rows.dart` builds
every row; `SettingsDialog`, `setting_controls.dart`, `LichessAccountState`,
`AppUpdates`, `updateRows`, `update_prompt.dart`), the value and its store
`lib/storage/settings.dart` (`Settings`) and `lib/storage/settings_store.dart`
(`SettingsStore`), rows assembled in `lib/app/app.dart` (`_settingRows`),
login `lib/net/lichess_login.dart`, account keys `lib/storage/lichess_token.dart`,
updates `lib/storage/update_files.dart` and `lib/storage/update_install.dart`.

## Screen

Opened by the gear at the right end of the top bar (`lib/app/top_bar.dart`,
tooltip names Ctrl+,) or Ctrl+, / Cmd+, (`AppKey.settings`). The Train tab's
gear opens the same dialog showing only the `Training` place. Engine rows are
also behind the engine pane's gear (`EngineSettingsView`), and the Expectimax
rows behind that tab's gear; all of them write the same `Settings` value.

A fixed 760×440 dialog (`settingsDialogWidth`/`Height` in `ui/theme.dart`):
title `Settings` with a close button (Esc), a `Search settings` field, a
180 px list of places with icons on the left, the chosen place's rows on the
right, and a footer `Changes save automatically`, replaced in the error colour
by the store's problem when a write fails. Search matches place names, row
labels and hints across every place; nothing found reads `Nothing matches
"<query>".` Each row is a label, an optional hint and one control (choice,
typeable number stepper, switch, secret field, button or shown text).

Places, in order:

- **Look** — `Board coordinates` (`Show` / `Hide`, default Show); `Piece
  notation` (`Letters (KQRBN)` default, or `Figurines`), hint is a live
  `1.e4 e5 2.Nf3 Nc6 3.Bb5` sample plus `· files keep the letters`.
- **Training** — `New lines per sitting` (0–1000, default 10), `Reviews per
  sitting` (0–1000, default 0; `0 = all lines`), `Move delay` (200–2000 ms,
  step 100, default 700), `Replay missed moves` (on), `Rate difficulty
  myself` (off; `Off: graded from your mistakes. On: 1–4 after each line.`).
  See [trainer](trainer.md).
- **Tactics** — `Accept other winning moves` (off; `Checks alternative answers
  at depth 14`). See [tactics](tactics.md).
- **Engine** — `Analysis engine` (typeable choice: `Stockfish 19 (built in)`
  plus engines registered in Engine tournament that can analyse), `CPU cores`
  (1 – this machine's cores; half of them until the user picks; hint `of N on
  this computer; half by default`), `Memory` (16–4096 MB, step 64, default
  256), `Lines shown` (1–8, default 3).
- **Repertoire** — `Opponent rating` (1100–2900, step 100, default 2200; the
  Elo replies, gaps and coverage are predicted for, shared with Expectimax)
  and `Cover replies met once in` (5–1000 games, step 5, default 50).
- **Expectimax** — the Expectimax tab's settings (`Method`, `Replies from`,
  `Fall back to Maia`, `Fall back to Maia under`, `Depth` (0 = no limit),
  `First move`, `Later moves`, `Search replies met once in`, `Engine depth`,
  `Evaluation`). See [generation](generation.md).
- **Files** — `Copy files from outside Documents when opened` (on; `into
  Documents/pgn_collections, so they can be edited`).
- **Accounts** — `Lichess`: the hint says where the account stands and the
  control is the one button it needs now (see Actions). `Personal access
  token` (a secret field) shows only while signed out or checking.
- **App** — `Version` (`2.1.0 · up to date · checked 3h ago`) with `Check
  now`; `Check for updates automatically` (`At startup and once a day`);
  `Download updates automatically` (hidden for a copy that updates by hand);
  while there is a release, a `Chess Auto Prep X.Y.Z` row (see Actions);
  `Previous update did not finish` with `Show log` after a failed install;
  `Licences` ▸ `View`; `Diagnostics` ▸ `Copy diagnostics`; `Log folder` ▸
  `Open` (`app.log, for a bug report`). Without an updater the first row is a
  plain `Version`.
- **Shortcuts** — every `AppKey` (`lib/ui/app_keys.dart`) as a row: the
  action, its keys, and where it works as the hint. Built from the same table
  the handlers bind and tooltips name, so it cannot drift.

## Actions

**Change a setting** — any control → `SettingsStore.update` shows the new
value at once and writes the whole of `settings.json`; writes in flight merge
so the newest value lands last. Display changes apply immediately; engine
cores or memory restart the engine; other engine and search values apply to
the next search or job. A failed write keeps the value on screen, shows the
problem in the footer, and the next change writes again.

**Log in to Lichess** — `Log in` → PKCE OAuth in the system browser: a local
callback server on port 8919 (another free port when that is busy), scopes
`preference:read study:read study:write` (writing is for Study's `Send to
Lichess…`), `state` checked on the way back; the browser
tab ends on a plain `Logged in.` / `Not logged in.` page. While waiting the
hint reads `Waiting for the browser…` with `Cancel`, or `The browser did not
open. Copy the link and open it.` with `Copy link` and `Cancel`. Signed in:
`Logged in as <name> · until <date>` (or `· personal access token`) with `Log
out`. Failures replace the hint in the error colour until the next attempt:
`Lichess said the login was declined.`, `No answer from the browser in five
minutes.`, `Could not open a port for the browser to come back to.`, `Could
not reach lichess.org — it needs a connection.`, `Lichess turned the login
away.`, `Lichess could not answer.`, `Logged in, but the account could not be
saved. Try again.` The explorer's `Log in to Lichess` uses the same flow
(`lichess_login_dialog.dart`).

**Use a personal access token** — paste into the secret field; on leaving or
submitting it is checked against `lichess.org/api/account` (`Checking the
token…`) → signed in, or `Lichess rejected that token. Check it was copied
fully and has not been revoked.`

**Log out** — no confirmation; `Logging out…`, every Lichess account key is
removed. Game-download usernames are not touched (they live in Tactics ▸ `My
accounts…`).

**Updates** — release builds check GitHub Releases 10 s after start and then
hourly whether 24 h have passed; development builds only on `Check now`
unless `CHESS_AUTO_PREP_RELEASES_URL` points at a fixture. The update row's
hint and button follow the state: `Available · installs when you close the
app` / `Install`; `Available on GitHub` / `Open releases` (manual copies);
`Downloading… 42%` / `Cancel`; `Downloaded and verified` / `Install`;
`Starting the installer…`; `Installs when you close the app. Linux packages
may ask for your password.` / `Cancel installation`; or a failure (`Could not
reach GitHub.`, `The download failed verification and was discarded.`, …) /
`Try again`. An automatic check that finds a new version asks once per run:
`Chess Auto Prep X.Y.Z is available`, `Release notes`, `Skip this version` /
`When I close the app` / `Update now` (manual copies: `Download the new
version from GitHub.` with `Skip this version` / `Later` / `Download`). `Update
now` keeps the dialog up as `Updating to Chess Auto Prep X.Y.Z` with the
download's progress, then closes the app the normal way (unsaved work is asked
about) and the helper installs and reopens it. A skipped version is neither
asked about nor downloaded again. Failed automatic checks are only logged.

**Copy diagnostics** — copies the version, platform details and the tail of
`app.log` (at most 32 KiB / 160 lines; `DiagnosticReport`) to the clipboard;
the hint reads `Preparing diagnostics…`, `Diagnostics copied.` or `Could not
copy diagnostics. Try again.` It reads no account preferences or chess data
and drops recognisable credential lines.

**View licences** — Flutter's licence page with every Dart package plus the
bundled components in `lib/app/bundled_licences.dart` (Stockfish, Hivemind,
Maia 3, ONNX Runtime and its notices, Inter, Source Code Pro, Noto Sans
Symbols 2, cburnett pieces, lichess opening names). A licence file that cannot
be read is logged and left out.

**Open log folder** — opens `<support>/logs` in the file manager.

## Data

- **`<support>/settings.json`** — one JSON object written whole on every
  change through an atomic replace; the last write wins. Top-level keys:
  `boardCoordinates`, `figurines`, `tournamentFinalPositions`, `engineCores`
  (absent = half the machine), `engineMemoryMb`, `analysisEngine`,
  `engineLines`, `engineThreat`, `copyFilesIntoDocuments`, `opponentElo`,
  `coverOnceIn`, `expectimax`, `explorer`, `puzzles`, `autoAdvance`,
  `acceptAlternativeAnswers`, `training`, `myGameSpeeds`, `updates` (switches,
  last check, skipped version), `workspaceLayouts`. Unknown keys are kept and
  written back. Several have no row and are set where they are used (explorer
  source and filters, puzzle filters, threat arrow, pane layouts).
- **Fail open** — settings never block startup. A file that cannot be read is
  moved into `<support>/recovery-quarantine/`, logged, and the app starts on
  the defaults. A symlinked `settings.json` is followed.
- **Lichess account** — SharedPreferences keys `lichess_access_token`,
  `lichess_auth_username`, `lichess_token_expiry`, `lichess_is_pat`. Plain preferences, not
  an OS keychain. An expired OAuth token or unreadable keys read as signed out.
  The token is never logged.
- **Log** — `<support>/logs/app.log`, one line per entry (`2026-09-19T20:31:04.123
  E start stockfish-linux: No such file`), appended across runs; a file past
  2 MiB at start becomes `app.log.1`.
- **Updates** — downloads go to `<cache>/updates/<tag>-<random>/`, hashed as
  they arrive and kept only when size and SHA-256 match; the armed helper's
  `install-requested` marker and the `reopen` marker sit beside the payload.
- Every board, engine job, explorer, search and trainer reads `Settings`
  through the one `SettingsStore`.

## Owner decisions

- Shape: search box, list of places, rows; kept compact (owner, 2026-09-21:
  "Option A is just so overwhelming to look at… make B compact"). A row exists
  only when something reads it.
- The gear at the right end of the top bar and Ctrl+, are the ways in; the
  mode menu lists modes only (owner, 2026-09-22).
- The app is dark only: no Light/System theme and no Appearance row (owner,
  2026-09-22).
- No dropdowns: choices are side-by-side buttons or typeable choice fields,
  numbers are typeable steppers; one CPU-cores knob, not cores plus threads
  (owner, 2026-09-06).
- The engine pane's gear and the Expectimax tab's gear edit the same values as
  their Settings places; copy is shared (`EngineSettingCopy`,
  `SearchSettingCopy`).
- Updates come from GitHub Releases only; `Update now` reopens the app on the
  new version.
