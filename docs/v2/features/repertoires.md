# Repertoire builder

Status: corrected by the owner (2026-09-21: this mode is the builder; decisions below)
Old code (oracle only): `lib/screens/repertoire_library_screen.dart`, `lib/features/repertoires/`,
`lib/widgets/chapter_list_body.dart`, `lib/services/repertoire_file_editor.dart`
Plan step: 3

## Purpose
Someone keeps and builds their opening material here: every repertoire they own, the chapters inside
it, and the moves, replies and gaps of the chapter on the board. There is no separate builder: a
repertoire chapter open in the workspace is editable, and reading one is the PGN Viewer's job. They
leave with a chapter that answers more of what opponents actually play.

## Screen
Reached from the mode menu as **Repertoire builder** (owner, 2026-09-22: the library and the builder are one mode, named for the building), and pushed as a picker by any mode that
needs a repertoire before it can work (Builder, Trainer, generation). No screenshot.

- **Toolbar heading** — `Your repertoires`, or `Repertoire recovery` in the recovery view.
- **`Open PGN file…`** (filled, reads `Importing…` with a spinner while a file is read), **`Create new
  repertoire`** and **`Paste PGN`** — all disabled while any catalog write is in flight.
- **`Recovery`** — only where the platform supports it (Linux); becomes `Back to library` with `Refresh`.
- **Search repertoires** — a search field, shown only once at least one repertoire or study exists.
- **Repertoire row** — an icon, the name, `{n} chapters · Modified 4h ago` (`just now`, `{n}m ago`,
  `{n}h ago`, `{n}d ago`, then a locale date), in the order the filesystem lists the folders.
- **Row actions** — `Browse chapters`, `Rename repertoire`, `Delete repertoire` as icon buttons;
  rename and delete are disabled while busy.
- **Studies section** — `Repertoires` and `Studies — custom tactics` headers appear only when the host
  asked for studies (the trainer's picker). Study rows show a chapter count and have no row actions.
- **Empty states** — `No repertoires yet` / `Open a PGN file or create a repertoire to get started.`;
  a search with no hit shows `Nothing matches "<query>".`
- **Failure panel** — replaces the list: `Could not load repertoires. Please try again.` with `Retry`,
  or `The folder may have moved, but its references could not be confirmed. Reload the library to
  recover this operation before making another change.` with **`Recover library`**.
- **Recovery view** — one row per deletion receipt: name and `Deleted 2d ago`, with `Restore`. A
  receipt whose files moved reads `Recovery files are missing or changed` and cannot be restored.
  Empty: `Recovery is empty` / `Deleted repertoires will appear here.` A failed restore prints `Restore
  failed. Your recovery files are retained. Refresh the list or choose another name.`
- **Chapter picker** — pushed by `Browse chapters`: the repertoire's name in the bar, `Search
  chapters`, `Add chapter`, and one card per `.pgn` file with `12 lines` or `12 lines · 4 chapters`,
  plus `Rename chapter` and `Delete chapter`. Empty: `No chapters yet` / `Add a chapter to start
  organizing this repertoire.`; no match: `No chapter matches "<query>".`
- **Course chapters** — a file carrying its own chapters lists them indented with their line counts; 3
  show, then `Show all N chapters` / `Show fewer chapters`. Search matches and expands them too.
- **Folder view** — tapping a repertoire replaces the list with `Organize your repertoire` / `Drag
  chapters into folders and lines between chapters. Right-click for more actions.`, a back arrow
  (`All repertoires`), the repertoire's name in the title bar, and **folder-view actions**: `Train
  repertoire`, and once a chapter is active `Read chapter`, `Train chapter`, `Build chapter` with the
  active chapter's name beside them.
- **Outline panel** — the folders, chapters and lines of the open repertoire, with drag and drop, a
  `Find a chapter or line` box, `Undo`, and right-click menus (`New chapter…`, `New folder…`,
  `Rename…`, `Move to folder…`, `Move to chapter…`, `Split into chapters…`, `Delete chapter…`, `Open`,
  `Train this chapter`, `Train this line`, `Audit this chapter`, `Generate lines into this chapter…`).
- **`Refresh library`** — the only entry in the overflow menu; refreshes the list, or the outline when
  a repertoire is open.

## Actions
**Open a repertoire** — tap a row → the folder view opens on its first chapter, found by walking the
folder and then its subfolders; the side to train comes from that chapter's `// Color:` line and
defaults to White → `Could not open that repertoire. Try again.`
**Browse chapters** — the list icon → the chapter picker; picking a chapter hands its file to the host,
a course chapter the file plus that title. Backing out without picking re-reads the library.
**Create** — `Create new repertoire` → a form: `Bring your lines. Start training.`, a name (hint `My
Sicilian`), `White`/`Black`, and `Import PGN` vs `Empty repertoire`. A picked file fills the mono paste
box and, if the name is blank, suggests the file's name and colour → `Open or paste a PGN with moves to
train.`, `Could not read that file.`, `Could not open that file. Try again.`, `A repertoire named "X"
already exists.` (with `Choose another name`), `Could not create the repertoire. Your input is still
here; try again.`, `The file may already be saved. Keep this draft and reload the library before
retrying.` An empty one reports `Created “X”. Add moves before training.`; one with moves opens into
its chapter, or into the picker when the import produced several.
**Import a PGN file** — `Open PGN file…` → the native picker; the file's name becomes the repertoire
name, illegal characters replaced by `_`, trimmed to 100 characters and suffixed ` (2)`, ` (3)` … until
free, else `Imported repertoire` → `Could not read that file.`, `That PGN has no moves to train.`,
`Could not import the repertoire. Please try again.`, `Import preparation failed. No repertoire was
published. Keep this draft and retry.` On success: `Imported “X”. Rename it from your repertoire list.`
**Paste PGN** — a dialog (`Add your moves now. You can rename the repertoire later.`, hint `1. e4 e5
2. Nf3 Nc6…`); the colour is inferred from the moves and the name is `Pasted repertoire` (+ a free
suffix) → `Paste PGN with moves to train.`, `Could not import. Your PGN is still here; try again.`
**Search** — filters names as you type; in the chapter picker it also matches course chapters.
**Rename a repertoire** — the pencil → `Rename repertoire` / `Enter new name for the repertoire:`.
Validation: `Please enter a name.`, `Names cannot contain < > : " / \ | ? * or control characters.`,
`Names cannot end with a dot or space.`, `That name is reserved.`, `That name is reserved by the
operating system.`, `Names must be 120 characters or fewer.`, `A repertoire named "X" already exists.`
The folder moves without replacing anything, and training schedules, history, move progress, the
mistake log and the designated-book paths are rewritten to the new path → `Could not rename
repertoire.`, or the recovery-required panel when the references cannot be confirmed.
**Delete a repertoire** — the bin → `Delete repertoire "X"?` / `Its files and training history will be
kept. Restore it from Recovery in the library.`, or, where recovery is unsupported, `Its files will be
moved to Chess Auto Prep recovery trash.` The whole tree moves to the recovery folder and its
references follow it → `Could not delete repertoire.`
**Restore** — `Restore` → `Choose a name for the restored repertoire:`, prefilled with the original
name; the same rules apply plus `A repertoire with this name already exists.` It refuses an existing
destination, verifies the recorded directory identity, replays the references and drops the receipt.
**Recover library** — the button on the recovery-required panel → replays the interrupted rename,
delete or restore from the journal. Any other catalog write is refused until it succeeds.
**Add a chapter** — `Add chapter` → `Name this chapter (e.g. a variation or system):` → the new file
opens at once → `That chapter already exists.`, `Could not create chapter.`, `Chapter creation needs
verification: <path>. Recovery: <path>. Do not retry.`
**Rename a chapter** — the pencil on a chapter card → `Rename Chapter` → the file is renamed inside its
folder → `Could not rename chapter.`, `A chapter named "X" exists`.
**Delete a chapter** — the bin on a chapter card → the contents are captured, then the confirmation,
then the file is quarantined beside its folder; the result dialog names the original, the retained copy
and the raw backup. Chapters never appear in the repertoire recovery list.
**Reorganise** — in the folder view: drag a chapter into a folder, drag lines between chapters, or use
the right-click menus to create folders, move, split a chapter into its course chapters, or delete.
Every edit offers `Undo`; undoing a move of lines into a new chapter returns the lines but keeps the
chapter it created, and says so.
**Hand off** — `Train repertoire` / `Train chapter` / `Train this line` open the trainer on that path;
`Read chapter` and clicking a line open the PGN Viewer at that file and game; `Build chapter` opens the
builder on the chapter, reloading it from disk.
**Refresh** — the overflow entry, and automatically on re-entering the mode (the list, or the outline
when a folder is open), so edits other modes made show up.

## Data
- `Documents/repertoires/<name>/` is a repertoire; each `.pgn` inside it is a chapter and nested
  folders are shelves. A stray `.pgn` directly under `repertoires/` is silently moved to
  `<its name>/Main.pgn` on every listing; `*_raw_games.pgn` sidecars, `.cap-pgn-history`,
  `.cap-repertoire-publications` and the generation-draft folder are never listed.
- A chapter file starts with a `//` preamble — `// <chapter name>`, `// Color: White|Black`, an
  optional `// Chapter: <course chapter>`, `// Created on <date time>` — then its games. Import expands
  variations into separate lines and splits a course of two or more chapters into one file each. The
  preamble, comments, NAGs and headers must survive a round trip.
- Deletion moves the tree to `Documents/.chess_auto_prep_trash/repertoires/<receipt id>`; the intent
  and completion journal lives in `<app support>/repertoire-mutations/`. Nothing is pruned, and a
  folder missing from its receipt stays listed but cannot be restored.
- A rename, delete or restore rewrites `repertoire_reviews.csv`, `repertoire_review_history.csv`,
  `repertoire_move_progress.csv` and `repertoire_move_attempts.jsonl` in Documents, keeps the prior
  text under `Documents/.cap-reference-history/<operation id>/`, and updates the designated white and
  black book paths; parked recovery paths drop out of the active books.
- The Builder, Trainer, Generation, Checks, the planner and the Viewer's `My books` tab open the same
  files; studies are read from `Documents/studies/`.

## Keep / Change / Drop
Keep — every item under Screen and Actions (34 items), read against the decisions below.

Quirks to rule on: a repertoire is a folder but a chapter file is what every other mode loads, so
"repertoire" means three things (folder, file, course chapter inside a file); a recoverable delete
exists only on Linux and the confirmation sentence changes elsewhere; chapter and repertoire deletion
use unrelated recovery stores and only the latter has a restore screen; the list is in filesystem
order with no sort control and the chapter count ignores subfolders; an import names the repertoire
after the file with no chance to correct it; a row tap opens the folder view here, a chapter in a
picker.

## Decisions (owner, 2026-09-21)
- **No separate builder mode.** The old builder's screen folds into this mode, which carries its name; `builder.md` is
  kept only as the oracle for the old outline and save behaviour. No Build switch: a move played on a
  repertoire chapter is saved, as it is today. The folder view is the outline column, not a screen.
- **One loop, as Chessbook does it.** The reading card gets a tab strip under the engine bar, `Moves`
  | `Replies` (`workspace.md`). Replies lists what Maia-3 predicts at the position on the board for
  the **Opponent rating** setting, most likely first: share, move, a tick when the chapter plays it,
  the word `gap` when the opponent plays it often enough and the chapter has no answer. Clicking a
  row plays it. The status line reads `Their replies · 2200 · 4 gaps · 87% covered` (`Our candidates`
  at our move). **Next gap** on the tab strip walks the chapter's gaps most-reached first: a missing
  reply lands on the position before it with its row marked, a dead end where the chapter stops.
- **Gaps come from Maia only**, offline and the same model the search uses. A gap is a position
  reached at least once in N games (**Cover replies met once in** setting, default 50) at the
  opponent rating with no move of ours. Reach is the product of the opponent's shares from the
  chapter root; our moves count as certain. Coverage is one minus the reach that ends in gaps. A
  reply that leads into a position another chapter of the same repertoire answers (or another line
  of this one) is not a gap; its row names that chapter (`Petroff`, or `this chapter`) where `gap`
  would stand (owner, 2026-09-22: "it shows moves missing even when they are present in other
  chapters"). The other chapters are read from disk once and again after any library change or
  chapter switch; draft chapters do not count as answers.
- **The side is asked once, not switched.** The reading card says `White · 12 lines`; there is no
  White/Black control on it. A chapter whose file has no `// Color:` line is asked `Which side is
  <chapter> for?` when it opens, and the answer is written into the file. Changing it later is
  `Play as Black` / `Play as White` in the Actions menu (owner, 2026-09-22).
- **Actions sits beside the mode menu** at the top left, and the list column starts at its
  narrowest (180 px); the divider widens it (owner, 2026-09-22).
- **Chapters have a visible root.** `// Root: 1. e4 e5 2. f4` shows under the chapter's name in the
  outline; `New chapter` offers `From here` with the board's moves, which is how a chapter for one
  opening is set up. An empty rooted chapter starts its board at the root.
- **A draft is a chapter.** `// Draft` in the heading shows it muted with `Proposed` in the outline.
  Its lines are read and edited in the same workspace; accepting them is moving them.
- **Lines move by drag and drop.** Ctrl-click and Shift-click pick lines; dragged onto another
  chapter they become lines of it, dragged onto a line they fold into it as variations; the line
  menu's `Move to chapter…` does the first by name. The target file is written first, against the
  revision it was read at, and the lines leave the open chapter only after that write landed.
- `Fill gaps from here…` is live (2026-09-22): see `generation.md`, "What was built".

## Decisions (owner, 2026-09-22)
- **The mode is `Repertoire builder`.** The library and the builder are one mode, named for the
  building. The settings gear is in the top bar's right corner, not in the mode menu.
- **Import has no form.** The old Create dialog is dropped whole. `Open PGN file…` picks a file and
  the repertoire appears in the list named after the file (the old app's naming rules), opened on
  its first chapter; the name is changed with the list's own rename. The side is the existing
  `Which side is <chapter> for?` question when the file carries no `// Color:` line. Paste is Ctrl+V
  on the library and a file dropped on the window does the same as `Open PGN file…`. Variations
  become lines and a course of several chapters becomes several chapter files, silently, as the old
  import did. `Create new repertoire` is the one-field name dialog `New chapter` already uses.
  Built 2026-09-22: a dropped file is left out, since the project carries no drop package; the
  side is inferred from the tree's shape (the branching side is the opponent, else the side most
  lines end on) when at least eight lines make it plain, and asked otherwise.
- **The Explorer tab** (`workspace.md`) is where the user looks up what masters and Lichess play
  before choosing their own move; Maia stays the only source of shares, gaps and coverage.
- **The outline stays as it is** (owner, 2026-09-22: "I like whatever the current UI is"): the
  collapsible repertoire list, the collapsible chapter column, a chapter's lines under it when
  clicked. No folder creation, moving or folder rows in the app; folders already on disk are read
  as they are today. The old `Organize your repertoire` view and its folder menus are dropped.
- **Next: the Explorer tab, import with no form and `Fill gaps from here…`**, built together
  (owner, 2026-09-22); the trainer waits.
- **Expectimax is a column of the Replies tab at our move.** `Our candidates` shows, beside the
  share, the expectimax value a run stored for that move, read from the `[%expectimax]` and
  `[%score]` tokens in the move's comment; a move no run reached reads a muted `not in tree`. The
  values ride in the comments, so they follow a line dragged from a draft into a real chapter.
  Nothing is computed while browsing (owner, 2026-08-21); `Fill gaps from here…` is the one way
  to get a value.
- **Deleted chapters** (built 2026-09-22, decided without the owner; the old `Recovery` view,
  read against the outline): a `Deleted chapters` link under the repertoire list swaps the list
  for every chapter in the repertoires' `.cap-pgn-history/` folders, under the repertoire's name,
  newest first, each with `Restore`. Restoring puts the file back under its name with its
  training rows; when that name has been taken since, the user names it (`Main (restored)`).
  A deleted repertoire is its chapters, so it comes back one chapter at a time.
- Left for later: training rows do not follow a line that changes chapter; the model's answers are
  cached in memory only; the trainer must skip draft chapters.
