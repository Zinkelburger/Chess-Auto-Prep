# Settings

Status: draft from the old app
Old code (oracle only): `lib/screens/settings_screen.dart`, `lib/features/settings/`,
`lib/features/updates/`, `lib/widgets/settings/`, `lib/widgets/accounts/`, `lib/infrastructure/`
Plan step: 13

## Purpose
Someone wants the app to behave differently everywhere — a labelled board, more cores —
or wants to connect an account, take an update, or find the log after something went wrong. They leave
with the preference saved and confirmed on disk, or with an honest failure and a `Retry`.

## Screen
Reached from the gear in every mode's toolbar (tooltip `Settings`); it opens on that mode's own page.
The title bar reads `Settings` with a close button (`Close settings`, Escape). No screenshot.

- **Find a setting** — a search box over the navigation, matching label plus hidden keywords (`cores`,
  `figurines`, `token`…); all terms must match. Nothing matches: `No matching settings`.
- **Navigation** (220 px, left) — `Accounts`, `Board & moves`, `Analysis`, one entry per
  mode that registered a page (`Training`, `Tactics`, `Game viewer`, `Repertoires`, `Tournament
  engines`, `Bughouse`), then `Data & storage`, `App`, `Shortcuts`. Below 760 px it becomes a
  horizontal strip of 170 px tiles above the content.
- **Save status line** — one per section: `Loading saved preferences…`, `Saving preferences…`, `Saved
  preferences could not be loaded.`, `Preferences were not saved. Your changes are kept for retry.`
  with `Retry`, or the section's policy sentence when idle.
- **`Accounts` ▸ Your chess usernames** — `Used to find your games for review and tactics. No login
  required.` Two plain boxes, `Lichess` (autofocused) and `Chess.com`; under a filled box, `Last
  downloaded Sep 4, 2026` or `Not downloaded yet`. `Save usernames` → `Usernames saved.`
- **`Accounts` ▸ Lichess login** — `Connect to import private studies and increase API limits.
  Optional.` Logged out: `Lichess: not logged in` with `Log into Lichess` and `Use a personal access
  token instead`. Logged in: `Lichess: logged in as <name>` over `Personal access token` /
  `Logged in until 2027-03-14` / `Logged in`, with `Log out`.
- **`Board & moves`** — policy `Saved display changes apply to all boards immediately.` `Board
  coordinates` (`Off` / `Inside the board`, the default / `Outside the board` / `Every square`), `Show
  legal moves` (`Show possible destinations when selecting a piece`, off by default) and `Piece
  notation` (`Letters (KQRBN)`, the default, or `Figurines (♔♕♖♗♘)`), over a live preview of the
  position after 1.e4 e5 2.Nf3 Nc6 3.Bb5 with the line written in the chosen notation.
- **`Analysis`** — `Shared by board analysis across the app. Game analysis depth is used by reviews and
  new builds.` Policies: `Saved engine changes apply to the next search or job.`, `Game analysis depth
  applies to the next job.`, `Saved prediction changes apply to the next position.` Every number is a
  typeable stepper.

  | Setting | Default | Range |
  |---|---|---|
  | CPU cores | 1 | 1 – logical cores of this machine |
  | Memory (MB) | 128 | 16 – 8192, step 16 |
  | Board analysis depth | 15 | 1 – 99 |
  | Game analysis depth | 15 | 1 – 99 |
  | Suggested lines | 3 | 1 – 10 |
  | Opponent rating for predictions (Maia) | 2200 Elo | 600 – 2400, step 100 |
  | Moves shown | 8 | 3 – 20 |

- **`Analysis panels and move tables`** — `Shared across views that show these panels. Study uses the
  board engine controls above.` Four switches, all on: `Engine continuations`, `Practical move scores
  (Expectimax)`, `Predicted move frequency (Maia)`, `Engine scores in move table`.
- **`Repertoire`** (v2, 2026-09-21) — `Opponent rating` (1100–2900, default 2200, step 100; what
  the Replies table, gaps and coverage are predicted for) and `Cover replies met once in` (5–1000
  games, default 50). The dialog grew from 300 to 340 px for the sixth place.
- **`Repertoires`** — `My repertoires`: `Compare your games with these books to see where you left your
  prep.` Owned by [repertoires.md](repertoires.md). **`Data & storage`** is the whole Databases page
  embedded; see [databases.md](databases.md).
- **`App` ▸ App updates** — `Stable releases from GitHub. Install after you finish your work.`
  `Installed version: {version}`, `Check for updates automatically` (on; `At startup and at most once a
  day while the app is open.`), `Download updates automatically` (on), `Check now`, and the status
  sentence: `Updates are checked against stable GitHub releases.` / `No newer release found.` /
  `Checking GitHub releases…` / `An update is available to download.` / `Downloading update… 42%` /
  `Update downloaded and verified. Choose when to install it.` / `Update could not complete: <error>`.
- **`App` ▸ About & open source** — `Chess Auto Prep on GitHub` (`Source code, releases, and issue
  tracker`), **`Open log folder`** (`Errors are written to app.log — attach it to a bug report`),
  `Open-source licenses` (`Includes Hivemind by aminwoo, the MIT-licensed bughouse engine`).
- **`App` ▸ Reset** — `Reset engine, analysis, display and database preferences. Your accounts, games
  and repertoires are kept.`, button `Reset settings…`.
- **`Shortcuts`** is a read-only `Action` / `Key` / `Where` table of every binding in the app, and the
  **Per-mode pages** are described in each mode's own spec; one not yet built shows `Loading settings…`.

## Actions
**Change a setting** — a stepper, switch or choice → the one changed field is written, read back, and
only then installed as the live value (display immediately, engine at the next search or job). A
failed write keeps the typed value as a draft, marks the section failed and offers `Retry`; unrelated
preferences are never rewritten.
**Set your usernames** — type and `Save usernames` → each site's name is stored and its "last
downloaded" date cleared, so it reads `Not downloaded yet` until the next download. An empty box means
"I do not play there". No validation, no network call.
**Log into Lichess** — a PKCE flow: a local callback server on port 8919
(`http://localhost:8919/callback`), the system browser opens `lichess.org/oauth` asking for
`preference:read study:read`, and the tile shows a spinner, `Waiting for browser…` and `Cancel`. The
browser tab ends on `Authorization Successful` — `You can close this tab and return to Chess Auto
Prep.` — or `Authorization Failed` — `Something went wrong. Please try again in the app.` Success
stores the token (365 days when Lichess does not say) and the account name. Denial, `Cancel` or five
minutes of silence returns the tile to `Lichess: not logged in` with no sentence; the explorer's copy
of this flow instead offers `Copy login link` and a failure sentence.
**Use a personal access token** — reveals an obscured box, `Create one at
lichess.org/account/oauth/token with the "Read preferences" and "Read private studies" scopes.`;
`Save token` → `Checking…` validates against the account endpoint → stored and never expires, or
`Lichess rejected that token. Check it was copied fully and has not been revoked.`
**Log out** — no confirmation; `Logging out…`, the token is revoked at Lichess best-effort, every
Lichess auth key is removed and the tile flips back. Usernames and downloaded games are untouched.
**Check for updates** — `Check now`, or automatically at startup and at most once every 24 h (polled
hourly) → the latest GitHub release is read (20 s timeout) → `GitHub update check returned {status}. Try
again later.` on a bad answer. A newer version announces itself once per tag in a dialog, `Chess Auto
Prep {version} is available`, with `Later` and `Release notes`.
**Download update** — automatic when the switch is on, else the `Download update` button → the release
asset streams to the cache with a live percentage, and its size and SHA-256 are checked: `Update
download size does not match the release.`, `Update download exceeds the expected size.`, `Update
checksum verification failed. The download was discarded.`
**Install when I close the app** — arms a detached helper: `The app will update and reopen after you
close it normally. Finish and save your work first. Linux packages may ask for your administrator
password.` `Cancel installation` disarms it, or `Installation cancelled, but the helper has not
stopped yet. Check again later.` A
failed attempt is reported once at the next start: `The previous update did not finish`, with
`Installer logs: <path>`. Flatpak, Windows portable, unmarked Linux bundles and development builds
hide every install button and say `This installation uses manual updates…` with `Open releases`.
**Open log folder** — opens `<support>/logs` in the desktop file manager → `Could not open the log
folder`. Beside it, the project page (`Could not open the Chess Auto Prep GitHub page`) and licenses.
**Reset settings** — asks `Reset analysis, board and data preferences?` / `Reset engine, analysis,
display, and database preferences to factory defaults?` → those four sections go back to the defaults
above → `Settings restored to defaults`, or `Some preferences could not be saved. Retry the failed
section.`

## Data
- Everything is SharedPreferences, one key per field, written individually and confirmed by rereading:
  board coordinates / legal moves / piece notation; engine cores, hash MB, board depth,
  MultiPV, moves shown, Maia Elo, panel visibility, explorer defaults; game-analysis depth (migrated
  from the old tactics-import depth key); the evaluation-database and designated-repertoire paths;
  update switches, last attempt and cached payload path.
- Lichess access token, refresh token, expiry, account name and the "is a personal token" flag are
  **plaintext SharedPreferences values**. The two site usernames and their last-download timestamps are
  separate keys; the OAuth account name is not the same value as the typed Lichess username.
- The log is `<support>/logs/app.log`, on Linux `~/.local/share/com.example.chess_auto_prep/logs/`.
  Only warnings and errors are written, one plain line each (`2026-09-19 14:42:10 ERROR Downloads:
  message`, the error, up to 12 stack frames), after a session banner naming the version and OS. It
  rotates to `app.log.1` at 512 KiB, so two files are all it ever occupies; write failures are swallowed.
- Downloaded update payloads live in the cache directory under `updates/`, with an install-request
  marker beside the payload and `last-error.txt` for the previous attempt. The same preferences are
  read by the board, every engine job, the explorer, generation and reviews.

## Keep / Change / Drop
Drop — `Appearance`: v2 is dark only; no Light or System theme (owner, 2026-09-22)
Keep — Find a setting
Keep — Navigation
Keep — Save status line
Keep — `Accounts` ▸ Your chess usernames
Keep — `Accounts` ▸ Lichess login
Keep — `Board & moves`
Keep — `Analysis`
Keep — `Analysis panels and move tables`
Keep — `Repertoires`
Keep — `Data & storage`
Keep — `App` ▸ App updates
Keep — `App` ▸ About & open source
Keep — `App` ▸ Reset
Keep — `Shortcuts`
Keep — Per-mode pages
Keep — Change a setting
Keep — Set your usernames
Keep — Log into Lichess
Keep — Use a personal access token
Keep — Log out
Keep — Check for updates
Keep — Download update
Keep — Install when I close the app
Keep — Open log folder
Keep — Reset settings

Quirks to rule on: tokens sit in plaintext preferences; "Lichess login" and "Lichess username" are two
unrelated settings storing two different names on one page; a failed OAuth in Settings says nothing
while the same flow elsewhere prints a sentence; logging out needs no confirmation; `Reset settings`
covers engine, display and database preferences but not accounts, updates or any per-mode
page; `Data & storage` is a whole other mode embedded in a pane; `Show legal moves` defaults off while
every other display aid defaults on; the update dialog can interrupt work at startup; nothing copies
the log or a diagnostics summary from inside the app.

## Questions for the owner
- Do tokens move to an OS keychain in v2, or stay in preferences with a warning?
- Should `Copy diagnostics` (log tail + version + OS, like the bughouse engine report) ship here, so a
  bug report is one button rather than a file manager?
- Is one flat settings screen still right, or do per-mode pages belong beside their mode?
- Should `Reset settings` also cover the per-mode pages?
