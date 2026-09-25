# Architecture renewal: a fresh app in `lib/v2/`

**Status: Partially implemented; correctness hardening planned (2026-09-24).**
The [data correctness contracts](#data-correctness-contracts) and
[hardening batches](#correctness-hardening-order) below are the next design and
verification work, not claims about guarantees already implemented. Existing
feature statuses record delivery; they do not certify the new contracts.

This is the third version of the rewrite plan, with its correctness design
revised on 2026-09-24. The first (Sept 16, commit `6d980630`) migrated the app in place; its
work log is [the evidence record](ARCHITECTURE_RENEWAL_EVIDENCE.md) and its
final text is at `449d5428`. The second (Sept 18, `58a8dfd8`) moved to a fresh
app. This version keeps that decision and fixes how the work is cut. Read this
file, not the earlier ones.

## Decision

Write the application again from an empty directory, `lib/v2/`, with its own
entry point, `lib/main_v2.dart`. The old app keeps working and shipping until
the new one replaces it; then the old code is deleted and `lib/v2/` moves up
to `lib/`.

The rewrite keeps what is not the problem:

- **The same Flutter project:** `pubspec.yaml`, platform runners, bundled
  engines and assets, `packages/`, packaging and release tooling.
- **The same user data:** every file and database keeps its format and
  location. Both apps can run on one profile at the same time.
- **Every mode.** Nothing is dropped: Tactics, Player analysis, Repertoire
  builder, Repertoire trainer, PGN Viewer, Study, Engine tournament, Bughouse
  lab, Databases, Repertoires, Players & prep.

Everything else is written again, including the algorithms. **No file is
copied from the old app.** The old code is reference material: read it to
learn what a feature does, then write it to [the definition of clean
code](#what-clean-code-means-here). For algorithms the spec is
[ALGORITHM.md](ALGORITHM.md), [DATA_INTEGRITY.md](DATA_INTEGRITY.md) and, for
Scid, `tools/scid_reference`; the old app stays installed as an oracle, so a
rewritten algorithm is checked by running both on the same input and comparing
where the result is deterministic. Copying would carry the debt in (a 71-field
config synced by hand, a third algorithm bolted on as an `extension`, five
copies of pool warm-up); the comparison test is the better safety net.

The product shape also changes: five modes that are each "a PGN with a board"
become one workspace (see [Product shape](#product-shape)).

## What the old app gets wrong

Measured on 2026-09-19; details in
[the Aug 21 audit](maintenance/2026-08-21-architecture-audit.md).

| Problem | Evidence |
|---|---|
| Too big for what it is | 227k lines in `lib/`, 165k lines of tests, 11 modes, 20 feature folders plus 108k lines of legacy `core/`, `services/`, `screens/`, `widgets/` |
| Five modes are one thing | Repertoires, Builder, Trainer, Study and PGN Viewer each have their own screen (1,875 / 1,478 / 973 / 1,101 lines), controller, move tree and save path for the same board-plus-moves task |
| God classes hidden by `part` | `_PgnViewerScreenState` 2,296 effective lines, `_RepertoireScreenState` 2,440, `GenerationSessionController` 1,414, `TreeBuildConfig` 71 fields synced by hand at 8 sites |
| Global singletons | `StorageFactory.instance`, `EvalCache.instance`, `ProbabilityService.instance`, `MaiaFactory.instance`, `EngineSettings.instance`, `AuditPersistence.instance` |
| Duplicated core code | Movetext builders, FEN parsers, PGN tokenizers and header parsers each existed 3–14 times; five hand-rolled staleness tokens |
| Two of everything mid-migration | `features/repertoire` and `features/repertoires`; `generate` and `generation`; `AppColors` and `design_system`; `core/` and `chess_core/` |
| Ad-hoc write safety | Whole-file writes without an expected revision and undo without one caused the lost-edit incidents |
| Ceremony agents must feed | A 3,060-line component map, three JSON debt ledgers, boundary scripts, an 8-minute suite |

## What the two earlier attempts taught

1. **Old and new code in one tree never converge.** Every step added adapters,
   bridges and ledgers; `lib/` grew from 219k to 237k lines before shrinking to
   227k with 112k legacy lines left and none of 20 feature folders finished.
2. **A plan that asks for evidence gets evidence.** 27 acceptance IDs and a
   4,620-line record consumed most of the effort. Now the only record is one
   status cell per step and the commit history.
3. **"Evaluate X" is a day lost.** Riverpod, Drift, Freezed, go_router, Dio,
   Sentry, Alchemist and Patrol were each proposed for trial; Riverpod was
   adopted, then retired. Every choice is made below; none is re-opened.
4. **Unbounded goals burn budgets.** "Finish the plan" ran for a week. A
   session gets one row of the step table and a hard stop.
5. **Scaffolding before features is where agents disappear.** A step that
   builds theme tokens, settings stores, lint rules and test harnesses has no
   screenshot to fail. Each step ends with something the product owner can see.

## Rules for the old app during the rewrite

- The old app is **frozen**. Fix data loss, crashes and release blockers only.
  No refactors or migrations; each one makes the rewrite chase a moving target.
- `v2` never imports or copies old `lib/` code. Read it, then write the `v2`
  version. What must stay compatible is data and protocols, not code: file
  formats, the SQLite lock the two apps share, and settings keys.
- A data-safety bug found while rewriting is fixed in `v2` and ported to the
  old app only when the old app can lose user data because of it.
- The old ledgers (`scripts/architecture_feature_debt.json`,
  `scripts/architecture_retirements.json`, `scripts/legacy_theme_consumers.json`)
  stay untouched until switch-over deletes them with the code they describe.

## Product shape

One **workspace**: a board, a move tree, an engine pane, an explorer pane and
one side panel, over one **document** (a PGN file with a revision from the
store). This is the Lichess model, where analysis, study and practice share
one board, tree and engine. Modes are what fills the side panel and what drives
the workspace:

| Mode today | In `v2` |
|---|---|
| PGN Viewer | Workspace + a game list (collections, filters) |
| Repertoire builder | One mode with Repertoires, named for the building (owner, 2026-09-21 and 22): the library list, the chapter outline and the Replies tab (Maia shares, gaps, Next gap) over the workspace; generation writes draft chapters, no tool panels |
| Study | Workspace + the same chapter outline + Lichess import/export and quiz markers |
| Repertoire trainer | A training session driving the workspace in quiz mode |
| Tactics | A puzzle session driving the workspace, plus a puzzle list |
| Player analysis, Players & prep | Opponent search, prep sheets, tournaments, people directory; games open in the workspace |
| Databases | Master games, TWIC, broadcasts, Scid export; games open in the workspace |
| Engine tournament, Bughouse lab | Their own screens, as today, on the same engine supervisor |

The workspace, move tree, engine pane and explorer are written once. A panel
receives the one or two owners it uses (below) and adds its own state; it never
has its own board or move tree.

Size target for the whole of `v2/`: under 60k lines of `lib/`, against 227k
today. The gate that matters is per step ([below](#a-step-is-done-when)); the
total is the sanity check.

### Workspace owners

The workspace is several small owners, not one. A panel takes the one or two
it uses. What lays panels out — the shell, `WorkspaceView`, the Actions
menu — takes the `Workspace` value (`workspace/workspace.dart`), which only
holds the owners below, so a new owner is one field there rather than one
more parameter on every layer.

| Owner | Holds | Never holds |
|---|---|---|
| `DocumentSession` | The parsed move tree as an immutable value, the cursor, how far the line is shown while a puzzle asks for the rest (`shownTo`), the store revision, dirty state, undo receipts | Engine output, explorer data, panel state |
| `EngineAnalysis` | The running engine job for the cursor position and its latest snapshot | Anything about the document |
| `Explorer` | The explorer query for the cursor position, its state and the session's answers (`ExplorerAnswers`, asked through `ExplorerDatabases`) | Anything about the document; a listed game being kept as a file (`GameFetcher`) |
| `Replies` / `GapHunt` | The Maia table for the cursor position / the walk over the open chapter and the gap `Next gap` marked; both ask one `ReplyModel` cache | A copy of the tree or cursor |
| `WorkspaceLayout` | Which panel is open and the split sizes | Data |
| `FileFilter` | The game filter's rules for the open file and which of its games pass them; cleared when another file is opened, pasted or closed | The games themselves |
| `FileTree` / `MyGamesTree` | The explorer's `This file` and `My games` trees, built off the UI isolate and dropped when their file changes | The document, the cursor |
| `WorkspaceRequests` (`app/workspace_requests.dart`) | The mode, the status line, and every cross-mode request that puts a document on the board or takes it off (a list's click, Open/Import/Paste, an explorer game, Close file), each answering a sealed `RequestResult`; the leave question goes through `ExitGuard`, the side question and the clipboard through `WindowInput` | The document, panel state, dialogs |
| A panel's owner (`GenerationRun`, `TrainingSession`, `HoleHunt`, …) | That tool's state, keyed to a document revision | A second copy of the tree or cursor |

An owner notifies only for what its listeners show. `DocumentSession`
notifies its own listeners when the document changes (another chapter or
game, an edit, a refusal, a flip) and `cursorListenable` when the cursor
moves; `anyChange` is both, for views of the position (board, engine,
explorer, replies, move note, comment field). A derived owner such as
`ChapterOutline` notifies when its output changes, not whenever its inputs
do. A list highlights its current row through `ui/selection.dart`, so a
cursor move redraws two rows, and builds its rows lazily
(`ListView.builder`). A `State` that reacts to an owner with more than a
rebuild uses `ui/listening_state.dart`, which follows the widget across
`didUpdateWidget`.

Split an owner when it has two jobs, which its fields and its listeners
show — never to get under a count. The old `PgnViewerController` (1,341
lines) is what this table prevents. A split whose second half only answers
the first's calls is a forwarding layer (rule 3): `Library` and the
`LibraryWrites` cut from it to pass a ten-field cap were merged back on
2026-09-22, because every `Library` command was `_writes.x()`.

Committed document changes have a separate owner from an active editor.
`storage/DocumentRepository` wraps the filesystem adapter and publishes typed
create/save/move/delete events only after success. `RepertoireCatalog` coalesces
those events into a committed listing; a change during a read invalidates that
read, and the next publication retains the whole change batch. Library search
and busy state do not invalidate the catalog. Books, training and repertoire
indexes consume it independently. A whole-file autosave already represented by the open
session does not restart a training sitting; a sibling mutation or a course
file save does reload the scope. Explicit refresh handles changes made outside this process.

`AppParts` is the composition root. `WorkspaceRequests` coordinates navigation,
including dirty-draft decisions and desktop file-open requests; request tickets
cancel superseded opens even when the latest request selects the current file.
`DocumentSession` owns the active editor, while `document_projection.dart` owns
file/section projection and `document_history.dart` owns held edits and board
undo. These helpers have no widget or persistence side effects.

`PendingWrites` belongs to the application, not to a mode. Accepted commands,
queued reviews, books and settings writes remain tracked after their screen or
progress owner is disposed. Closing disables new window input, pauses producers,
flushes the document and drains accepted persistence before stopping engines.
Failures and timeouts require an explicit close-without-saving choice. Training
commands remain ordered by their shared progress store across scope replacement;
failed commands retain their original timing, rows and stable operation id.
Training acceptance is journaled before waiting for a failed predecessor;
the queue can recover without the former screen, registry or process.
Book and settings snapshots keep their latest unsaved value for retry, including
after their presentation owner is disposed; loading cannot silently replace that
value. Existing dialogs and puzzle delays pause during close and resume when it
is cancelled. Books and settings use a directory lock plus a comparison with the loaded file before
atomic replacement; another instance's edit is reported instead of overwritten.

## Data correctness contracts

**Target design; implementation is tracked in the hardening table.** Keep the
shared workspace, pure chess code, concrete owners and existing storage formats.
Make correctness a property of a complete operation, including its reads,
dependent writes, recovery and publication. Directory boundaries alone cannot
establish that property.

### What DDIA contributes

*Designing Data-Intensive Applications* explains transactions, derived data and
end-to-end correctness; see the [first edition's final chapter](https://www.oreilly.com/library/view/designing-data-intensive-applications/9781491903063/ch12.html)
or [second edition chapter 13](https://www.oreilly.com/library/view/designing-data-intensive-applications/9781098119058/ch13.html).
The decisions below are our application of those ideas to this desktop app,
not prescriptions attributed to the authors.

| Idea | Decision for this app |
|---|---|
| Systems of record versus derived data | Identify which bytes cannot be reconstructed before defining caching or cleanup. |
| Transaction isolation | Specify which competing operations and reads must behave as if performed in sequence; test those histories. |
| The dual-write problem | A document change and its required reference changes have one recoverable operation boundary. |
| Materialized views | Catalogs, gap walks and indexes name their inputs and can be rebuilt from authoritative state. |
| Idempotence | Recovery and retry may execute again; their durable effects must not be duplicated. |
| Integrity versus timeliness | Preserve correct source data; allow explicitly stale derived views where safe. |

Kleppmann's [isolation tests](https://martin.kleppmann.com/2014/11/25/hermitage-testing-the-i-in-acid.html),
[dual-write examples](https://martin.kleppmann.com/2015/05/27/logs-for-data-infrastructure.html)
and [discussion of derived data](https://martin.kleppmann.com/2015/03/04/turning-the-database-inside-out.html)
explain the relevant failure modes. His coauthored
[local-first research](https://www.inkandswitch.com/essay/local-first/)
also informs retaining user-owned files and offline operation.
This design needs no distributed broker, global event store, new state framework
or new source-of-truth database. Use SQLite transactions where the existing data
already shares one database; use guarded file publication and recovery for the
formats that must remain files.

### Authority across the whole app

Authority is assigned per data set, not per directory or file extension.
Rebuildable does not mean cheap, and does not grant permission to delete.

| Area | Authoritative state | Derived or temporary state | Durable unit |
|---|---|---|---|
| Workspace, viewer, library, study | PGN bytes, preserved versions, required references | Parsed tree, filter, cursor, selection; an unsaved draft is explicitly separate | Scoped edit; compound rename/move/delete/restore |
| Books | Book definitions and membership | Expanded chapter set, counts | Membership edit; reference migration with its document operation |
| Repertoire training | Existing schedule, streak, history and attempt files; do not assume one can reconstruct all the others | Due queues, scope lists, lesson board | One rating and its required records; reference migration |
| Tactics | Puzzle PGN, review fields, analyzed-game markers; source games that have no other copy | Puzzle queue, current puzzle, mining computation | One analyzed game's puzzles and completion marker together |
| My games | Saved corpus, account identity and download configuration | Opening index, book comparison, displayed freshness | Corpus publication; freshness advances only after publication |
| Generation and checks | Accepted PGN edits, retained run artifacts, user choices | Search frontier, gaps, coverage, evaluations | Job-specific checkpoint; publish accepted output against its expected destination |
| Players and prep | Player identities, corpus generations, prep notes and groups | Statistics, opening trees, opponent analysis | Corpus plus manifest; one saved prep edit |
| Databases | Installed dataset identity and manifest; irreplaceable game rows in mixed databases | Position indexes, downloadable caches | Completed import unit or new dataset generation |
| Engine tournaments | Run configuration, finished games and their outcomes | Live board, crosstable | One completed game and its outcome |
| Bughouse | Saved matches and promised saved analysis, including provenance | Live search, partial move scores, archive queries | Completed analysis entry or match checkpoint |
| Settings and accounts | Existing settings and credential stores | Form state, connection status | Settings update with conflict checks |
| Navigation and layout | Persisted preferences only where the feature already saves them | Mode, focus, pane sizes, pending open request | No independent document writes |

The player, database-management and tournament rows specify contracts for their
future implementation. They do not authorize extra product features or change
the owner's approved mode specs.

### Consistency the user can observe

| Operation or read | Required guarantee |
|---|---|
| An edit on the active board | Read the current draft. Show its save state separately; another mode does not imply a save. |
| A successful durable command | Its required writes are complete. A dependent command waits for that result and reads a coherent source snapshot. |
| Training after an accepted rating | Wait for all relevant preceding writes, even across multiple scope reloads; a failed rating remains recoverable. |
| Rename, move or committed undo | Document and essential references form one operation; readers do not treat an intermediate state as complete. |
| Catalog, gaps, explorer, book check | May refresh asynchronously. Keep old content only when safe and visibly stale; navigation validates references before using it. |
| Engine or network response | Publish only into the request and input version it answers. |
| Reopen after a crash | Recover affected operations before exposing writable state or training against it. |
| External edit or sync conflict | Revalidate; preserve ambiguous versions and report a conflict. App locks do not control other programs. |

An in-process notification is a wake-up hint, not durable evidence of a commit.
A restart or newly mounted consumer must reconstruct current state without
having heard earlier notifications. Freshness tokens local to one process are
not global revisions and are never trusted across restarts.

### Where the responsibilities live

Extend existing owners as each batch needs them. These are responsibilities,
not a request to create an interface or class for each row.

| Existing area | Responsibility after hardening |
|---|---|
| `chess/` | Pure transformations, reference mappings, scheduling and validation; no I/O or notifications. |
| Feature command owner, such as `Library` | Interpret intent and construct the complete operation, including required dependent changes. Never repair references in an optional UI listener. |
| `storage/`, including relocation and guards | Check revisions, lock, stage, preserve, commit and recover; typed terminal outcomes. |
| `DocumentRepository` | Announce committed outcomes with affected references and revisions; never announce a partially completed semantic command as complete. |
| `DocumentSession` / saver / history | Own the active draft, edit policy and receipt-based undo; keep draft operations distinct from committed operations. |
| Training persistence / `PendingWrites` | Own accepted writes, their barriers and retry material across presentation lifetimes. |
| Catalog and derived owners | Observe explicit input versions, invalidate affected results and reject obsolete completions. |
| `AppParts`, requests and exit guard | Compose owners; coordinate startup recovery, navigation and shutdown. No chess or file-format rules. |

Keep the import table below. A shared storage operation takes concrete data
describing references and writes, not a dependency on the Books or Trainer UI.
Extract shared mechanics only when two concrete operations need the same rule.

### Commit and recovery protocol

A single scoped PGN edit remains one guarded replacement. A transaction already
inside one SQLite database uses that database's transaction. The following
protocol is for a command that must update multiple authoritative resources.

1. **Plan.** Capture intent, affected resources, expected revisions and explicit
   reference mappings. Keep expensive parsing, network calls and engine work
   outside commit locks. Assign an operation ID before retryable durable work.
2. **Validate under the shared guards.** Recheck the read set, destination
   collisions and collection assumptions. A folder operation protects namespace
   membership, not just the files found during an earlier scan. Overlapping
   operations use one documented, acyclic lock order compatible with v1.
3. **Prepare durably.** Preserve required before-content and stage after-content.
   Record a versioned recovery manifest with the operation ID, allowed paths,
   expected before/after identities or hashes and the required steps. Preparation
   failure changes no authoritative content. Recovery data contains no secrets.
4. **Apply.** Once durable commit intent is recorded, complete the operation or
   leave a recoverable obligation. Do not abandon it because a widget was
   disposed or a navigation ticket changed. Hold conflicting managed reads and
   writes behind the operation boundary.
5. **Finish.** Confirm the required steps have their intended outcomes and
   persist completion before returning success. Produce a receipt with the
   resulting revisions and inverse information. Release guards before invoking
   UI listeners. Refresh derived data separately.

One storage entry point acquires the operation's guards; the participating
storage routines must not recursively acquire the same locks. Drain preceding
accepted work before taking guards it needs. Never wait for the entire pending
registry from inside one of its own tracked operations.

The manifest is recovery metadata; the existing files remain authoritative.
Multiple file replacements are not one atomic filesystem operation. Cooperating
readers see a coherent boundary because they use the same guards and recovery
gate. Arbitrary external programs may observe intermediate bytes; this design
does not claim transactional isolation against them.

For example, rename course section A to B while a book includes only A:

| Point | Durable state | What the app may claim |
|---|---|---|
| Before preparation | PGN names A; book names A | A is committed. |
| Prepared | Before/after versions and the A-to-B mapping are recoverable | Rename is pending; cancellation before commit intent can still leave A. |
| Interrupted after PGN replacement | PGN names B; book still names A; intent remains | Recovery required; affected readers cannot treat this as a complete rename. |
| Recovered and completed | PGN and book both name B; completion is durable | B is committed; views refresh from that result. |
| Undo requested | Receipt expects the completed participants | Validate all participants, then apply B-to-A as a new operation. |

Training rows stay unchanged for this section rename because their file path
and line IDs stay unchanged. A file rename additionally includes the training
path mapping. Each operation names only the participants it actually changes.

Recovery reuses the operation ID. For each step it distinguishes: still at the
expected before-state, already at the intended after-state, or changed by
somebody else. Apply the first once, accept the second, and preserve/block the
third. A lost acknowledgment is an unknown outcome, not permission to create a
new operation and append another rating. Where legacy formats lack operation
IDs, staged replacement plus expected hashes and retained receipts must prove
whether a write landed; do not blindly replay append/increment instructions.

Startup checks pending manifests before affected reads. The same gate is needed
at later reads/mutations because another app process can fail after startup.
Unrelated data can remain usable. Malformed/unknown-version manifests produce
an explicit recovery-required state, never an empty pending list. Retain recovery
material until completion is durable; backup retention cannot remove content
still needed by a pending operation or valid undo receipt.

Required application states are `queued`, `preparing`, `applying`, `committed`,
`rejected` (nothing changed), and `recoveryRequired` (completion needs resolution).
An ordinary typed rejection is different from an exception whose durable result
is unknown. Cancellation before commit intent can reject the operation; after
intent it stops the caller waiting, not the obligation to finish safely.

### Identity and undo

Keep the existing path/section references and persistent `LineID` format during
coexistence with v1. A content hash identifies a version, not the enduring
identity of a document: two copies can have identical bytes and independent
histories. Use one implementation of descendant membership and reference
rewriting for books, training and recovery.

A supported rename/move produces an explicit old-to-new mapping. Copy creates
a separate document; delete moves content into recovery; restore validates the
destination before restoring references. Preserve line IDs when identity is
preserved. Cross-file line migration must state whether progress follows and
how collisions are handled before that feature's deferred scope is implemented.
Do not infer an external rename solely from matching content or display names.

Before relocating an actively trained file, stop accepting ratings against the
old reference and drain already accepted ones, then capture the migration's
read set. Resuming uses the new reference. Include a test where a first-ever
rating has no existing row: row-conflict detection alone cannot stop an old
path being recreated after a move. A reused path is not permission to attach an
old session to a new document. Supported v1 writers must satisfy the same
ordering contract before coexistence is certified.

A training command carries the persisted source observation captured with its
input, including native file identity as well as content hash. Under the shared
recovery domain, validate that observation before publishing any training file;
a first attempt or history-only write needs the same protection as a rating.
Course sections loaded from the same file must agree on that observation. The
open draft can still supply training lines, anchored to its persisted source;
an acknowledged own save may refresh future commands only from its proven
before/after receipt. Already accepted commands retain their original input.
PGN save and undo pause training input and settle those accepted commands before
replacing the source; the hold lasts through receipt and displayed-text adoption.
A failed training write blocks publication while preserving the PGN draft and
the current lesson. Closed-source Library writes and exact retries use the same
barrier. An ordinary optimistic save cannot renew stale training authority by
adopting an unrelated equal-content file.

`TrainingProgress` derives accepted rows against a private projection of earlier
accepted changes; displayed progress advances only after commit acknowledgement.
`ProgressFiles.enqueueWrite` and `enqueueAttempt` persist those frozen rows or
answers before `commit` waits for predecessors. A missing predecessor intent is
an unsaved acceptance, retained for ordered retry. A known optimistic conflict
is refused before enqueue; a conflict arising after durable acceptance preserves
the command and requires recovery.

`TrainingWrites` owns the ordered private `Support/training-writes/` queue.
Queued intents recover forward. At the head, one command captures all four
training files as exact nullable byte snapshots, including unchanged files and
torn historical attempt bytes. A committing record binds the complete before/
after plan to the frozen command; replay validates every participant and source
before publishing anything. Completion replaces full snapshots with a compact
receipt retaining command, order, profile and source proofs. An exact completed
retry acknowledges that receipt without replacing subsequent data. Native old
journal copies remain admissible only with a verified forward transition to the
current receipt.

Recovery inspects all protocols before replay. Simultaneously pending training
and namespace operations have no established ordering and block access. Normal
access drains training before a new structural operation; accepting another
training command can validate its projected predecessor state without publishing
that predecessor. V1 accepts only strictly validated completed training history
and refuses every pending or unknown training journal before its own recovery.
Completed receipts are retained and scanned, so per-command/read cost still
grows with receipt count; retained native previous copies can also keep old full
snapshots. Native reads batch up to 32 candidates with a 16 MiB byte budget
(one oversized record is allowed), while every record is still validated. A
warm Linux measurement with 5,000 minimal compact receipts reduced median
inspection from 467 ms to 153 ms; four normal command scans still cost about
0.52–0.61 seconds before source reads and publication. This does not certify
long-running training-history scale.

Relocation completion and recovery flush both endpoint directories and their
containing entries before rewriting references or retiring the recovery note.
A flush failure leaves the note and reports an unresolved operation. Directory
flushes are verified on Linux; the existing Windows adapter skips unsupported
directory flushes, and macOS durability remains unverified.
The legacy v1 Windows/macOS training adapter still uses an explicitly selected
content-only check; it does not detect equal-content path reuse. Native object
IDs also do not establish a history of arbitrary external unlink/recreation
when the filesystem reuses an ID. Supported moves and recoverable deletes keep
the original object, which is the identity boundary exercised here.

Draft undo changes only the draft. Committed undo is a new guarded inverse
operation covering all required participants. If any expected participant has
changed, reject before applying the inverse and keep the receipt. Redo, where
supported, obeys the same rule. Undo does not silently discard training performed
after a rename or restore a book definition over someone else's edits.

### Durable work and job lifetimes

`PendingWrites` becomes an app-lifetime registry of individual obligations,
not just futures associated with disposable owners. Each entry retains its
operation identity, affected resources, typed result and retry/recovery material.
A successful unrelated write cannot clear its failure. Read barriers outlive
all the view replacements that wait on them. Persistent recovery is the store's
job; an in-memory registry alone does not survive a crash.

Distinguish accepted in memory, durably prepared, and committed. Only committed
is shown as saved. Preserve failed drafts/outcomes for retry or explicit discard;
do not dispose their last copy when a scope or mode changes. Replacing unsent
autosave drafts is allowed; coalescing distinct training ratings is not.

Every background job captures immutable input versions and configuration.
Generation publishes against its destination revision. Mining checkpoints one
game with its completion marker. Downloads advance freshness only after corpus
publication. Database importers publish completed units/generations. Tournaments
save completed games before counting them as durable results. Bughouse separates
partial scoring, complete scoring and saved scoring, and retries missing work.
The concrete job owns its checkpoint format; shared code only manages lifetime,
resource budgets and progress delivery.

Bughouse match checkpoints retain the exact accepted snapshot in `PendingWrites` and stop
before another game after a publication failure. Final completion includes confirmed
engine exit. `match.json` remains the existing authority; v2 repairs its deterministic
`games.bpgn` export on reopen only from supported valid JSON, under a per-match lock.
Read-only inspection never invokes that repair. V1 reads both formats but does not
repair exports or share the v2 match lock; simultaneous cross-app match editing is
not covered. Analysis saves retain frozen entries after owner disposal and reuse one
SQLite history ID across lost acknowledgments, without replacing newer current rows.
Uncommitted analysis and checkpoints that never reached JSON remain RAM obligations;
this tranche makes no crash-survival claim for those bytes or Windows/macOS guarantees.

The H5 generation owner now distinguishes computed results from acknowledged
publication. `FillGaps` retains one run id/tree text and ordered Finds transaction,
then shows completion only after both succeed. Failed batches remain retryable
through owner replacement; drafts freeze their timestamp/path/text and compare
an uncertain created file before ever choosing another destination. Native tree
publication is create-only or exact-byte acknowledgement under the document
recovery domain. The registry is app-lifetime retention, not a durable spool for
unfinished computation; only committed artifacts are promised after restart.

The implemented download publication path freezes site, username, returned PGNs
and fetch time in `DownloadSaves`. Its per-corpus `PendingWrites` obligations
outlive the screen and retry in acceptance order without another HTTP request.
`GamesCache.keep` returns `GamesKept` only after the corpus and its `.fetched`
note are acknowledged; failures return `GamesNotKept`. Exact retries deduplicate
by site game ID, or by trimmed PGN text when no ID exists. Account freshness is
written afterward, bound to the captured username and serialized with username
changes; an unacknowledged preferences value is not exposed as a saved date.
Reviews consume persisted corpus snapshots. Unavailable accounts retain the
last names and block new downloads. Any owner's unresolved username obligation
also blocks admission until the shared account resource settles successfully.
Unavailable corpora remain distinct per-site errors with read retry, rather
than empty results or a completed review.

This download tranche has an explicit restart boundary: accepted HTTP results
are retained **in memory** until corpus publication, with no durable enqueue
journal. They survive owner disposal and an ordinary failed-write retry, but a
process crash before publication can lose that response. Once published, the
corpus survives restart even if its freshness note or account timestamp fails;
reopening and retrying an already published batch does not append it again.
Corpus publication and freshness are separate writes, not one transaction.
On restart the old freshness remains eligible for refetch; deduplication makes
refetch safe when publication actually landed before its acknowledgement was
lost. No persistent HTTP spool is required by this boundary. This tranche does
not complete H5's mining, generation or bughouse work, or certify Windows/macOS
durability.

The implemented mining checkpoint owns one game's frozen puzzles and completion
marker in `SetAdditions`. An app-owned `PendingWrites` obligation retains the
accepted result and its added count; Retry saves that result without another
engine pass, including after the reviewing owner is disposed. Completion scans
read the persisted tactics PGN rather than an unsaved editor preamble. When the
set is open, the session saver remains its writer; a failed/conflicted draft
stays visible and is not discarded to manufacture a successful checkpoint.
A retry confirms the specific appended puzzles and solutions, not only their
completion marker or position. Removing or replacing an accepted puzzle leaves
the checkpoint unresolved; unrelated review metadata may still be edited.
Closed-set writes hold the document-access barrier so an overlapping open reads
the completed file. An exact published checkpoint can resolve a lost
acknowledgement without adding its puzzles again or resetting its added count.
Accepted mining results remain **in memory** before PGN publication. A crash
before publication can require recomputation; after publication, the puzzles
and completion marker restart together in the same PGN replacement. Every review
exit awaits engine cleanup; a failed exit acknowledgement remains a visible
failure with the already saved puzzle count. Startup failures are visible, and
disposal shares one cleanup attempt with the running review, including when an
engine finishes starting after disposal.

The engine supervisor owns each process through startup, active requests, stop
and confirmed exit. Responses carry request identity; buffers and work queues
are bounded. Finite operations have deadlines, while continuous analysis has an
explicit stop. Retries release failed processes. Stop/dispose also accounts for
an engine that has been requested but has not finished starting.

The UCI implementation now starts its finite deadline with the request's `go`,
including the first request. `EngineSupervisor.start` accepts `finitePatience`
(default ten minutes); callers with unusually deep searches can supply a larger
budget. Continuous analysis remains uncapped until stopped. A finite deadline
reports failure even after partial output; an explicit UCI stop waits up to five
seconds before terminating an unresponsive process. The supervisor owns UCI and
Hivemind startup through confirmed native exit, including disposal during spawn
or handshake. Closing stdout alone does not confirm exit. Hivemind's active-search
stop budget is unchanged by this increment.

Shutdown rejects new commands, stops/checkpoints producers, resolves drafts,
drains accepted writes, and then releases engines and stores. A timeout is not
success. Explicit close-without-saving may abandon uncommitted drafts, but it
does not erase recovery information for a partially applied operation.

### Derived views and coherent reads

An index or analysis result names its complete inputs: relevant document
revisions, corpus fingerprint, book membership version, settings and engine/model
version where applicable. Capture a coherent source snapshot using existing
guards/transactions, or validate the entire read set before publication. Checking
each file once at unrelated times is insufficient for a multi-file invariant.

Committed changes identify affected resources and reference mappings. Catalog
batches retain the relevant changes while coalescing notifications. A projection
publishes only if its captured inputs still match current inputs; cancellation
also stops wasted work, but cannot replace that check. A missing event after a
crash is repaired by rebuilding from source, not by assuming the view is current.

The active editor provides a draft overlay where the product promises immediate
feedback. Persisted views never mistake that overlay for a committed revision.
After a required write, dependent actions wait for the appropriate barrier or
read the committed source directly. They do not use a known-stale gap walk or
membership expansion to authorize a mutation.

Invalidate by affected inputs: a sibling deletion recomputes gaps, a membership
change recomputes the book scope, a cursor move does neither. Keep pure reusable
indexes keyed by source version; bound cache size. A failed rebuild may leave a
labelled old view, but its unavailable source must not become an empty success.

The first H4 increment captures complete repertoire membership and native PGN
revisions under the recovery domain, parses one file at a time, then validates
the entire set before publishing. Catalog and shelf retain their last complete
snapshot on failure. Gap navigation validates its captured answers again before
using them. The book comparison includes present or absent downloaded PGNs in
the same final file fence and checks synchronous account and committed-selection
revisions afterward. Unreadable accounts and corpus files are explicit failures;
book selection drafts remain editable but cannot certify a committed comparison.
Library, reply, repertoire-tree and game-comparison views expose unavailable
inputs and Retry; stale derived actions cannot be activated by mouse or keyboard.

The next H4 increment joins native `books.json` and all four training-file
proofs to that same final fence. `BookSnapshot` pairs immutable membership with
its exact native source, including absence; an unacknowledged write cannot
advance the owner's committed proof. `TrainingReadSet` records the same bytes
used to decode progress. Fixed profile participants stay bound to the configured
and pinned canonical roots, checked again after the last native observation.
`ScopeReader` in `features/trainer/training_scope.dart` captures complete fresh
membership; missing or unreadable included chapters refuse the whole scope.
The Trainer validates that snapshot with book/progress inputs, then checks local
editor, accepted-write and cancellation authority before publishing. Single-chapter
training retains the intentional draft overlay with its persisted source proof.
Explicit book-scope and comparison Retry refresh native membership, first
retrying a retained failed selection write when necessary. Even no-book and
no-account comparisons validate the inputs supporting that empty result.

The repertoire tree uses the same native book/shelf fence when inputs change,
then projects cursor movement synchronously from that validated pair. Its Retry
also resolves a retained failed selection write. `MyGamesTree` captures all
configured downloaded corpora, including absent files, checks account admission
and a final native PGN fence, and withholds stale answers and keyboard actions.
The optional SQLite archive captures its schema and exact selected rows in one
read transaction. Its immutable proof names the configured/canonical database
path, selected collections, absence, and a logical corpus fingerprint. The final
PGN recovery guard validates that proof through a fresh SQLite transaction,
including WAL commits, before publishing. Database/WAL/SHM bytes are neither
copied nor hashed. This is a logical selected-corpus proof: an identical logical
replacement remains valid, and no physical file-generation identity is claimed.
An unreadable optional archive still produces explicitly labelled downloaded-only
results; a previously captured archive that changes during a build refuses the
whole result and offers Retry.

Catalog admission exposes one affected-resource delta per input revision while
retaining the complete batch for final listing publication. Scoped native fences
include directory membership and absence, so unrelated repertoire changes do
not restart gaps, training, tree or book comparisons. Nested chapters use their
top-level repertoire boundary. Cursor movement projects an already-validated tree
without rereading native inputs. A whole-file save may preserve a live lesson only
while its write guard is held and only when the editor adopts that event's exact
committed native revision before resuming; an outside writer or failed adoption
forces reload. Committed downloaded-corpus edits also invalidate MyGamesTree at
the repository boundary, before download timestamps or later UI notifications.

H4 remains in progress pending combined verification and independent review.
An owner revision proves an observed or accepted local selection, not an
unobserved external edit to its backing file.

### Compatibility, diagnosis and acceptance

The promise that v1 and v2 can share a profile remains. Match both lock identity
and lock order, including v1's repertoire domain guard. Locks alone cannot teach
v1 to recover a new v2 manifest. Before enabling a new compound-write protocol,
prove that both supported applications recover or refuse affected access after
either crashes. A narrowly scoped v1 data-safety fix is allowed by the existing
freeze policy. Do not enable the protocol while this compatibility gate fails.
An unsupported older binary or arbitrary external tool is outside that guarantee.

Keep public formats and paths compatible. New private recovery metadata is
versioned and validated; unknown versions are preserved. Tools/MCP writers must
use the compatible guarded protocol or be handled as external writers with
revision validation and refresh. A filesystem watcher is only an invalidation
hint, never proof of a coherent snapshot.

Log operation/job ID, affected resource, expected/resulting revision and phase,
without credentials or unnecessary user content. Report the same failure in the
UI with a usable retry/recovery action. A read-only integrity check should find
unfinished operations, dangling references and mismatched derived versions;
repair reconstructs only disposable derived state automatically.

The H6 read-only report now inspects strict settings and publication stages,
concrete native recovery owners, book selectors, generated v4 formats and
bughouse JSON/export agreement. It is reachable from Settings and unavailable
startup settings. Checks preserve profile bytes and directory membership;
unknown recovery metadata skips dependent work, and diagnostics exclude source
bodies. Generated format validation covers visible Documents folders without
claiming source freshness; match checks are individually locked observations.
There is no automatic repair, credential check or general database audit in this
tranche. Native inventory and owner/widget checks, independent review, analyze/lint
and headless Linux startup-failure/report/recheck plus normal Settings entry
checks passed. Both retained match-stage false-clean cases were reproduced
before the fix. Windows/macOS integrity behavior remains unverified locally.

The H6 credential tranche distinguishes an unavailable read from signed out and
blocks authentication changes until a successful read retry. Malformed cached
credential values explicitly require repair and restart because the legacy
desktop preferences backend itself caches them; no false reload guarantee is
claimed. Shared preference
credential operations serialize, including expiry removal, and unacknowledged
cached grants are withheld from HTTP clients. Save retry keeps the exact grant;
public requests can deliberately fall back to anonymous access. Authenticated Lichess client diagnostics
redact transport and parse payloads, including study/game downloads and Explorer. Existing plaintext v1 keys remain unchanged:
this does not certify crash-atomic multi-key writes or concurrent v1/v2 profiles.

| Proof | Observable invariant |
|---|---|
| Rename section, then undo while its book is active | Name, membership and training scope agree at each completed boundary. |
| Hold a rating write; trigger two scope reloads | Neither reload exposes progress predating the accepted write as current. |
| Delete/import a sibling that answers a gap | Gap and Replies views converge to the committed repertoire without reopening the chapter. |
| Select nested chapters, then remove their repertoire | No descendant remains included by a stale explicit selection. |
| Kill a worker after each durable step; reopen twice | Required state is recovered or blocked; retry duplicates no records. |
| Fail an analysis save; fail an engine midway and retry | Unsaved is visible; incomplete scores do not count as finished. |
| Disable puzzle auto-advance during its delay | No scheduled advance occurs afterward. |
| Compete v1, v2 and another isolate; inject an external edit | Managed operations serialize; incompatible changes are preserved and reported. |
| Drop a notification; rebuild a view from source | The view reaches the same result as a fresh derivation. |
| Repeatedly open/close modes and jobs | Process, subscription and queue counts return to their documented baseline. |

Use real temporary profiles for storage/restart tests, controlled completions
and fake time for concurrency tests, and production `AppParts` wiring for the
user sequences. Add generated operation sequences against a simple reference
model where interactions justify them. Domain algorithms use specification cases
and deterministic v1 comparisons where v1 is a valid oracle. Measure representative
large corpora and establish performance budgets before calling scale verified.
State the supported filesystem/platform fault model; process-kill tests alone
do not prove every device survives power loss.

## Layout

```text
lib/main_v2.dart          entry point: flutter run -t lib/main_v2.dart
lib/v2/
  app/                    composition, window, mode menu, cross-mode requests
  ui/                     theme tokens and shared controls
  diagnostics/            the log facade every other folder reports through
  chess/                  pure Dart: PGN, positions, moves, evaluation, generation
  storage/                PgnDocumentStore, SQLite stores, settings, credentials
  engines/                UCI supervision, pools, analysis streams
  net/                    Lichess, chess.com, US Chess and other clients
  workspace/              board, move tree, engine pane, explorer, side-panel host
  features/<mode>/        one folder per mode: panels, sessions, lists
test/v2/                  mirrors lib/v2/
```

Allowed imports:

| From | May import |
|---|---|
| `chess/` | Pub packages without Flutter or `dart:io` |
| `storage/`, `engines/`, `net/` | `chess/`, pub packages, `packages/` |
| `ui/` | Flutter only; no feature, storage or engine code |
| `diagnostics/` | Pure Dart, so `engines/` can report from outside Flutter; nothing else in `v2` |
| `workspace/` | `chess/`, `storage/`, `engines/`, `net/`, `ui/` |
| `features/<mode>/` | `workspace/` and everything it may import; never another mode |
| `app/` | Everything in `v2` |

Every folder except `chess/`, which stays pure, may also import
`diagnostics/`. `dart:io` is for `storage/`, `engines/`, `net/` (sockets:
the Lichess login listens on a loopback port) and `app/`; files are written
only in `storage/`. Nothing in `v2` imports the old `lib/` folders;
`scripts/check_v2.py` enforces this table. The one exception is `lib/main_v2.dart` importing
`lib/debug/agent_driver.dart`, the headless-test hook shared with the old app.
Cross-mode jumps (open this line in the builder, train this chapter) are typed
requests handled by `app/`: `WorkspaceRequests` owns them and `Shell` only
draws its mode and status and maps the lists, the explorer and the keys to
its commands. Questions it puts to the user come in through an interface
(`ExitGuard`'s `DraftQuestion`, `WindowInput`), so the flows are tested
without widgets. The way out of the window (`AppExit` in `app/app.dart`) waits for
the draft, then stops the engines, then closes the log, once however often
it is asked.

## Code rules

1. **One owner per piece of mutable state.** A `ChangeNotifier` or
   `ValueNotifier` constructed in `app/` and passed down by constructor or
   Provider. No singletons, service locators or second dependency container.
2. **Pass owners, not bags of callbacks.** A widget receives the owner it
   uses, or an immutable value plus the commands it needs.
3. **No forwarding layers.** A class that only passes calls to another class
   does not exist. No facades over owners the widgets could use directly.
4. **Widgets do no I/O.** They call their owner. Owners call `storage/`,
   `engines/` or `net/`.
5. **Interfaces only at real boundaries:** filesystem, SQLite, engine
   processes, network, clock. Internal algorithms are concrete functions.
6. **Split a class by job, not by size.** Never use `part` to spread one class
   over files.
7. **Typed results and failures.** Owners expose typed status (idle, running,
   failed, done) and typed errors; widgets turn them into text. Widget copy is
   plain English strings. There is no ARB or `gen_l10n` in `v2`; the
   localization section of [the UI guide](agents/ui.md) does not apply here.
8. **A failure is reported twice: to the user and to the log.** At the catch
   site, `log.w`/`log.e` with the action that failed and the error; at the
   widget, the typed failure as plain English. Warnings and errors go to the
   console in every build mode and to `<support>/logs/app.log`, so a user's
   report of "an error appeared" can be answered without reproducing it. Never
   log secrets, tokens or file contents — the path and the error are enough.
   The facade lives in `diagnostics/` and its file sink in `storage/`
   (`v2` may not reuse the old app's); `main_v2` installs the sink before
   anything that can fail, then `app/error_log.dart`: Flutter's own errors
   (a layout assertion, a build that threw, an uncaught async error) become
   an `E performLayout(): …` entry with the blamed widget and the app's
   frames, so a console that scrolled away is still in the file. Build it in the first step that can report a
   failure, not before, and never swallow an error into a bare `catch (_) {}`.
9. **Async work has an owner and a stale check.** Each action declares whether
   a repeat is rejected, merged or queued. A result that arrives after its
   document, position or request changed is discarded. Disposing a widget never
   kills work that should continue, such as a running generation.
10. **Explain non-obvious algorithms next to the code:** representation, units,
   score perspective and a small example. Long explanations go in
   [ALGORITHM.md](ALGORITHM.md).
11. **Build only what the current step's screenshot needs.** No abstractions,
    options or scaffolding for a later step.
12. Follow [the Dart conventions](agents/dart.md) for paths, helpers and
    `SafeChangeNotifier`, and [the UI conventions](agents/ui.md) for controls,
    typography, shortcuts and copy density. Where those guides name old
    folders, the `v2` equivalents apply.

## Choices already made

None of these is re-opened during the rewrite.

| Area | Choice |
|---|---|
| Dependency passing | Constructors, with Provider for Flutter lookup and listening. No Riverpod, Bloc or GetIt. |
| State | Plain immutable values and sealed classes. No code generation. |
| Packages | No new pub dependencies beyond two the owner allowed on 2026-09-21: `chessground` (Lichess's board, by the `dartchess` authors) and `multi_split_view` (draggable panes). The existing set (`dartchess`, `provider`, `http`, `sqlite3`/`sqflite_common_ffi`, `shared_preferences`, `stockfish`, `onnxruntime`, `window_manager`, `file_picker`) covers the rest of `v2`. A hand-rolled piece is replaced by a package only when the package does the whole job; the PGN reader stays, because no package keeps untouched games byte for byte or reports where a bad token is. |
| Database | The existing SQLite files, schemas and migrations. |
| Files | A new atomic writer in `v2/storage/` that takes the same SQLite-transaction lock the old app takes (`file_operation_lock.dart` documents the protocol), so the two apps lock each other out. |
| Network | `http` behind one client per service, each with its own retry policy. |
| Navigation | A persistent shell with the mode menu and plain `Navigator`. No router package. |
| Strings | Plain English in widgets. |
| Credentials | Keep reading the existing SharedPreferences tokens. A vault migration is a separate, later step. |
| Panels | `multi_split_view` with minimum sizes; the divider look and the pane widths are tokens in `ui/theme.dart`. A saved layout is not built yet. |
| Theme | Dark only; no Light or System theme is planned (owner, 2026-09-22). Tokens in `ui/`. Built in step 0 only as far as a board and a move list need; extended by later steps. |
| Catalog and visual tests | Widgetbook on production widgets, added at step 12. Widget tests before that; no golden framework. |

## What clean code means here

Clean code is code a maintainer reads once and can predict. Three questions
decide it, and the reviewer answers each with a file and line, not an opinion.

**Can I read it?**

- Names say what; comments say why. A comment that explains *how* a block
  works means the block should be rewritten (kernel `coding-style`). A
  non-obvious algorithm gets a short paragraph with its representation, units
  and one worked example beside the code (Knuth).
- A function does one thing and usually fits on a screen. The checker fails
  past 80 lines or 3 levels of nesting; aim for 5 parameters or fewer. Extract a piece when it has a name and a
  contract, not to hit a length; one long linear function that runs top to
  bottom once is better than six that share state through fields (Carmack).
- A file holds one type or one group of closely related functions. Never
  `part`. The checker fails past 1,000 lines, a backstop against a god file
  rather than a target: splitting one job across files to get under a
  number costs more reading than it saves. The caps were 400/50 until
  2026-09-21 and 600/50 until 2026-09-22; both times commits went in only
  to get under them (a shortened comment, a session split, a `Writes` half).
- Composition has three layers (ports and adapters; lila's per-module
  `Env`). `app/environment.dart` is every way out of the app — files,
  dialogs, sites, engines, Maia, the clock, timings — as one
  `AppEnvironment`; `.native()` builds the real ones. `app/app_parts.dart`
  (`AppParts`) puts the app together over any environment in order and
  disposes it in reverse, calling `app/mode_wiring.dart` and
  `app/workspace_wiring.dart`, each of which builds its owners and
  connects them. `app/app.dart` hosts the window over `AppParts`. The
  window tests build a scripted environment and the same `AppParts`
  (`test/v2/support/window_fixture.dart`), so they test the real wiring.
  A new owner goes in the wiring it belongs to; a new way out of the app
  is a field of `AppEnvironment`.
- A mode is a `ModeView` (`app/mode_view.dart`): it owns its reading-card
  tabs and answers for its list, Actions menu, own tab bodies and flags.
  The shell asks the mode on screen instead of switching on which mode it
  is; a new mode is a subclass and one arm of `modeViews`.
  `WorkspaceView` takes one `WorkspaceHooks` value for what the window
  adds to the workspace.
- Clear beats clever (Pike). No tricks that need a second reading.

**Can I reason about it?**

- Data is values. Domain types are immutable; a change returns a new value.
  Mutable state lives in exactly one owner that notifies (Hickey: do not braid
  state, identity and time).
- Effects happen at the edge. Parsing, tree operations, scheduling and scoring
  are pure functions of their arguments; `storage/`, `engines/` and `net/` do
  the I/O; owners connect the two. A pure function is tested with values only.
- Expected outcomes are typed results, not exceptions: a sealed `SaveResult`
  with `Saved`, `Conflict`, `Collision`, `Invalid`, `IoFailure` and an
  exhaustive `switch`. Design so the error cannot happen where possible
  (Ousterhout: define errors out of existence).
- Ids and units are types when confusion would be a bug: `Fen`, `Revision`,
  `ChapterId`, `Centipawns` (lila's opaque ids). Not every string.
- After an `await`, transient reads and computations check their input/request
  identity before publishing. Accepted durable operations instead follow their
  commit/recovery protocol even if the initiating view has gone. Every
  subscription, timer and process has a named owner and an explicit end;
  disposing a view does not dispose durable obligations it initiated.
- No `dynamic`, no `late` for things that could be constructor arguments, no
  boolean parameters that switch behaviour, no nullable fields that mean
  "not loaded yet" when a sealed state would say it.

**Can I change it?**

- One place per fact. FEN normalisation, movetext formatting, chapter naming
  each exist once. A little copying at the edges is better than a dependency
  on an unrelated module (Pike); a second implementation of a rule that must
  agree is a bug.
- Deep modules: a small interface hiding real work (`store.save(doc,
  expected: rev)`), never a wide one (`writeFile(path, bytes, {overwrite,
  lock, backup, …})`). A class or method that only forwards to another does
  not exist (Ousterhout).
- Nothing is there for later. No options nobody sets, no abstract classes
  with one implementation, no hooks for a step that has not started. Dead
  code is deleted, not commented out.
- Modules do not reach across: a feature imports `workspace/` and below,
  never another feature (lila's `modules/`, each with its own wiring).
- Tests describe behaviour a user could see or a contract another module
  relies on. A test never reads private state or asserts a call sequence. If
  a refactor that keeps behaviour breaks a test, the test was wrong.
- Dart idiom: [Effective Dart](https://dart.dev/effective-dart), `final` by
  default, sealed classes and exhaustive switches, records for small tuples,
  extension types for ids, `package:path` for paths.

### Style reference

Copy the shape of these files; they are what the rules above look like:

| File | Shows |
|---|---|
| `lib/v2/chess/pgn/game_tree.dart` | Immutable values (`MoveNode`, `NodePath`, `GameTree`), doc comments that say why |
| `lib/v2/chess/pgn/pgn_reader.dart` | A pure function over a package, typed issues instead of exceptions |
| `lib/v2/chess/pgn/tree_merge.dart` | One algorithm, one paragraph explaining it |
| `lib/v2/workspace/document_session.dart` | An owner: two fields, commands, derived getters, the document and the cursor notified apart |
| `lib/v2/features/library/library.dart` | Sealed states and results, a stale check after `await` |
| `lib/v2/workspace/move_tree_view.dart` | A widget built from an owner, private sub-widgets, no I/O; lines built once per tree, a cursor move redraws two moves |
| `lib/v2/app/workspace_requests.dart` | Cross-mode requests as an owner: sealed results, questions behind an interface, a disposed check after every `await` |
| `lib/v2/storage/chapter_files.dart` | An interface at a real boundary (the filesystem) with sealed results, and its one adapter |
| `lib/v2/engines/uci_engine.dart` | A protocol over a pipe: serialised searches, each with its own stream, so stale output cannot land |
| `lib/v2/workspace/engine_analysis.dart` | An owner over a background job: enable/disable, stale checks, a 200 ms snapshot buffer, `dispose` |
| `test/v2/workspace/engine_analysis_test.dart` | Fake time, a scripted double, assertions on the owner and never on private state |

`scripts/check_v2.py` enforces the numbers below and the import table; run
it before saying a step is done. `scripts/ci.sh lint` runs it and its tests
(`scripts/test_check_v2.py`).

### Reviewer checklist

The independent review of a finished step answers these, each with a location:

1. Any file over 1,000 lines, function over 80, nesting over 3?
   (`scripts/check_v2.py` finds all three. A `group(...)` or `test(...)`
   body in a test file is a function; `main()` and `group(...)` bodies are lists of cases and are not.) Any split made
   only to get under one of them, or a file too small to be read on its
   own?
2. Any owner holding data that belongs to another owner in the
   [workspace table](#workspace-owners)? Any mode importing another mode's
   folder? (`scripts/check_v2.py` finds the second: shared code moves to
   `workspace/` or `ui/`.)
3. Any `await` not followed by a stale check? Any subscription without a
   `dispose`? (`scripts/check_v2.py` finds one kind: a `State` whose
   `initState` calls `widget.<owner>.addListener` must use `ListeningState`
   (`ui/listening_state.dart`) or implement `didUpdateWidget`, so a widget
   rebuilt with another owner stops hearing the old one.)
4. Any exception used for an expected outcome? Any `catch` that swallows?
5. Any pass-through class, unused option, abstract type with one
   implementation, or code for a later step?
6. Any rule implemented twice? Any old-app code pasted in?
7. Any test that reads private state or asserts implementation order?
8. Any comment that explains *how*? Any algorithm without a *why*?
9. Is the `v2` line count for this step below the old app's for the same
   features?

A finding is fixed before the status cell says Done. **Step 0 is reviewed by a
second agent before step 1 starts**, because every later step copies its
style.

## Data safety

User data is the one thing the rewrite must never damage. The target guarantees
across multiple stores are defined in [Data correctness contracts](#data-correctness-contracts);
the sections below specify document formats and individual storage operations.
[DATA_INTEGRITY.md](DATA_INTEGRITY.md) lists every store, its format and its
recovery files.

### Stores and formats

| Data | Where | Must preserve |
|---|---|---|
| Repertoires and chapters | Documents `repertoires/` folders: chapter PGNs, or one course PGN whose games name their chapter (see [Course files](#course-files)) | Comments, variations, NAGs, unknown headers, machine tokens such as `[%eval]`, `[%pv]` and `[%clk]` |
| Studies | Multi-chapter PGNs in Documents `studies/` | Lichess export tags, root comments, per-chapter orientation |
| Games | Support `app_games.db`, collection-scoped with position indexes | Tactics source games that have no other copy |
| Training | Review, progress and history CSVs and attempt JSONL, keyed by file path and line id | Scheduling and history across chapter rename, move, split and delete, and across edits that would change a derived line id |
| Generation output | Versioned bundles via the artifact repository, plus legacy chapter-side files | Readability of old artifacts; user edits to companion PGNs |
| Settings and accounts | V2 Support `settings.json`; existing SharedPreferences account/credential keys | Existing keys and values; no implicit account migration |
| Recovery | Atomic-write journals, quarantine, PGN recovery snapshots, SQL `game_trash`, schema-upgrade backups, the training records a relocation replaced in Documents `.cap-reference-history/<operation>/`, and the Support note naming a move whose training rows are not rewritten yet | Each keeps its purpose; none of them is the version history — see [Backups](#backups) |

### Course files

A repertoire is a folder; a chapter is a `.pgn` in it, or — for a course —
the games of one file that carry the same `[ChapterName]` (the Lichess study
export's tag). One rule, `chapterSections` in `chess/pgn/chapter_sections.dart`:
each named chapter retains `(path, section)` identity even when it is the last
chapter left. Untagged games form the unnamed section. A stale explicit section
never opens a different surviving chapter; older whole-file references still
read a singleton file. Book membership therefore survives sibling deletion.

Listings traverse nested repertoire folders without following symlinks or
entering hidden recovery/staging folders. Native startup/listing moves legacy
root-level PGNs to `<name>/Main.pgn` through the guarded document store, carrying
training references and backups; a collision leaves the original visible.
Nested backup histories follow folder moves, and nested recovery files can be
listed and restored. Native affected access first takes the canonical repertoire
recovery domain shared with supported v1 on Linux, then the Documents namespace
and distinct leaf locks. V2 PGN access, training reads/writes, library/deleted/
study scans and PGN imports recover its existing relocation notes before access.
Malformed, unsupported, unreadable or ambiguous notes remain intact and block
access; a matching native identity must prove whether a move landed. V1 refuses
unfinished v2 notes, and v2 refuses pending/unknown v1 move and publication
receipts with an instruction to reopen v1. Valid completed v1 history remains
readable. V1 conservatively guards supported Documents accesses, including the
four training files. No foreign journal is replayed and no metadata format is
introduced by this gate. Non-Linux v1 recovery remains unverified.

File rename, move, quarantine delete and file restore now use `FileRelocations`
and private version-1 `Support/relocation-writes/<id>.json` records. Each record captures the
PGN's canonical endpoints, native identity and hash; all four training files'
exact before/after text (including absent and unchanged participants); raw book
selectors; and the complete backup-directory identity, index and file inventory.
The captured Documents spelling preserves training keys reached through a
configured alias alongside canonical keys. Pending recovery verifies that alias
still resolves to the pinned Documents root. No current paths are consulted to
reinterpret a terminal receipt's intended operation.

Preparation validates every participant and preserves changed training inputs
under `.cap-reference-history/<id>/` before durable commit intent. Recovery
validates the complete read set before moving the PGN, publishing rows and book
selectors, and transferring backup ownership. Occupied destination history moves
to a deterministic preserved aside; a chapter with no incoming history cannot
inherit it. Namespace flush failures retain intent, and replay flushes both
endpoints and their ancestors. `Moved` is returned only after completion.
`AcceptedFileChanges` retains the original id and revision through UI and registry
retry, coordinates books and open drafts, and follows or closes only the
matching accepted file observation. V1 refuses pending, malformed or unknown
relocation records before its own recovery/access; validated complete/cancelled
records remain readable. Native Windows replacement can leave an old copy
beside a journal if cleanup is interrupted. Recovery retains that copy and
accepts it only when its reserved name, complete immutable payload and recorded
phase prove it belongs to the current valid receipt; it never replays the old
copy. Backup-index recovery similarly checks retained replacement copies
against the captured index. Unknown or conflicting artifacts still block access.

Folder moves use a version-2 variant in the same journal and recovery loop.
`DirectorySnapshot` captures every regular file and directory, including binary
sidecars, empty folders, nested quarantines and uppercase PGNs. Each entry has
its native identity; files also have their content hash. Relative paths retain
the host's spelling. Recovery verifies the entire tree at its recorded endpoint
and all training, book and backup participants before publishing anything else.
Every captured PGN has an explicit backup-ownership plan. Links, unsupported
nodes, metadata-root overlap and cross-filesystem moves are refused before
intent. The original note decoder still recovers older moves; its writer is
retired.

Folder commands retain their accepted id and use prefix admission for both
names, so a late child load cannot cross the move. The editor follows only a
matching native revision from the committed inventory. Imports retain their
staging folder, destination and command through uncertain placement and return
the original import result after retry. A confirmed destination collision alone
advances to another name.

A quarantine delete keeps the current PGN version before preparation and moves
its backup ownership with the file; restore brings that history back. Deletion
ids follow the existing recovery filename grammar. Repertoire deletion retains
its accepted ordered file list and failed command, leaving sidecars and prior
quarantine contents in place. It resumes without repeating completed files.
Pre-journal quarantines lack proof tying a former path's backup history to the
restored file: occupied history is preserved separately rather than merged by
guesswork. Those historical ownership links remain unverified.

Existing unfinished folder notes continue through their original recovery
protocol. Accepted training commands use the durable queue described under
[Identity and undo](#identity-and-undo). Multi-file edits remain H3c work.
Completed relocation snapshots are retained;
pruning and scan costs remain explicit follow-up work. The tested native
recovery platform is Linux; Windows/macOS durability is unverified.

- **One file, one write path.** A chapter of a course file opens as a
  `SectionView`: its games in file order as an ordinary `Chapter`, so every
  edit works unchanged. `spliced` puts the edit back into the file, and the
  store checks the whole file against the file-level arrangement, as it does
  for a chapter file. Games the edit kept stay in their own places; a new
  game goes at the end of the file carrying the chapter's name.
- **Chapters are tags.** Moving lines to another chapter of the same file
  (`linesNamed`), renaming a chapter (`sectionRenamed`) and deleting one
  (`sectionRemoved`) each change one file. Deleting is an edit that undo takes
  back, not a quarantine. A course chapter does not move to another
  repertoire without its file.
- **Line ids are written down.** A game without an id header is trained under
  an id worked out from its main line and its place in the file. Any edit that
  would change that id — moves edited, a game above it moved or removed —
  first writes `[LineID]` with the current id (`withIdsPinned`), which both
  apps read before working one out. Progress therefore stays keyed by file
  path and id, the format the old app shares, and chapter changes inside a
  file never touch the training files.
- **Import writes one file.** A course or study with several chapters is
  written as `<repertoire>.pgn` with `[ChapterName]` and `[LineID]` on every
  line (`courseText`). A one-chapter import is a chapter file as before.
- **The old app** lists a course file as one chapter until step 14, and trains
  it under the same keys.

### Backups

The user never asks for a backup and never names one. Losing work is a bug in
this section, not a mistake the user made.

- **Every replaced byte is kept.** A save, append, import, rename or delete goes
  through the store, and the store already returns the validated before-content
  of the file it replaced. That content is what gets recorded. A write whose
  backup could not be recorded does not proceed; it returns an I/O failure like
  any other.
- **Backups live in Support**, under `backups/<document id>/`, one plain copy
  per version named by commit time and content hash, with a small index per
  document. Copies are not compressed: PGN is small, disk is cheap, and a
  compressed copy is one more thing that has to work before a save may go
  ahead (versions an earlier build gzipped are still read, by their magic
  bytes). They are never written into Documents: a synced folder must not
  gain files the user did not make, and a restore must work when Documents is
  the thing that went wrong.
- **Identity, not path.** Versions follow the document's identity, so a rename
  or a move keeps one history instead of starting a second one.
- **Unchanged content costs nothing.** A save whose bytes hash to the newest
  stored version records nothing.
- **Retention** is by age, then by size: everything from the last day, hourly
  for a week, daily for a month, weekly for a year. A byte cap prunes oldest
  first. The newest version of a document is never pruned, and pruning runs on
  its own schedule, never inside a save.
- **Restore is a normal save.** Settings ▸ Data lists each document's versions
  with time, size and move count, previews one, and restores by writing it
  through the store — so the restore is itself backed up and undoable. Nothing
  is ever replaced without the user choosing it.
- **SQLite** (`app_games.db`) is snapshotted with SQLite's backup API, not by
  copying db/WAL/SHM, when the newest snapshot is older than a day.
- **What it is not:** not the undo history (store receipts, in-session), not the
  generation artifact history (versioned bundles, per run), not the recovery
  files above (interrupted writes and deletes). Those keep their own purposes.

Step 2 owns the write path and the recording; the restore screen ships with
step 13's Settings, and until then a version is recoverable from Support by
hand.

### PGN document store

Every PGN write goes through one `PgnDocumentStore` in `v2/storage/`. Nothing
else in `v2` calls `File.writeAsString`.

| Intent | Contract |
|---|---|
| Open | Returns revision and content. Absent, unreadable and malformed are distinct results; a failed read is never an empty document. |
| Create or save a copy | Exclusive create; a name collision returns a collision and replaces nothing. |
| Save | Requires the loaded revision and the scope of the edit. If the file changed on disk, return a conflict. There is no overwrite flag. |
| Append, import or edit | A locked transformation of current content. Returns the validated before-content and the committed revision together. |
| Undo | Validates that storage still holds the revision the undo entry expects; restores that entry's before-content. On mismatch it rejects and keeps history. |
| Rename, move, delete | The same store and lock, with collision checks, and training references updated in the same operation. Delete is recoverable. |

Results are typed: saved, conflict, collision, invalid document, refused or
I/O failure. Only *saved* clears the dirty state. A conflict keeps the user's
draft and offers keep editing, save a copy or reload. Dismissing a dialog never
grants overwrite permission.

A save also declares what it is changing. `save` takes an `EditScope`: the
games of the version on disk it writes again and how many it adds at the end,
or `WholeDocument` for a restore, an import or a caller that cannot say, which
is logged as a warning so it is visible. The scope comes from the edit that
produced the text — `addMove` and `setComment` report the games they wrote —
never from comparing the new text with the old, which would agree with
whatever the writer did and leave nothing to refuse. Before anything is written, the new
text and the version on disk are cut into games with the chapter reader's own
splitter and compared: a game the scope does not name that would change, a game
that would disappear, or a changed `//` heading refuses the save, names the
first game that would have changed and writes nothing. Then the version being
replaced is copied into Support, and only then is the file replaced. A create
has no previous version, so there is nothing to declare and nothing to compare.

Course-section renames attach explicit `SectionRename` intent to the ordinary
edit scope. Held edits keep that intent in the draft; discard and draft undo
write nothing. Keeping the draft commits its PGN and exact `books.json`
reference snapshot together. The store checks section lineage independently
of the ordinary game-byte scope and preserves unknown book fields. Book edits
accepted beforehand settle first; controls wait while references are committing.

This operation uses private version-1 `Support/compound-writes/<id>.json`
receipts containing canonical document paths and exact before/after content
(the content itself is the comparison, rather than a separately stored hash).
The outer shared domain, Documents and distinct participating directory locks
cover recovery and publication. Prepared receipts cancel without publishing;
committing receipts finish only participants at their expected before/after
bytes. Unknown, malformed, unreadable or externally changed participants block
with retained recovery material. V1 recognizes the envelope and refuses pending
or unsupported receipts before its own recovery, directing the user to v2.

A completed receipt authenticates the inverse; undo validates both participants
and journals that inverse as another operation. Failed acknowledgements retain
the original operation id and exact draft or inverse for explicit retry, while
new document edits are blocked. Training paths and stable line IDs are unchanged
by a section rename. Complete receipts currently retain full snapshots and are
validated on each recovery access; space and scan cost grow with structural
history. Pruning or compact terminal receipts require a separate compatible
protocol, not deletion of material still used by retry or undo. These durability
and coexistence paths have native Linux tests; Windows/macOS remain unverified.

`savePair` extends this boundary to exactly two PGNs through strict version-2
compound receipts. Each participant carries its own expected revision, edit
scope and preserved before-content; both are validated before publication.
Books and training files are outside this receipt. Exact retry authenticates
both participants, and one inverse restores both or refuses an intervening
change. Repository notifications cover both configured document references,
including a Documents-root alias.

`DocumentSession.externalEdits` prepares a source edit without changing the
editor and holds saving through publication and adoption. An uncertain accepted
operation retains its retry barrier. Historical completion can settle that
operation, but the editor adopts its result only after fresh content and native
identity proof; a changed source retains the draft as a conflict. Navigation
cannot make a completion replace another editor. This is a tested foundation:
Library cross-file line moves still use their existing flow. Connecting them
awaits the product decision about training progress when lines move or merge.

For an ordinary save, the store does not read the file back after the
rename, and does not read its own backup back before it: a temp-and-rename on
a local disk does not fail silently, and a check that reads every byte again
buys nothing the revision check and the kept copy do not already give. What
the store keeps is the protection against the two things that really happen —
another writer, and a bug in this app's own writer.

**Nothing waits for the disk.** Reading bytes and hashing them happen on
another isolate (the native probe in `packages/document_file_io`), and so do
decoding a large file, encoding and hashing the text to write, and the
game-by-game comparison. Parsing a chapter into its tree happens on another
isolate once the text is larger than a few tens of kilobytes. A large
generated book opens and saves without the window pausing.

A revision is the SHA-256 of the exact bytes on disk. The same bytes have the
same revision, but two copies remain different documents with their own
references and histories. Different bytes from those expected are a conflict,
never permission to replace. (The native file identity the probe also returns
is used by moves, which write it down so that a move interrupted half way can
be finished by the file rather than by its name.)

Undo history is built from store receipts (actual before-content and committed
revision), never from controller memory. Edits A → B → C leave rC on disk. Undo
C checks rC and restores B, and because a revision is the bytes, B's entry
expects exactly what is on disk again. If an external edit E happened before
C, undo C restores E and the older B entry stays disarmed. A failed or
uncertain undo never pops history.

**Reading and writing a game.** `v2/chess/pgn/` owns the PGN grammar; dartchess
is used for legality and positions, never for text. Reading a game yields its
header lines with the endings they had, its moves, the termination marker it
wrote (never the `[Result]` tag), the whitespace before the moves, and a list
of named, located issues. **Any issue at all makes the game not whole:** it
keeps its own bytes, is left out of `Chapter.writableTree`, and every edit
that would have to rewrite it is refused with a typed reason the screen shows.

**The round-trip gate.** `rewritten` in `chess/pgn/rewrite_gate.dart` is the
only way a game already in a file becomes new text. It refuses a game reading
did not take whole; otherwise it writes the game, reads that text back and
compares headers, separator, moves, comments, annotations and marker, and
answers `LineRewritten(line)` or `LineRefused(reason)`. An edit commits
nothing until every game it must write comes back, so a note never lands in
some games and not others, and a refusal reaches the user as a typed reason.
The store needs no hook: a chapter that cannot be written never produces text
for the store to save.

A comment lives where it lived. A move several games play is commented in the
games that already carry a comment on it, or in the first game that plays it
when none does; reading merges the comments of every game, so the workspace
still shows one note.

The writer's canonical form is stated on `writeMoveText`. It keeps the SAN the
file spelled, every comment's text, the order of moves and variations, the NAG
numbers and the marker; it normalises redundant move numbers, several comments
on one move into one, `;` comments into `{}`, symbolic annotations into their
numbers, and `e.p.`. Each normalisation reads back as the same game, which the
gate proves, and writing twice gives the same bytes.

**When the file is written.** The workspace does not write on every move.
An edit starts a one-second clock, every edit inside it restarts the clock,
and the file is written once when it runs out, with the newest text: a burst
of moves is one write. Anything that needs the file now ends the wait at
once — opening another document, a rename, the window losing focus or
closing, and undo, which writes the waiting draft before it steps back.
Only one write is in flight at a time and edits made during it collapse into
a single pending save, so there is never a queue of stale snapshots. This is
what Obsidian and VS Code do, and for the same reason: the file is never
more than a moment behind the screen, and a keystroke never costs a write.

### Required failure tests (step 2)

Against real files in a disposable directory: concurrent create of the same
name; a stale save after an external edit; two app writers, including the old
and new apps at once; an external edit before an append, then undo; successive
and per-move undo with an external edit between; an interrupted replacement,
then recovery; a queued save after switching chapters; a generation that
finishes after its source changed; a failed read, unreadable file and
disk-full error; chapter rename, move and delete while a training session is
writing. Tests never touch the user's real profile.

### Filesystem notes

- Locks coordinate app writers only. Commit-time revision checks catch what
  they can of external editors; backups cover the rest.
- Treat Documents as possibly synced. A delayed or failed read is an error, not
  empty content. Never merge or delete conflict copies automatically.
- Live SQLite files and lock databases stay in local Support storage. Back up
  SQLite with its backup API, never by copying db/WAL/SHM files.
- Durability goal: survive app or worker termination. POSIX: write temp, fsync,
  rename, fsync the directory. Windows: `ReplaceFileW`, sharing violations
  retried with a capped backoff and a fresh revision check.

V2 desktop compatibility (2026-09-25): the native file adapter normalizes
Windows long/UNC paths, preserves ACLs and alternate streams on replacement,
retains a recovery copy for partial replacement failures, and rechecks content
and identity between bounded sharing retries. macOS stages use `F_FULLFSYNC`.
Names have both a character cap and a UTF-8 byte budget, leaving room for
staging and recovery names. macOS retains App Sandbox with outgoing network,
OAuth loopback-server and user-selected file permissions; Finder PGNs enter
the same guarded import route as Windows and Linux. External files are copied
into the app's Documents folder, so recent imported files do not require
persisting grants to their external originals.

`.github/workflows/desktop-contracts.yml` runs native v2 document, locking,
login, exit and desktop integration checks on Windows 2022/2025, macOS and
Linux as a release gate. The non-publishing `windows-check` branch runs its
Windows cases too. `--self-test-desktop` in the release executable uses a
disposable temporary profile to check long Unicode document paths, save on
exit, reopen, rename/recoverable delete, bundled Stockfish, Maia and actual
login callback sockets. `tools/test_desktop_bundle.py EXE --report REPORT`
runs that check, preserves its JSON result, and fails on a missing report,
timeout or failed step. Windows checks exercise both portable and installed
builds, including the portable build with the machine's VC++ runtime removed.
These are host/file-operation gates, not sudden-power-loss or cloud-provider
certification; Windows directory-entry durability remains unpromised.

## Settings

- One writer per key. A failed read is different from an absent key and never
  starts work with defaults. A failed save is shown as failed.
- Jobs capture their configuration when they start.
- Secrets never appear in snapshots, logs, Widgetbook or exports.

`SettingsStore.ready` requires a successful native read (including confirmed
absence). Malformed JSON, linked files and non-file paths preserve the saved
bytes and block edits; a failed reread retains the last valid choices without
authorizing their publication. Startup shows the file location with Retry
settings before exposing modes or launching engines. Successful retry resumes
startup once. Existing failed saves retain their own retry obligation; an
unverified staging file is preserved. Read diagnostics omit source contents.

## Network and offline

The app is usable with no connection. What the user has already downloaded is
on this computer, and a fetch that does not happen leaves it on the screen.
The old app broke this by reading its games cache only when a fetch returned
*empty*: a fetch that threw went past it, and a startup "check for new games"
that skipped the cache on purpose turned a missing connection into a page with
no games on it.

- **One client per service** in `net/`, injected at its owner, each with its
  own retry and backoff policy. Both paths are driven in tests by a fake
  client; no test reaches the real network, and `flutter test` blocks it
  anyway by answering every socket with an empty 400.
- **A failed fetch never takes data away.** The owner keeps what it had, marks
  it stale with when it came down, and names the service it could not reach.
  An empty list is a far stronger claim than "could not check".
- **Refreshing harder still cannot empty the screen.** A forced refresh — the
  user pressing check-for-new, or a startup check — prefers the network and
  ignores any freshness window, but never discards the local copy on the way
  back. Only a request with nothing stored behind it shows an error instead of
  content.
- **Two services fail independently.** One site being unreachable never
  removes the other's rows.
- **What a panel displays is persisted**, not held for one session, so a
  second launch offline shows what the first launch fetched. In-memory caches
  are scratch for a single session. The one decided exception is the Lichess
  explorer, whose database is the service: it stays online-only and says so
  with a retry (see [the workspace spec](v2/features/workspace.md)). A panel
  that cannot answer offline says which service it needs and offers the retry;
  it never shows an empty result or an unresolvable spinner.
- **A stale answer is labelled, not hidden:** one muted line naming the
  service and the age, beside the content, never instead of it.

**Required failure tests**, in each step that adds a client: a fetch that
throws, one that returns nothing, and one that returns a 429 and a 500 — each
against a store that holds content and against one that does not; a forced
refresh that fails; and two services where one fails and the other does not.

**Confirming it in the running app** belongs to the step's screenshot. The
accepted screenshot is the online proof; the offline proof is the same screen
from `python3 scripts/app_driver.py start --offline`, which runs the app in a
network namespace with loopback only — display, VM service and session bus
intact, nothing else reachable. Warm the build with a normal `start` first.
(`unshare` around the driver does not work: the app runs in a user-manager
unit, not as a child of the caller.)

## Engines and background work

- One supervisor owns every engine process, drains stdout and stderr into
  bounded buffers, and defines cancel, graceful stop, timeout and kill per
  engine type. Cancelled is reported only after resources are released.
- Engine processes die when the app dies, including when it is killed. Tested
  on Linux in step 1; Windows (Job Object) and macOS when those hosts are
  available. Never kill processes by name.
- Continuous analysis updates the UI at most about every 200 ms with the latest
  snapshot of all MultiPV lines; `bestmove`, completion and errors arrive
  immediately. No trailing debounce.
- Workers, ports, timers and subscriptions have a named owner and an idempotent
  shutdown. Opening and closing a mode repeatedly returns process and port
  counts to baseline.
- Large documents are shown from immutable projections tied to a revision.
  Never deep-copy or compare a whole move tree on each cursor move.

## Interface

- A quiet dark workspace by default; colour only for meaning (errors,
  evaluation, selection). Board, moves and the current task get priority.
- Context stays visible: current file, side, orientation, selected line,
  filters and save state. Back, cancel and mode switches return to the same
  position and draft.
- Distinguish unsaved, saving, saved, failed and conflicted. Real progress,
  never a fake ETA.
- 12px type floor, 4.5:1 contrast, usable at 150% and 200% text scale.
- Typeable choice fields instead of dropdowns, visible search inputs, shared
  confirmation and name dialogs, shortcuts in tooltips.

## Keeping the UI replaceable

The owner will change the look of `v2` often, so the rule that makes that
cheap comes first: **a widget file can be deleted and rewritten from its
owner's public API and the theme alone.**

- Owners (the `ChangeNotifier`s in `workspace/` and `features/`) import
  `package:flutter/foundation.dart` at most, never widgets. They expose
  values, typed states and commands; they know nothing of layout, text or
  colour.
- A widget is a function of one or two owners: it reads their values, calls
  their commands, and keeps only view state (hover, scroll position, an open
  menu). State that two widgets need lives in an owner.
- Only `Shell` and `WorkspaceView` know which panel sits where. Every other
  widget lays out its own contents and nothing else.
- Colours, font sizes, font families and spacing come from `ui/theme.dart`
  (`darkTheme()`, `BoardTheme`, `Space`, `monoText`, `scoreText`). Literal
  `Color(0x…)`, `fontSize:` and `fontFamily:` appear only under `ui/`;
  `scripts/check_v2.py` rejects them elsewhere. A widget that needs a new
  value adds a named token to the theme.
- A widget file (one importing `package:flutter/material.dart` or
  `widgets.dart`) never imports `dart:io` or `net/`; the checker rejects
  that. From `storage/` and `engines/` it takes value types only
  (`ChapterRef`, `Score`, `EngineLine`), never an adapter or a process.
- Every owner has a test without widgets. Every widget test uses a scripted
  owner or double from `test/v2/support/` and never a real file or engine.
- **Keep presentation in the theme and panel files.** Inter and Source Code Pro,
  sizes 18/14/13/12, surface `1B1B1D`, board `F0D9B5`/`B58863`. The owner's
  2026-09-24 polish uses brighter blue `80B4FF` with filled buttons `2459C4`.
  Read the old mode or `lib/design_system/theme/` for reference values and
  behavior, never copied code. Layout and palette changes stay out of owners.
- The reviewer's test for a step: could the new widget file be rewritten from
  scratch by someone who read only the owner's public API and the theme?
  If not, state or layout leaked into the wrong place.

## Correctness hardening order

These batches precede broad feature expansion. Each delivers a named user
sequence and the smallest reusable mechanism needed for it. They are dependency
groups, not a request to implement the whole design in one session. Split a
batch into bounded operation-specific tasks when needed; keep one status cell
per batch and use tests and commits as the implementation record.

| Batch | Depends on | Scope and first places to change | Exit condition | Status |
|---|---|---|---|---|
| H1 | None | Direct fixes: recursive book selection, gap invalidation, analysis-save errors, partial engine retry, puzzle timer; `books`, workspace wiring, bughouse stores/search, puzzle trainer | Their acceptance sequences above pass through real wiring; failures are visible | Done 2026-09-24: recursive book removal, catalog-driven gap refresh, typed analysis-save failures with exact-entry retry, partial engine retry and puzzle timer cancellation; regression failures reproduced before fixes, independent review, v2 suite and analyze/lint; headless Linux save failure/retry verified against disposable SQLite. Unsaved analysis remains in memory (H2/H5). |
| H2 | H1 | Accepted ratings and writes outlive reload/dispose; `PendingWrites`, training progress/owner, exit guard | Two overlapping reloads cannot bypass the same pending rating; failed outcomes remain retryable; shutdown is honest | Done 2026-09-24: app-owned training obligations, ordered barriers and exact in-process retry survive reload/dispose; retained book/settings/account/recent-file/copy outcomes; shutdown covers existing dialogs and suspends puzzle timers. Failure-first regressions, independent reviews, 2,155 v2 tests and analyze/lint passed after merging current main. Headless Linux partial training publication survived scope replacement and retried with three history rows exactly once. Persistent crash recovery remains H3; Windows/macOS durability unverified. |
| H3a | H2 | Existing relocation recovery before affected reads; document guards, training reads, startup; reconcile v1 domain locks/order | Kill during a move, reopen/train from either supported app; no missing or duplicate progress; incompatible access blocks safely | Done 2026-09-24 on Linux: canonical shared domain before affected Documents access; strict v2 notes recover before PGN/training reads and complete scans, foreign receipts refuse without mutation, and UI shows the recovery reason with Retry. Regression-first tests, independent reviews, 2,232 v2 tests, final focused storage/legacy checks and analyze/lint passed. Six real-process tests cover cross-app exclusion, SIGKILL and all four training files recovering once; headless refusal/retry verified. No new metadata format. Windows/macOS recovery guarantees remain unverified; v1 native recovery is still Linux-only. |
| H3b | H3a | One compound operation for course rename/book references and its inverse; Library, storage, session history | Rename and undo agree across PGN/book state, including crash and external-conflict cases | Done 2026-09-24 on Linux: explicit section intent follows held/coalesced drafts; one guarded private receipt commits PGN and books, preserves unknown fields and validates the complete inverse. Exact retry, external conflicts, navigation admission and v1 refusal have regression tests; 2,381 v2 tests, focused legacy/process checks and analyze/lint pass. Real SIGKILL preparation/publication tests and headless partial book-write failure, Retry and undo verified both participants. Complete receipts remain retained with growing scan/storage cost; Windows/macOS durability unverified. |
| H3c | H3b | Apply the proven operation boundary to supported file/folder moves, delete/restore and multi-file edits | Every existing command has an explicit required read/write set, recovery path and compatible undo behavior | In progress: source admission, file/folder relocation, delete/restore, retained import placement and durable accepted training verified 2026-09-25 on Linux. Relocation preserves four training files, books, backup ownership and complete folder inventories; prior 2,722 v2/264 legacy tests and headless interrupted rename/delete/restore proofs passed. Training freezes accepted commands in an ordered persistent queue, validates all participants before replay, and compacts completion receipts. Latest full v2 suite: 2,773 passed, four Windows-only skips; final focused native/storage/legacy/frontend suite: 903 passed, four Windows-only skips; analyze/lint and independent review passed. Three actual SIGKILL boundaries recover distinct commands exactly once. Headless interrupted mark-known plus queued exclusion survived restart, blocked access until Retry, then recovered the original timestamp and one history row; a second reopen left all four training files byte-identical. Native receipt batching improved measured scan cost, which still grows with history. Two-PGN commit/inverse and workspace preparation/adoption are now verified foundations: 1,463 focused storage/workspace/Library/legacy tests passed with four Windows-only skips, including three real process-kill boundaries and historical-retry conflicts. Library cross-file moves remain unfinished pending the training-progress policy decision; Windows/macOS durability remains unverified. |
| H4 | H2, H3c | Versioned input snapshots for catalog, shelf, gaps, book comparison and training; targeted invalidation | A late computation cannot replace a newer result; a fresh rebuild equals the displayed committed projection | Done 2026-09-25 on Linux: complete native repertoire snapshots and final read-set validation; explicit failed/stale catalog, shelf, gap, tree and game-comparison reads; committed book/account owner revisions and keyboard guards. Includes native book/training proof, complete Trainer scope reads, repertoire-tree selection validation and downloaded-corpus/account fences with stale keyboard guards. Latest frozen v2 suite: 2,990 passed, four Windows-only skips; analyze/lint passed. Headless Linux Library, gaps and game-comparison checks retained prior views and blocked stale actions; native book and training-file failures also blocked Trainer/book-tree actions, and Retry restored the original lines. Additional MyGames UI proof was not run; its native and keyboard regressions passed. Targeted committed-input invalidation, scoped membership fences and guarded own-save receipt checks are implemented. SQLite selected-corpus snapshots now join the downloaded-PGN final fence; 138 merged focused tests, analyze/lint and independent review passed. Windows/macOS native guarantees remain unverified. |
| H5 | H2, H3c | Generation, mining, downloads, bughouse and engine lifetimes; job-specific checkpoints and truthful completion | Stop/retry/restart neither duplicates saved units nor loses promised results; resources return to baseline | In progress: finite UCI watchdogs and supervisor ownership through startup/disposal are integrated; 144 focused tests passed, including eight native Linux startup/exit checks. The download publication/retry tranche now retains frozen HTTP results in app-owned obligations, confirms corpus before freshness, preserves independent site results, and exposes account/corpus read failures with retry. Failure-first checks: 97 focused tests passed, followed by 62 native/cache/account/owner tests including fresh-store refetch, lost acknowledgements, missing-ID deduplication and a disposed owner's username barrier; analyze/lint passed. Headless Linux production-component fixtures verified save and read errors, retained usernames, blocked download admission and working retries. Accepted HTTP results are retained in RAM until publication; restart can refetch with old freshness and deduplicate published games. The mining tranche now retains frozen per-game results and counts across failed saves, retries and reviewing-owner disposal; persisted completion scans exclude unsaved editor markers, and closed publication blocks stale navigation. Native Linux lost-ack/reopen tests cover one puzzle/marker publication, while an open editor conflict remains explicit. Failure-first mining checks passed 86 focused tests on the merged tree, including startup/disposal errors and preservation of the exact accepted puzzles through editor changes; 53 native/owner/app-wiring tests also passed after merging settings and generation; analyze/lint passed; headless Linux production UI verified failure→Resume with one saved puzzle and no repeated engine searches. Generation now retains failed Finds/tree/draft publications through disposal and exact retry, with truthful completion, guarded immutable native artifacts and frozen draft placement. Headless Linux tree-save failure/Retry then draft creation preserved the source and produced one tree, seven findings and one draft. Unexpected startup/search/cleanup failures release once and resume analysis only after cleanup settles. Bughouse match fail-stop/checkpoint retry, derived-export repair and analysis history retry are implemented with failure-first native publication/acknowledgment, malformed-input and owner-lifetime regressions; The initial 96 focused tests and merged 294 app/bughouse tests passed with analyze/lint; final native follow-up also verifies bounded creation durability, actual v1 writer compatibility and redacted malformed-input failures. Headless Linux production-panel/native-store fixtures verified blocked admission, exact Retry and explicit Resume to completed games. Windows/macOS lifecycle and durability guarantees are unverified locally. |
| H6 | H4, H5 | All existing modes: focus/shortcuts/navigation/close, settings, credentials, diagnostics and integrity checks | The complete cross-mode sequence below passes with real disposable storage, offline/error cases and headless UI checks | In progress: settings read/startup admission now preserves malformed or unavailable files, blocks default-based edits and engine startup, and retries the read before opening the workspace. Failure-first and review regressions passed; latest merged app/settings suite: 244 tests; analyze/lint passed. Headless Linux cold startup preserved the malformed file and Retry opened the workspace after repair. Credential read/retry and redacted diagnostics have eight reproduced failures and 97 passing focused storage, owner, authenticated-client and settings-widget tests; independent review and headless Linux failure/Retry and cached-malformation refusal passed. Final merged app/network/settings suite: 307 tests; analyze/lint passed. Malformed cached credentials require repair and restart; the legacy plaintext multi-key store has no new crash-atomic guarantee. Three combined acceptance tests now exercise native AppParts editing/training, an accepted rating across two scope reloads and section rename, sibling gap invalidation, guarded undo/refusal, and fresh-owner recovery after an injected post-namespace relocation interruption. They compare PGN, book and all four training participants after restart; a combined Shell test covers every mode, note-field shortcut ownership, offline Retry, blocked navigation and cancelled close. Supporting focus/exit/invalidation tests and three real-process training restart checks passed; analyze/lint passed. Headless Linux startup recovered a deliberately interrupted native relocation; a subsequent cold launch of the actual main_v2 entrypoint showed the same Preparation book, one learned line and its saved note, and the native model marked the removed sibling’s c5 answer as a gap. Disk inspection confirmed one rating/history/attempt and relocated selectors with no old-path rows. The read-only integrity report now covers strict settings, retained publication stages, concrete recovery metadata, book selectors, visible-folder generated formats and bughouse exports. Native byte/membership invariance tests, review, analyze/lint and headless startup/settings report/recheck proof passed. It performs no repair and makes no global freshness or credential/database-audit claim. The merged integrity/cross-mode focused suite passed 70 tests. Final full-suite verification remains; Windows/macOS guarantees remain unverified. |
| H7 | H6 | Remaining approved player/prep, database and tournament features, following their product rows | Each adds its own source/derived classification, durable unit and failure/restart tests while meeting the shared contracts | Not started |
| H8 | H7 | Platform/scale/compatibility gates, data migration rehearsal and switch-over readiness | No untested supported-platform durability claim; recovery and parity gates pass before old code is retired | Not started |

Compatibility and scale checks start in the batch that changes their boundary,
not only at H8. Do not put a failing test on main to reserve a later batch;
commit a regression with the fix that makes it pass. H1's smaller fixes do not
substitute for the operation and lifetime work in H2-H5.

The integration sequence is: edit and train a course chapter; start a rating;
rename its section while a book is active; change training scope twice; remove
an answering sibling; verify membership, progress and gaps; undo the rename;
interrupt a durable move; restart; verify those same facts from disk and then
from the UI. Check expected intermediate states, not just the final screen.
The answering sibling need not be selected in the active book: its deletion
then leaves the rename receipt's book participant unchanged and undo succeeds.
Also exercise a selected sibling. Its deletion changes that participant, so
undo must refuse, retain its receipt and preserve the post-delete PGN, book and
training bytes; a fresh open must show those same facts. This is the guarded
inverse contract above, not permission to overwrite intervening book changes.

Implementation tasks run relevant tests, analysis and lint. Visible changes
also need a headless app check. Documentation-only planning runs lint and link
checks; it does not require a screenshot or mark an implementation batch Done.
Update the existing contract when the implementation changes it, without adding
a parallel report or debt ledger. New public formats, dropped product behavior
or weakened compatibility remain product decisions; internal implementation
choices follow the contracts here.

## Order of work

The feature-delivery history and remaining product scope follow. Start with the
unfinished [hardening batches](#correctness-hardening-order) before expanding
these rows. A feature's earlier Done status is not an H-batch completion.

One row is one agent session. Each row ends with a headless screenshot the
product owner looks at, tests passing, and the work integrated into local
main. Rows deliver a feature, never a foundation; theme tokens, `SplitPane`,
settings, lint and Widgetbook appear inside the row that first needs them.

| Step | Scope | Ends with | Status |
|---|---|---|---|
| 0 | **Board on screen.** `main_v2.dart`, a window with the mode menu stub, board widget, move-tree widget; open a real chapter from Documents `repertoires/` read-only; click and arrow through moves. Only the theme values a board and a move list need. | Screenshot of a real chapter | Done 2026-09-19: 1.5k lines, 23 tests; second-agent review the same day, its findings fixed (typed file results, open race, move-list rewrite, 18 more tests) |
| 1 | **Engine.** Supervisor, one Stockfish, engine pane with MultiPV lines at 200 ms, kill-on-exit test on Linux. First step that can fail, so it also installs the log: facade in `diagnostics/`, file sink in `storage/`, installed by `main_v2` before the engine starts. | Live evaluation on the board, and an engine that will not start named in `app.log` | Done 2026-09-19: 1.6k lines, 41 tests; a real Stockfish dies with a SIGKILLed parent on Linux (`test/v2/engines/stockfish_exit_test.dart`); a start failure is an `E start …` line in `app.log` |
| 2 | **Document store.** `PgnDocumentStore` (open, save, create, rename, move, recoverable delete) with revisions; add moves and comments in the workspace; save; undo from receipts; every replaced version recorded per [Backups](#backups); the required failure tests; the old app sees the edit. | Edit a chapter, reopen it in the old app | Done 2026-09-19 (owner has not yet seen the screenshot): 6.4k lib lines total, 217 tests; store with revisions, backups and the cross-process lock proof; moves, comments, autosave, undo and conflict handling in the workspace; the old app reads the edit. 2026-09-20: saves settle a second after the last edit instead of going out per move, backups are plain copies, the post-write read-back and backup read-back are gone, and every byte-wide step runs off the UI isolate. Windows replacement and sharing retries built 2026-09-25. Not built: retention/pruning, delete/promote/NAG edits |
| 3 | **Library.** Repertoire list, search, create, rename, move, recoverable delete; training references follow chapter changes. Import is `Open PGN file…`, Ctrl+V and a dropped file with no form (owner, 2026-09-22; `docs/v2/features/repertoires.md`). | Screenshot | Done 2026-09-19 (owner has not yet seen the screenshot): 7.7k lib lines total, 264 tests; repertoire folders with chapter counts and search, create, rename, move a chapter, recoverable delete of a chapter or a whole repertoire with the training rows following each file, shared name and confirm dialogs. Import built 2026-09-22 (`codex/v2-import`): `Open PGN file…` / Ctrl+O in the builder and `Paste PGN` / Ctrl+V make a repertoire named after the file (or `Pasted repertoire`), with no form; `chess/pgn/repertoire_import.dart` cuts every variation into a line of its own, one chapter file per `ChapterName` (Lichess study) or per shared player-header title (Chessable course), model-games chapters and finished games kept whole, the side read off `// Color:` or the shape of the tree (`inferredRepertoireSide` in the same file) and otherwise asked once on open; the files are written into a `.import-` staging folder and renamed into place, so nothing half-written is ever listed; `Create repertoire` asks for a name only. Screenshot: a pasted Chessable course as two chapters, opened on the first. Recovery built 2026-09-22 (`codex/v2-chapter-recovery`): `Deleted chapters` under the repertoire list swaps it for the chapters in every repertoire's `.cap-pgn-history/` (the old app's quarantine names, `DeletedChapters` in `storage/chapter_files.dart`), grouped by repertoire, newest first, each with `Restore`, which moves the file back through the store so its training rows follow it; a name taken since is asked for again, never replaced; a deleted repertoire comes back chapter by chapter. Screenshot: a deleted Jones chapter and the whole `e6 benko` repertoire restored. Not built: a dropped file (no drop package in the project), the old app's whole-repertoire receipts under `.chess_auto_prep_trash/`, the folder Organize view, studies, the picker other modes push, late writes from an active trainer session re-adding an old path (no v2 trainer yet) Course files 2026-09-22: a course imports as one PGN whose games name their chapter in `[ChapterName]`; its chapters open, edit, rename, delete and exchange lines inside that one file, and edits pin `[LineID]` so progress keeps its keys ([Course files](#course-files)). Not built: merging an existing folder of chapter files into one course file, per-chapter `// Root:`/`// Draft` inside a course file |
| 4a | **Chapter outline.** The open repertoire's chapters and the open chapter's lines in a column beside the board, with search, the line operations, the move edits that rewrite whole games, and a playing side that can be changed. | Screenshot | Done 2026-09-20: 18.4k lib lines total with step 4b, 802 tests; the column lists chapters and lines (name, branch-point moves), clicking opens a chapter or moves the cursor, 200 ms search over names and movetext, rename/delete a line with an eight-second Undo, New chapter, Delete from here / Promote variation / Make main line on the move's right button, and a two-button side that rewrites `// Color:` in place. Not built: move a line to another chapter, drag and drop, multi-select, folders, course sections, split, import, check disk, publish, a line count for chapters that are not open, and a resizable or collapsible column. Reviewed the same day; its findings fixed (a moved game no longer takes the whitespace after it, a line that loses its moves keeps its name and id, the next edit closes the Undo offer, Ctrl+Z reaches the document from every column, the current line is worked out once per cursor move) Extended 2026-09-21 (`codex/v2-repertoire-builder`, 25.1k lib lines, 1,036 tests): chapter roots shown under names and `New chapter` from the board, `// Draft` chapters shown as Proposed, Ctrl/Shift multi-select, drag and drop of lines onto chapters (main lines) or lines (sidelines), `Move to chapter…`; `Library.moveLines` writes the target first. |
| 4b | **Study.** Study mode over the same workspace: the studies in Documents `studies/`, one game per chapter, the chapter list and its operations, per-chapter orientation, Lichess import from a URL, export, quiz markers. | Screenshot | Done 2026-09-20: 18.6k lib lines total, 816 tests; one session reads one game of a file as the chapter, so the study list, the chapter list, New/Rename/Orientation/Reorder/Delete chapter, New and Delete study, Copy study and chapter PGN, Lichess import from a URL and `[%tstart]`/`[%tend]` quiz markers all run on the same board, saver and store. Left out: drag-and-drop reorder (menu only), the chapter manager dialog, chessgames.com collections and `study/by/<user>`, PGN-file import, Save study PGN as…, per-chapter free-form tag editing, Set starting position on an existing chapter, clear comments/variations, study rename, the compact layout and the Train and Browse handoffs |
| 5 | **Trainer.** Training session over the workspace, scheduling, history and bulk actions on the existing CSV/JSONL formats. | Screenshot and one completed session | Done 2026-09-22 (owner has not yet seen the screenshot): a Train tab on the reading card, not a mode. `chess/training/` (line ids agreeing with the old app's on every fixture, SM-2, the drill: walkthrough, quiz, replay), `storage/training_store.dart` over the four shared files (row-level optimistic writes under the Documents lock, other rows byte for byte, `.pre-csv-v2.bak`), `features/trainer/` (Trainer, TrainingProgress, Lesson, the tab); the lesson takes the board through `workspace/board_claim.dart` and pauses the engine. This chapter or the whole repertoire; Learn 10 / Review due; four ratings with their intervals, keys 1–4, Space, ↓, Esc; Again comes round again; mistakes list; exclude, mark known/untrained. The card now starts wider than the board (2:3). Screenshot: Jones 1.e4 e5, 86 chapters, 1,559 lines. Added 2026-09-22 (`codex/v2-trainer-extras`): the move box (`chess/typed_move.dart`: SAN or UCI, played on the first unique legal match that cannot go on to name another move, so `O-O` waits for Enter while `O-O-O` is legal; `/` or any move letter typed on the lesson goes there), `Training order` / `Course order` / `Most likely first` (`chess/training/line_order.dart`; the last reads `CumProb`/`Importance` and shows only when a line has one), `Read` and `Open in Builder` on each row (a game row reads on click) and a mistake row putting its position on the board, all through `WorkspaceRequests.openAt`; moving to another chapter of a whole-repertoire scope reads nothing again. Added 2026-09-25: immediate-quiz Drill over searched lines, once per set with saved ratings; persisted Learn/Review/Drill limits, reply delay, mistake replay and drill shuffle; direct course PGN import on Train. See `docs/v2/features/trainer.md`. Not built: PGN header mirror (the CSV is the truth), remaining legacy depth/walkthrough/streak settings, studies as puzzles, the lesson's Line menu (`View moves and notes`, `Explore position in Builder`) |
| 6a | **PGN Viewer.** Open a PGN file (recent list or the desktop's dialog), list its games, one game at a time on the shared board, annotate through the same saver. | Screenshot | Done 2026-09-21, second pass the same day after the owner saw it: 21.0k lib lines, 937 tests. Reading column in the old app's shape (heading, engine as one row when off, moves with comments laid out as paragraphs with inline moves, diagrams and Chessable headings, a navigation row); editing is a strip behind Actions ▸ Edit / Ctrl+E (Done, Undo, save state, six glyphs, comment field); the eval bar is gone from the app; a typeable game counter under the board, ↑/↓ for games, Home/End/PgUp/PgDn for the line, F, E, Ctrl+B hides the list (its `«` in the pane's corner, the `»` in the top bar), Ctrl+O opens a file, Ctrl+K types into the Actions menu; a file outside Documents is copied into `pgn_collections` on open. Third pass the same day: the reading column is half the workspace and a near-black rounded card, as the old app's. Under the board, in the height the board leaves, a card with the current move (number, glyph and its meaning) and its note, as Lichess shows it; it scrolls inside a fixed height and is left out when there is less than 120 px. Not built: right-click ▸ Comment, paste from the clipboard, filters, sort, the remembered reading position, My books, engine review, Tree and Collection, export, solitaire (an action of the viewer, per the owner), autoplay, fullscreen, handoffs |
| 6b | **Explorer tab.** The reading card's third tab, lila's explorer: a gear holding the source (Masters, Lichess with speed and rating chips, TWIC with the classical chip, This file, My games) and one muted summary line; the move / games / bar table with a totals row and the games list under it; TWIC offline from the local master database, the Lichess sources online-only with `Try again`. Decisions in `docs/v2/features/workspace.md`. | Screenshot, online and offline | Done 2026-09-22: `chess/explorer_answer.dart` and `explorer_choice.dart`, `net/lichess_explorer.dart`, `storage/master_book.dart`, `workspace/explorer.dart` (holding `ExplorerAnswers`, with `explorer_databases.dart` and `game_fetcher.dart`), `explorer_pane.dart` and `explorer_menu.dart`; 41 new tests, the required failure tests among them. The gear's choice is kept in `settings.json`. A listed game is fetched, kept as its own file under `pgn_collections/explorer games/` and opened in the PGN Viewer at the ply on the board. Screenshots: TWIC table with the hover board and the games; the Lichess chips behind the summary line; offline, `Could not reach the Lichess database — it needs a connection. TWIC works offline.` with `Try again`. Found on the way: `explorer.lichess.ovh` now answers HTTP 401 to every request without a Lichess token, so signed out the tab says `Lichess turned the request away. Add your Lichess token in Settings and try again.`; the token row already exists. Not built: the `This file` and `My games` sources (they need step 6c's collections) and a hover board on the games list. |
| 6c | **Collections.** Collections from `app_games.db`, filters, the `This file` and `My games` explorer sources fed from them. | Screenshot | Partial 2026-09-23 (owner has not yet seen the screenshot): `storage/game_store.dart` reads the old app's `app_games.db` read only on another isolate (absent, busy, damaged and newer-schema files are typed results; rows without PGN are counted); `chess/opening_index.dart` merges games by position (main lines to move 25, W/D/L plus undecided, the first 100 games) and is narrowed at answer time; `chess/game_filter.dart` is the old viewer's header rules. `workspace/file_filter.dart` owns the filter over the open file (applied 300 ms after typing; another file, a paste or close clears it and drops a pending change); `workspace/local_games.dart` holds `This file` (`FileTree`, the open file's games under the filter, built on a killable isolate past 64 KiB — another file, a paste or close stops it and drops its tree, an edit of the same file keeps answering until rebuilt) and `My games` (`MyGamesTree`: the `games_library` downloads plus the database's library, Player analysis and tactics collections for the saved accounts, each game once). Both are segments of the Explorer tab's source row, the table and games list unchanged; a `This file` game opens in place where its main line reaches the position. The viewer column gains `Filter games` (chips, Field / Rule / Value blocks with typeable `ui/choice_field.dart`). Screenshots: `This file` on a seven-game collection, narrowed to `4 of 7 games` by `Player contains Alvarez`, and `My games` from a test `app_games.db`. Not built: position and move-sequence filters, the saved slice per path, `Include variations`, opening an `app_games.db` collection in the viewer as a list, sort |
| 7 | **Generation.** `Fill gaps from here…`: a one-dialog launch, progress as a line in the card, cancel, the result as a `// Draft` chapter carrying `[%expectimax]` tokens, and the expectimax column of the Replies tab; expectimax rewritten from ALGORITHM.md and compared with the old app on the same input. | One real build | Done 2026-09-22 (`codex/v2-fill-gaps`): Actions ▸ `Fill gaps from here…` asks three numbers (rating, half-moves, cover once in N) in one dialog; the search runs from the board for the chapter's side with the chapter's own moves as pins, Maia-3 as the opponent, a second Stockfish at depth 14 behind `eval_cache.db` in the old app's format (`storage/eval_cache.dart`, sqlite3, deepest wins) and the reply floor `1/N` as a second horizon; the engine pane reads `Paused while filling gaps`; the card shows `Filling gaps · depth 3/8 · 412 positions` with Cancel; the result is `<chapter> (draft)` beside the chapter, `// Draft`, at most 100 lines most reached first, near-copies folded in as sidelines by the old diversity bar (`chess/generation/draft_lines.dart`), lines the chapter already plays left out, every move carrying `[%expectimax]` and `[%score]`, the first `[%cumProb]`; the v4 tree is kept under `.cap-generation/`; the Replies tab shows the `[%expectimax]` value beside each of our candidates or `not in tree`. A real fill at depth 3 on a two-line Italian chapter wrote 8 lines in about 20 s. Not built: `Prefer traps` and trick lines, resuming a kept tree, ChessDB as a source. 2026-09-23: reworked into the Search tab — inline numbers and one Search/Stop button, a live table of expectimax and engine values at the board, no pins or `Prefer traps`, lines only on `Make lines` (`generation.md`). Same day: nothing pruned, no default depth, `Stop after depth N`, finds kept in `finds.db` and listed in the Positions column (Actions ▸ Panels, Ctrl+P) that opens each line on an analysis board (`generation.md`, last section) |
| 8 | **Checks.** Holes/tricks, coverage, audit and planner as side-panel tools on the same document. | Screenshot | Partial 2026-09-21: coverage and the planner are the Replies tab — Maia-3 in `engines/maia/` (mem patterns disabled, rewritten from the old contract), `workspace/replies.dart` (the table), `gap_hunt.dart` (the walk and Next gap) + `gap_walk.dart`, sharing `reply_model.dart`, the `Moves` \| `Replies` tab strip (`ui/pane_tabs.dart`), Next gap, Opponent rating and Cover-once-in settings; screenshot showed 15 gaps · 12% covered on a three-line chapter. Holes, tricks and the audit are not built; the owner's decisions are in `docs/v2/features/repertoires.md` and `generation.md`. |
| 9a | **Tactics: puzzles.** The set, filters, puzzle session, stats written back. | Screenshot and one completed session | Done 2026-09-22 (`codex/v2-tactics`): Tactics in the mode menu. The left column is the queue: `Play tactics (n)`, the count with the kinds under it, the filters behind a `Filters` disclosure beside the count they change (kinds, order, group by game, unreviewed only, hide one-star, last N days), a search box and the puzzles, which are exactly what Play plays. A puzzle is a game of `Documents/tactics_sets/Default.pgn` on the shared board with `DocumentSession.shownTo` hiding the answer from the move list, the note under the board and the arrow keys; the engine is switched off for each puzzle. The card gains a `Puzzle` tab: side to play, `You played f4 (mistake)`, the feedback line, Show solution / reset / Skip→Next in fixed places, stars once the answer is on view, auto-advance, `Puzzle 3 of 12 · 1 failed` and End session, then the recap with Retry mistakes. The first attempt is written into the game's own headers in the old app's order through the session's saver (only that game is rewritten; the analyzed-games line is kept). Space shows the solution and ↓ moves on while a puzzle is up. Decided without the owner: the list is the queue (one filter, not separate browse filters); a revealed answer is recorded as nothing, as the old app did. Not built: accept other winning moves, the tactic editor and row menu, delete, multi-select, the source game in the Game tab, the old app's CSV sets and study-as-set review. 2026-09-22 second pass (owner: "just set up my accounts and do some tactics"): each mode keeps its own card tabs — Tactics has only `Puzzle` (pinned) and `Game`, with Explorer from Actions; no header, game counter, engine row or move arrows while the answer is hidden, the engine off on entering the mode; Tactics' own Actions menu; `Analyze` opens the Game tab with the engine on; ↑ / ‹ go back a puzzle; the filter starts on every date and an emptied window offers `Include older puzzles`; buttons re-themed app-wide for contrast (filled 5.3:1, a secondary blue-grey 9.6:1) with icons on Play / Next / Skip / Show solution |
| 9b | **Tactics: my games.** Download from Lichess and chess.com, the Stockfish review that mines puzzles into the set, pause and resume, game cards, moments strip, opening review. | Screenshot, online and offline | Partial 2026-09-22 (`codex/v2-tactics-cleanup`): the top of the Tactics column is `Add accounts` (a two-field dialog, no login) and then the usernames with `Change`, one `Get games` / `Pause` / `Resume` button and one status line (`Looking for your mistakes… 7 of 20`, `Review complete · 95 new puzzles`); Actions has `Get my games` and `My accounts…`. Screenshot online: a Lichess account's 20 games reviewed into 95 puzzles that arrived in the list during the run. `MyGames` keeps the Lichess and Chess.com usernames under the old app's preference keys, downloads the newest 20 games per account (Lichess export with the token as a bearer and 60/120/240 s 429 back-off; Chess.com monthly archives), keeps them in the old app's `games_library` cache and reviews from it when a site cannot be reached, judges each of the user's moves at depth 15 on the pane's cores, and appends puzzles in the old app's text to `Default.pgn` with the game id in the analysed-games line in the same write — through the session when the set is open, else through the store. Not built: game cards, moments strip, time-control filters, flaw tags, the Maia-shaped answer line (the forcing-moves line is used), startup check; the book check and the opening review are row 9c |
| 9c | **My games: the book check.** The user's saved games read against their repertoires, in a mode of their own (owner, 2026-09-22). | Screenshot | Done 2026-09-22 (`codex/v2-my-games-book`): `My games` in the mode menu with the Tactics accounts block, a Games / Openings switch, a verdict per game and the ways games left the book grouped most often first, and a pinned `Book` tab with the move played beside the book's moves, `Show the move` and `Open in builder`. The check (`chess/book/`) is pure: a game is in the book up to the last position any repertoire of its side reaches, by any move order; it reads the Tree tab's index, now shared as `RepertoireShelf` over `chess/repertoire_index.dart`. A download asks for 200 games while fewer are saved. Spec: `docs/v2/features/my-games.md`. Screenshots: the list at the narrowest column, the Book tab, Openings, and Open in builder on the chapter at the position. Not built: mistake counts and moments on the games, a per-colour book choice, commentary lines as not recommended |
| 10 | **Players.** Player analysis, opponent search and prep sheets, tournaments, people directory, US Chess lookup. | Screenshot | Not started |
| 11 | **Databases.** Master games, TWIC import and browser, broadcast collections, Scid export. | Screenshot | Not started |
| 12 | **Engine tournament and Bughouse lab** on the shared supervisor. | Screenshot | Partial 2026-09-23, the Bughouse half (owner has not yet seen the screenshot): 6.4k lib lines against the old lab's 11.8k, 123 tests. Built from the web pages, spec in `docs/v2/features/bughouse-lab.md`: `chess/bughouse/` (two-board table, per-board line, setup boxes, Hivemind's scale and joint moves, matches and BPGN; keys, SAN and UCI checked against the Python tools on a generated fixture, `match.json` against an old-app fixture), `storage/bughouse_books.dart` (Hivemind book and FICS archive, read only), `storage/bughouse_matches.dart`, `engines/hivemind_*.dart` on the shared supervisor (install checked against the manifest before every launch), `features/bughouse/` (the table, scores from the book or a live search, Analyze, the archive, matches, the one screen). Screenshots: the start from the book; a live search filling in; Analyze; a match. Not built: the Engine tournament mode; the old lab's editable clocks, board editor palette and Compare clock scenarios (dropped, see the spec) |
| 13 | **Services.** Settings screen, Lichess and chess.com accounts, updates, diagnostics (**Open log folder**, copy diagnostics); Widgetbook. | Screenshot | Partial 2026-09-21: the settings store and dialog. One `Settings` value in `storage/settings.dart`, one writer (`SettingsStore`, `settings.json` in the support folder, a failed read preserving the file and blocking startup until Retry succeeds); a 640×300 dialog (the gear at the right end of the top bar, Ctrl+,) with a list of five places — Look, Engine, Files, Accounts, App — and the chosen place's rows, one line each, searchable across places. Rows today: board coordinates; engine cores, memory and lines (the engine restarts for cores or memory, re-searches for lines); copy files from outside Documents on open; the Lichess account (2026-09-22: Log in through the old app's PKCE flow, the wait with Cancel and Copy link, Log out, a personal-token row while signed out; the old app's keys, so both apps share the account); Open log folder. Owner's rule for the page: a row only when two people want different values and the app cannot tell; a mode's own knobs stay in the mode. Not built: figurines, chess.com, updates, diagnostics copy, Widgetbook |
| 14 | **Switch-over.** `main.dart` starts `v2`; delete the old code, tests, ledgers and checks; move `lib/v2/` to `lib/`; gather the folders the app writes in Documents (`repertoires/`, `studies/`, `pgn_collections/`, `games_library/`, `analysis_games/`, `tactics_sets/`, `opponents/`, `engine_tournaments/`, `exports/`, `repertoire_debug_runs/`, and the tools' `expectimax_runs/` and `lichess_broadcasts/`) under one `Documents/Chess Auto Prep/`, moving existing data once with a backup of every moved file and rewriting the settings keys and training references that name old paths (owner decision 2026-09-21; not earlier, because both apps must share the same folders until then); rewrite COMPONENT_MAP and the agent guides. | Old code gone | Not started |

A row that turns out too large for one session is split into two rows here,
each with its own screenshot; it is not stretched over two sessions.

### A step is done when

1. The product owner has seen the screenshot and accepted it.
2. Everything in the row's scope works in the running `v2` app, or the owner
   dropped it (remove it from the row so it is never ported).
3. It reads and writes the same data as the old app, and both run at once.
4. Tests cover its user actions, its failure paths and every write it makes.
5. Every failure it can hit names the action in the log, and the screen says
   the same thing in plain English.
6. Its `v2` code is smaller than the old code for the same features. If it is
   not, stop and review the design before continuing. Tests are counted
   separately.

Mark the status cell *Done* with the commit. Nothing else is written down.

### Known hard problems

Each belongs to the step that owns it:

- **Step 3:** chapter rename, move and delete must update training references,
  including late writes from an active session and a reused path.
- **Step 3:** the old app serialises every repertoire operation behind a lock
  on `<repertoires>/.cap-directory-domain` as well as the folder locks both
  apps take; `v2` does not take it yet, so against the old app the folder
  locks stop two writers in one folder but not two repertoire-wide
  operations.
- **Step 6:** opening another file, pasting, recovery and close must stop
  delayed collection, filter, index and analysis work.
- **Step 2/7:** autosave is bounded (no unbounded queue of snapshots);
  generation publishes only against its source and run identity, never over an
  edited companion PGN. Legacy artifacts stay readable; legacy runs are not
  resumed.
- **Step 2:** a backup that cannot be recorded must fail the write without
  leaving a half-applied change, and retention must never race a save.
- **Step 13:** tokens are plaintext in SharedPreferences. Migrate one account
  at a time: write the vault, read it back, then remove the old key.
- **Platforms:** engine cleanup after a killed app is verified only on Linux.

## How agents work on this

### The brief

Each mode has a behaviour spec in [`docs/v2/features/`](v2/features/README.md):
what is on the screen, what the user can do, what data it touches, what can
fail, and the owner's Keep / Change / Drop verdict on each item. The spec is
the scope of a row; the row text in the table is its summary; the old code
is consulted only for file formats and algorithms. A row starts when its
spec says `corrected by the owner`.

The product owner starts a session with one row and this brief, filled in:

```text
Goal: v2 step N — <the row's scope in one sentence>; screenshot; tests;
integrate; stop.

Rules:
- Work only in lib/v2/, lib/main_v2.dart and test/v2/. Never import or copy
  old lib/ code; read it, then write the v2 version. Never edit the old app.
- No new pub packages. No package or framework evaluations.
- No documents except the one status cell in docs/ARCHITECTURE_RENEWAL.md.
  No evidence logs, checkpoints, reports, ledgers or diaries.
- No scaffolding for a later step. Build what this step's screenshot needs.
- From step 2 on, every PGN write goes through PgnDocumentStore; other stores
  own their formats and join compound operations where the contracts require it.
- Budget: stop after about three hours of work or when the goal is met. If not
  done, commit what runs, integrate it if checks pass, and report what is
  missing in three lines.
- Done = screenshot from the headless driver, tests passing,
  python3 scripts/check_v2.py clean, scripts/ci.sh analyze lint, integrated to
  local main, v2 line count reported. Before saying done, answer the nine
  reviewer questions in docs/ARCHITECTURE_RENEWAL.md with a file and line.
```

To see the app: `python3 scripts/app_driver.py start --target lib/main_v2.dart`
from the worktree, then copy a chapter into the profile's
`Documents/repertoires/<name>/` folder that `status` reports.

### Session rules

- **One row per session.** Never "finish the plan", "the whole renewal" or an
  overnight goal. The next row starts after the owner has seen the screenshot.
- **Before integrating**, run `scripts/ci.sh analyze lint` and the `test/v2/`
  suite. The old app's full suite is not run for `v2` changes.
- **Status is the table cell.** Commit messages and tests are the record.
- **Review:** one independent review of the diff against the
  [reviewer checklist](#reviewer-checklist) when a row is marked done.
- **After a context reset**, re-read this file and `git log -- lib/v2`.
- **Ask the product owner** about scope, dropping something and visible design.
  Decide implementation details without asking. In an
  [unattended run](#unattended-runs) a visible-design question defaults to
  what the old app shows for that mode, and the question goes in the report.
- **When unsure, do the smaller thing.** Unsure whether to add a class: do
  not. Unsure whether something is an owner: only if it holds mutable state
  that outlives a widget; otherwise it is a value or a function. Unsure where
  a file goes: the import table decides, and a file that needs two folders is
  two jobs. Unsure about a screen: match the old app's screen for it.

### Unattended runs

When the owner is away, one session works through several rows with this
prompt. It is the brief above plus the review, the stop rules and the
report; nothing in it lets the agent choose scope.

```text
Work through docs/ARCHITECTURE_RENEWAL.md, "Order of work", one row at a
time, starting at the first row whose status is Not started. First read the
whole file, then `git log --oneline -- lib/v2`, then every file in its
style-reference table. For each row, in this order:

1. Review the previous row: spawn one subagent with the reviewer checklist
   and the "Keeping the UI replaceable" section over
   `git diff <first commit of that row>^..HEAD -- lib/v2 test/v2`. Fix every
   must-fix finding in a commit of its own before starting the new row.
2. Make a worktree: `python3 scripts/agent_worktree.py v2-stepN`.
3. Read the row's spec in docs/v2/features/ (stop if it is not marked
   corrected by the owner). Build the row from the spec; nothing for later
   rows; Drop lines are never built. When it needs a value the old app has (a colour, a size, a file format, a layout), read
   the old code or screenshot the old mode and copy the value, never the
   code. Owners first, with their tests; widgets last, from the owners.
4. See it: `python3 scripts/app_driver.py start --target lib/main_v2.dart`,
   seed the profile the driver reports (copy a chapter from the old app's
   Documents/repertoires; never point v2 at the real folder from a test),
   drive the feature, take a screenshot and open the PNG yourself. Check:
   the row's feature works on a real chapter, nothing overflows, only Inter
   and Source Code Pro, no colour without meaning, nothing below 12px.
5. Checks: `python3 scripts/check_v2.py`, `scripts/ci.sh analyze lint`,
   `scripts/ci.sh test test/v2`. All clean, no skips you added.
6. Stop the preview. Commit, push, `python3 scripts/agent_worktree.py
   --verify .`, `python3 scripts/agent_integrate.py`, then `--verify`. Set
   the row's status cell to `Done <date>: <lib lines>, <tests>` and change
   nothing else in docs.
7. End the row with a five-line note: what works, the screenshot path, what
   was left out, what you were unsure about, the commit on main.

Then start the next row.

Stop and wait for the owner when:
- a row needs a design or scope decision the plan does not make: say what
  the choice is, do not pick;
- a row has taken more than three hours: integrate what runs, report;
- a row would write to user data (step 2 onwards) and its required failure
  tests are not green;
- the reviewer reports the same kind of problem in two rows running;
- a tool (driver, runner, engine) has failed twice in a row.

Never: work on the old app, add a pub package, write documents beyond the
status cell, run the old app's full suite, copy old code, or start a row
because the previous one "mostly" works.
```

## References

- [DATA_INTEGRITY.md](DATA_INTEGRITY.md): stores, formats and recovery files.
- [COMPONENT_MAP.md](COMPONENT_MAP.md): what the old app does, for parity.
- [ALGORITHM.md](ALGORITHM.md): tree-generation pipeline.
- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations).
- [SQLite: how to corrupt a database](https://www.sqlite.org/howtocorrupt.html)
  and [WAL](https://www.sqlite.org/wal.html).
- [Windows Job Objects](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects)
  and [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew).
- macOS runs Stockfish from `Contents/Helpers`, signed at build time with
  sandbox inheritance after verifying the pinned archive. Extracting the
  upstream signed binary at runtime was rejected by the macOS sandbox. The
  packaged release check exercises the helper under the release entitlements.
  [Apple's helper sandbox requirements](https://developer.apple.com/library/archive/qa/qa1773/_index.html).
