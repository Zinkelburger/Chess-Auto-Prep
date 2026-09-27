# Architecture renewal evidence record

**Closed record of the first, in-place renewal attempt (Sept 16–18, 2026).**
Do not extend it. The [current plan](ARCHITECTURE_RENEWAL.md) replaces that
approach with a fresh app in `lib/v2/` and keeps status in its own table.
Section links below that point at the old plan refer to its version at commit
`449d5428`. Nothing here overrides the current plan.

### Builder native history and private graph cutover (2026-09-17)

Source `09aeb6ed` replaces Builder append/history authorization with validated
native revision receipts and one session edit/history queue. Deletes
`AppendMovesResult`, `appendMoveAtPath`, `appendMovesAtPath`, `rebuildLine`,
`reconcileInstalled`, the duplicate writer queue and Builder's public mutable
`openingTree`. All Builder graph consumers use the protected query projection;
the decoder's mutable graph is copied into exclusive session ownership. Zero
remaining retired API references were verified in `lib/` and `test/`.

515 focused tests and three Linux native journeys passed: batched append and
successive UI undo, equal-text external replacement refusing undo while retaining
the document/board/graph/history, annotation/reload and import conflict. Merged
analyze/lint passed with 13 informational findings, no warnings/errors. This
completes the named history/graph responsibility without a compatibility shim.
Whole Builder still requires durable scratch recovery, host retirement and
remaining non-history edit contracts. Undo restores decoded PGN; original
encoding/raw bytes remain in native recovery archives. Other-host gates remain
unverified.

## Execution record — 2026-09-16

Historical evidence and decisions follow. Earlier temporary-bridge and
checkpoint sequencing is superseded by the current execution order (old plan at `449d5428`);
recorded test results retain only their original scope and limitations.

The product owner explicitly authorized the **whole renewal and end-to-end
validation**, not merely a planning update. Starting commit: `e477dc58`.
Implementation owner: the architecture-renewal task; product/visual owner:
the directing user. The existing release policy still applies. No release is
requested. Worktree: `codex/architecture-renewal`.

### S0 brief and reproduction

Scope: the three controller writes, storage-derived append receipts, guarded
successive/per-move undo, fileless sessions, draft deletion and chapter-switch
rejection. Keep the current formats, dependencies and decoded-content storage
contract. Native byte/file-identity revisions remain milestone 2 work; an S0
pass does **not** establish DATA-04 or power-loss durability.

The initial nine tests in
[`repertoire_mutation_safety_test.dart`](../test/features/repertoires/repertoire_mutation_safety_test.dart)
all failed on the starting implementation: color/root/import lost interleaved
writes; external-before-append annotations were lost on single and batched
undo; external-after-append and between-undo edits were overwritten; undo
bridged an unrelated external edit; and a failed undo consumed its entry.
These are reproduced failures, not just inspection findings.

Repair uses the existing expected-content guard. Append preparation supplies
immutable before-content and ordered logical steps from the same validated
baseline; one forward disk commit still supports one undo per actual new move.
The writer links only matching history and keeps committed provenance separate
from the mutable undo expectation. Duplicate additions do not invent history.
A malformed adapter receipt fails without manufacturing stale memory snapshots.
Draft deletion has a separate in-memory undo and never writes a whole chapter.
An uncertain undo is reconciled only against that attempted decoded result;
unrelated current content cannot refresh its expectation. Native identity and
cross-process replacement ambiguity remain outside S0's decoded-text guarantee.

Effort budget: S0 3 active hours, including 1 hour validation reserve; midpoint
after reproduction and first passing regression run. At that checkpoint the
nine failures were repaired and the first 76 focused tests passed. Additional
failure/chapter-switch cases and native desktop checks passed before integration.
The source checkpoint was reached in 31 minutes of elapsed time, including
build/test waits (an upper bound on active effort, not a user-task performance
measurement). No package spike was needed for S0.

### S0 exit evidence

Implementation commit: `19906aeecd652a5f52504d05acd80f6bfc8d1abe`.
The following evidence is scoped to S0, not a pass for the replacement
architecture or all workflows sharing the same requirement ID.

| Requirement ID | Scope/host | Check or test path | Result | Commit | Remaining limitation |
|----------------|------------|--------------------|--------|--------|----------------------|
| DATA-01 | Three current-code repertoire actions / Linux | `test/core/repertoire_mutation_safety_test.dart`; `integration_test/repertoire_mutation_test.dart` | Pass: interleaved replacements rejected, missing destinations fail, import drafts survive conflict/retry | `19906aee` | Decoded-content guard; no native byte/identity claim |
| DATA-03 | Append/batch/undo/draft deletion / Linux and deterministic failures | `test/core/repertoire_writer_undo_test.dart`; `test/core/repertoire_mutation_safety_test.dart` | Pass: validated before-content, per-move/successive undo, external edits before/after/between, broken history links, definite/post-install failure, refresh failure, malformed receipt, 20-entry history | `19906aee` | Future native revisions must repeat these contracts; no power-loss claim |
| STATE-01 | Repertoire append session and import confirmation | `test/core/repertoire_mutation_safety_test.dart`; `test/widgets/pgn_import_dialog_test.dart` | Pass: queued/in-flight chapter switches cannot update the new session; one pending import commit, draft retained on failure | `19906aee` | Does not establish application-wide job ownership or Riverpod lifecycle behavior |
| TEST-01 | S0 maintenance increment / Linux | `scripts/ci.sh analyze lint`; 11 focused test files listed below; both desktop targets | Pass: 150 focused tests and 8 desktop tests; analyzer has 9 existing informational lints, no warnings/errors | `19906aee` | Full release/offline/engine gates not run; no release requested |
| DATA-01 | Native missing-destination retry and restart | Private app driver; [inspected screenshot](images/architecture-renewal-unsaved.png) | Pass: draft remains readable, restore destination and retry saves once, driver restart/reopen retains all three games and external annotation | `19906aee` | Automatic fixture/agent inspection, not a human usability study |
| PLAN-01 | Renewal inventory | Execution record above/below | Unverified: scope and initial owner/parity map recorded; inventory incomplete | `19906aee` | Detailed schema/key/reference/native matrices and measured UX/performance baselines still required |
| DATA-04, DATA-05, DATA-06, DATA-07 | Replacement storage/artifact contracts | Not implemented by S0 | Unverified | `19906aee` | Native identity/durability, consistent restore and generated-artifact publication remain pending |
| OPS-01, OPS-02 | Native coverage | Linux app builds/boots; Windows/macOS unavailable | Unverified for renewal exit gates | `19906aee` | Signing, installers, native crash diagnosis and other-host checks not run |

Reproduce the focused suite with:

```sh
scripts/ci.sh analyze lint
scripts/ci.sh test test/core/repertoire_mutation_safety_test.dart test/core/repertoire_writer_test.dart test/core/repertoire_writer_undo_test.dart test/core/repertoire_controller_test.dart test/core/repertoire_load_test.dart test/core/repertoire_line_save_switch_test.dart test/services/repertoire_service_test.dart test/services/repertoire_file_editor_test.dart test/utils/atomic_file_safety_test.dart test/widgets/pgn_import_dialog_test.dart test/screens/repertoire_screen_test.dart
scripts/ci.sh integration integration_test/app_test.dart integration_test/repertoire_mutation_test.dart
```

`integration` now accepts focused targets and gives each executable a separate
bounded display/session bus. The first combined native attempt failed to attach
to its second executable; separate launches fixed that harness failure. The
initial native test also expected a success snackbar, but the product deliberately
suppresses those; the final test checks the imported line and persisted content.
The final dialog layout received another passing 9-test run after screenshot
inspection fixed a truncated error label. These reruns are not added to the
150 unique focused-test count.

The desktop app-recreation test logs an inline-engine preparation warning during
teardown/recreation; its data/UI assertions pass. The separate headless preview
showed real Stockfish analysis, but this is not evidence for the full PROC-01/
PROC-02 lifecycle gates. The preview was stopped before final checks.

**Next required increment:** complete milestone 0's missing inventory and
measured baselines, then implement and validate the first repertoire slice.
Milestones 1–7 and PLAN-02 have not been completed. The catalog boundary
checkpoint below starts the Riverpod migration; no new design direction,
shared native-revision store or vault migration is claimed.

### Catalog boundary checkpoint — first slice in progress

The renewed full-rewrite instruction retains the original scope. The prior
status-only turn did not implement architecture; this checkpoint changes the
production ownership. The first-slice budget remains 8 active hours, midpoint
4 hours, with 1 hour validation reserve and 30-minute package spikes. This
checkpoint starts that budget; it does not graduate milestone 0 or the full
first slice. The outstanding schema/reference/host inventory and measured
performance/restore baselines remain required before later slices expand.

Implemented paths:

- `lib/app/app_dependencies.dart`: app-owned dependency composition and scoped
  overrides; no implicit Riverpod retry.
- `lib/features/repertoires/models/`: canonical metadata, immutable creation
  results/requests and catalog snapshots. All callers use the new canonical
  metadata/result imports; the old files do not re-export them.
- `lib/features/repertoires/repositories/`: pure Dart catalog contract.
- `lib/features/repertoires/controllers/`: manual Riverpod presentation owner
  for load/create/rename/recoverable delete, with explicit command rejection,
  coalesced refresh, stale-read suppression and in-flight commit retention.
- `lib/features/repertoires/widgets/`: the production list, creation route and
  import/paste interaction. These no longer call global storage or the legacy
  creation service; forms submit injected domain requests.
- `lib/infrastructure/repertoires/`: injected compatibility adapter to the
  current storage/creation implementation. It preserves existing formats,
  chapter splitting, rename history handling and quarantine behavior.

The singular `features/repertoire/` remains the owner of unmigrated document,
outline and generation workflows, not a duplicate catalog. Its retirement is
milestones 3/5. The catalog storage adapter and legacy creation function remain
until the shared document/directory mutation contracts pass milestone 2/3;
non-catalog My-repertoires designation still calls that function. The existing
Provider app owners remain until their respective slices migrate; they do not
own catalog state. Picker/PGN codec helpers, shared theme/controls and the
chapter organizer are still legacy dependencies, with replacement in 1/2–3.

First-slice persisted-reference ledger (source inspection; not a restore pass):

| Authority | Format/key and owner | Required preservation / remaining evidence |
|-----------|----------------------|---------------------------------------------|
| Repertoire contents | `Documents/repertoires/<folder>/<chapter>.pgn`, `IOStorageService` and creation/chapter-split services | Catalog migration retains path, headers and bytes; native revision and multi-file creation transactions remain pending. |
| Recovery content | `Documents/.chess_auto_prep_trash/repertoires/`, `FileMutationService` | Delete moves directories without overwrite; native journey verifies recovered bytes. User-facing restore and interrupted-restore rehearsal remain pending. |
| Attempt history | `repertoire_move_attempts.jsonl`, `MoveAttemptStore` | Current directory rename calls `repoint`; full history/reference restore remains to test. |
| Designated opening books | SharedPreferences `my_repertoire_white_paths`, `my_repertoire_black_paths`, `MyRepertoireSettings` | These are folder paths. Current storage rename does not update these keys; the first-slice settings/rename transaction must address that existing gap before DATA-06/SET-01 pass. |
| Catalog UI state | Scoped controller snapshots; widget-local search and draft text | No new persistent schema/key. Persisted navigation/search restoration belongs to the shell work still pending. |

Package spike: stable `flutter_riverpod`/`riverpod` **3.4.3**, Flutter **3.47.2**,
Dart **3.13.2**, committed lockfile. Manual `NotifierProvider` and repository
provider overrides are used; no generation or experimental mutation API.
Transitive additions are `listen` (BSD-3-Clause) and `state_notifier` (MIT);
`flutter_riverpod` and `riverpod` are MIT. Licenses were inspected in the resolved
package cache. No second state owner
was created for a migrated action. Riverpod owns presentation only, and the
repository can be constructed/tested without a provider container. Native
plugin dependencies are unchanged. Package lifecycle/disposal/retry checks
exercise the locked version, following the [Riverpod 3 migration guidance](https://riverpod.dev/docs/3.0_migration).

Checkpoint verification (the source is the catalog-boundary checkpoint commit;
these are scoped results, not complete first-slice gates):

| ID | Scope/host | Check | Result | Remaining limitation |
|----|------------|-------|--------|----------------------|
| ARCH-01 | Migrated catalog / Dart | `scripts/check_architecture_boundaries.py`, its five regression cases, analyze/lint | Pass: widget/controller storage bypass rejected; pure models/contracts and injected infrastructure enforced | Legacy organizer/picker/codec bridges remain documented above. |
| STATE-01 | Catalog controller / locked Riverpod | `test/features/repertoires/repertoire_catalog_controller_test.dart` | Pass: ten cases covering overlapping actions, stale reads, immutable projections, synchronous/asynchronous read failure, explicit retry, write failure, disposal and offscreen commit | Document/jobs and whole-app ownership remain pending. |
| DATA-02, TEST-01 | Existing storage adapter / Linux | `test/features/repertoires/repertoire_catalog_repository_test.dart` | Pass: four real-filesystem cases for concurrent create, invalid input, rename collision and byte-preserving recoverable deletion | Native identity/durability and multi-file transaction gates are not proven. |
| TEST-01 | Catalog consumers / Flutter | Focused catalog, import/paste, course navigation, library, builder, creation, metadata and My-repertoires panel tests | Pass: 60 cases; the final synchronous-retry correction adds one case and reruns all ten controller cases | Not the full release suite. |
| TEST-01, UI-02 | Linux native app | `integration_test/repertoire_catalog_test.dart`, `integration_test/app_test.dart`, `integration_test/repertoire_mutation_test.dart` | Pass: nine journeys, including new create/search/rename/open/app-recreation/delete recovery and prior draft/conflict regression | App recreation is not a forced process-kill test; the existing engine Worker-unavailable warning on recreation remains outside this catalog gate. |
| UI-04 | Linux private headless preview | Inspected 1280×720 [catalog screenshot](images/architecture-renewal-catalog.png) after reload | Pass for existing catalog rendering, readable rows/actions and no overflow | No new appearance selected; product-owner design review and broader usability gates remain pending. |

Initial native test attempts failed because the reused disposable profile had
multiple rows, a prior run's name already existed, and the destructive confirm
uses a text button. The test now creates a unique name, targets its own row,
and locates the dialog action independently of button styling. These fixture
errors were corrected and the native sequence passed. Analysis/lint passes with
nine pre-existing informational lints and no warnings/errors. The final retry
fix also receives its focused native catalog rerun. No native file-identity,
full backup/restore, new design/ARB/Widgetbook, shared settings, persistent-shell
or Windows/macOS gate is implied. PLAN-02 stays pending until the complete
first-slice evidence exists.

### Native document-store checkpoint — Linux adoption started

The preceding catalog checkpoint is integrated as `1c7dd833`. This increment
implements the native-identity feasibility spike and the first production
consumer of the typed document boundary. The complete rewrite and first-slice
exit gates remain active; it does not graduate milestones 0, 1/2 or PLAN-02.

`features/documents/models/` and `repositories/` now own the cross-feature
`PgnDocumentStore` contract: open, exclusive create and revision-required save.
`infrastructure/documents/NativePgnDocumentStore` implements it using the existing
atomic writer's scoped transaction and the existing SQLite mutex. The writer
retains its lock until every started write completes, including a write that a
callback forgot to await. Legacy writers retain their existing API and behavior.

The private `packages/document_file_io/` C/Dart package reads bytes and identity
from one native handle, checks metadata and path binding, and hashes the exact
bytes before decoding. POSIX identity is device/inode; Windows source uses volume
serial plus 128-bit FileIdInfo. The code asset builds with the already-resolved
Dart native toolchain and is bundled in the Linux desktop app. Package license
is the repository's AGPL-3.0; no native binary download or extra runtime package
version upgrade was introduced. Native calls, hashing, text decoding and
compression run in isolates, not synchronous UI callbacks. See the
[package contract](../packages/document_file_io/README.md) and
[Dart's build-hook guidance](https://dart.dev/tools/hooks).

Production Linux catalog creation/import now receives this store through
`AppDependencies`; it no longer depends solely on the legacy check/rename create
path. POSIX exclusive publication uses link/unlink of the flushed staging file,
which cannot replace a competing destination. A save requires the captured
canonical-path document identity, native identity and SHA-256 revision; only a
confirmed committed receipt advances a baseline. After staging, the destination
is rechecked while the shared mutex remains held. Final symlinks, hardlinks,
non-regular objects, embedded-NUL paths and files over 512 MiB fail closed;
parent aliases are canonicalized. An external editor can still race validation
and rename: this is explicitly not filesystem compare-and-swap.

Before replacement the store retains exact prior bytes under
`.cap-pgn-history/<digest>.bytes`. Compressed PGNs remain compressed. Directory
flush and post-install observation precede acknowledgement. A post-install
failure returns `PgnWriteUncertain`, preserving the observed result, baseline
and recovery path rather than inviting a blind append retry. The creation and
import interfaces show explicit uncertainty copy and retain form/PGN drafts.
Recovery versions are never automatically pruned; user-facing restore/indexing,
retention policy and consistent database/document backup remain unfinished.

Evidence for this checkpoint (source: the commit containing this record):

| ID | Scope/host | Evidence | Result | Remaining limit |
|----|------------|----------|--------|-----------------|
| ARCH-01 | Typed document boundary | Architecture lint now covers `features/documents/` and prohibits native/FFI access in migrated feature layers | Pass | Existing editor/chapter/generation writers still need migration. |
| DATA-02, DATA-04 | Native store / Linux x64 | `test/infrastructure/documents/native_pgn_document_store_test.dart` | Pass: 18 cases, including same-byte replacement, BOM-only change, aliases, missing/unavailable identity, two writers/isolate contention, exclusive native publication, gzip preservation, transaction lifetime and injected commit failures | Other hosts unverified; full rename/delete lifecycle and stable identity/reference migration are pending. |
| DATA-05 | Recovery/error semantics / Linux | Exact baseline-byte recovery and post-install flush failure cases; existing atomic recovery suite | Pass for tested cases | Lock wait/hold measurements, large-file budgets, power-loss/remote-provider protocol, kill-at-each-step and Windows retry gates remain unverified. |
| TEST-01 | Native package and consumers | 61 focused Flutter cases across document, atomic, catalog, import and creation tests; strict C11 compile with `-Wall -Wextra -Werror`; app analysis/lint and package analysis | Pass (final checks recorded at integration) | Not a full release suite. |
| TEST-01, UI-04 | Linux packaged desktop | `integration_test/document_store_test.dart`, `repertoire_catalog_test.dart`, `repertoire_mutation_test.dart` | Pass: three journeys; uncertainty retains draft and a retry cannot replace the installed file | Existing inline-engine warning on app recreation is not a process-lifecycle pass. |

Initial work caught and corrected a package dependency constraint mismatch,
binding/type compilation errors, and a widget test that equated completion of
its fake disk write with completion of the controller/navigation handoff. The
final test waits for that actual handoff. These failures are not omitted from
the record, and the final relevant checks pass.

Final app analysis/lint passed with nine existing informational findings;
the native package analysis reported no issues. The private headless preview
was inspected: a duplicate name displays its error while retaining the name
and creation choices. The preview was stopped before the final source checks.

**Remaining first-slice work:** shared save-status/conflict/copy UI; route all
chapter/editor/import/generation mutations through the store; directory-mutation
coordination and multi-file course publication; preserve designated-book and
training references during rename/restore; typed settings; measured baselines
and consistent backup/restore; design-system/ARB/Widgetbook and persistent shell.
Windows replacement/ACL/backups/transient sharing and macOS full-sync require
native host evidence. Production adoption therefore remains Linux-only; other
hosts keep the documented legacy adapter, not an inferred native safety pass.

### Settings ownership checkpoint — book selections

Following native-store checkpoint `96ef8935`, the first typed settings section
lives under `features/settings/{models,repositories,controllers}`. App startup
injects `AppSettingsRepository`; the SharedPreferences implementation owns the
existing White/Black book keys. `MyRepertoireSettings` now adapts the same owner
for unmigrated Games consumers and has no independent persisted state. Its
process singleton is a temporary composition bridge, not a second writer.

Book edits serialize against a fresh read. Add/remove operations apply to the
latest state, inputs are captured/validated, and confirmed values are immutable.
Saving and failed states retain a distinct draft. Each write checks platform
success and reads back the value; a platform error after commit is reobserved
rather than rolled back. Explicit retry reapplies the operation to current
values. Legacy data with a wrong type or invalid path fails visibly and is not
silently overwritten. Successful reads deduplicate path lists without writing
on load. Only confirmed selection changes notify old analysis listeners.

My books now shows a retry action and pending choices on failure. If import
creates the repertoire but designation fails, retry only saves the designation.
The repository has a component-aware path relocation operation with partial
commit/retry evidence, but filesystem rename is **not yet connected**. The next
required step is a durable directory/reference coordination protocol, including
training references and restart recovery. Simply repointing settings after a
rename would retain the existing partial-commit failure; it is not presented as
completion. Engine/eval/training/display sections and credentials are still
unmigrated, and the first-slice SET-01 gate remains partial.

Verification: 70 focused repository/platform/Games tests and two Linux desktop
cases pass, including a real read-only preferences file and UI failure/retry
followed by a fresh-owner load. Analysis/lint passed with nine existing informational findings and six
boundary tests. Private headless screenshots were inspected for a real
read-only-file failure and its successful retry; the draft was absent from
confirmed books until retry, and the final JSON contained the chosen path.
The preview profile permissions were restored and the preview stopped. The initial widget run exposed a retained completed queue future
crossing the test clock boundary; idle queues now discard that future, and
widget tests inject a fresh owner and await the confirmed handoff. The failed
run was stopped through its own identified job service after the assertion
left the shared test owner pending. No other job was stopped.

The manual read-only-file preview exposed a separate platform-cache defect:
Linux's locked `shared_preferences_linux` 2.4.1 mutates a second cache before a
failed write and serves it even after `SharedPreferences.reload()`. Startup now
installs `FreshDesktopPreferencesStore` for the legacy Linux/Windows plugins:
it serializes every platform operation and creates a fresh plugin backend for
each, preserving existing keys, prefixes, filters and file format. This prevents
an unrelated legacy setting from flushing a failed book draft later. The three
platform/interface dependencies were promoted from transitive to direct at
their already-locked versions; no dependency version changed. Linux native
failure and retry are verified; equivalent Windows source is wired but has no
native host evidence yet. macOS keeps its native preference backend. This is
not a cross-process transaction, power-loss guarantee or completion of the
remaining settings migrations. The initially green injected-failure test alone
was insufficient; the real read-only-file regression now covers the defect.

### Directory rename checkpoint — Linux reference recovery

After settings checkpoint `c4835559`, Linux repertoire folder renames and nested
folder moves go through `infrastructure/repertoires/RepertoireDirectoryMutations`.
It records a versioned intent under Support `repertoire-mutations/` before the
namespace change. Native directory identity is device/inode; Linux publication
uses `renameat2(RENAME_NOREPLACE)`, so even an external creator racing the last
check cannot have its destination replaced. Unsupported native operations fail
closed. Namespace and journal directory flushes precede acknowledgement.

A pending journal is replayable only when the source is absent and the exact
recorded directory is at the destination. A preparation with the original still
at its source and no destination is cancelled rather than executed on startup.
Replaced destinations, reused source names, unreadable identities and malformed
journals block recovery and retain all evidence. Completed/cancelled receipts
are retained; no automatic retention policy is introduced.

Reference migration updates review schedules, review history, per-move progress,
mistake JSONL and both designated book lists. It reads the latest training file
under its existing lock, preserves other rows/unknown values, and retains the
first pre-migration text in Documents `.cap-reference-history/<operation>/`.
A partial failure can replay without double-moving already migrated paths. The
settings owner performs its existing verified field updates. This is a journaled
multi-step operation, not a filesystem/database/preferences atomic transaction.

Managed storage read/write/update/create/delete and the injected native PGN
store share a repertoire domain mutex with these directory moves; a staged PGN
save finishes before a waiting folder move. The domain mutex is derived from the canonical repertoire root and is separate
from namespace/file locks, avoiding recursive lock acquisition. Storage fixtures
with only a Documents override now derive their support/repertoire roots from
that fixture, instead of consulting the real user profile.

The catalog displays a persistent **Recover library** action for an incomplete
move and clears it only after a successful recovery read. It does not resend the
original rename. The Linux desktop journey exercises rename, injected
interruption, recovery through that action, retained PGN comments, training and
book references, and fresh catalog/settings owners.

Evidence: 89 distinct focused cases across directory/native-document/storage/
training/catalog tests; two Linux desktop journeys (the new recovery flow and
the existing create/search/rename/open/delete/reopen flow); strict C11 compilation,
app/package analysis and lint. Four step hooks cover preparation, move,
reference completion and journal completion. These are deterministic exception
and reconstructed-owner tests, **not** evidence of OS kill/power-loss durability.
Final headless screenshots show an ambiguous pending move blocking the catalog,
then successful recovery after the disposable ambiguity is removed. The
recovered PGN is present and its journal is completed. The preview is stopped
before final checks. App analysis/lint passes with nine existing informational
findings; package analysis and strict C compilation are clean.

Remaining at this checkpoint (trash restore advances below): journaled trash
restore and its catalog UI; multi-file course
publication; single-chapter/file rename migration; permanent logical document
IDs and stale training-session writes after a move; recovery/version retention;
external writers that do not participate in the domain mutex; lock/performance
budgets; and Windows/macOS native adoption. Legacy writers without a baseline
can still recreate a stale absent path after a completed move; migrating them
to the revision-required API remains necessary. Native pre/post identity checks
are not an atomic compare-and-swap against arbitrary external source replacement.
The first-slice data gates and full rewrite remain partial.

### Recovery checkpoint — Linux deletion and restore

Following `14eb0d62`, `RepertoireDirectoryMutations` now journals deletion and
restore as directory moves under the existing repertoire domain lock. Deletion
retains the whole tree at Documents `.chess_auto_prep_trash/repertoires/<id>`;
its receipt retains the original path and native identity. Newly created recovery
ancestors and both namespace parents are flushed. Restore resolves the receipt
by id, verifies identity, refuses collisions using native exclusive rename, and
records a separate completion linked to the deletion. Prepared-but-unmoved
operations cancel on recovery; moved operations finish references without
repeating the rename. Completed restore receipts cannot consume another
folder's deletion record. Records and recovery content are never auto-pruned.

All four training reference formats and book selections relocate into recovery
and back through the existing replayable migration. Parked book selections are
excluded from active Games analysis; restoration reactivates selections still
present in settings. Explicit subsequent selection changes remain authoritative.
A newer folder at the old path does not inherit the deleted folder's references.
The original PGN bytes, annotations and unknown training fields are retained.

The injected catalog contract/controller now own recovery listing and restore.
The Linux **Recovery** view accepts the original name or another name, displays
missing/replaced folders with restore disabled, and uses **Recover library** for
uncertain operations. Nested folders deleted through the legacy outline also
receive receipts and restore inside their original parent. The shared name dialog
explicitly permits the unchanged name for restore. Other hosts retain their
existing quarantine behavior and do not advertise the unverified restore UI.

Broader outline tests found a dependency leak: its parser ignored injected
storage and consulted `StorageFactory`, triggering desktop plugin access in
isolated tests. `RepertoireService` now accepts storage, and the outline and
chapter splitter pass their owner through. Pure text parsing stays independent
of storage. This repairs the ownership connection; it does not claim migration
of the legacy editor or multi-file splitter to the native document API.

Evidence for this checkpoint: 168 distinct focused regression cases pass. The
set covers the journal,
catalog controller/repository, My books, game deviations, outline, splitter,
file-mutation boundary, IO storage, parser, line moves and file editor. Native
journeys cover create/search/rename/delete, collision-preserving restore under
a different name, fresh application owners, interrupted folder rename, and an
interrupted restore through the UI using the original name. The initial desktop
check exposed the shared dialog's unchanged-name behavior; the initial expanded
outline run exposed the storage injection leak. Both were fixed and rerun.
Inspected headless screenshots show [the recovery list](images/architecture-renewal-recovery.png)
and [the restored library](images/architecture-renewal-restored.png). The preview
uses the disposable driver profile and is stopped before final checks. App
analysis/lint passes with the nine existing informational findings, and the
updated local documentation links and whitespace checks pass.

Remaining: adoption of older unjournaled quarantine entries; restoring nested
folders whose original parent was subsequently removed/moved; retained-version
UI and pruning policy; stable logical identities and stale training sessions;
revision-required migration of all writers; multi-file course publication;
consistent profile backup/restore; lock/performance budgets; process-kill and
power-loss rehearsal; Windows/macOS adoption; design/ARB/Widgetbook and the
persistent shell. The first slice and full architecture renewal remain partial.

### Publication checkpoint — complete new repertoire imports on Linux

After recovery checkpoint `1995d990`, new-repertoire creation no longer writes
the first chapter into the live folder and then splits it there on Linux.
`RepertoirePublication` describes the complete chapter set. A planner runs off
the UI isolate and shares the extracted `CourseChapterPartition` with the legacy
splitter; this removes duplicated naming/pinning logic instead of maintaining
two course interpretations. Canonical callers, including the generation planner,
use the extracted helper directly. Original line names/IDs, model-game tags,
unknown headers and annotations remain attached to their games. Course filenames
are unique after normalization and avoid reserved operating-system names.

`NativeRepertoirePublicationStore` creates a private batch under the same
filesystem at `repertoires/.cap-repertoire-publications/<id>/`. The typed native
PGN store writes the transformed `payload/` chapters and retains original input
text as `source.pgn`. A flushed manifest records directory identity and every
chapter's native identity and byte digest. Only a fully prepared folder reaches
the shared domain lock and a single `renameat2(RENAME_NOREPLACE)` publication.
An existing folder (even empty), concurrent same/case-folded name, or racing
external creator cannot be merged into or overwritten. The catalog excludes
private staging; ordinary folder moves/deletion cannot select it.

The publication manifest states are staged, pending, completed and cancelled.
Preparation failures leave the live library unchanged and retain private data;
forms retain their inputs and report that nothing was published. Recovery never
publishes an uncommitted staged draft. A pending intent with its original payload
still private and destination absent cancels; an installed folder is acknowledged
only when its directory identity and entire chapter set match the manifest.
Ambiguous/replaced/edited output retains its receipt and blocks subsequent
managed operations through the existing **Recover library** flow. Completed
receipts remain audit records; later intentional edits do not reopen them.
The shared creation helper routes the catalog and My books through this Linux
path; non-Linux hosts retain the existing adapter pending their native gates.

Verification: 162 distinct focused tests and four Linux desktop journeys pass.
Analysis/lint passes with nine existing informational findings; local document
links and whitespace checks pass. Regression evidence includes hidden partial staging; interruption after each
chapter, staged manifest, commit intent, install and acknowledgement; unchanged
and colliding destinations; two concurrent case-folded names; external creators;
staged/installed edits; directory replacement; source-text retention; reserved
staging operations; malformed/escaping/symlinked manifests; and reads waiting
for publication acknowledgement. Existing splitter, outline, creation, native
PGN store, catalog, import-dialog and My books tests cover compatibility.
The first expanded widget run exposed a fake-time wait on a progress indicator;
it now drains real controller completion while advancing route frames and asserts
the visible selected chapter. No production test bypass was introduced.

Native desktop journeys exercise failed preparation with draft retention,
interrupted publication followed by collision-preserving retry, the full catalog
create/search/rename/delete/restore flow, and course import/reopening with both
chapters, pinned IDs and annotations intact. A separate headless app check made
only its disposable staging directory read-only: creation retained its draft and
published no folder. Restoring permissions and retrying published both chapters.
Screenshots were inspected for [the retained draft](images/architecture-renewal-publication-failed.png)
and [the complete chapter list](images/architecture-renewal-publication-complete.png).
The preview was stopped and its fixture permissions restored before final checks.

Remaining: transactional splitting/merging of **existing** chapters and their
references; all legacy editor/generator writers; stable document identities;
UI for retained private imports and retention policy; large-document and lock
budgets; actual process-kill/power-loss rehearsal; Windows/macOS adoption;
full profile backup/restore; and the design system, ARB, Widgetbook and persistent
shell. Native identity checks do not provide compare-and-swap against arbitrary
external editors. New-directory atomic publication does not prove the separate
existing-document transaction gates. The first slice and full rewrite remain
partial, with PLAN-02 still pending.

### Localization checkpoint — migrated catalog presentation

After publication checkpoint `2bc97d9f`, the first slice adopts Flutter's
standard `flutter_localizations`, `intl` and `gen_l10n` workflow. English ARB
source and generated typed accessors live in `lib/l10n/`; both production app
roots register delegates and supported locales. This follows the plan's default
and [Flutter's localization workflow](https://docs.flutter.dev/ui/internationalization).
Only the SDK localization package and its pinned `intl` dependency were added.
English is the sole supported locale; unsupported device locales resolve to it.

UI-01/ARCH-01: migrated catalog labels, tooltips, validation, empty/error states,
rename/delete/restore prompts and creation/import/paste messages use typed
accessors. Plurals and formatted numbers are ARB messages; dates older than a
week use locale month names and include the year. Relative-time thresholds stay
shared with legacy callers. Pure `FileNameProblem` validation and typed repertoire
failures are mapped to messages in presentation. Architecture lint rejects
localization imports in migrated domain, controller and infrastructure layers.
Shared controls accept resolved labels. PGN tags, stored IDs and canonical
formats stay locale-independent; legacy UI localization remains with its owner.

Expanded English labels at 100%/200% text exposed an overflowing creation action
row. `OverflowBar` now stacks the actions when needed. Name dialogs scroll;
paste errors no longer have a three-line truncation cap. Creation/paste errors
are live regions. These checks cover the inexpensive expansion/scaling gate;
full pseudo-localization/RTL matrices and other-language translations are not
claimed. Existing theme/components remain until the design foundation migrates.

The check runner now generates messages before analysis, Flutter tests and
native integration checks. A direct test after an ARB edit had used stale
accessors, so regeneration is an enforced check prerequisite rather than a
manual memory requirement. Generated accessors are committed with their ARB.
The real-I/O course-import widget fixture starts its action outside Flutter's
fake-time zone so the native publication planner can complete; product code
contains no test-specific shortcut.

Verification: 57 focused tests and eight Linux desktop journeys pass. Analysis/
lint passes with nine pre-existing informational findings, including seven
architecture-boundary regression tests. The production catalog journey runs
with an unsupported French device locale and verifies English fallback through
create/search/rename/restart/delete/restore; the other native cases cover course
imports, failed/uncertain publication, reference recovery and settings failures.
Headless screenshots of [creation](images/architecture-renewal-localization-creation.png)
and [paste validation](images/architecture-renewal-localization-paste-validation.png)
were inspected. The private preview was stopped. Documentation links and shell
syntax/whitespace checks pass. No Windows/macOS, full release or screen-reader
certification is claimed.
This checkpoint advances UI-01 and ARCH-01, but does not complete either the
first slice or PLAN-02. Remaining first-slice work includes shared save/conflict
interaction, persistent shell, design-system/Widgetbook, complete settings and
native/recovery/performance gates. Milestones 3–7 retain their full scope.

### Design-system checkpoint — production controls and Widgetbook

After localization checkpoint `7cd67ca5`, `lib/design_system/` owns the canonical
production theme, motion, typography/spacing and five shared controls used by
the catalog. Existing import sites are retargeted and old control/theme paths
are removed, with no re-export copies. `WorkspaceTheme` supplies typed workspace
surfaces with `copyWith`/`lerp`; standard roles remain in `ColorScheme` and
`TextTheme`. The migrated catalog resolves the active theme and has no fixed
palette/type-size reads. Shared controls also resolve theme colors; dark neutral
values and bundled font names have one owner. The existing charcoal/neutral
accent treatment is retained as the first reviewable direction.

UI-01/ARCH-01: manual [Widgetbook 3.25](https://pub.dev/packages/widgetbook)
cases use these production components and repository contracts, with in-memory
library/recovery state and scripted creation success/delay/failure. Picker and
chapter-navigation seams prevent fixtures opening real user storage. Theme and
text-scale addons cover light/dark and 100/150/200%. A test exposed dialogs
falling back to Widgetbook chrome's 100% scale; the case host now captures its
scale along with Material's theme capture. This is fixture wiring, not a copied
form implementation. Theme-switch tests retain creation draft, focus and
selection, and reduced-motion navigation omits the fade.

The design system cannot depend on app/features/storage. Migrated widgets cannot
import legacy themes or invent colors/type sizes. The legacy exception ledger
names 257 remaining file owners and removal milestones; lint rejects new users
and requires deleting retired entries. Widgetbook cannot directly instantiate
real storage or access global singletons. The check runner analyzes the catalog,
and the app driver accepts an in-checkout `--target` while preserving bounded
execution, private display/profile, and checkout ownership.

Verification (Linux, source: the commit containing this record):

- 70 focused widget/unit cases pass, covering theme contrast, 100/150/200% text,
  dialog inheritance, keyboard rename, draft/focus preservation, reduced motion,
  localization and legacy callers of the moved controls.
- Five native desktop journeys pass: one real Widgetbook rename/delete/restore
  journey with memory fixtures, two production catalog journeys, and two native
  document-store failure/retry journeys. The fixture journey is not evidence of
  disk persistence; the production journeys exercise that boundary.
- `scripts/ci.sh analyze lint` passes with nine pre-existing informational
  analyzer notices and all ten architecture-guard regression tests passing.
- The driver launched `widgetbook/main.dart` on its private display/profile.
  Inspected [dark catalog](images/renewal-widgetbook-dark.png),
  [light catalog at 150%](images/renewal-widgetbook-light-150.png), and
  [light rename dialog at 150%](images/renewal-widgetbook-light-dialog.png)
  screenshots show readable controls and wrapping without overflow. Preview
  stopped after inspection. This is implementation review, not owner acceptance.

This checkpoint does not complete UI-01 or the first-slice gate: persisted light/dark/
system appearance, full focus/disabled/busy/accessibility matrices, native reader
checks and product-owner visual review remain open. Other screens still have
legacy dark styles. Shared save/conflict interaction, persistent shell, settings,
recovery/performance/platform evidence and PLAN-02 remain required. No later
feature milestone is graduated by this component migration.

### Shared save checkpoint — draft-preserving interaction

After design-system checkpoint `02a57df4`, the first-slice save foundation now
includes `DocumentSaveSession`, immutable save state and `DocumentSavePanel`.
The session receives `PgnDocumentStore` directly, with no Flutter/provider/I/O
imports. The shared `SaveStatus` control receives text, tone and action widgets;
the repertoire creation form adopts it and focuses/selects a colliding name
without clearing PGN or side. New English ARB messages own this presentation.

DATA-02/STATE-01/UI-01: a save submits the captured baseline and draft. Edits
during I/O remain dirty after a successful receipt; duplicate submissions do
not launch another operation. Conflicts and dismissal never adopt a newer
revision. Copies use exclusive creation and adopt the destination only after a
saved receipt. Uncertain outcomes block ordinary retry, including after edits
or dismissal; an uncertain copy is inspected at its attempted destination.
Unexpected adapter exceptions are treated as uncertain. A later failed copy
cannot clear a preceding uncertain-write warning.

Reload is explicit, reads afresh and retains displaced drafts in the session,
including text entered while the read was pending. Missing/read failures never
discard the draft or baseline. Each retained draft can be restored as unsaved
text against the currently loaded revision; restore itself makes no write.
Inspection is read-only and closing its dialog grants no replacement permission.
Widgetbook has clean, dirty, saving, conflict, collision, failure and uncertain
cases using the actual session and shared UI with a memory repository.

Verification (Linux, source: the commit containing this record):

- 60 distinct focused tests pass: the 59-case session/UI/localization/native-store
  regression run plus the added real-Widgetbook copy-dialog regression; all six
  Widgetbook cases pass after its fix. Coverage includes in-flight edits,
  duplicate submission, conflict/dismissal, missing/read failure, exclusive copy,
  uncertain write/copy, disposal, multiple retained drafts and keyboard focus.
- Three native desktop journeys pass: the new shared save interaction over
  disposable real files and both existing interrupted-import document-store
  journeys. The new journey verifies an external edit survives rejection,
  reload/restoration, a colliding copy and a successful copy reopened through a
  fresh native store. It was rerun after session changes.
- `scripts/ci.sh analyze lint` passes with nine existing informational notices
  and all eleven architecture-guard tests passing. Document widgets now obey
  the same active-theme boundary as catalog widgets.
- Headless inspection checked [dark conflict](images/renewal-save-conflict-dark.png),
  [light conflict at 200%](images/renewal-save-conflict-light-200.png) and
  [retained draft at 200%](images/renewal-save-retained-light-200.png). Visual
  inspection exposed the fixture copy dialog escaping the localized nested
  navigator; a test reproduced the crash before `useRootNavigator: false`
  fixed it. Repeated headless inspection verified the corrected
  [copy dialog](images/renewal-save-copy-light-200.png) and
  [saved copy](images/renewal-save-copy-saved-light-200.png) at 200% text;
  preview stopped afterward. This is not product-owner acceptance.

This advances the milestone-2 shared interaction requirement without claiming
complete document adoption. The fixture editor/picker is not a production
workspace. Legacy editor/generation/undo/chapter writers remain to migrate;
persisted draft recovery, close guards, large-document inspection, validation,
full workspace/session restoration and remaining native platform gates are
unfinished. Draft retention here is in memory and lasts only for the session;
it is not crash recovery. Persistent shell, appearance/settings, performance,
owner review and PLAN-02 remain open for the first slice.

### Persistent navigation checkpoint — repertoire workspaces

After shared-save checkpoint `e6111e70`, the repertoire library, Builder and
Trainer use `WorkspaceShell` with an owned nested Navigator. Repertoire/chapter
pickers and Builder planning/build/audit destinations retain the owning toolbar.
Child Actions targets navigation, not the hidden board; View and Settings remain
available. The root toolbar stays mounted to preserve its settings owner while
excluding its hidden controls from focus/pointer/semantics. Popup routes do not
replace workspace chrome. Back/Escape use the innermost route and respect busy
`PopScope` guards. Global modal tasks remain outside the workspace stack.

STATE-01/UI-02: mode changes retain nested pages, picker input and creation
forms. The library refreshes its injected catalog controller without changing
widget identity, and keeps the catalog mounted behind an open outline. Main's
inactive branches cannot claim keyboard focus; `WorkspaceBranch` restores the
last attached focus destination on return without taking focus from root
modals. Builder focus returns only to
its visible, active root. Builder/Trainer defer source handoffs while a nested
page is open, preventing a planning form's underlying source changing silently;
Builder also defers until generation ends. A newer explicit picker choice
supersedes an older pending request. Deferred work runs after navigation and
job callbacks complete, rather than mutating their source mid-callback.

Picker screen ownership moves into `features/repertoires/widgets/`, with all
imports retargeted and no shims. The production shell has a Widgetbook fixture
combining a memory catalog, actual creation controls and illustrative editor.
The nested-Navigator default remains selected; no router package is introduced.

Verification: 30 distinct focused shell, Widgetbook, MainScreen, Builder and
course-navigation regression cases pass (the final seven-case shell rerun
corrects a missing Material ancestor in its new test fixture). Four native
Linux application journeys pass: retained Builder picker/filter/position and
settings owner; creation draft and Escape after actual mode-menu round trips;
catalog create/search/rename/restart/delete/restore; multi-chapter publication
and reopen. The native round trip initially exposed lost keyboard focus;
`WorkspaceBranch` fixes it and both focused and native regressions pass.
`scripts/ci.sh analyze lint` passes with nine pre-existing informational
analyzer findings and eleven architecture-checker tests. Headless production
screens were inspected at 1280×720: [creation draft under its owning toolbar](images/renewal-workspace-creation.png)
and [Builder picker under its owning toolbar](images/renewal-workspace-picker.png).
The preview used disposable data and was stopped. Full release tests and
Windows/macOS native runs were not run for this checkpoint.

This does not graduate UI-02 or milestone 1/2: persisted document sessions, deep links, memory/frame profiling and nested
interactive-engine visibility remain unverified. Appearance/settings, remaining
recovery/platform/performance gates, owner review and PLAN-02 remain open.

### Appearance checkpoint — persisted preference and migrated surfaces

After navigation checkpoint `53c229bb`, `AppSettingsRepository.appearance` owns
one typed Dark/Light/System preference. Dark preserves the product default;
`app/themed_application.dart` selects the committed value and supplies both
canonical themes to MaterialApp. System resolves desktop brightness; explicit
choices stay stable. `features/settings/widgets/appearance_settings.dart` is a
localized, adaptive control reachable through Settings → Appearance and settings
search. It shows pending/failed choices separately from the applied value.

SET-01/STATE-01: the infrastructure owner serializes updates to `app_appearance`,
validates stored names, reads back successful writes and reconciles errors before
reporting committed state. Unknown keys are preserved until a user chooses a
replacement. Subscription/rebuild does not replay failed writes or failed loads;
Retry and Reload saved choice are explicit. Book selections and unrelated keys
remain independent. Native checks install the same fresh desktop preference
backend as production, including a real read-only-file failure and repair.

UI-01/UI-02: theme changes retain navigator identity, open routes, creation input
and focus. Shared Actions/mode menus, breadcrumbs, contextual hints and chapter rows use resolved
colors; the legacy-theme ledger shrinks from 257 to 252 owners. Settings chrome
and catalog/create/recovery destinations use the selected theme. Fixed-color
legacy modes, Builder/Trainer content and planning/audit pages, outline and old
settings forms remain inside explicit `LegacyThemeBoundary`/`LegacyPageRoute`
adapters. Retire those adapters with their feature owners; this is not a claim
that every legacy pane has a complete light design. Settings Widgetbook cases
use only memory contracts and actual production controls. The boundary gate now
also rejects fixed colors/styles and legacy theme imports in settings widgets.

Verification: 90 distinct focused regressions pass across preference contracts,
appearance widgets, Widgetbook, settings/navigation, shared menus/breadcrumbs,
Builder and chapter/course navigation. Those include both light/dark rendered
chapter contrast, 200% text in a narrow window, OS-brightness changes, explicit
overrides, slow/reentrant writes, invalid keys, failure/retry/read-back mismatch,
and navigator/text/focus preservation. Twelve architecture-checker cases and
`scripts/ci.sh analyze lint` pass with nine pre-existing informational findings.
Four distinct Linux native journeys pass: read-only preference failure/repair;
appearance change with an open creation draft and fresh-owner reload; Builder
picker/filter/position/settings retention; creation draft through mode-menu round
trips. All native tests use the runner's disposable profile.

The headless production app was also stopped and relaunched as a new process:
[Light remains selected after restart](images/renewal-appearance-restarted-light.png).
The [creation form and toolbar in Light](images/renewal-appearance-creation-light.png)
were inspected at 1280×720. The preview was stopped afterward. These are Linux
checks, not Windows/macOS, native screen-reader, physical-display or release-suite
evidence. Early compile issues and the final unused test import were corrected;
no new analyzer findings remain.
Remaining: migration of the bounded legacy interiors, OS/native accessibility
and platform checks, physical-display/owner review, performance and the other
first-slice gates. No change to the full renewal scope or milestone graduation.

### Study document adoption checkpoint (2026-09-16)

Milestone 3 is partial. Study's model/controller now have one canonical owner
under `features/studies/`; pure PGN text helpers moved to `chess_core/pgn/` with
imports retargeted, no compatibility re-export files. Tests mirror Study ownership.
App startup injects the document store and library repository; lint enforces the
new pure-model/controller/infrastructure boundaries. Legacy Study board/layout
widgets remain in their existing locations until their UI workflow migrates.

Study now uses the shared `DocumentSaveSession` via `DocumentSaveActions` and
exposes its real production recovery dialog. Linux app composition uses native
identity/byte revisions. Other hosts use a named content-only legacy adapter;
it cannot prove identity or native durability. Captured write receipts retain
later edits; failed/uncertain writes stop implicit autosave/navigation retries.
Slow open/reload/decode operations retain intervening edits. Reload and restored
drafts do not silently rebase stale content. Copies create exclusively and become
the active study; export has its own save owner and preserves source state.
The file picker selects an export folder only, and no longer writes PGN bytes.

Evidence (Linux, this checkpoint):

| ID | Scope/check | Result | Remaining limit |
|---|---|---|---|
| ARCH-01 | `scripts/ci.sh analyze lint`; 13 dependency regressions; canonical imports and Study tests moved with their owner | Pass; 9 existing informational analyzer findings | Other workflows still use legacy ownership |
| DATA-02, DATA-04, DATA-05, STATE-02, TEST-01 | 381 focused tests: `test/features/studies/`, `test/features/documents/`, `test/infrastructure/documents/`, Study import/selection, PGN parsing/slicing and storage-integrity regressions | Pass; native same-byte replacement, uncertainty reconciliation, queued autosave failure, slow open/reload edits, copy collisions and late-copy edits covered | No power-loss simulation; content-only non-Linux bridge is not a native guarantee |
| UI-01, TEST-01 | `integration_test/study_save_recovery_test.dart` boots the actual app, enters a move, conflicts with native replacement, reloads/retains/restores, saves an exclusive copy and verifies both files; `integration_test/app_test.dart` | Pass: 1 Study journey and 7 boot/navigation tests | Full release suite and all modes not claimed |
| UI-01 | Headless production app with disposable profile; inspect [conflict](images/renewal-study-conflict.png) and [retained draft](images/renewal-study-retained.png) screenshots | Pass at 1280×720; duplicate legacy error toast retired | Remaining Study screen theme/localization/accessibility not certified |

Initial native journey failed because its shared test helper searched for the
retired popup-menu type; it now selects the production `MenuItemButton`, and
the journey passes. Initial analysis caught migration wiring/import/ARB metadata
issues, corrected before the final checks. No release publication requested.

Remaining: Study's legacy namespace/reference transactions; persistent drafts and
close guards; document-level undo receipts; the other PGN editors; resizable/shared
workspace composition; complete Study localization/theme/accessibility; large-
document budgets and non-Linux native gates. The full renewal remains active.

### Application close ownership checkpoint (2026-09-17)

After Study adoption `a011ceb2`, `app/desktop_application.dart` owns window close
policy through an injected pure-Dart `DesktopClosePort` and native adapter.
`DocumentCloseCoordinator` and its registration scope coordinate Study, PGN
Viewer and pending repertoire line edits across retained workspaces. A feature
unmount cannot disable application close prevention. Duplicate events share one
attempt; every approval names its document revision, and later edits or changed
membership require another attempt. A native close failure restores prevention.

The app-scoped Study guard exists even before visiting Study mode. Its localized,
themed dialog uses the production save/recovery panel for unsaved content,
uncertain writes and retained drafts. Known failed/uncertain saves are not
implicitly retried. Close without saving grants an exact approval but does not
mutate the draft. PGN discard-on-application-close now has the same property:
another owner cancelling cannot erase it. Pending raw viewer comments are flushed
before the final revision check. Repertoire close attempts await pending line
saves and do not consume a failure on repeated close requests.

Native testing initially found GTK's first-run desktop integration modal blocked
window-close events while remaining invisible to Flutter screenshots. The bounded
runner now seeds only fresh disposable profiles with a declined offer, preserving
explicit fixtures and leaving the user's desktop settings untouched. The native
journey asserts receipt of the real close event, saves an exclusive Study copy,
and observes the approved handoff without destroying the test host. Final native
window destruction is checked separately in the headless preview.

Evidence (Linux, this checkpoint):

| ID | Scope/check | Result | Remaining limit |
|---|---|---|---|
| ARCH-01 | `scripts/ci.sh analyze lint`; 13 dependency regressions | Pass; 9 existing informational analyzer findings, no warnings/errors | Unmigrated workflows retain legacy ownership |
| DATA-02, STATE-02, TEST-01 | 34 focused tests across close coordinator, Study guard, desktop host/adapter, repertoire pending saves, PGN viewer display/shortcuts and app widgets | Pass; duplicate requests, late revisions, owner disposal, failed native close, retained drafts and PGN discard followed by another owner's veto covered | Persistent drafts and full job shutdown remain pending |
| OPS-01, TEST-01 | `scripts/ci.sh with -- python3 tools/test_agent_jobs.py` | Pass: 11 runner tests, including isolated desktop choice and preservation of explicit fixtures | Native Windows/macOS not exercised |
| UI-01, TEST-01 | `integration_test/document_close_test.dart`, `integration_test/study_save_recovery_test.dart`, `integration_test/app_test.dart` | Pass: 9 desktop cases; actual native close request, save-copy bytes, conflicts/recovery and boot/navigation | Close test records the final handoff to keep its host alive; full release suite not run |

Initial repertoire test failures came from a fixture reaching path-provider
without an initialized binding. It now injects temporary native storage roots,
so its existing five cases and new close-failure case run without desktop data.
The initial Study guard fixtures also needed construction inside the widget-test
clock; the corrected tests pass without a production timing workaround.
Headless visual inspection at 1280×720 verified the
[unsaved close dialog](images/renewal-study-close.png). Cancelling retained the
move, saving a copy from another mode produced the expected PGN bytes, and the
final confirmation terminated the actual preview process. Flutter logged an
implicit-view removal warning during native teardown; this is recorded as a
remaining native-platform concern, not a clean release-shutdown certification.
Inspection also caught stale unsaved wording after a successful save; the dialog
now says the study is saved, covered by its widget regression.

Remaining: persistent document/draft recovery across restart; full PGN Viewer
store adoption; document undo receipts; builder drafts and application-job
shutdown; large-document budgets; complete workspace/theme/accessibility work;
Windows/macOS native checks. Milestones 1/2 and 3 remain partial; this is not a
full application migration or a completed PLAN-02 gate.

### Study restart recovery checkpoint (2026-09-17)

Following app-owned close coordination `2569bcb6`, Study now has a persisted
workspace checkpoint under its canonical feature boundary. Its pure snapshot and
repository contract preserve PGN content, original native revision, retained
drafts, uncertain writes/copy destinations, chapter, cursor and orientation.
Startup injects the file adapter and an app-lifetime recovery controller; a
localized recovery banner is available from every mode.

Recovery captures at a bounded one-second cadence, with one in-flight write and
one coalesced pending snapshot. It does not serialize the tree for each cursor
notification. Writes use the existing atomic journal and checksum a versioned JSON
payload; Linux also flushes the checkpoint directory. This preserves the last
acknowledged checkpoint after process death, not edits still waiting for their
next checkpoint or a claim about power-loss behavior. Checkpoint failures remain
visible and require an explicit retry.

Separate random records and lifetime SQLite transactions isolate concurrent app
sessions, including separate isolates in one process. Process death releases the
lease without stale-lock deletion. Recovery discovers only inactive sessions;
unknown/corrupt records remain on disk and surface a failure. Restore never adopts
a newer disk revision or writes the original PGN, and blocks implicit autosave.
A later explicit save still checks the captured baseline. A fresh checkpoint is
acknowledged before the old entry is resolved. Dismissal is explicit and revision
guarded; resolved bytes remain archived. Existing drafts displaced by recovery
and retained drafts carried through ordinary Study opens are preserved.

Validation on Linux:

| Check | Evidence |
| --- | --- |
| Analyze and architecture/file-mutation lint | Pass; nine existing informational analyzer notices, no new notices. All 13 boundary checker tests pass. |
| Focused Study/document/native-recovery/widget suite | All 122 tests pass, including continuous-edit checkpoint cadence, corruption, stale receipts, failed writes, retained drafts and recovery-before-resolution ordering. |
| Native desktop integration | All ten tests pass across app navigation, Study save recovery, cross-mode close and startup recovery. Startup recovery preserves an externally modified source and saves a separate copy. |
| Process death | A subprocess writes an acknowledged checkpoint, remains hidden while alive, then is killed with SIGKILL. A new reader discovers the exact retained draft after its lease releases. |
| Full preview process restart | In a disposable headless profile, entered `e4` and a comment, confirmed checkpoint bytes, stopped and launched a new app process, restored via the startup banner and verified cursor/comment plus the separately saved PGN copy. |
| Visual inspection | [Recovery review](images/renewal-study-restart-review.png) and [restored Study](images/renewal-study-restart-restored.png), captured from the production UI at 1280×720. |

Early test-fixture failures (real-isolate work under the widget fake clock and
Dart subprocess build-hook stderr) were corrected before the passing runs.
This increment does not establish power-loss behavior or the full release gates.

Remaining: other PGN editors' recovery/store migrations; automatic restoration of
clean workspaces and their full UI state; archive retention/purge UX; document undo
receipts and immutable projections; large-document performance measurements;
builder and job shutdown; native Windows/macOS durability and release gates.
Milestones 1/2 and 3 remain partial; later feature migrations are still required.

### PGN collection edit ownership checkpoint (2026-09-17)

Following Study restart recovery `14356ed1`, PGN Viewer now delegates collection
edit/persistence state to `PgnCollectionEditor` under `features/documents/`.
The metadata mixin is removed, not retained as another writer. The constructor
requires an injected `PgnCollectionRepository`; the composition root chooses the
native Linux document store and other hosts retain the legacy serialized adapter.
Pure mainline/header algorithms have canonical `chess_core/pgn/` paths, with
imports updated and the old lexer path removed.

Scoped saves preserve other games and unparsed/banner bytes: match the submitted
original games uniquely against the current source, then validate that observed
native revision at commit. A replacement before validation conflicts; arbitrary
external writers can still race the last validation/rename. Native baseline
history is retained. This merge policy does not promise to reject every
same-content replacement between initial collection load and patch observation.

The edit owner serializes writes, preserves newer edits against the submitted
receipt, suppresses failed/uncertain queued retries, and retains each already
queued draft separately if a prior write failed. Recovery copies include the
collection banner. Uncertain acknowledgements cannot be replayed through Save.
Outgoing receipts cannot mark another collection saved. Test fixtures explicitly
inject their own repositories and disposable document roots.

Validation on Linux:

| Check | Evidence |
| --- | --- |
| Analyze/lint | Pass, including 13 architecture-checker tests; only the nine existing informational notices remain. |
| Regression suite | All 334 tests pass across document sessions/stores, PGN controllers/readers, lexical/property tests, storage integrity and app widgets. |
| Final message-ownership follow-up | All ten collection revision tests pass, including preservation of unrelated load failures during edit-owner notifications. |
| Native desktop integration | All nine tests pass: viewer comment save/conflict/recovery, seven app navigation cases and cross-mode document close. |
| Headless production preview | Edited a move comment, verified the saved PGN/banner/unrelated game; replaced the source externally, edited again, verified the source stayed untouched and the recovery copy contained the latest draft/banner. Inspected the [conflict screenshot](images/renewal-pgn-collection-conflict.png) at 1280×720. |

Early fixture failures were corrected: repositories now capture the intended
fixture storage, session tests provide disposable document roots, and desktop
editing selects a move before typing into its enabled annotation field. Native
race injection targets the pre-validation temp-flush boundary; the documented
post-validation external-writer window is not claimed as protected. Full release
and Windows/macOS native gates were not run for this increment.

Remaining document-workspace scope includes Viewer typed inspection/reload/copy
UI, pasted-collection Save As migration, persisted unsaved Viewer sessions,
private mutable cores and immutable projections, undo receipts, large-document
budgets and removal of the remaining viewer slice/window mixins. The old viewer
still owns library/session reads, navigation and rendering. Milestone 3 remains
partial, and this does not complete milestones 1/2 or 4–7.

### PGN Viewer recovery and copy checkpoint (2026-09-17)

Following collection ownership `eaf71d32`, the same `PgnCollectionEditor` now
implements `DocumentSaveActions`. Viewer uses the shared localized save panel
for inspecting the current file, reloading while retaining a draft, restoring
retained work, and exclusively creating a copy. There is no second edit owner.
Structured dirty state compares per-game baselines; UI notifications do not
serialize the full collection. File opens capture a document-store snapshot.

Reload/restore decode before adoption and acknowledge recovery PGN bytes before
displacing dirty work. A failed recovery write keeps the live draft. Edits made
while recovery is being written veto replacement and retain both the acknowledged
older draft and the newer live work. Restoring retained text is an explicit
whole-document replacement against the captured current baseline, so another
external edit produces a conflict rather than a silent rebase. Failed or uncertain
autosaves do not resume implicitly when opening recovery UI or closing the app.

Save As and PGN export no longer delegate writing to a file picker. A destination
form returns an absolute folder/name; optional native browsing only selects a
folder. The injected repository creates exclusively. Collisions preserve the
existing file and the draft, and late edits remain dirty after a copy receipt.
Save As adopts its acknowledged file and reading session. Export has its own
save session, leaves the viewer source unchanged, and retains the Open action.

Validation on Linux:

| Check | Evidence |
| --- | --- |
| Analyze/lint | Pass; 13 architecture-checker tests pass and only the nine existing informational notices remain. |
| Focused regression suite | All 304 tests pass across document/Study sessions and stores, PGN controllers, viewer widgets and app startup. |
| Final recovery follow-up | All seven recovery tests pass, including retaining an unannotated pasted collection before restoring another draft and refusing displacement after a failed recovery write. |
| Native desktop integration | All three journeys pass: pasted Save As/export cancellation and collisions; viewer conflict inspection/reload/restore/copy; cross-mode native close with a Study draft. |
| Headless production preview | Inspected the [recovery panel](images/renewal-pgn-save-recovery.png) and [copy destination](images/renewal-pgn-copy-destination.png) at 1280×720. Verified that a conflicted source remained unchanged and the new copy contained the edited comment and collection banner. |

The first export integration attempt failed to open the hover-driven submenu;
the corrected mouse-hover journey passes. Untouched pasted PGNs now participate
in close recovery, and a widget regression proves cancellation retains them.
Automatic checks used disposable profile data; the preview was stopped afterward.

This remains partial milestone 3 work. Retained-draft choices are session-local;
the separately written recovery PGNs do not constitute continuous Viewer
checkpointing or startup discovery. Private game cores/immutable projections,
undo receipts, complete workspace restoration, large-document budgets and the
remaining viewer mixin/legacy-reader migrations are still pending. No milestone
1/2 or 4–7 graduation, Windows/macOS certification or release validation is claimed.

### Shared workspace recovery and Viewer lifetime checkpoint (2026-09-17)

After PGN recovery/copy `d9a339ea`, Viewer ownership moves out of its screen.
`app/pgn_viewer_lifetime.dart` constructs the legacy controller, reader handle,
analysis controller and checkpoint owner; the screen borrows them. This app
bridge remains temporary until the underlying reader and analysis ownership
migrate. `PgnCloseGuard` protects the document even before the screen exists.
Cancelling another document's close approval never discards this draft.

Study's checkpoint controller, pure repository contract, native journal/lease
store and recovery host now have canonical shared owners in `features/documents/`
and `infrastructure/documents/`. Their previous Study paths are removed without
forwarding shims. Injected codecs keep the existing Study schema/directory intact;
Viewer uses its own `pgn-viewer-recovery-v1` namespace. Live-instance exclusion,
checksum checks, atomic replacement, exact-revision resolution and archived bytes
follow the same tested protocol for both workspaces.

Viewer checkpoints retain current text, each game's persisted original, the full
source revision, explicit whole-replacement intent, retained drafts, uncertain
write destination, selected game, mainline ply and orientation. Recovered edits
keep their original scoped patch baselines; a changed source game still conflicts.
In-flight writes recover as uncertain. Restoration validates the decoded game
count, refuses intervening edits, retains displaced work before adoption, and
never resumes source autosaving or engine enrichment implicitly. A replacement
checkpoint must be acknowledged before resolving the previous recovery entry.

Validation on Linux:

| Check | Evidence |
| --- | --- |
| Analyze/lint | Pass; 13 architecture-checker cases pass and only the nine existing informational notices remain. |
| Focused regression suite | All 318 tests pass across Study/documents, native stores, PGN controllers, lexical/save integrity, viewer widgets and app startup. Includes immutable checkpoints, per-game original preservation, in-flight-copy uncertainty, concurrent-edit rejection, corrupt selections, repeated-restore rejection and failed-write/recovery ordering. |
| Shared journal/lease regression | Existing Study payloads still round-trip; live stores/isolates stay hidden, failed replacement preserves the acknowledged checkpoint, stale receipts cannot resolve newer records, and SIGKILL releases a subprocess lease without losing acknowledged work. |
| Native desktop journeys | All five pass: Viewer close before first reader mount plus restart/conflict/copy; Study restart/conflict/copy; Viewer save/reload/retained recovery; pasted-copy/export; cross-mode native close. |
| Full app-process restart | Entered an unsaved annotation and advanced to ply 2, verified checkpoint bytes and unchanged source, stopped the headless process and launched a new one. Recovery appeared in Tactics before Viewer mounted; restored annotation and ply 2, verified the new checkpoint retained original per-game text and that the source stayed unchanged. Inspected [startup review](images/renewal-pgn-restart-review.png) and [restored Viewer](images/renewal-pgn-restart-restored.png) at 1280×720. |

Early fixture failures identified the new lifetime boundary: standalone widget
fixtures now explicitly stop their app owner, and close assertions allow its
checkpoint flush to finish. The native conflict test waits until the recovery
write is idle before activating Save a copy. An ignored repeated restore now
returns an explicit rejected result, so it cannot close the review dialog while
the first restore is still running. All corrected checks pass. Preview
data stayed in the disposable driver profile, and the preview was stopped.

Remaining milestone 3 scope includes private mutable game cores and immutable
projections, undo receipts, variation-cursor/filter/tab/panel restoration, other
editors' checkpoints and large-document measurements. This does not graduate
milestones 1/2 or 3, start/finish milestones 4–7, or certify non-Linux native and
release gates. Checkpoint acknowledgement is the recovery boundary; edits not
yet checkpointed can still be lost on abrupt process termination.

### Study private-core and projection checkpoint (2026-09-17)

After shared recovery checkpoint `2c8d421d`, Study's public document/chapter/tree
access returns immutable projections. The controller alone retains the editable
core. Widgets cannot cast the values back to that core; lists, headers and NAGs
are detached and unmodifiable. Import/adoption also copies NAG arrays, closing an
input alias. Commands distinguish navigation along an existing move from an edit,
and reject invalid/no-op cursor/comment actions without dirtying the document.

Document and chapter projection keys contain the session, kind, chapter identity
where applicable and content revision. Disk baselines remain separate. Navigation
and save-status changes reuse document projections; unrelated chapters remain
identical across edits and reorder. A measured initial 20,000-node full copy took
up to 35 ms in the debug fixture, motivating incremental reconciliation by changed
node and ancestor IDs. Ordinary local edits share unchanged immutable subtrees;
bulk clears deliberately rebuild their chapter. Later runs varied up to 49 ms
for full materialization; 100 local updates plus identity assertions took about
20–22 ms total. These synthetic debug measurements establish the optimization's
purpose, not compliance with end-to-end frame or allocation budgets.

Pure cursor/read contracts now live under `chess_core/moves/` and the shared
movetext writer under `chess_core/pgn/`, with callers updated and no re-export
shim. The shared PGN editor uses read-only contracts and explicit mutation
callbacks, including its legacy scratch host. A stable tree editing identity
keeps annotation field state/focus while revisions change. Study confirmations
use immutable chapter identity/revision, and sibling/chapter removal preserves
the selected position rather than following a shifted list index.

Verification (Linux, this checkpoint):

- `scripts/ci.sh analyze lint` passes with the nine existing informational notices;
  architecture boundary checks and all 13 checker tests pass.
- All 381 focused tests pass across Study, immutable snapshots, move navigation,
  PGN parsing/serialization, editor focus/stale menus, repertoire save/undo safety,
  Viewer game models and study selection. This includes 20,000-node deep/wide
  construction and batched edits/reorder/deletion against the private core's PGN.
- Native Study restart/edit/conflict/copy, document-close and Viewer restart
  journeys pass. The Study journey types through two immutable revisions, verifies
  field identity and preserved prior text, and saves both recovered and newly
  typed notes to an exclusive copy without changing the externally edited source.
- Headless production preview: played `e4 e5`, entered and extended an annotation
  across revisions, verified the field kept focus and both board and movetext
  retained the position. Inspected the [1280×720 screenshot](images/renewal-study-projections.png).
  The preview used only disposable data and was stopped after inspection.
- Broader tests exposed repertoire fixtures that still depended on platform path
  discovery without a Flutter binding. Explicit disposable `IOStorageService`
  roots now let those cases reach their intended conflict/undo assertions.

This advances STATE-02 and ARCH-01 without graduating milestone 3. Dedicated
cursor/visible-window projections, narrower subscriptions, undo receipts,
Viewer/Builder private ownership, complete session restoration, decoder/object
construction/GC profiling and native large-document frame budgets remain pending.
Milestones 4–7 and non-Linux/release gates remain unfinished.

### Study selected-view checkpoint (2026-09-17)

After private-core checkpoint `f62f6d4b`, Study separates chapter metadata and
cursor projections from full document/chapter snapshots. Metadata and identity
reads never touch move nodes; `chapterAt` copies only the requested chapter.
Cursor values have their own view revision and retain identity across edits
elsewhere, metadata renames and save-status changes. Cached whole-document views
are invalidated on edits so unused older trees are not retained by the cache.

The legacy screen-wide listener is removed. Selected subscriptions independently
update the title, save indicator, menu availability, chapter list/selection,
engine position/orientation and editor tree/cursor. The board compares only its
position, orientation and shapes, so ordinary prose and glyph edits leave it
unchanged. A repaint boundary preserves the board's painted layer across prose
and glyph updates; shape changes replace it. Chapter metadata subscriptions also
keep the manager current when imports or other actions change the chapter list.
The chapter picker resolves stable keys after its dialog. Chapter row keys survive
metadata changes/reorder; inline rename
refuses a switched document or destination. `StudySelector` uses the existing
Provider bridge strictly as a read subscription; it does not introduce a second
action/document owner. Riverpod/bridge retirement remains part of the migration.

Focused evidence covers zero node reads for metadata, lazy chapter materialization,
pending edits surviving interleaved metadata reads, independent immutable cursor
revisions, stale chapter action checks and actual production-widget identity
across prose/glyph/shape/cursor/library updates. All 127 focused Study, editor,
save-safety and startup tests pass, including chapter-manager updates and retained
board paint layers. A synthetic 20,000-node course (100 chapters) reads metadata
without touching any move root and materializes only the selected 200-node chapter;
one debug run measured approximately 1.2 ms and 1.7 ms respectively. These are
diagnostics, not parsing, retained-memory or native-frame budget certification.
All three native Linux journeys pass: Study restart recovery, save-conflict
recovery and application close with dirty documents. Analysis/lint pass with
nine existing informational analyzer notices. In the disposable headless app,
restored the prior Study draft and edited its annotation; inspected the
[1280×720 Study workspace](images/renewal-study-selected-views.png). Windows/macOS
and the complete release suite were not run for this checkpoint.
This advances STATE-02 and UI-02; it does not
complete the large-document gate. Visible movetext windowing, parsing/GC/retained
memory/native frame budgets, undo receipts, other editors and milestones 4–7
remain unfinished.

### Editor movetext viewport checkpoint (2026-09-17)

After Study selected-view checkpoint `401c6141`, the shared interactive editor
uses `features/documents/models/move_text_layout.dart` for a pure row index and
`features/documents/widgets/move_text_viewport.dart` for lazy presentation.
The prior recursive widget builder and eager `SingleChildScrollView`/`Column`
are removed. Indexing is iterative, with shared linked ancestor addresses;
selection compares node IDs, and paths are materialized only for actions.
Runs contain at most 24 moves. Comments and runs still wrap naturally and have
variable heights; this is not fixed-height clipping. The viewport prefetches
240 pixels and the editor caches at most 96 recent row widgets.

A two-sided sliver anchor lets distant selections mount without laying out all
preceding rows. The exact selected chip is revealed inside long wrapped runs.
Existing paragraph/chip identity remains stable across cursor-only updates.
Inline draft text belongs to the editor, so eviction or re-anchoring cannot
silently replace uncommitted text with the original comment. That regression
was reproduced during implementation and now passes. The architecture lint
allows Flutter's `WidgetsBinding` frame scheduling only in feature widgets;
application service singletons remain forbidden, including in those widgets.

A synthetic 20,000-ply index completes without recursive stack growth or copying
20,000 ancestor lists. One debug run indexed it in about 20 ms. A separate
20,000-node annotated wide-tree widget fixture mounts fewer than 30 move chips,
jumps to the final variation, scrolls backwards and returns to the start.
Tests also cover 200% text, long wrapped rows, variation numbering, null moves,
metadata-only comments and draft restoration after eviction.

Verification: all 190 focused document/Study/editor/repertoire-screen/startup
tests pass, and all three native Linux journeys pass (20,000-node open/edit/save,
Study restart recovery and save-conflict recovery). The large native fixture has
100 annotated 200-ply branches in one chapter. Opening through UI settling took
23,183 ms; distant navigation through settling took 640 ms; process RSS sampled
after saving was 772,870,144 bytes. These debug measurements include native reads,
worker decoding, receive/adoption, projections and the UI, but do not isolate
their costs or distinguish retained memory from transient allocations. They
identify an unresolved performance problem, not a passing large-document budget.
Next profile decoding/adoption/indexing and GC in profile mode before choosing
incremental indexing or worker residency. The initial native build failed from a
missing Flutter rendering import for the cache-extent type; the corrected build
passes all native journeys.
Analysis/lint pass with nine pre-existing informational notices and 14 boundary
regressions. In the headless app, opened the same course from the disposable Study
library, selected a variation move and scrolled through wrapped annotations;
inspected the [1280×720 viewport](images/renewal-study-lazy-rows.png). The preview
was stopped. Windows/macOS and full release gates were not run for this checkpoint.

The compact row index is still O(nodes + prose) and rebuilt on content edits.
This checkpoint does not certify STATE-02's profile-mode allocation/GC/frame
budgets, worker-residency decision, undo cycle measurements or image-memory
budget. Viewer movetext uses its existing renderer; Viewer/Builder private-core
adoption, Riverpod retirement and milestones 4–7 remain pending.

### PGN decoding checkpoint (2026-09-17)

After viewport checkpoint `f433838c`, production single-game syntax parsing now
uses `chess_core/pgn/pgn_parser.dart`. The boundary checker also enforces this
entry point in unmigrated code. Multi-game parsing and specialized lexical
readers retain their existing contracts.

The upstream syntax parser repeatedly copies the remaining physical line around
brace comments. A large annotated course on one line therefore incurred
quadratic copying. The adapter bounds comment-bearing input segments while
preserving header escapes, comment contents/newlines, semicolon comments and
original escape-line behavior. Only temporary parser input changes; stored PGN
bytes are untouched. Explicit move-number labels are discarded before parsing:
the upstream parser otherwise mistakes `10000.` for a null move. Standalone
null moves remain supported. Position replay and fresh-ID adoption now use
explicit stacks, preserving sibling order and annotations without recursive
decoding of deep lines.

Evidence on Linux (debug builds, bounded local runner):

| Check | Result |
|---|---|
| Same saved 20,000-node course, stage diagnosis | Syntax parsing fell from 15,742,099 µs to 81,495 µs; worker decode plus transfer fell from 16,627,796 µs to 252,213 µs in the first optimized diagnostic. |
| Final portable synthetic-course diagnostic | Syntax 78,577 µs; replay 137,832 µs; fresh IDs 8,449 µs; projection 34,165 µs; row index 366,216 µs; worker decode plus transfer 275,183 µs. |
| Native 20,000-node Study journey | Open/settle 1,328 ms (previous checkpoint: 23,183 ms); distant selection 657 ms; RSS after edit/save 769,368,064 bytes. Open, jump, edit and save pass. |
| Broader regression suite | 1,202 tests pass; one existing skip documents game-ending draws incorrectly counted as clean in tactics mining. Includes semantic parser comparisons and a 20,000-ply numbered line with independent fresh IDs. |
| Native recovery journeys | Study restart recovery and save/conflict/reload/exclusive-copy journeys pass, for three native journeys including the large document. |
| Analysis and boundary lint | Pass with nine existing analyzer info notices; all 15 boundary-checker tests pass. |

The broader run initially exposed the large move-number parser bug and missing
localization/disabled-expiry assumptions in settings test fixtures; these were
corrected before the passing run. The diagnostic is repeatable with
`scripts/ci.sh test tools/bench/study_document_bench.dart`; it shares the native
test's generated course and does not access user files by default.

This removes the measured syntax bottleneck, not the remaining performance gates.
Row indexing still scales with the selected chapter, and the native debug RSS
measurement does not establish profile-mode allocation, GC or frame budgets.
Incremental indexing, worker placement decisions, Viewer/Builder private cores,
undo/session parity, presentation bridge retirement and milestones 4–7 remain
unfinished. Windows/macOS native checks and full release gates were not run.

### Builder private move-tree ownership checkpoint (2026-09-17)

After PGN decoding checkpoint `548c6ca6`, `RepertoireController.tree` returns a
cached immutable `MoveTreeSnapshot`. The mutable draft remains private; importing
an annotated tree copies its nodes, lists and annotations with fresh IDs. Even
the close-revision token now contains an opaque session identity instead of a
mutable tree reference. Old projections retain their values after later edits.

Study and Builder now use `chess_core/moves/move_tree_projection_cache.dart` for
tree projection. Owners record ancestor paths before mutation; local edits share
untouched branches, bulk changes recapture, replacement rotates editing identity,
and cursor-only changes reuse the exact view. Study retains its chapter metadata
and selection caches. Builder line-entry commands now report structure changes
when they insert moves even if the requested cursor was already selected.

Builder's editor/analysis wrappers accept the shared read-only contract. Its
session-scoped `snapshotForSave` supplier captures the controller's current
revision synchronously after an edit, before the widget rebuilds. This is needed
because serializing the displayed immutable revision would otherwise save the
previous content. The debounce still retains both the captured text and original
destination across chapter switches. The native journey also exposed a missing
Builder glyph callback; the displayed buttons now invoke the controller and save
through this same boundary.

Verification (Linux, this checkpoint):

| Check | Result |
|---|---|
| Unit/widget regression | 443 distinct cases pass across the broader run and focused reruns: repertoire controllers/writers, navigation, mutable/immutable move models, Study, traps, training-session controller, Builder screen, editor/autosave and scoped Study rebuilds. No skipped cases in this selected scope. |
| Ownership and capture | Tests reject mutable-list writes, preserve old annotations, detach imported trees, share untouched branches, retain opaque close tokens, restore draft undo and capture edits before any host rebuild or chapter switch. |
| 20,000-node Builder fixture | First projection 33,494 µs; deep annotation plus revised projection 2,311 µs. The 99 untouched root branches retain identity; navigation reuses the full view. These debug timings exclude parsing/adoption and do not certify allocation or frame budgets. |
| Native integration | Five journeys pass: Builder annotations/glyph save and reload; two existing workspace navigation/draft journeys; large Study open/jump/edit/save; Study conflict/reload/retained-draft/exclusive-copy recovery. Large Study open 1,240 ms, jump 643 ms, RSS after edit/save 781,115,392 bytes. |
| Analysis and lint | Pass with nine existing analyzer info notices; all 15 architecture-checker tests pass. |

A disposable headless app check also typed a comment, toggled the Builder glyph
and inspected both the saved PGN (including earlier variation/annotation text)
and the [1280×720 Builder screenshot](images/renewal-builder-projection.png).
The preview was stopped. Existing recovery banners in the disposable profile
belong to earlier recovery checks.

The first broader run exposed four writer-undo fixture failures because storage
roots were not injected. Writer and undo fixtures now use disposable storage and
dispose their controllers; their ten cases pass. A mistyped rebuild-test path was
corrected to `test/widgets/study_rebuild_scope_test.dart`, whose two cases pass.
The first native Builder run failed on its disconnected glyph action; the actual
production callback was fixed before the complete native rerun passed.

This advances STATE-02 and ARCH-01 for Builder's edited tree; it does not migrate
the whole legacy repertoire coordinator. Storage/session collaborators, Builder
draft recovery, remaining undo receipts, scoped presentation subscriptions and
Provider retirement remain pending. Viewer private-core adoption and windowing,
complete editor parity/performance gates, milestones 4–7 and non-Linux/release
gates also remain unfinished.

### Viewer mainline ownership checkpoint (2026-09-17)

After Builder checkpoint `ca376687`, Viewer copies caller-owned parsed games
before normalization and keeps its parsed input and editable mainline private.
`chess_core/pgn/pgn_game_view.dart` supplies detached immutable metadata and move
snapshots; `pgn_game_copy.dart` copies parsed trees iteratively. Local annotation
edits retain unchanged move snapshots, navigation reuses the list, and the
renderer shares the owner's position memo across annotation revisions.

Mainline comment/glyph commands accept opaque move identities. Delayed callbacks
from a replaced game are rejected without emitting a save. Annotation adoption
detaches the incoming values, retains cursor/session identity, and rejects the
same SAN played from a different starting position before modifying live state.
Serialization copies mainline annotations before shortening stored engine-line
references, so preparing output cannot silently mutate the owner.

Viewer sideline extraction now uses the existing shared iterative move-tree
decoder. This also fixes variation introductions: starting comments remain
separate from trailing comments through extraction, rendering and saving; the
intro appears before the move it introduces. The shared training reader accepts
the immutable mainline values without changing its workflow ownership.

Verification (Linux, this checkpoint): 232 selected unit/widget cases pass,
covering Viewer/core PGN, collection setup, parser properties, training reader,
analysis annotations and movetext rendering. New regressions exercise a
20,000-ply parsed-input copy with independent annotation containers, retained
snapshots, stale callbacks, atomic rejected adoption, serializer purity and
variation-introduction ordering. Three native journeys pass: collection save/
conflict/reload/retained-draft/collision-safe copy; pasted-collection exclusive
copy/export; app-owned close/restart recovery with cursor and source preservation.
The save journey also preserves a variation introduction and unrelated game
bytes. Analysis and lint pass with nine existing info notices and all 15
architecture-checker tests passing.

The disposable headless production app opened a fixture with a mainline note,
variation introduction and trailing sideline note. The inspected
[1280×720 Viewer screenshot](images/renewal-viewer-mainline.png) confirms their
order and legibility. The preview was stopped; its existing recovery banners
belong to earlier test fixtures. The first focused run exposed introduction
folding and a whitespace-sensitive PGN assertion; the decoder/rendering fix and
semantic assertion passed the complete selected rerun.

This advances STATE-02, ARCH-01 and annotation parity without completing the
Viewer private-core migration. Its sideline forest remains mutable, and the
legacy controller, widget mixins, asynchronous load lifetime and eager movetext
rendering remain to migrate. Full hierarchy/legacy retirement, editor session/
undo/performance gates, milestones 4–7 and non-Linux/release gates are unfinished.

### Viewer variation ownership and hierarchy checkpoint (2026-09-17)

After mainline checkpoint `24c7d331`, the canonical game owner is
`features/documents/controllers/viewer_game_controller.dart` (`ViewerGameController`).
The old `core/pgn/viewer_game_model.dart` path is removed. Parsed games, mainline,
variation forest and navigation fields are private. Public variation nodes and
cursor paths are immutable snapshots; commands resolve stable IDs inside the
owner and reject targets from deleted/replaced trees. Solitaire reveal sets are
also detached on adoption.

`chess_core/pgn/sideline_projection_cache.dart` shares unchanged plies and branch
snapshots. It uses the same iterative node-capture algorithm as Study/Builder;
navigation reuses the forest, and annotation edits recapture their ancestry.
Tree queries, deletion, scratch cleanup, engine-line merging and serialization
are iterative. Removing the selected subtree or clearing scratch analysis now
retreats both cursor and board. Focused reading scopes/bookmarks refresh their
node values when a projection changes, preserving reading position while showing
the latest annotations.

Stored engine verdicts and annotation transforms moved from `services/` to
`chess_core/analysis/`; position replay/index codecs moved to `chess_core/pgn/`.
Imports and corresponding tests use their canonical paths without re-export
bridges. Numeric quality-NAG rules are separate from UI glyph styling. The
plain-Dart diagnostic exposed a hidden Flutter import through the LRU cache's
test annotation; it now imports `meta` directly, with the already locked version
declared as a dependency. The lint gate follows project imports, exports, parts
and conditional alternatives to reject framework/native-I/O dependencies in
chess core and this game owner.

Verification (Linux, this checkpoint):

| Check | Result |
|---|---|
| Unit/widget regression | 750 distinct cases pass across the 748-case broad run and focused reruns: document/Study owners, move-tree snapshots, Viewer/solitaire, parser/replay/analysis, collection filters, training reader, PGN properties, annotation-panel behavior and LRU behavior. No selected cases skipped. |
| Deep sideline | A 20,000-ply line passes load, detached projection, navigation, annotation adoption, edit, serialization and deletion without recursive traversal failure. |
| Plain Dart | `tools/bench/viewer_document_bench.dart` runs without Flutter. On the shared 20,000-node fixture: parse 88,293 µs, adopt 156,128 µs, first projection 31,989 µs, deep edit plus projection 2,627 µs; all 98 untouched variation roots shared. RSS 278,675,456 bytes. These are one-run diagnostics, not allocation/native frame certification. |
| Architecture gate | All 18 boundary-checker regressions pass, including transitive, export, part, conditional-import and cycle cases. |
| Analysis and lint | Pass with nine existing analyzer info notices; no errors or warnings. |
| Native integration | Five journeys pass: collection mainline/variation annotation and glyph save plus conflict/copy recovery; exclusive copy/export; close/restart recovery; Builder annotation/glyph save/reload; large Study open/jump/edit/save. Study open 1,311 ms, distant jump 658 ms, RSS 778,928,128 bytes. |

The first ownership regressions caught old mutable-reference assumptions and an
incorrect interpretation of `addChild`'s second result (mainline status, not
insertion status). Changed-child detection now compares the owned child count;
scratch promotion invalidates the changed child as well as its ancestors.
Glyph actions now flush pending prose first, and same-target rebuilds preserve
text while its debounce is pending. The focused host-echo regression checks that
the immediate serialized result includes both edits. The native journey initially
failed to enter its second note: a field-level assertion showed empty input
before the glyph action. Its fixture now explicitly focuses the field and verifies
entered text before asserting saved annotations. Two nonexistent focused-test
paths were also corrected to the actual Viewer widget suite.

The headless production app also opened a disposable PGN, focused its Sicilian
variation, typed a replacement note and selected the Good move glyph. The
[1280×720 screenshot](images/renewal-viewer-variation-owner.png) shows the focused
reader updated in place, with its introduction, selected move and new note.
The saved PGN contains both the note and `$1`, with the mainline preserved.
The preview was stopped; its recovery banners belong to prior disposable tests.

Remaining: legacy collection orchestration, async game-load lifetime, nested
annotation reconciliation, Viewer movetext windowing, scoped presentation state,
workspace/undo/performance parity and remaining hierarchy/bridge retirement.
Milestones 1/2 and 3 remain partial; milestones 4–7 and non-Linux/release gates
remain unfinished.

### Viewer loading ownership checkpoint (2026-09-17)

`features/documents/controllers/viewer_game_load_controller.dart` now owns
asynchronous source-game replacement. Its immutable states distinguish idle,
loading, loaded, typed failure and closed. Each load rotates an opaque request
revision before awaiting the archive. New selections (including empty/failed
ones), repository replacement and disposal revoke previous reads and deferred
position/loaded/materialized-analysis callbacks. Superseded success or failure
cannot replace the current game or its error. Shared database opening is not
cancelled: this owner revokes publication, not the archive connection's lifetime.

`features/documents/repositories/stored_game_repository.dart` is the pure lookup
contract. The indexed `infrastructure/documents/archive_stored_game_repository.dart`
adapter borrows an injected GameStore opener. `AppDependencies` supplies it through
`StoredGameScope`; standalone readers can instead pass `storedGames` directly.
The Viewer and tactics copy/add-to-study workflows use this contract, and the old
`services/stored_game_lookup.dart` singleton helper is deleted. The underlying
GameStore connection bridge remains until training/ingestion milestones 4/5.
A missing/unavailable optional archive preserves an explicit fallback solution;
without one, missing and unavailable are distinct failures. Text-only readers do
not open an archive. The transitive pure-Dart dependency gate now includes the
load owner as well as the game owner.

Replacing a Viewer control handle detaches its predecessor. Header-only updates
refresh title metadata while preserving a matching game's cursor; a changed PGN
starting FEN replaces the game. Annotation callbacks cannot publish the previous
game into a loading selection. A successful replacement clears the previous
inline preview and emitted-edit marker.

Verification (Linux, this checkpoint):

| Check | Result |
|---|---|
| Unit/widget regression | 113 cases pass: document controllers, Viewer loading and annotation/solitaire/read-view behavior, archive adapter and tactics source-game actions. No selected cases skipped. |
| Loading ownership | Eight pure-owner cases exercise reversed completion, late failure, explicit fallback, missing/unavailable distinction, retry, empty-selection revocation, disposal and text-only loading. |
| Linux native integration | Ten cases in `integration_test/viewer_loading_test.dart` pass: nine production-reader scenarios shared with widget tests plus app dependency wiring to a disposable SQLite archive. Existing full-app collection annotation/save/conflict recovery and restart recovery journeys also pass (12 native cases total). |
| Architecture | The load controller is included in the transitive pure-Dart gate. The 18 boundary-checker regression cases pass. |
| Analysis/lint | Pass with nine existing informational notices; no warnings or errors. |

The first adapter test assumed a headerless imported PGN was retained verbatim;
the existing importer adds default headers to such input. The fixture now carries
an Event header and verifies the stored source bytes and collection isolation.
No production regression was identified by that failed assertion.

The headless production app opened the recovered native-test collection and
switched between its two games. The inspected [1280×720 screenshot](images/renewal-viewer-loading.png)
shows the second game's retained note, selected d4 move and matching board.
Recovery banners belong to this disposable profile. The preview was stopped.

Remaining: legacy collection orchestration, nested annotation reconciliation,
Viewer movetext windowing, scoped presentation state, workspace/undo/performance
parity, full hierarchy/bridge retirement, milestones 4–7 and non-Linux/release
gates. The full renewal remains incomplete.

### Viewer nested annotation checkpoint (2026-09-17)

`features/documents/controllers/viewer_sideline_adoption.dart` replaces the
root-only comparison and merge. It validates all stored branches before applying
an update. Removing, replacing or adding an ordinary nested move causes annotation
adoption to decline; the widget then loads the changed game. A best-line reference
permits additions only along that exact path, including when it extends an
existing stored root or promotes an active scratch continuation. Unrelated new
branches are not admitted merely because their first SAN matches an engine root.

Accepted updates apply nested comments, starting comments and NAGs (including
removals), while matching nodes retain identities and the current board/cursor.
Unmatched scratch continuations stay ephemeral and are omitted from serialization.
Duplicate equal-SAN siblings match by occurrence instead of aliasing one mutable
node. Incoming sibling order wins; stable untouched descendants and plies share
snapshots. Changed IDs propagate to their ancestors in one reverse traversal,
without constructing a full ancestor list for every deep node. Both validation
and application are iterative. The annotation-owner tests now live beside the
owner under `test/features/documents/controllers/`.

Verification (Linux, this checkpoint):

| Check | Result |
|---|---|
| Unit/widget regression | 261 cases pass across document controllers, chess core, PGN helpers, Viewer loading/annotation/display/navigation, solitaire and reading panes. No selected failures or skips. |
| Nested ownership | Full-tree annotation removal/replacement, rejected nested structural edits without mutation, exact engine-path extension, scratch retention, duplicate siblings, reorder/no-op projection sharing and deep adoption pass. The 20,000-ply case now verifies an incoming leaf comment before a local edit and serialization. |
| Linux native integration | All 12 loading/annotation cases pass, including focused nested note adoption, its next serialized glyph edit, and nested structural replacement. The full-app collection annotation/save/conflict-recovery journey also passes (13 cases total). |
| Plain Dart diagnostic | On the shared 20,000-node fixture: parse 84,518 µs, load 153,834 µs, first projection 31,742 µs, local edit/projection 3,457 µs, annotation refresh/projection 161,456 µs. Both edits share all 98 untouched roots. RSS 294,088,704 bytes; one-run diagnostics, not frame/allocation certification. |

`collection` is now an explicit dependency for pure list comparison, using the
already locked 1.19.1 version. The initial analysis check identified the missing
direct declaration. Final analyze/lint passes with nine existing informational
notices and no warnings or errors; all 18 architecture-checker regressions pass.
The lockfile change only marks the existing package version as a direct dependency.

The headless production app opened a disposable nested-variation fixture. Its
inspected [1280×720 screenshot](images/renewal-viewer-nested-annotations.png)
shows the selected Nc6 move, its separate introduction and trailing note, and
the matching board. Live incoming-update behavior is covered by the native
scenarios above. Recovery banners belong to the disposable profile, and the
preview was stopped.

Remaining: collection/widget orchestration, Viewer movetext windowing, scoped
presentation, document/session/undo/performance parity, legacy hierarchy/bridge
retirement, milestones 4–7 and non-Linux/release gates. This completes neither
milestone 3 nor the full renewal.

### Shared document viewport checkpoint (2026-09-17)

The bounded editor viewport now lives in the design system as
`layout/anchored_document_viewport.dart`. Its `DocumentRows` contract exposes
immutable row identity/index information without chess models or feature imports.
`features/documents/widgets/move_text_viewport.dart` is the editor-specific
adapter: node-to-row lookup remains with the feature, and navigation does not
recreate the full row index. Study and Builder already use this shared component.
Distant selections now choose their anchor during the build update, so an
unmounted destination appears in its first frame. Local selection inside a tall
wrapped row retains the exact-item reveal behavior.

The existing PGN Viewer still uses its rich eager document renderer. Replacing
that requires a row index for prose, diagrams, engine notes, inline variations,
focused branches and editors, plus preservation of the reading pane's anchors
and bookmarks. This checkpoint extracts the common viewport; it does not claim
that Viewer rendering is bounded yet.

Verification (Linux, this checkpoint): 18 focused tests pass, covering generic
50,000-row first-frame jumps, bounded mounted rows, stable row state after
insertion, empty/replaced documents, editor virtualization at 20,000 nodes,
200% text, tall move runs, retained drafts, cache updates and autosave. Two native
journeys pass: large Study open/jump/edit/save (open 1,738 ms, distant jump 546 ms,
RSS 762,712,064 bytes) and Builder annotation/glyph save, mode change and reload.
These debug timings remain diagnostics rather than frame/allocation certification.
Analyze/lint passes with nine existing informational notices, no warnings/errors,
and all 18 boundary-checker regression cases pass. No selected cases are skipped.

The first run of the new state-retention tests used `ValueKey<int>` finders for `ValueKey<Object>` fields;
correcting the test finders resolved those failures.

The headless production app opened the disposable “Large course viewport” Study
and selected its Nf6 move. The inspected [1280×720 screenshot](images/renewal-shared-document-viewport.png)
shows the selected move, wrapped annotations, corresponding board and annotation
field. Recovery banners are from the test profile. The preview was stopped.

Milestones 1/2 and 3 remain partial. Viewer adoption, document/session/undo/
performance parity, hierarchy/bridge retirement, milestones 4–7 and non-Linux/
release gates remain unfinished.

### Viewer bounded-rendering checkpoint (2026-09-17)

Viewer now uses the shared document viewport in production. The pure
`features/documents/models/viewer_document_layout.dart` indexes visible mainline
and variation runs iteratively, with a maximum of 24 moves per run and constant
time move/node/key lookup. Nested alternatives keep their source reading order;
folded branch heads, focused scopes, solitaire reveal boundaries, repeated prose
references and engine suggestions retain their distinct behavior. Selection-only
mainline updates reuse the index. The recursive variation widget traversal and
eager whole-document Column are retired; prose, diagrams and move widgets are
built for mounted rows. Engine-only scores do not force one row per move.

The reading pane supplies an external controller and applies its exact anchor
during layout, including the second sliver layout needed after pixel correction.
Reverse-side destinations are re-anchored before layout, avoiding forbidden
reads of descendant heights. Short games stay at the top; final moves respect
the actual document end. Focus bookmarks store a stable viewport-origin row key
and relative pixel offset. Inline prose previews preserve browsing position;
inline comment drafts survive eviction and save to the original move. Training
uses this viewport without an outer scroll view, keeps lesson prose scrollable,
and shares its snapshot identities across unchanged presentation updates.
`MainlinePositions.positions` shares an immutable list until replay changes.

Verification: the 137-test focused regression batch passes, including reading
anchors in the first painted frame, focus/parent bookmarks, long sticky passages,
engine suggestions and extension/save, diagrams and legal inline previews,
loading/recovery, Study/Builder viewport behavior and mainline memo invalidation.
New cases exercise 20,000 annotated mainline plies, a 20,000-ply sideline,
20,000 nested branch indexing/folding and draft eviction. Large Viewer navigation
mounts fewer than 300 move chips and keeps the same mainline index revision.
All 15 selected Linux native cases pass: two large Viewer journeys, twelve
loading/annotation journeys and Builder edit/save/mode-change/reload.

The full unit/widget run also completed: 6,231 passed, five failed and eleven
were skipped. All five failures came from older settings test hosts missing
localization delegates after the settings migration; their hosts now use the
production delegates. The eleven skips are pre-existing native-engine availability
and documented behavior/expectimax review cases. This is not a clean full-suite
result; all 40 cases in the follow-up files pass after repair, including the five
previously failing settings cases, lesson scrolling/rebuild stability and engine
suggestion interaction. No cases in those focused files or native journeys were
skipped. Analyze/lint passes with nine pre-existing informational notices and all
18 architecture-checker regression cases. Initial layout/anchor failures and
obsolete eager-widget assertions were corrected during development; a new lesson
test also initially omitted its required PGN fixture field.

The headless production app opened the disposable 20,000-ply PGN, jumped to move
10,000 and returned to its opening annotation. Inspected screenshots show the
[final selected move](images/renewal-viewer-bounded-end.png) and the
[opening prose and board](images/renewal-viewer-bounded-prose.png). Recovery banners
belong to the disposable profile. The preview was stopped before final checks.

These are correctness and bounded-widget checks, not completed frame/allocation
or release certification. Individual large comments remain whole passages.
Collection/widget ownership, scoped presentation, session/undo parity, remaining
feature migrations, bridge retirement and non-Linux/release gates remain open.
Milestones 1/2 and 3 remain partial; milestones 4–7 remain unfinished.

### Viewer preference and session ownership checkpoint (2026-09-17)

Reading checkpoints now have a pure owner at
`features/documents/controllers/viewer_session_controller.dart`, with a pure
`ViewerSession` value and injected `ViewerPreferencesRepository` contract.
App startup selects `infrastructure/documents/shared_preferences_viewer_repository.dart`.
The old `core/pgn/viewer_session_store.dart` and `slice_persistence.dart` are
retired. Canonical game identity moves from the catch-all services directory to
`chess_core/pgn/game_identity.dart`; all consumers use the same unchanged algorithm.

The repository retains existing keys/payloads for last file, per-file bookmark,
recent files, saved filters and automatic opening detection. Session saves and
close are ordered; deduplication records only successful acknowledgements, so
retrying the same failed bookmark writes it again. Reads wait for pending session
operations. The adapter checks rejected boolean writes and refreshes the plugin
cache before access, preventing failed cached writes being read back as persisted.
This queue is local to one app instance; the two session keys are not a
cross-process or atomic multi-key transaction. PGN bytes are unaffected by these
preference writes.

The legacy collection host now reports failed reading checkpoints and clears its
own error on a successful retry without clearing newer unrelated errors. Recent
file reads reject stale results after a new open; async restore guards disposal.
Pasted games remain readable when opening-preference reads fail, with detection
disabled and an explicit error. App lifetime shutdown awaits the final checkpoint.
This does not add a close veto for a failed reading preference write.

Verification: all 101 focused unit/widget cases pass, covering session ordering,
failed acknowledgements/retries, legacy preference payloads and identities,
saved-filter/mainline restoration, stale recent reads, pasted-game read failure,
collection revision and write preservation, Viewer display and close protection.
Both Linux native journeys in `integration_test/pgn_restart_recovery_test.dart`
pass: unsaved draft recovery after external source replacement with an exclusive
copy, and clean-session reopening at the same game/mainline move without a draft.
These restart journeys reconstruct the app and its owners within the native test
process; they do not certify an OS crash or a separate-process restart.
Analyze/lint passes with nine existing informational notices and all 18
architecture-checker cases. No selected tests are skipped. An initial regression
batch failed to compile a new fake's cursor setter; it was corrected and the full
focused batch rerun successfully. Full-suite, engine and other-platform gates were
not rerun for this checkpoint.
Collection/widget orchestration, scoped presentation, variation-cursor/panel
restoration, Builder persistence/undo/recovery, other feature migrations and
non-Linux/release gates remain open. Milestones 1/2 and 3 remain partial;
milestones 4–7 are unfinished.

### Viewer collection loading and library boundary checkpoint (2026-09-17)

`features/documents/controllers/viewer_collection_load_controller.dart` now owns
whole-collection request revisions and typed read/decode outcomes. File opening
uses the injected collection repository's observed snapshot and modification
metadata. Text opening uses the same request lifetime. Missing, unreadable, empty,
comment-only and failed decoding are distinct results; superseded work returns no
publishable result. Closing, navigation restoration, recovery adoption and disposal
invalidate pending reads, decoding and metadata. Empty or failed newer requests
also revoke older successful work. The pure owner is transitively checked for
Flutter/native dependencies.

`PgnCollectionDecoder` is injected at the app boundary. Its isolate adapter
returns fresh game entries and the preserved banner using the canonical pure
`chess_core/pgn/pgn_collection.dart` codec. Recovery preparation uses that same
injected decoder. Existing callers now import the moved codec directly, without
forwarding shims. Membership of the decoded collection is immutable; the legacy
host takes ownership of mutable game entries for editing. This does not yet make
all legacy collection state private or immutable. Invalidating a request discards
its result; the already-running worker may finish, pending wider job supervision.

`PgnLibraryRepository` now supplies recent-file existence, browse-parent paths
and the default collection directory through a storage adapter selected at app
startup. The legacy Viewer no longer imports `StorageFactory` or the default-PGN
service. The remaining unused `exportSliceToPath` direct-write bypass is retired;
the production export screen still uses the shared save/copy protocol.

Two new regressions reproduced manual edits being displaced when a pending file
read or pasted-text decode completed. Both entrypoints now recheck replacement
protection immediately before adoption, retaining the current draft and showing
the existing unsaved-changes error. A pasted decoder failure releases loading
without replacing the current document or leaking an unhandled future.

The codec extraction also exposed a banner-boundary mismatch: the splitter
accepted indented/CRLF headers and headerless movetext, while banner extraction
lost preceding comments in both cases. Two failing regressions now pass after
banner scanning was aligned with the splitter's leading-comment rules. Native
copy/export coverage now pastes a banner before an indented header.

Validation: the 151-case focused unit/widget batch passes, including nine pure
loader cases, both reproduced late-manual-edit races and failed pasted decoding.
All 17 selected Linux native cases pass (12 Viewer loading/annotation cases,
two restart/recovery cases, one exclusive copy/export case, two 20,000-ply Viewer
journeys). After the banner correction, all 66 affected parsing, loading, save,
recovery and session cases pass; the updated native copy/export case is rechecked
separately and passes. Analyze/lint passes with nine existing informational
notices and all 18 architecture-checker cases. The headless production app
reopened the native saved copy and navigated to e4; the inspected
[screenshot](images/renewal-viewer-collection-load.png) shows the matching board,
selection and retained note. Recovery banners are from the disposable profile.
The preview was stopped before final checks.
Initial unused-import/override warnings from retiring legacy APIs and a removed
import still needed by the unused export method were corrected. No selected
cases are skipped. Full-suite, engine and other-platform gates are not claimed.
Remaining: collection/filter/widget ownership, scoped presentation, complete
session/undo parity, Builder storage/recovery, later feature migrations and
non-Linux/release gates. Milestones 1/2 and 3 remain partial; 4–7 are unfinished.

### Viewer filter ownership checkpoint (2026-09-17)

Accepted filters now belong to the pure
`features/documents/controllers/viewer_filter_controller.dart`, with immutable
selection/config/index snapshots and captured game records. The owner validates
worker indices, preserves the accepted selection on failure, and exposes loading,
errors and restoration notices. Explicit apply, reset, close, navigation and
disposal invalidate older work. Reapplying an identical selection also revokes a
pending different request without moving the current reading cursor. Every new
computation has its own request generation; the old mixin shared a generation
between overlapping computations and allowed an older result to overwrite a
newer intent.

The first source-change guard simply cancelled matching, but a session regression
showed this dropped a chip-removal request when background opening detection
updated headers during its computation. The owner now keeps that logical request
pending and refreshes records/index inputs after a source revision changes. Old
results and old errors cannot publish; only a result for the current source and
intent is accepted. A saved filter with no matches still falls back to the
collection; deliberate zero-match requests retain the active filter. Only queried
FEN-index entries are copied, preserving bounded index lookup overhead.

The `pgn_viewer_controller_slices.dart` part/mixin is removed. The legacy host
forwards filter commands and retains reader/tree/sort presentation effects and
injected preference writes. Saved-filter loading uses the already-read config,
removing a duplicate preference read. Navigation retains one immutable selection
snapshot. The full filter workspace receives `PgnCollectionFilter` explicitly,
keeps its editable draft on worker failure and offers retry; its source callbacks
reject both replaced collections and obsolete content revisions.

`chess_core/pgn/pgn_slice_filter.dart` contains the pure predicates and candidate
matching; `infrastructure/documents/isolate_pgn_collection_filter.dart` owns
isolate execution and indexed candidate preparation. The old services path is
retired and callers use canonical imports. Chip-edit transformations have a
canonical document-model path. The generation inline editor still uses the
infrastructure helper directly and retains its legacy workflow ownership.

Verification: all 354 selected unit/widget regressions pass, including header,
position, AND/OR and sequence matching, malformed PGNs/null moves, indexed and
replayed parity, immutable capture, overlapping requests, failure/retry, source
refresh, saved filters, native file-write safety, Viewer widgets and close guards.
All three Linux native cases pass: the new real filter UI apply/reopen/clear journey
and both clean-session and draft-recovery restart journeys. The filter journey
verifies selected game/mainline restoration and unchanged source bytes.

Final review reproduced an introduced cursor leak: applying the restore result
remembered the departed reader's ply on the newly adopted collection. Restoring
now skips outgoing-cursor capture; all 58 affected follow-up tests pass, including
that regression. The native filter journey passes again after this correction. Malformed decoded
filter settings also release loading and report a failure before worker startup.
The initial source-change cancellation regression and obsolete overrides/imports
were corrected; an intermediate test fixture's callback conversion also failed
to compile before repair. No selected cases are skipped. Full-suite, engine and
other-platform gates were not rerun for this checkpoint.

The headless production app was inspected with an Event filter in the
[editable preview](images/renewal-viewer-filter-owner.png) and the
[applied reading view](images/renewal-viewer-filter-applied.png), showing one
selected game with the matching board and retained move cursor. Recovery banners
belong to the disposable profile. The preview was stopped before final checks.
Analyze/lint passes with nine existing informational notices and all 18
architecture-checker cases.
Remaining: private collection/presentation ownership, legacy filter draft widgets
and theme/localization, complete session/undo parity, Builder storage/recovery,
later features and non-Linux/release gates. Milestones 1/2 and 3 remain partial;
4–7 remain unfinished.

### Viewer board and window ownership checkpoint (2026-09-17)

After filter checkpoint `fe2df868`, the last Viewer controller part/mixin is
retired. `features/documents/controllers/viewer_presentation_controller.dart`
owns board perspective, orientation and serialized fullscreen intent without
Flutter or native dependencies. `viewer_perspective.dart` is the canonical
immutable value/header model; collection-player detection now lives in
`chess_core/pgn/pgn_collection_players.dart`. All callers use canonical imports.
The old window part and direct `windowManager` calls/listeners in the Viewer
controller and screen are removed. Transitive purity checks cover the new owner.

App startup injects `DesktopFullscreenPort`, implemented by the native
`WindowFullscreenAdapter`. The listener belongs to the app-lifetime Viewer owner,
so screen mounting no longer controls native state observation. Initialization
subscribes before reading current state and retains newer events over stale
snapshots. Native operations serialize, rapid toggles use pending intent, and
Escape during pending entry schedules exit. Failures release pending intent,
retain the last accepted state and allow retry. Disposal detaches the listener;
late acknowledgements, errors and retained callbacks cannot notify or reclaim
focus. Window errors cannot overwrite newer unrelated document errors during
ordinary board changes or successful retry.

Orientation preserves the current side for absent or ambiguous player names,
including the same exact name on both sides and empty names. Exact full-name
matches take precedence over surname fallback. Manual flips become the reading
preference for later games without changing an active solitaire session's side.
`PgnCollectionEditor` now owns the perspective-header mutation and its baseline,
conflict/recovery and save behavior. A new regression reproduced a lost metadata
edit when screen-only drill annotations were present: the stored-text overlay
hid the perspective update. The editor updates that overlay's header separately,
so explicit perspective edits save while temporary drill annotations stay out
of the PGN. The failing regression now passes.

Verification: all 152 selected unit/widget regressions pass across Viewer,
collection helpers/revisions, session restoration, saves, recovery, data integrity
and screen/shortcut behavior. All 57 follow-up cases pass, including 14 pure
presentation-owner cases, native-channel listener lifecycle/dispatch tests, error
ownership and perspective save/conflict/drill-overlay regressions. These batches
overlap. Both Linux native journeys pass: Settings orientation selection, explicit
save with exact unrelated-byte preservation, F11/Escape presentation, app-owner
reconstruction and reopened perspective; plus the existing filter apply/reopen/
clear journey. No selected cases are skipped.

The first native test failed because it searched for a standard Back button;
it now uses the production Close settings control. Initial extraction compiler
errors from a subclass constructor, canonical import and library-directive order
were corrected before the passing batches. Analyze/lint passes with nine existing
informational notices and 18 architecture-checker cases.

The headless production app reopened the saved native fixture with Black at the
bottom; inspected screenshots show the [reader](images/renewal-viewer-perspective.png)
and [persisted orientation setting](images/renewal-viewer-perspective-settings.png).
The recovery banners belong to the disposable profile. The preview was stopped
before final checks. Xvfb native tests exercise plugin calls and the app's fullscreen
presentation; they do not certify a real window manager's physical fullscreen
transitions, Windows/macOS, separate-process restart or full release gates.

Remaining: private collection ownership, scoped reader/widgets, complete session/
undo/panel parity, Builder storage/recovery, theme/localization migration, later
feature migrations and platform/performance/release gates. Milestones 1/2 and 3
remain partial; 4–7 are unfinished. This is not full-renewal completion.

### Viewer collection membership checkpoint (2026-09-17)

Following board/window checkpoint `03673c8f`, the pure
`features/documents/controllers/viewer_collection_controller.dart` owns file
membership, visible indices/order, selected index and sort preference. The host
publishes read-only lists/getters instead of independently assignable fields.
Adoption captures the caller's list; filtering validates bounds and duplicates
before changing anything. Navigation restoration validates order and selected
index atomically. Sorting publishes new fixed lists, uses original file position
for deterministic ties, and preserves previously published order. File-order
restoration distinguishes repeated occurrences of the same entry object.
Selection shares the existing lists; identical views retain list identities and
view revision. Pure sort helpers move to `chess_core/pgn/pgn_game_sorting.dart`
without a forwarding shim. Transitive purity enforcement includes the new owner.

The screen no longer assigns the selected index. It awaits `selectGame`, which
reports false for superseded cached-analysis loads instead of authorizing work
for a departed selection. Decoded documents enter through an explicit adoption
command with draft protection and request invalidation; paste uses the same
boundary. The returned request revision lets paste reject reentrant handoffs
made during notification. Navigation captures immutable visible indices rather
than a mutable filtered list.

A strengthened regression reproduced an existing callback leak: late annotations
for a departed game could mutate that old object and mark the new collection
dirty. Identity membership now rejects those callbacks before the editor sees
them; games hidden by a filter remain valid members. Background annotation
completion also checks the captured collection identity. Both screen-only and
persisted late-edit regressions now pass.

A reentrant-selection regression also reproduced a false readiness result: an
older selection could borrow the newer load's generation during orientation
notification. Selection now has its own accepted-intent token, separate from
view revision, so selecting the same row again supersedes pending work without
rebuilding lists. Both pre-load and in-load reentrancy are covered. Disposal
rejects pending selections and does not start late annotation enrichment.

A final combination test reproduced another existing inconsistency: applying a
filter ignored the selected sort, and clearing it briefly published file order
while still reporting newest-first. Both operations now apply the chosen ordering
before notifying. The native collection journey covers this combined behavior.

Verification: all 128 selected unit/widget regressions pass across collection
ordering, sorting, Viewer, session restoration, metadata, recovery, file safety,
data integrity and screens/shortcuts. All 85 affected final follow-up cases pass after
the stale-edit, reentrancy and filter/sort corrections; these batches overlap. The nine pure
collection-owner cases include a 20,000-game selection loop that retains the
same membership/order objects; this is allocation-shape evidence, not a complete
frame/GC/performance-budget certification. All four selected Linux native cases
pass: sorted collection navigation/history/reopen with exact source-byte
preservation, filter apply/reopen/clear, clean-session reopen and retained-draft
recovery. The collection and both restart/recovery cases pass again after the
membership and selection guards. The expanded collection journey passes again
after the filter/sort correction. No selected cases are skipped. Full-suite,
engine, other-platform and release gates were not run for this checkpoint.
Analyze/lint passes with nine existing informational notices and all 18
architecture-checker cases.

Visual verification uses the private Linux preview and disposable native-test
profile. The [restored board and move](images/renewal-viewer-collection-order.png)
show game 2 of 3 at `c4`; the [game picker](images/renewal-viewer-collection-list.png)
shows newest/middle/oldest order with the middle game selected. Both screenshots
were inspected. Recovery banners belong to the disposable fixture profile.

These are fixed membership/order views, not immutable snapshots of game values:
`PgnGameEntry` contents still use the legacy mutable editor model. Private entry
ownership/projections, scoped widgets and complete session/undo/panel parity are
still required. This checkpoint does not graduate milestone 3 or complete the
full renewal; later features, performance and platform/release gates remain open.

### Viewer navigation edit-context checkpoint (2026-09-17)

Following collection checkpoint `fca0a99a`, the collection editor owns a private
edit ledger per adopted collection. An opaque navigation context retains that
ledger and validates its editor, path and ordered game identities on adoption.
The legacy host no longer clears screen-only and edit tracking independently.
The old outcome/block `Expando` maps are removed. Baseline, pending-write count,
original game bytes, dirty metadata, screen-only substitutions, save outcome,
read failure and automatic-save block now share one collection lifetime. Public
save status and autosave configuration are read-only; changes use commands.
The serialized write queue and retained-draft chooser remain editor-session-owned.

Two file-level regressions failed before implementation. First, returning to a
collection rebuilt its baseline from live game text and discarded screen-only
substitutions; drill-only notes could enter a later perspective save. Second,
returning while an outgoing save was pending detached its receipt from the new
baseline, so a failed source write left the returned draft reporting clean.
Both regressions now pass. Navigation preserves the exclusion and original
bytes, and receipts update their captured ledger even while it is parked.
Failures cannot publish errors, busy state or file timestamps onto an unrelated
collection. Returning restores conflict/uncertain state and blocks implicit retry.

Save Copy establishes a separate destination ledger, clearing the old source
outcome for that destination while older navigation contexts retain their source
baseline and conflict. Deliberate edits made during a copy remain dirty. Fresh
adoption resets the whole ledger atomically; invalid contexts cannot replace it.
The host rejects navigation callbacks after disposal.

Verification: all 132 selected unit/widget regressions pass, including existing
navigation, recovery, source-preservation, session, revision and data-integrity
coverage. All 41 final affected tests pass after the status-API encapsulation;
these batches overlap. Tests cover successful/failed receipts both before and
after return, uncertain-write rejection, copy/source isolation and context
validation. Analyze/lint passes with nine existing informational notices and all
18 architecture-checker cases. An intermediate getter-edit compilation error was
corrected before the final gates and native runs.

All four selected Linux native cases pass: the new drill/navigation/perspective
save/copy/reopen journey, the existing sorted collection/filter/history journey,
and both clean-session and retained-draft restart cases. The new journey verifies
that source banners and untouched games survive, drill annotations stay off disk,
the copy gets its own path and a reopened copy has no transient drill notes. App
owners are reconstructed in-process; this is not new OS-crash or other-platform
evidence. No selected cases are skipped. Full-suite, engine, cross-platform and
release gates were not run for this checkpoint.

The [saved-copy preview](images/renewal-viewer-navigation-copy.png) was inspected
in the private Linux app: game 1 of 2 shows `e4 e5`, no drill-only note, and the
persisted black-side orientation. The preview used the native journey's disposable
copy, selected through that isolated profile's last-file preference; recovery
banners belong to other disposable fixtures. It does not access user data.

These are in-memory navigation handles, not a durable navigation-history format
or immutable game values. Private collection entries, remaining document/session/
undo/panel parity,
Builder recovery, later feature migrations and full performance/platform/release
gates remain open. Milestones 1/2 and 3 are partial; 4–7 remain unfinished.

### Builder document-boundary checkpoint (2026-09-17)

Following Viewer edit-context checkpoint `0dcd6d23`, Builder now requires injected
`RepertoireDocumentRepository` and `RepertoireDecoder` contracts under
`features/repertoires/repositories/`. App startup supplies them through Provider;
the Trainer receives its board session explicitly. The controller and writer no
longer resolve `StorageFactory`, construct `RepertoireFileEditor` or create the
old concrete loader. A focused architecture rule rejects those regressions.

The old loader is retired. `LoadedRepertoire` lives in feature models, PGN
metadata parsing lives in `chess_core/pgn/repertoire_headers.dart`, and worker
scheduling lives in `infrastructure/repertoires/isolate_repertoire_decoder.dart`.
Pure text editing, line IDs, document splitting and immutable append receipts
have canonical chess-core libraries. Imports move directly; no forwarding
libraries remain. Transitive purity enforcement covers the new contracts and
load values as well as chess core.

`DocumentRepertoireRepository` routes Builder reads, line edits/deletions,
metadata changes, imports, appends and undo through the shared PGN document store.
Linux uses the native revision/history protocol selected at startup. Other hosts
retain the content-only compatibility store. The existing logical per-move undo
chain and queued session checks remain intact. Undo's exact decoded-result
reconciliation is explicit; this does not graduate native persistent undo receipt
provenance or other-platform commit protocols.

A new regression reproduced an external-before-save overwrite: editing a loaded
line replaced a newer annotation on disk. Each line saver now captures its
loaded original and advances it only to an acknowledged stored game. Queued and
retained callbacks share that collection's originals; unrelated games and custom
headers survive. A changed derived ID can resolve the exact acknowledged game
only when unique. Replacement input is normalized to one game, keeping chapter
preambles out of its movetext; multi-game line replacements are rejected. This
also fixed a follow-up sequential-save regression. Bulk deletion validates all
captured index/game pairs atomically, and late single/bulk deletion cannot clear
the new chapter's selected tree.

The native import-conflict fixture now injects a document-store decorator before
app construction and interleaves a real filesystem edit before native commit.
It no longer changes a global storage singleton underneath a running controller.
Legacy unit fixture composition still captures disposable storage in a test
helper; new repository contract tests use an injected scripted store directly.

Verification: the initial focused batch passed 189 tests, the broader
Builder/Trainer batch passed 109, the targeted follow-up passed 41, and the
final affected screen/repository/controller batch passed 55. These batches
overlap and are not a distinct-test total. Four native cases passed across
`builder_projection_test.dart`, `repertoire_mutation_test.dart` and
`workspace_navigation_test.dart`: annotation/glyph persistence, import conflict
and retry, navigation and draft retention. Analyze/lint passed with nine
existing informational diagnostics, no warnings/errors, and 19 architecture
checker regressions. No selected tests were skipped. An incorrectly combined
runner invocation started the full suite; it was deliberately cancelled and
does not count as a suite pass. Engine, other-platform and release gates were
not run.

The private preview reopened the native import fixture with both games and the
external annotation intact. Visual inspection also caught the internal
`.cap-pgn-history` directory in the chapter outline; recursive outline loading
now excludes that reserved directory, with a real-filesystem regression.
All 23 outline tests and analyze/lint passed after that correction. The rebuilt
app's [inspected screenshot](images/renewal-builder-document-boundary.png)
shows the two chapter lines and retained external annotation without exposing
the internal history folder. The headless preview used disposable data and was
stopped before handoff.

This is milestone 3 progress, not full Builder migration. The legacy host/presentation, outline and
generation file-editor callers, app-lifetime Builder recovery, retained scratch
drafts and complete native undo receipts remain pending. Milestones 1/2 and 3
are partial; later feature, performance and cross-platform/release gates remain
open.

### Builder board ownership and canonical hierarchy checkpoint (2026-09-17)

Following document-boundary checkpoint `428d48f5`, Builder now owns mutable board
state in a pure `RepertoireBoardController` under
`features/repertoires/controllers/`. It encapsulates the move tree, cursor,
position/path caches, annotations, variations, root navigation and draft-edit
receipts. Immutable projections and structural sharing remain intact. The host
publishes notifications after a command completes and synchronizes the opening
graph using immutable SAN/FEN paths, without replaying each move.

`RepertoireController` and `RepertoireWriter` now have canonical feature-controller
paths; their legacy `core/` libraries are removed. `RepertoireAuthoring` lives in
feature models and no longer constructs `RepertoireService` or depends on Flutter.
Shared navigation is in `chess_core/moves/`; course headers and variation expansion
are in `chess_core/pgn/`. Consumers import these owners directly. The moved tests
mirror feature/chess-core ownership. Architecture enforcement checks the board
and authoring dependency closures and refuses reinstating the six retired
libraries as forwarding shims.

Draft deletion returns an opaque receipt bound to its board adoption and expected
movetext. An equal-looking replacement board cannot revive an older draft undo;
successive deletions in the same lifetime still restore comments, glyphs,
variations and cursor. Root deletion continues to clear the board and can be
undone. Invalid starting FEN adoption now refuses the operation without replacing
state or invalidating its undo receipt. No persistent file undo semantics change.

Verification: 205 feature/shared-navigation tests passed, followed by 81
Builder/Trainer/widget/undo tests and 44 focused checks after the final review
correction. These batches overlap. All four native cases passed across
`builder_projection_test.dart`, `repertoire_mutation_test.dart` and
`workspace_navigation_test.dart`. Analyze/lint passed with nine existing
informational diagnostics, no warnings/errors, and 20 architecture checker
regressions. A standalone Dart VM probe exercised board edit/undo plus pure line
authoring/adoption without Flutter initialization. The existing 20,000-node test
measured a 30.9 ms initial projection and 1.2 ms deep annotation projection in
this run; these are focused debug measurements, not full profile-mode budgets.
No selected tests were skipped; full-suite, engine, other-platform and release
gates were not run.

The private rebuilt preview reopened the native import fixture and navigated
from the start to `e4`; the [inspected screenshot](images/renewal-builder-board-owner.png)
shows the board, selected move and retained external annotation in sync. The
headless preview used disposable data and was stopped after inspection.

This remains milestone 3 progress: document/session recovery, private opening-graph ownership,
remaining legacy presentation, outline/generation editors and complete native
undo provenance are still unfinished. Later training, jobs, platform and release
gates remain open.

### Parallel renewal execution brief (2026-09-17)

The product owner renewed authorization to **finish the whole plan**, explicitly
requested subagents, larger completed workflows, improved testability/safety and
legacy removal. Starting integration baseline: `9036708c`. The goal remains the
complete acceptance register, not a count of extracted classes. Local `main` and
its verified backup are the deliverable; publication is not requested.

**PLAN-02 decision: bounded repair and consolidation.** The first slice remains
partial. Its controller/repository overrides, native document mutations, catalog
recovery, shared save interaction and retained shell are exercised by the earlier
checkpoints. However, there is no recorded product-owner visual acceptance,
complete profile-mode budget, full-profile restore rehearsal or native
Windows/macOS evidence. These are unresolved gates, not implicit passes. The
large accumulation of checkpoints has not retired whole legacy workflows. The
renewed instruction authorizes independent repairs in later owners while these
gaps are closed; it does not graduate milestone 2 or waive an acceptance ID.

| Owner | Bounded outcome | Required evidence | Budget / midpoint |
|-------|-----------------|-------------------|-------------------|
| `builder_renewal` | Builder document loading, destination and queued edits have one injected session owner; failed switches retain the current document; remove superseded host ownership/test hooks | ARCH-01, DATA-02/03, STATE-01/02, TEST-01; current Builder/Trainer callers remain functional | 4 active hours: 2 implementation, 1 regression tests, 1 integration reserve; midpoint after production wiring |
| `training_renewal` | Training source, progress and preference dependencies are injected; session phases own lifecycle; preserve persisted history and retire migrated `services/training` owners | ARCH-01, DATA-06, SET-01, STATE-01, TEST-01; deterministic source/settings/cancellation failure tests | 6 active hours: 3 implementation, 2 parity tests, 1 integration reserve; midpoint after source/session cutover |
| `generation_renewal` | Generation stages recoverable run output and validates source revision before publication; edited companion files survive; pending writes cannot outlive their run | ARCH-01, DATA-02/05/07, STATE-01, PROC-01, TEST-01; stale source, interrupted publication, disposal and duplicate-job tests | 6 active hours: 3 implementation, 2 failure tests, 1 integration reserve; midpoint after publication wiring |
| Integrating agent | Reconcile source-backed inventory and acceptance register, rehearse cross-store restore, enforce new boundaries, validate merged production code and integrate local main | PLAN-01/02, DATA-06, ARCH-01, TEST-01; exact committed branch/backup evidence | 4 active hours: 1 inventory, 1 restore rehearsal, 2 review/integration reserve; midpoint after restore result |

No package spike or visual redesign is part of this repair batch. Queue/build
waits are not active effort. Owners report their midpoint, removed production
owners, exact checks and remaining compatibility dependencies. At a budget cap,
finish and back up the safe checkpoint; record a revised bounded scope before
further expansion. Full renewal remains active until every applicable gate has
current evidence. Platform and visual-review gaps remain explicitly unverified.

The integration midpoint restore rehearsal passed on Linux:
`test/infrastructure/profile_restore_rehearsal_test.dart` closes all fixture
writers, copies Documents/Support plus synthetic book preferences, restores into
a different disposable profile, and deletes the source. It verifies exact PGN
bytes (BOM, variations, NAGs, custom tags), SQLite integrity/foreign keys/schema,
source-game IDs and position rows, then explicitly relocates chapter/history/book
references. Native-to-compatible-adapter rollback reopens current data and
preserves annotations and new SQL games written after cutover; the original
backup stays unchanged. This is DATA-06 evidence for the tested **stopped-profile
protocol**, not a live backup feature, native preference export, crash-consistent
cross-store snapshot or proof for all remaining domain formats. No user data or
credentials enter the fixture. A formatting parse failure in the new PGN fixture
was corrected before the passing run.

Profile-mode baseline budgets, selected before measurement: the existing
20,000-node annotated Study fixture must open/decode/receive within 5 seconds;
30 warm distant-navigation commands and 30 comment-edit/projection commands
must each have p95 at most 50 ms; RSS growth over
that bounded sequence must stay within 64 MiB. These are initial regression
ceilings on the two-CPU Linux runner, not a claim of 60 Hz rendering. Frame
build/raster times and GC counts are captured separately by the native Flutter
performance binding. `scripts/ci.sh profile` uses the existing bounded headless
runner and writes `build/renewal_performance.json`, including failure evidence.
It refuses a debug run. Undo, allocation attribution, image memory and
other hosts remain additional STATE-02 measurements; navigation does not certify
them. This extends the integrating agent's scope by one active hour (half an
hour harness, half an hour validation) to replace debug-only evidence.

The first profile run exposed an unmet frame budget despite passing command
latencies: distant navigation built below 7 ms, while repeated comment edits
built near 398 ms. The existing stage diagnostic isolated full row-index
comment filtering at 363 ms. The repair preserves filtered paragraphs for
unchanged move nodes with weak cache keys and checks source text for mutable
legacy callers. The profile gate now requires p99 frame builds within 32 ms on
the bounded headless host, in addition to command/memory budgets. This is a
regression ceiling, not a 60 Hz/GPU claim: headless raster timings reported
near zero and cannot establish production GPU latency. Study performance repair
adds one active hour within the authorized scope. The second profile's Dart
assertions passed, but its shell wrapper failed because the wrapper was edited
while executing; the complete command must pass on the final source.

The final complete profile command **passed** after immutable annotation
revisions began reusing unchanged rows and the redundant document-wide row-key
map was removed. Structural/paragraph-count changes still use full indexing;
mutable legacy callers never enter the snapshot reuse path. On the recorded
fixture, open/decode/receive took 302 ms and first frame 987 ms; navigation p95
was 0.153 ms, edit/projection p95 0.304 ms, navigation frame p99 6.913 ms and
edit frame p99 **9.346 ms** (worst 11.951 ms). RSS decreased during the bounded
sequence. [Recorded scalar report](evidence/renewal-linux-profile.json) retains
budgets and scope limitations. Eighteen focused layout/editor tests passed,
including annotation parity, structural fallback, paragraph keys, immutable
rows, 20,000-node navigation, 200% wrapping and draft eviction/autosave behavior.

### Larger ownership completions (2026-09-17)

| Source commit / requirement | Production change and retired owner | Evidence and remaining scope |
|-----------------------------|-------------------------------------|------------------------------|
| `b4c22ad1` / ARCH-01, DATA-02/03, STATE-01/02, TEST-01 | `RepertoireDocumentSession` owns load epochs, destination, parsed document/metadata and pending edit queue. Host shrinks from 781 to 281 lines; production test hooks removed. Public line collections are defensive immutable copies. | 243 focused tests, six final session tests, four native journeys and a standalone Dart VM probe passed. Failed loads retain destination, board, selection, color/root and undo together; pending save failures keep blocking navigation/close. [Inspected recovery screenshot](images/renewal-builder-document-recovery.png). Opening graph privacy, scratch recovery and native undo provenance remain. |
| `1e104097` / ARCH-01, DATA-06, STATE-01, TEST-01 | All 14 `services/training/` libraries retired. Session/phase/progress owners and pure settings have canonical training paths; app composition injects source/review/header/answers/config ports, with filesystem/preferences adapters under infrastructure. | 232 focused tests passed, including source/chapter/settings/rating races, duplicate completion, partial-write retry and failed header mirror. Analyze/lint passed with nine existing infos. [Inspected production Retry component](images/renewal-training-retry.png). Existing CSV/JSONL formats and identities retained. In-memory retry is not crash-resume or cross-file atomicity; ordinary settings still require one app-scoped writer and explicit active-sitting policy. |
| `a7d8dfd7` / DATA-02/07, PROC-01, ARCH-01, TEST-01 | Per-session generation publication captures source/config before work; stages complete course/model output and a manifest in a retained run directory; commits once through the document store and records a separate receipt. `PgnBatchWriter`, blind companion overwrite/delete and public partial-tree save are retired. | 99 affected tests passed, including actual full-pipeline source conflicts, native staging and cancellation/disposal/engine failure lifecycles. Analyze/lint passed with 12 infos. Old companions survive; conflicts/uncertain writes report retained manifests and never auto-replay. Tree/probe/trap/partial caches and a recovery browser remain. |
| `8231b2bc` / ARCH-01, STATE-01, PROC-01, TEST-01 | Retired `core/pgn_viewer_controller.dart` and all `core/pgn/` owners after injecting index storage, cancellable computation, opening data, Solitaire settings/trophies and analysis ports. Removed unused collection merge helper and its obsolete mirror tests. | 339 broad tests passed; five transient load failures were fixed and the affected files passed in a 48-test rerun. Four native Viewer workflows passed, plus adapter failure checks and analyze/lint. [Inspected tree/board screenshot](images/renewal-viewer-workspace.png). Disposable `.fenidx` v1 is rebuilt as source-fingerprinted v2. Concrete reader/analysis construction remains an explicit app bridge. |
| `c83a895d` / DATA-02/07, STATE-01, TEST-01 | Removed `GeneratedLineExport`, `onLinesSaved` and `appendNewLines`. Generation awaits a complete committed-document receipt; Builder validates the receiving session and atomically refreshes it. Ordinary line saves now return a complete document baseline and refresh it before later actions. | 125 affected tests and 34 final receipt/adapter/pipeline tests passed; analyze/lint passed. Replayed callbacks, A→B→A handoffs, late decode, failed refresh, external other-game edits and line-save→append→undo are covered. Full decode per acknowledged line edit is a remaining large-chapter cost. |
| `a455747d` / SET-01, STATE-01, TEST-01 | One app-scoped training settings owner serializes immutable field patches. Concurrent panels share committed/draft/failure state and retry. Running sittings, including auto-next, freeze their effective configuration; edits apply to the next sitting. | 204 focused tests passed with no skips; analyze/lint passed. Native production panels exercised save failure→Retry→persist→restart with synthetic preferences. [Inspected failure UI](images/renewal-training-settings-failed.png). Legacy keys/defaults preserved. Drafts remain in memory, cross-process serialization and atomic multi-key preferences are not claimed. |

An accidentally broad training test command was interrupted after roughly
4,000 passes, eight skips and one unidentified failure. A captured integration
run subsequently completed with **6,396 passes, 11 skips and one failure**:
the MainScreen test fixture lacked the newly required training document
dependency. `a455747d` fixes that fixture through production boundaries; the
final combined suite **passed with 6,408 tests and 11 skips**. Those skips include
opt-in engine/live-network checks and documented existing algorithm cases, not
11 newly passing release gates. Merged analyze/lint passed with 13 informational
findings and no warnings/errors; boundary regressions (23), check-dispatch
regressions and the worktree helper's six tests passed. The check launcher
now rejects misplaced focused targets
before starting any named step; `scripts/ci.sh analyze lint` and
`scripts/ci.sh test <targets>` are separate commands.

The next independent bounded owners are Viewer host retirement (five active
hours including one validation reserve, based on `9036708c`) and completion of
training SET-01 (four active hours including one reserve, explicit dependency
`1e104097`). The Viewer slice must replace implicit FEN-index/classification/
Solitaire collaborators before retiring its remaining `core/` host. Training
must serialize field edits through one app-scoped committed owner and prove
concurrent panels, failure/retry/restart and current-sitting configuration.
Midpoint is production wiring. These scopes continue the original whole-plan
objective; they do not graduate milestones or erase the residual gates above.

The generation follow-up extends the same document-authority repair by one
active hour, including validation: generation hands Builder a committed document
receipt rather than appended line deltas, and ordinary line saves must advance
the whole-document baseline before a subsequent edit. The confirmed stale
baseline is not left behind as an unrelated cleanup.

After Viewer handoff, the next Builder owner has six active hours including one
validation reserve for native-revision append/undo provenance and private opening
graph ownership (DATA-03/04, STATE-02, ARCH-01). Its dependencies are `b4c22ad1`
and the generation receipt follow-up; midpoint is production wiring. Durable
scratch recovery remains a separate open requirement. The integrating owner's
Study frame repair gets one further active hour to reuse immutable annotation
rows after caching alone reduced, but did not meet, the 32 ms frame gate.

The next two independent owners each have five active hours including one
validation reserve. Generation completes DATA-07 for tree/probe/trap/partial
artifacts through versioned bundles and one validated current manifest, wiring
both producers and actual readers; it depends on `c83a895d` and the current
training adapter. Settings completes SET-01 for engine, bulk-analysis and
board-display keys through section owners and captured active-job configuration;
it depends on `a455747d`, excludes credentials/external-eval database settings,
and retains explicit injected read-only bridges for legacy engine lifetimes.
Midpoint for each is production wiring. Parent integration owns shared docs,
boundary gates and the combined checks; neither agent independently advances main.

### Persisted authority and native inventory (2026-09-17)

This ledger supplements the workflow map below. It is based on source at
`9036708c`; it does not inspect the user's profile. Stable reference contracts,
not filenames alone, determine what a restore must preserve.

| Authority / owner | Format and location | References, migration and restore contract |
|-------------------|---------------------|---------------------------------------------|
| Repertoire catalog and document adapters | `Documents/repertoires/<book>/<chapter>.pgn`; course/color comments and standard/custom PGN tags | Absolute chapter/folder paths plus `[LineID]`; directory journals relocate four training files and both book selections. Preserve BOM, annotations, variations, NAGs and unknown headers; old readers retain PGN compatibility. |
| Study and Viewer document repositories | `Documents/studies/*.pgn`, `pgn_collections/` and user-selected PGNs | `[GameId]` links to saved games; document snapshots/recovery manifests carry edit context and revision. Retain unsaved recovery separately from committed PGNs. External files require a separately selected backup source. |
| Saved game store | `Support/app_games.db`, `gameStoreSchemaVersion = 2` | `games.id`, `(collection, game_key)` and `positions.game_id`; `game_trash` is recovery authority. Tactics source games may have no PGN copy. Upgrade snapshots use SQLite `VACUUM INTO`; newer schemas are refused. Stop all writers for a cross-store filesystem copy. |
| Master games | `Support/master_games.db`, schema 4 | Downloaded game/book index; may be rebuilt from available inputs. User-imported offline inputs must be retained separately before declaring their database disposable. Preserve schema guard and importer/reader compatibility. |
| Repertoire review service and move attempts | Three `Documents/repertoire_*.csv` files plus `repertoire_move_attempts.jsonl` | Chapter path, line ID and move index; CSV quoting/version-2 backup protects punctuation/multiline fields. Row merging rejects competing edits. JSONL unknown fields survive reference migration. No scheduling/schema change is authorized by an ownership move. |
| Tactics database | `Documents/tactics_sets/*.pgn`; legacy CSV inputs | Puzzle provenance and scheduling fields; `ChessAutoPrep-Analyzed-v1` completion marker and source GameId commit together. Preserve source archive and legacy input until migration verifies; failed decode cannot authorize pruning. |
| Player corpus | `Documents/analysis_games/player-<sha256>/current.json` and retained `versions/` | Identity hashes platform plus normalized username; current manifest chooses PGN+metadata generation. Derived indexes/evals are keyed by corpus fingerprint; tombstones must survive restore. |
| Opponents | `Documents/opponents/people.json` (`chess-auto-prep/people@1`) and `tournaments/<id>.json` | Tournament fields refer to person IDs. Preserve those IDs and unknown/unreadable originals; MCP handoff is a separate import file, not a second writer. |
| Engine/bughouse tournaments | `Documents/engine_tournaments/<id>/tournament.json`, `games.pgn`, `engines.json`; `Documents/bughouse_matches/<id>/match.json` | Tournament IDs, game order and custom engine paths; external executables/assets are dependencies, not embedded user data. Keep partially completed runs and their metadata together. |
| Generation and audit | Chapter-adjacent generation artifacts, source PGN and hunt report store | Source/run/config identity and companion PGN provenance are required. Existing unguarded writers are a repair target, not certified safe by this inventory. |
| Recovery namespaces | `.cap-pgn-history/`, directory staging/trash, `repertoire-mutations/`, `.cap-reference-history/`, workspace recovery | Preserve unfinished journals with payloads and exact original bytes; do not purge them or copy just the current PGN while a writer is active. |
| Preferences | Platform SharedPreferences file | Typed book/appearance owners coexist with legacy engine, eval, display, training and Viewer keys. Retain current names; do not run old/new writers for the same key. See key ledger below. |
| Credentials | Legacy SharedPreferences OAuth/PAT keys | `lichess_access_token`, `lichess_refresh_token`, expiry, username and PAT flag remain owned by `LichessAuthService`. These are **not ordinary settings backup data**. Vault migration/restart/disconnect is still SEC-01 work; no new plaintext credential path is introduced. |

Preference key ownership is explicit at each migration boundary:

- Books: `my_repertoire_white_paths` and `my_repertoire_black_paths`, through
  `PersistedRepertoireBooks`; appearance through `PersistedAppearance`.
- Training: `trainer_*` keys and `trainer_uncapped_default_v1`; move persistence
  out of `TrainingSettings` into the injected training adapter without changing
  keys, defaults or scheduling semantics.
- Engine: `engine_settings.*`; bulk depth uses `engine_settings.bulk_depth` with
  legacy `tactics_import.depth` read compatibility. Effective job configuration
  must be captured once; remaining whole-object writes need SET-01 migration.
- Eval: `eval.cdbdirect.*`, `eval.lichess.*`, `expectimax.chessdb_api` and
  `expectimax.probe_plies`; display: `display.board_coordinates`,
  `display.piece_notation`, `display.legal_moves`.
- Viewer: the key ledger in `SharedPreferencesViewerRepository` retains file,
  game and recent-session identity. Game review counts use `game_review.counts`.
  Account labels/fetch times remain in `AppState`; secrets stay out of this owner.

| Native dependency / source of truth | Ownership and host prerequisite | Current evidence limit |
|-------------------------------------|---------------------------------|------------------------|
| Stockfish executable; `tools/assets.lock.json` | UCI process/worker owner, bounded stop/kill; target-specific bundled artifact and source/license obligations | Linux engine fixtures/native journeys exist; forced-parent-death and packaged host matrix are not complete |
| Hivemind + ONNX Runtime/network; same asset lock | Separate engine process; optional assets, Windows private runtime package, retained model/engine licenses | Source/payload hashes are pinned. Host loader and descendant termination remain host-specific gates |
| Maia ONNX Runtime plugin | FFI session/tensor handles with worker ownership; target ABI/plugin bundle | App/native memory and shutdown budget is still unverified; process isolation cannot protect an in-process FFI crash |
| `document_file_io` private package | Native identity/read/flush handles behind document adapter; repository AGPL-3.0 | Linux package/journeys verified in earlier checkpoints. Windows replacement and macOS full-sync remain unavailable locally |
| SQLite and cdbdirect | Database/FFI handle owners; pinned lockfile/native asset build | Saved-game schemas/upgrade guards exist; full backup and host ABI checks are scoped separately |
| Desktop plugins | File picker, path provider, preferences, window manager/screen retriever, launcher/share/package info and JNI; exact versions in `pubspec.lock` | Generated plugin registrants enumerate Linux/Windows/macOS builds. Registration is not install/signing/vault/screen-reader evidence |
| Proposed credential vault | [flutter_secure_storage desktop prerequisites](https://pub.dev/packages/flutter_secure_storage#linux) | Linux preflight found `gnome-keyring-daemon`, but `pkg-config libsecret-1` lacks its development package and noninteractive sudo is unavailable. No vault dependency/migration has been installed or certified. |

The available verification host is Linux. Windows/macOS signed installation,
vault availability, native screen reader, forced-parent-death and update checks
are unverified. No certificate/account or remote telemetry is introduced.
Full-profile restore, measured profile-mode edit/frame/memory budgets, user-task
timing and visual acceptance must still receive executable or human evidence;
this inventory alone does not pass PLAN-01, DATA-06 or OPS-02.

### Initial parity and ownership inventory (milestone 0, partial)

The starting tree has 885 files under `lib/` and 674 under `test/`; these counts
are sizing context, not a migration target. All eleven `AppMode` values remain
in scope. Owners below name current code and the milestone responsible for
replacement; no row is declared migrated by being listed here.

| Capability | Current authority / entry point | Replacement milestone and inherited requirements |
|------------|---------------------------------|-------------------------------------------------|
| Repertoires list/create/rename/delete | `RepertoireListBody`, `RepertoireCreation`, `IOStorageService`; recovery through `FileMutationService` | 1/2: ARCH-01, DATA-02, DATA-04, DATA-05, DATA-06, STATE-01, SET-01, UI-01, UI-02, UI-04, TEST-01 |
| Repertoire builder and chapters | `RepertoireController`, `RepertoireWriter`, `RepertoireFileEditor`, `ChapterStore`, outline controller | S0 and 3: DATA-01, DATA-02, DATA-03, DATA-04, DATA-05, DATA-06, ARCH-01, STATE-01, STATE-02, UI-01, UI-02, UI-03, UI-04, TEST-01 |
| PGN Viewer | PGN viewer screen, `core/pgn/`, document-feature game/session owners | 3: ARCH-01, DATA-02, DATA-03, DATA-04, DATA-05, DATA-06, STATE-02, UI-01, UI-02, UI-03, UI-04, TEST-01 |
| Study | study screen/controller, multi-game PGN documents | 3: same document-workspace requirements as PGN Viewer |
| Repertoire trainer | `services/training/`, `ReviewProgressStore`, `MoveAttemptStore` | 4: ARCH-01, DATA-06, SET-01, STATE-01, UI-01, UI-04, TEST-01 |
| Tactics | `features/tactics/`, tactics session controller, game store | 4: ARCH-01, DATA-06, SET-01, STATE-01, UI-01, UI-04, TEST-01 |
| Player analysis | analysis screen, `PlayerCorpusStore`, game analysis controller | 5: ARCH-01, DATA-02, DATA-05, DATA-07, STATE-01, STATE-02, STATE-03, PROC-01, PROC-02, UI-01, UI-04, OPS-01, TEST-01 |
| Generation/audit/ingestion | generation session, `GenerationArtifactStore`, audit session and shared jobs | 5: same analysis requirements; source/run identity and edited companion PGN still need proof |
| Engine tournament | tournament controller/service/store, engine manager | 6: ARCH-01, DATA-06, STATE-01, PROC-01, PROC-02, OPS-01, OPS-02, TEST-01 |
| Bughouse lab | bughouse controller/engine session, optional bundled assets | 6: ARCH-01, STATE-01, STATE-03, PROC-01, PROC-02, OPS-01, OPS-02, TEST-01 |
| Databases | databases screen, `GameStoreService`, SQLite/eval adapters | 6: ARCH-01, DATA-05, DATA-06, STATE-01, SET-01, TEST-01 |
| Players & prep | opponents feature, `OpponentStore`, people/tournament JSON | 6: ARCH-01, DATA-06, STATE-01, UI-01, UI-04, TEST-01 |
| Accounts/settings | `AppState`, engine/eval/training/display settings, SharedPreferences | 1/2 establishes section owner; 6 completes SET-01, SEC-01, ARCH-01, TEST-01 |
| Navigation/file opening | app shell/`AppState` handoffs, navigation stack, `ViewerSessionController` | 1/2 and 3: UI-02, STATE-01, STATE-02, TEST-01 |
| Imports/exports/offline/recovery | PGN codecs, atomic writer, SQLite recovery, importers; fixtures already exist | Each writing slice: DATA-02, DATA-04, DATA-05, DATA-06, TEST-01 |
| MCP/offline tools | `tools/mcp/`, separate process runtimes and file contracts | 6: ARCH-01, DATA-06, DATA-07, PROC-01, PROC-02, TEST-01; follow their owning skills before editing |
| Installers/updates/native assets | packaging, updater, native asset manifest and release-tag workflows | 6/7: OPS-01, OPS-02, PROC-02, TEST-01 |

Persisted authority: chapter and study PGNs, source-game SQLite collections,
player-corpus manifests, training CSV/progress, opponent/tournament JSON and
saved analysis artifacts are authoritative in their respective domains.
SharedPreferences contains both preferences and legacy credentials; ordinary
settings exports must not absorb the latter. Eval indexes/download caches are
rebuildable only where their owner says so. Existing quarantine, atomic recovery
journals and schema backups have distinct retention purposes. A detailed
key/schema/reference ledger, consistent restore rehearsal and native dependency
license/ABI matrix are still required before milestone 0 graduates.

Reuse inventory: `scripts/ci.sh analyze lint`, focused Flutter tests, atomic
failure fixtures, storage/upgrade contracts, scripted engine fixtures,
`integration_test/app_test.dart` and the private app driver. Missing coverage:
shared revision/store contract, injected first-slice wiring, native identity and
vault failures, restore with new post-migration work, large annotated-document
profiling and user task timings. The runner redirects Documents/config/data to
its disposable profile; automatic checks never use the user's real databases.

Host matrix: Linux local development/runtime is available. Windows/macOS native
packaging, signing, reader accessibility, vault and forced-parent-death checks
are **unverified**, not inferred from Linux. Remote crash reporting, telemetry
and cloud sync remain outside scope. No package or runtime version has changed
in S0. Riverpod 3, catalog ARB and the first-slice Widgetbook are now adopted;
SQLite remains the storage default and Drift remains deferred.

Before starting 1/2, finish the missing inventory and record measured baseline
interaction/frame/edit budgets. Proposed effort cap: 8 active hours (4 feature,
2 tests, 1 packaging rehearsal, 1 validation reserve), midpoint at 4 hours;
Riverpod and Widgetbook spikes each capped at 30 minutes within that budget.
Native revision feasibility gets a separate 1-hour spike; inability to prove
safe identity fails DATA-04 and narrows work to a bounded repair, not a silent
weaker implementation. No later feature slice starts before PLAN-02 records
the first-slice result. Product-owner visual review remains required before
propagating a new appearance across the application.

### Generated artifact authority cutover — `7032e719`

DATA-07, ARCH-01 and TEST-01: all production generated tree/probe/trap/partial
writers and readers now use the injected `GenerationArtifactRepository`.
`StorageGenerationArtifactRepository` captures native source/run identity and a
deep configuration snapshot, stages immutable hashed payloads with a manifest,
and selects them through one revision-checked current-generation pointer.
Generation stages the full bundle before PGN export and selects against the
acknowledged PGN revision; probes and partial resume/discard carry their captured
source/generation identity. Builder, traps and training readers validate that
same authority before adopting results.

Retired production ownership: `lib/core/generation_artifacts.dart`
(`GenerationArtifactStore` and its sidecar writer/path APIs),
`ExpectimaxDatabase.persist`, `TrapExtractor` filesystem methods,
`ExpectimaxProbeStore`, and the unused eval-tree file loader/IO/stub/tab plus its
duplicate tests. The probe replacement is a pure codec, not a persistence
forwarder. Existing sidecar formats remain explicitly decodable by the new
infrastructure repository; they are untouched and never automatically promoted
to authoritative or resumable output. The deleted tab had no production callers;
it is not compatibility evidence.

Validation: **155 focused tests passed**, including disposable native filesystem
publication, generate → reopen → probe update → reopen, pause/live resume/cancel
and reopened partial resume, stale runs, edited artifacts, source/config races,
interruption and uncertain selection, plus relevant chess algorithms, training,
traps and Builder receipt/widget regressions. Analyze/lint passed with 15 infos,
zero warnings/errors. Headless Builder and settings screenshots were inspected.
An earlier inadvertently broad run was stopped after 2,110 passes and five
skips; it is incomplete and is not a passing-suite claim. Two initial invocations
with nonexistent test paths failed before the corrected focused batch passed.

Evidence limits: PGN and artifact-pointer commits are separate. If PGN commit
succeeds and artifact selection fails, the PGN stays saved, the old cache is
rejected for its new source, and the failed job reports the retained proposal
path. Artifact-only interrupted publication retains a valid prior generation
and recoverable proposal. Old generations and edited artifacts are retained;
no recovery browser or garbage-collection policy is added. Native filesystem
evidence is Linux-only; other host/release gates and the broader renewal remain
open. Engine runtime ownership is a separate cutover, not claimed by this commit.


### Completed engine/settings wiring and Viewer retirement checks (2026-09-17)

Engine/settings cutover integrated at `f1109c5b`: final constructors and all
selected production consumers replace old settings/engine singleton access and
temporary bindings. Analyze/lint passed with 45 informational findings; settings
and configuration capture checks passed 91 tests, final fixture/settings checks
passed 31, runtime lifetime checks passed three, and native Stockfish checks
passed two. Native Linux failure, retained draft, Retry, committed preferences
and full-process restart were inspected. Twenty-two resolved boundary-debt
entries were removed. Windows/macOS native verification, credentials and external
evaluation-database settings remain open. A subsequent full-suite audit and its
fixture repairs are recorded with the combined integration evidence below.

Viewer checkpoint `141b5271` deletes `PgnViewerController` and the unused
`PgnPerspectiveButton`, updates every consumer, and introduces no compatibility
facade. The document owner handles collection transactions; reading and library
owners handle their distinct state. Editor, filter, presentation, tree, playback
and Solitaire commands are consumed directly. UI error selection does not mirror
errors into document state; recovery and the leave dialog observe all relevant
owners. One replacement transition invalidates work before cancellation. Empty
filters cancel selected-game work; delayed restores and handoffs cannot move a
newer selected game. Retired paths/types are protected by the retirement gate.

The merged Viewer/engine source passes 375 focused tests and six Linux native
journeys across collection order/navigation, filtering, presentation, edit
contexts and restart recovery. This includes the 49-test owner suite and its navigation-cursor regression. This is ownership retirement, not whole Viewer
certification: the legacy screen/reader widgets, complete design-system gates,
immutable game contents and unverified platform gates remain separate work.

The `7032e719` artifact cutover initially had no production legacy reader.
The recovery follow-up below now supplies Builder Actions inspection/export for
legacy trees, probes, traps and unfinished output through the final repository.
Unproven source association still prevents automatic legacy resume or adoption
as current analysis; read-only recovery is not full legacy workflow parity.

Viewer production diff against integrated `f1109c5b`: 2,539 added and 2,405
removed lines (net +134), separate from tests and documentation. The 1,609-line
facade and 136-line unused perspective widget are deleted. Direct owner wiring,
serialized recent preferences, lifecycle fixes and scaled controls account for
new code. This is not a net-size reduction; the retirement evidence is deletion
of the forwarding owner/API, error mirrors and consumer dependencies. Continued
workflow work must still remove remaining legacy ownership and UI debt.


Combined verification: the full engine/artifact baseline at `f1109c5b` ran
6,421 passing tests, 12 skips and four failures. The failures were two Builder
settings fixtures, one settings contrast fixture, and a cache-only Explorer
fixture that unintentionally gained a scripted engine and lacked explicit cache
isolation. The scripted-engine source of false evaluations and the three provider
fixtures were repaired in the Viewer integration; cache isolation follows below.
The focused fixture suites passed 14 and 10 tests. The cache-only test now injects
an unavailable engine and still asserts that uncached evaluations stay absent.
This is full-baseline evidence plus focused repairs, not a claim of a green full
suite on the final merged Viewer revision. The merged Viewer tests and six native
journeys above passed. Final analyze/lint passed with informational findings only.

Production Linux screenshots were inspected for the
[restored reader](images/renewal-viewer-owner-cutover.png) and
[collection tree](images/renewal-viewer-tree-cutover.png), using only the disposable
profile left by the restart journey. The preview was stopped before the final
checks. Existing leaf tests additionally cover active themes and 200% text scaling;
these screenshots do not prove all UI-01 or non-Linux gates.


### External review follow-up: startup and test isolation (2026-09-17)

The supplied review describes the earlier `f1109c5b` baseline. Viewer facade
retirement is now on local main at `8e5e5dcc`; the legacy theme ledger has 246
entries, not 251. Whole UI renewal is still unfinished. The reported four test
failures remain historical baseline evidence, with focused repairs recorded
above; they must not be relabeled as a successful full-suite run.

Confirmed startup findings are addressed in the existing final owners.
`SettingsSectionController.ensureLoaded` retries when no committed value exists,
including after failed reads. `EngineLifecycle` queues startup with toggles and
generation, retains an unknown preference as off after failure, permits retry,
and prevents a late startup call from overriding a successful explicit toggle.
Navigation resume no longer rewrites preferences. Engine setters now submit
fields directly to the existing canonical normalization; their duplicate
normalization and inconsistent early-return guards are deleted.

The cache-only Explorer and eval-cache suites now install their own fresh
application-support directory before cache initialization, verify the expected
database exists before clearing any rows, reset between tests and delete their
own database at teardown. Our bounded test runner already overrides XDG data
paths; that does not establish the source of another runner's cache rows. No
user database was inspected or modified for this investigation. Retiring the
production eval-cache singleton remains separate unfinished ownership work;
this explicit test fixture does not certify that architectural replacement.

Validation on the combined `8e5e5dcc` source plus these corrections: the full
`scripts/ci.sh test` process exited 0 with **6,461 passing tests, 12 skips and zero
failures**. The 62 focused settings/lifecycle/runtime/cache cases also pass.
`scripts/ci.sh analyze lint` passes with 63 informational findings and no warnings
or errors; all 94 local file links across this plan and the component map resolve.
This full run includes the repaired provider fixtures and explicitly isolated
Explorer cache fixture. The 12 skips are still skips; this does not establish
unrun native/platform or whole-renewal acceptance gates. Production changes remove
87 net lines from existing settings/lifecycle owners and add no transitional
owner, facade or compatibility layer.

### Legacy artifact recovery access (follow-up to `7032e719`)

The artifact-authority cutover preserved sidecar files but left `readLegacy`
without a production caller. This follow-up restores discoverable reading and
export through Builder → Actions → Recover older analysis. One feature recovery
controller and dialog consume the final artifact repository; no legacy owner,
mutable sidecar writer, loader shim or forwarding facade returns. The retirement
gate also forbids `GenerationArtifactStore` and `ExpectimaxProbeStore` symbols.

The old capabilities were main-tree exploration/training metrics, probe/PV
lookup, trap browsing and automatic partial resume/discard. Recovery now exposes
tree/probe branches, saved evaluations/FENs/configuration, trap details and
unfinished positions. Invalid files/entries fail independently. Native reads
retain exact original bytes; explicit export uses exclusive native installation
and preserves existing destinations. Export errors/uncertain acknowledgement are
visible, technical detail is optional, and active exports keep the view open.
Originals and selected current generations remain untouched; no export silently
promotes old results to the current source.

Legacy association cannot be proved from filenames, root FEN or configuration.
Automatic legacy resume and insertion into current training/probe/trap data are
therefore explicitly unsupported. Users can inspect/export old work or start a
fresh build; only verified current-generation partials use the existing resume
path. Export is the original artifact, not a PGN conversion that would lose
analysis fields. This completes the production read-only recovery responsibility;
it does not claim full legacy automatic-resume parity, cross-file atomicity, a
browser for all retained generation proposals, or non-Linux certification.

Validation: **58 focused tests passed**, spanning the native artifact repository,
full generation publication/reopen pipeline, legacy recovery, race/lifetime
controller cases, production Actions/dialog wiring and the complete Builder
screen/toolbar fixtures. The final typed picker/read-failure correction passed
all seven affected controller/widget tests. Native cases cover BOM/gzip/malformed
byte preservation, external edits after capture, per-file/per-probe failures,
exclusive destination collisions, interrupted staging and uncertain directory
flush without replay or current-generation changes. Recovery widget journeys
also pass at 640×480 and 800×600 with 200% text; failures have localized primary
copy and optional diagnostics, and uncertain destinations are directly selectable.

The headless Linux production app was inspected using only a disposable profile:
[unfinished-build recovery](images/renewal-legacy-analysis-recovery.png),
[isolated malformed-file failure](images/renewal-legacy-analysis-error.png), and
saved probes reopened after a runtime restart. The preview was stopped before
final checks. These checks do not certify Windows/macOS, native file-picker UI on
other hosts, or large-artifact performance.

Initial validation failures were corrected: localization import/nullability
errors, one widget fixture timeout from asynchronous temporary-directory creation
under the fake clock (its own runner was stopped; the second case was cancelled),
and scaled-test scroll targeting. Compact recovery now has one scroll owner.
Those interrupted/failed runs are not passing-suite evidence. The earlier full
application suite at `0ee44d03` remains separate evidence; this follow-up uses
focused regression checks rather than claiming a new full-suite run.

Final `scripts/ci.sh analyze lint` passed with 63 existing informational findings,
zero warnings/errors, no new boundary debt and the retirement gate passing. All
96 local documentation links resolve; whitespace checks pass.


### Generation artifact domain closure (2026-09-17)

The final artifact service previously imported `services/generation/expectimax_probe.dart`
for a codec, which also imported build-run/subtree and operational configuration
owners. `tree_serialization.dart` combined the wire format with Flutter timing
output, worker scheduling and an unused transposition-map population hook.

The final pure `chess_core/generation/` owner now contains the canonical generated
tree/trap values and synchronous tree/probe codecs. All production and test/tool
consumers import those canonical paths. `GenerationArtifacts` captures the
mutable tree synchronously and owns off-isolate encoding; the domain codec no
longer schedules workers, logs Flutter diagnostics or mutates a caller's FenMap.
The shared exact four-field persistent FEN reducer lives in `chess_core/position/`.
Old `models/{build_tree_node,trap_line_info,trap_reply}.dart`,
`services/generation/tree_serialization.dart`, `services/eval/eval_canonicalize.dart`
and `serializeTreeInIsolate` are retired with no forwarding exports. The probe
codec is removed from the graft/rescore library, so reading saved artifacts no
longer imports the generation engine dependency closure.

The checker follows owners in every enforced/complete feature `services/` folder through project
imports, exports, conditional branches and parts, rejecting any legacy service
owner. The pure artifact closure also rejects native, Flutter and isolate
imports. New regression cases cover indirect dependencies, moved owner paths,
retired forwarders and separate scheduling; the exact debt ledger is unchanged.

Compatibility preserves existing v3/v4 tree defaults, parent/index identity,
probe framing and tolerant legacy entries, trap/reply defaults, persistent FEN
keys, and opaque historical configuration. Operational `TreeBuildConfig`,
probe graft/rescore, trap extraction and build/engine orchestration remain
unfinished responsibilities outside this codec cutover. This does not certify
the complete Generation feature or add legacy resume/proposal-browser parity.

Validation: `scripts/ci.sh analyze lint` passes with 63 pre-existing analyzer
infos and no errors/warnings; 43 checker regressions pass with the exact 1,459
entry debt ledger unchanged. The focused 20-file generation/algorithm/native
artifact/recovery/FEN batch passes 134 tests (zero failures or skips). A plain
Dart VM contract runner passes historical tree/probe/trap fixtures and 64 seeded
evaluation/probability/PV round trips, independently proving the codec no longer
requires Flutter to compile. The application-service regression confirms a tree
edit after asynchronous encoding starts cannot change the captured output.
The initial analyzer run found one unused legacy import and two new CLI-test
infos; those were corrected before the passing rerun. No UI behavior changed,
so this cutover reuses the preceding inspected recovery screenshots rather than
claiming a new platform/UI validation. No full-suite or non-Linux gate is claimed.


### Retained generation recovery completion (2026-09-17)

The existing recovery flow now covers retained PGN/model-game proposals,
artifact versions/unfinished outputs, manifests/receipts and legacy sidecars,
including user-edited `_model_games.pgn` companions.
`GenerationRecoveryController`/`GenerationRecoveryDialog` replace the two
legacy-only owners; their old files, types, `readLegacy`, `inspectLegacy`,
`exportLegacy` and app entrypoint are retired without forwarding bridges.
The existing artifact repository adds source discovery, catalog/read and captured
export; `GenerationArtifacts` keeps pure-codec scheduling. No second browser,
writer, dependency container or generic repository framework was introduced.

Empty/error/loaded Builder Actions all reach **Recover generated outputs…**.
A source chooser scans repository-owned namespaces under the configured library
root, including deleted chapters, without following links or entering hidden
trash/staging. Whole deleted repertoires first require the library's existing
folder restore. Selecting a run lazily observes fixed known filenames only;
manifest paths never authorize a read. Directory replacement is rejected,
missing/malformed/edited siblings remain individually inspectable, and captured
immutable bytes remain exportable even when decoding fails or originals change.

The view displays recorded source/config/run, source-revision comparison,
checksum differences and selection/publication evidence. No receipt does not
mean unpublished; an old artifact directory does not mean never selected.
Recovery does not adopt analysis or resume retained output, including apparently
matching source records. Export uses the existing native exclusive-install
transaction and displays a potentially installed destination after uncertain
acknowledgement. The source PGN, selection pointer and original retained bytes
are never changed by inspection/export. Owner epoch checks reject late reads;
closing while the destination picker is pending cannot export, and repeated
clicks cannot start duplicate exports.

Native fixtures exercise source-conflict PGN/model staging, committed PGN with
missing publication receipt, selected versus unselected/edited artifact records,
interrupted manifest-first staging, malformed manifest fixed-path reads,
namespace failure/retry, symlink/replaced-directory refusal, orphan discovery,
legacy BOM/gzip/malformed-byte recovery, collision and uncertain export. The
production widget journeys cover Actions entrypoints, orphan source selection,
enumeration failure→Refresh, PGN inspection/export and legacy tree/trap parity,
including 640×480 and 200% text. Controller tests retain delayed selection,
disposal, duplicate-export and picker-error coverage.

Headless Linux application evidence uses only the disposable driver profile:
[source chooser after restart](images/renewal-generation-recovery-sources.png),
[retained PGN/provenance](images/renewal-generation-recovery-pgn.png),
[isolated missing model-game failure](images/renewal-generation-recovery-missing.png),
and [native export result](images/renewal-generation-recovery-export.png).
The real native folder picker selected the disposable Documents directory; the
exported `.pgn` bytes matched the captured original exactly. The app runtime
restart rediscovered the deleted chapter namespace; the preview was stopped.
No real user library was used.

Development corrections: the first new storage fixture omitted the existing
`expectedContent` named argument; fixed before native coverage passed. Widget
fixtures initially awaited settling during native asynchronous reads or targeted
unscrolled controls; they now wait for owner completion and exercise visible
scroll controls. A new enumeration-category regression caught a read/enumerate
assignment swapped during editing; corrected and covered through repository and
visible retry journeys. These failed intermediate runs are not passing evidence.

Remaining limits: no automatic legacy/retained-output adoption or resume, no
retention/garbage collection or cross-file atomicity, no macOS/Windows validation,
and no large-history performance certification. Whole Generation remains
unfinished. This closes inspection/export accessibility for retained outputs in
the repertoire library; external chapter namespaces remain reachable when that
chapter is opened, and whole deleted repertoire containers use library restore.

Final local checks on the merged `29fbb4b0` baseline: analyze/lint pass with 63
existing infos, zero warnings/errors; 44 architecture regression cases pass and
1,459 exact debt entries are unchanged. The nine-file production/native/recovery
batch passes 68 tests with zero failures/skips. After adding the historical
model-games companion, its seven-test native legacy recovery file passes,
including exact edited/BOM PGN export. All 107 local links in the affected plan,
evidence, component map and generation README resolve; `git diff --check` passes.
No full-suite, release, engine-performance or non-Linux gate is claimed.


Independent review found that an unreadable descendant directory aborted source
recovery for every healthy sibling. The same repository now returns verified
source entries plus typed per-directory discovery failures; its existing
controller/dialog show those failures and retry through Refresh. Observations
from a failing or changed subtree are discarded, while a root failure or root
identity change rejects the complete listing. No extra owner, interface or
browser was introduced. Native Linux permission-denied fixtures verify healthy
orphan inspection, retry after permissions recover, and fatal root failure; a
production dialog test verifies the visible failure, healthy selection and
Refresh clearing the failure. This corrective batch passes 24 focused tests.

The fresh headless [partial discovery view](images/renewal-generation-recovery-partial-list.png)
shows the inaccessible folder alongside healthy deleted-chapter sources. Restoring
permissions and using Refresh removed the error and revealed the formerly
inaccessible source in the same dialog. The preview used the disposable driver
profile and was stopped before final checks. Analyze/lint pass with 63 existing
infos, no warnings/errors; 44 architecture checks pass with unchanged debt.

### Builder workspace retirement and independent review — 2026-09-18

The Builder branch at `a7352bb2` deletes the 284-line `RepertoireController`
facade and moves its production callers to the existing document, board and
writer owners or the app-owned workspace. `BuilderLifetime` owns durable draft
recovery before the route mounts. Widget autosave timers are removed; document
saves admit one active write and the latest pending content per line, preserving
ordering barriers around document commands. A recovered source needs native
revision, whole-source text and line identity evidence before autosave can
reattach. Missing/replaced sources remain editable detached drafts.

Independent review reproduced and repaired three races before integration:
source autosave could remove a draft still required by an unresolved copy;
selecting a retained outline row bypassed the native reattachment check; and a
late chapter load could replace a recovered scratch draft. Repairs reuse the
existing draft invariant, shared attachment validation and intent invalidation.
Copy/open/initial-folder selection now use the injected catalog's chapter
listing; direct `StorageFactory` access is removed from the Builder screen and
parts. A listing failure retains the draft, and retry performs the actual append.

Branch evidence: 327 broad focused tests before the final scratch-intent fix,
63 final recovery/load tests, three Linux native restart cases, and 44 final
catalog/localization/screen tests pass. Analyze/lint pass with 64 informational
messages and no warnings/errors. The parent reviewed the repairs and combined
the app-owned close/recovery hosts with the Study and Viewer hosts. The
[restored Builder](images/renewal-builder-restored.png) and
[restart recovery](images/renewal-builder-restart-recovery.png) use disposable
profiles; native replacement-to-outline-to-edit coverage verifies detachment.

This completes the named facade retirement and recovery responsibility, not the
whole Builder feature or its maintainability gate. Against `29fbb4b0`, the branch
adds 1,828 and deletes 852 handwritten production Dart lines: **net +976**, with
144 generated localization lines counted separately. Remaining legacy chapter
creation, UI coordination and theme work are not certified by these checks.

### Study import/publication review repair — 2026-09-18

Independent review of `3f3521bb` found that the app-owned collection importer
had retained native publication outcomes, but completed Lichess downloads still
used a duplicate editor create path without recovery. Scoped Lichess cancellation
also abandoned its caller while the old retry timer continued. The repair at
`92b799ee` gives completed Lichess downloads, collection downloads and Builder
study exports one admitted publication command and removes
`StudyController.createStudyFromPgn` with both consumers. The existing
`DocumentSaveSession` retains uncertain bytes/path; the editor remains the owner
of append and explicit document adoption. No new owner/interface files were added.

Rejected URL submissions remain in their existing dialog. Retry reuses the
resolved payload with the current append/delay options. Failed append keeps its
dirty chapters in the same editor instead of inviting a duplicate append;
unexpected unconsumed failures keep the downloaded payload. Superseded adoption
reports the actual publication result, never the unrelated current study title.
The URL dialog receives its repository directly from composition. Its transport
uses the injected HTTP client and cancels Lichess backoff/retry timers on close.

Validation: 234 focused Study/import/storage/UI and shared Explorer tests pass;
two Linux native tests pass (exclusive collection publication and Study native
conflict/reload/copy). Analyze/lint pass with 63 pre-existing informational
messages and no errors/warnings; all 43 architecture checks pass and exact
boundary debt falls from 1459 to 1457 for the complete Study branch. New coverage
includes uncertainty review, failed append retention, stale adoption, admission
retry without refetch, changed append selection, exact headerless PGN bytes,
Lichess cancellation during a 429 backoff, and 480×640 at 200% text. A real
headless app was inspected at 1280×720 and stopped after capturing the
[URL import dialog](images/renewal-study-url-import.png). No live website request
or user data was required. These checks do not certify Windows/macOS native
publication or the whole Study theme.

Maintainability remains **Partial**. Compared with main `29fbb4b0`, the complete
branch adds 941 handwritten production Dart lines, including localization
helpers and excluding generated accessors/ARB; Study screen grows
926→1049, URL dialog 434→479 and Builder screen 1315→1345. The review repair alone
adds 155 handwritten production Dart lines over `3f3521bb`. Retirement and ownership improved:
one publication authority replaces the duplicate create path and all old
`services/study_import/` files are gone. This is a safety/capability closure,
not evidence of an overall code-size or consumer-complexity reduction. The
planned consumer simplification and full Study design-system cutover remain open.

### Combined safety/recovery integration verification — 2026-09-18

The parent reviewed the repair diffs and reconciled Builder/Study application
lifetimes, the Builder publication consumer, localization and retirement guards
with retained Generation recovery. At code snapshot `4b6c5f1a`, the full local
suite passes **6,557 tests, 12 skips, zero failures**. After the final Study
feedback formatting correction at `7c3c85e2`, the real Linux app passes all seven
startup/navigation tests and the native cross-mode document-close test. The
headless runner uses disposable data. No Windows/macOS or release gate is claimed.
Final analyze/lint passes with 64 informational messages, zero errors/warnings,
44 architecture regression checks and 1,457 remaining exact debt entries.

The native command initially expired waiting for the busy checkout; its process
exited before one retry after the full suite completed. Environment diagnosis
also exposed a false driver-wiring failure: `grep -q` closed a pipe early under
`pipefail` although the committed installer existed. Draining the producer's
output fixes that check, and `doctor --quiet` passes. This tooling repair is not
credited toward either production-code reduction trial.

Plan/component links to the removed Builder facade were corrected. The three
updated documentation files contain 165 resolving local links/anchors. These
combined checks supplement the branch-specific native/failure evidence above;
they do not turn safety additions into a maintainability pass. Provider and
Viewer trials are assessed separately against their own complete scopes.


### Provider composition retirement (2026-09-18)

One app-owned `RepertoireCatalogController` replaces the two Riverpod family
owners. Two private read snapshots preserve library/trainer data and failures;
mutations reject overlap across both kinds and invalidate their older reads.
The owner survives route/listener loss; route re-entry explicitly refreshes.
Settings retain their existing repository as the only writer. Appearance's
Provider stream subscribes before `ensureLoaded`, seeds current state, and
cancels its subscription when the injected repository lifetime changes. The
borrowed repository is not disposed. Theme rendering selects committed values;
failed drafts stay visible in Appearance without changing the committed theme.

All seven production Riverpod imports, its dependency and three transitive
packages are removed. The three old settings-provider/stored-game/display-scope
files are deleted. Stored-game readers and tactics use the existing Provider
repository; board, SAN and reserve presenters observe the existing display
owner directly, retaining immutable defaults in bare previews. The checker
rejects retired scope/provider symbols and Riverpod imports/exports.

Action trace before: create form → Riverpod family lookup → notifier build/ref
repository lookup → repository write → keepAlive → per-family refresh → watched
provider state. After: create form → constructor-injected app catalog command →
repository write → refresh requested read snapshots → Provider notification.
The catalog command now blocks competing writes from the other view as well.
Appearance no longer wraps the typed SettingsState in a second public AsyncValue;
boards no longer subscribe to a duplicate scope over the same mutable owner.

Independent review caught two initial-read timing gaps: entering the trainer
while a library mutation was pending, and a trainer read invalidated by a later
failed library mutation. Controlled tests preserve the requested read in both
orders while proving a failed mutation is not retried. Repository override tests
also prove stale catalog results are rejected, synchronous appearance emissions
are observed, and replaced subscriptions are canceled. These corrections belong
to the same replacement, not a later cleanup task.

Measured against `a6238ff5`, the complete 15-file handwritten production scope
falls from 4,926 to 4,881 physical lines (254 added, 299 deleted, net −45).
All handwritten `lib/` Dart falls from 234,719 to 234,674; generated production
files are unchanged. Excluding comments and blank lines, the same scope falls
from 4,037 to 4,019 (−18), so the reduction is not comment deletion or line
compression. Function-typed callback declarations remain 9; no new supplier
callbacks were added. Catalog mutation ownership falls from two to one, and
lookup mechanisms fall from Provider/Riverpod/two generic scopes to Provider.
The measure includes full affected consumers, not only the three deleted files.

Validation: the initial 75-test catalog/settings/board/localization batch and
37-test Provider/Viewer/bughouse batch pass. The subsequent 20-test catalog and
Provider batch includes the independent review regression and passes. Linux
native catalog journeys pass 2 tests and native Viewer journeys pass 12 tests;
these preceded the final failed-mutation read-resumption correction, which is
covered by the subsequent controlled tests. Analyze/lint passes with the 63
pre-existing infos and no warnings/errors; 45 architecture checker cases pass
with the unchanged 1,459-entry debt ledger. Whole-application and non-Linux
certification are not claimed for this bounded composition replacement.

Fresh headless Linux evidence shows the same filtered catalog in
[Dark](images/renewal-provider-catalog-dark.png), the persisted
[Appearance selection](images/renewal-provider-appearance.png), and the retained
[Light catalog](images/renewal-provider-catalog-light.png). The search text and
results survive the appearance change and settings navigation. All three images
were inspected; only disposable driver data was used, and the preview was stopped.
The independent reviewer accepted the corrected lifecycle and smaller ownership
graph before integration; final merge checks must retain Builder's shared catalog
repository binding and its `listChapters` contract.

Integration at `c42fb5d0` preserves the reviewed Builder and Study changes from
`fa7f309e`. Against that immediate main baseline the complete production delta is
254 added / 302 deleted (net −48 handwritten Dart lines, generated unchanged);
the additional three removed lines were Builder's now-duplicated repository
binding, included in this measurement rather than counted as another cleanup.
The combined 56-test catalog/composition/Appearance/Builder/Viewer-loading batch
passes. Analyze/lint passes with 64 infos, no warnings/errors, 45 architecture
checker cases and the 1,457-entry debt ledger. This establishes the bounded
composition trial's reduction, simpler ownership and behavioral parity. The
separate Viewer trial must also pass before renewal expands to another workflow.

### Viewer leave/navigation simplification trial — 2026-09-18

Implementation `cb08f1fb` combines the duplicate screen/native leave prompts in
existing `document_save_dialog.dart`. The concrete choice contains the revision
captured at the button click. The screen validates that revision and its current
navigation before discarding; native close records approval without discarding,
because another participant may still cancel. Both subscribe to the existing
save-action state stream, eliminating the separate workspace-listener argument.
Clean checks include annotations flushed while capturing a revision and after
awaited autosave, so pending prose cannot silently escape close protection.

`ViewerOpeningTree` directly reads its existing collection owner and autoplay
steps its existing reader handle. Five suppliers that projected those same
owners disappear; genuine live opening-tree cursor callbacks remain. There are
no new production owners, interfaces, files, forwarding facades or compatibility
constructors. Component documentation describes the final dependencies.

The complete measured scope includes the Viewer screen and both parts, reading,
opening-tree and playback owners, save-state predicate, both dialog helpers,
native guard and app lifetime: **4,565 → 4,532 lines**, **113 added / 146 deleted,
net -33** against `af228c85`. This passes the bounded net-deletion check; it does
not certify the whole Viewer consumer architecture. Wider screen orchestration,
legacy surfaces and remaining architecture debt stay open.

After merging main `fa7f309e`, 53 focused tests pass, including actual reader
comments typed during a blocked autosave, an edit after the approval click,
click-time annotation flushing, native clean-state annotation flushing and a
later close participant cancelling without losing the approved PGN draft.
Analyze/lint pass with 66 informational findings and no errors or warnings.
Both Linux native journeys pass: cross-mode application close and Viewer
navigation, save baselines, copy and reopen. Independent review found the
post-autosave pending-comment gap; its repair and controlled widget regression
are included. The first new widget run reached the safety assertions but its
cleanup used `pumpAndSettle` against a blinking text caret; bounded transition
pumping fixed that test-only timeout, and the complete focused run passes.
The real headless app's [shared leave dialog](images/renewal-viewer-leave-approval.png)
was inspected at 1280×720 after editing a selected move with autosave disabled.
Save, Save a copy, Cancel and Close without saving remain visible; Cancel
returns to the retained annotation. The disposable preview was stopped.

Combined Provider/Viewer revision `e1286ced` passes **6,569 tests, 12 skipped,
zero failures**, analyze/lint (64 infos, no warnings/errors, 45 checker cases),
and both Linux native close and Viewer edit-context journeys. Independent
review approved the merge. An explicit mounted check and braces remove the two
new analyzer infos; the final Viewer delta against `4ebb3a36` is therefore
114 added / 146 deleted, **net −32**, with the complete scope at 4,533 lines.
Together the trials remove **80 handwritten production lines** against
`fa7f309e`, with no generated-code change. They pass the binding reduction,
clarity and parity gates and authorize the reviewed Builder wrapper deletion.
Neither result certifies the whole Viewer or the whole renewal. Total `lib/`
Dart is still 239,402 lines versus 218,957 at `e477dc58`; added recovery work
and generated localization remain separately accounted for. The actual shared
leave-dialog screenshot was also inspected during integration.

### Orphaned Builder layout retirement — 2026-09-18

Revision `2ead1e6c` deletes the unreferenced Edit Context zone, layout sheet,
tab descriptors, layout model, view enum and preference adapter: **0 added /
1,124 deleted production lines**, generated unchanged, against `e8355200`.
Its only constructions were in its two owned tests, which retire separately
(228 test lines). Current Builder compact/wide layouts already compose their
own editor, outline and reference panes. The Viewer-used split handle and its
real consumer remain byte-identical; no owner, preference data or runtime
behavior is migrated. Six retired paths/eight symbols are guarded and two
obsolete theme-ledger entries are removed. Independent implementation review,
50 existing Builder/Viewer tests, analyze/lint (64 infos, no warnings/errors)
and 45 architecture-checker cases pass. This is dead-code retirement; live
command-flow simplification is separately measured by the direct-editor cutover.

### Builder editor wrapper retirement — 2026-09-18

Builder's only `PgnWithAnalysisPane` caller disabled both its toolbar and embedded
analysis dock. The screen now constructs the existing `InteractivePgnEditor`
directly; `PgnWithAnalysisPane` (333 lines), `EditMainZone` (76) and the unreachable
`RepertoireAnalysisDock` (342) are deleted. Retirement rules reject their paths
and symbols, and the two deleted theme-ledger consumers are removed.

The final graph is screen → editor → existing board/workspace commands, replacing
screen → pane → zone → editor callback forwarding. Title changes still go to
`workspace.setTitle`; branch deletion goes through `workspace.deleteDraftBranch`
so writer undo evidence survives. Clipboard still uses the existing quiet helper,
and View in Lines and annotated read-only titles retain their original bindings.
The actual Engine reference tab and repertoire toolbar remain the live owners of
engine controls, import and reload. `_cursorScoped` placement and editor keying
are unchanged; no new owners, wrappers, state mirrors or interfaces are added.

Against `e8355200`, all eight complete changed handwritten production files shrink
from 3,458 to 2,695 lines (763 net removed). The three deleted files contribute
751 lines; the direct editor call saves 11; the remaining line removes a stale
comment for the separately approved dead context host. Excluding that coordinated
comment, this cutover independently removes 762 lines. All handwritten `lib/` Dart
(excluding `generated/`, `.g.dart` and `.freezed.dart`) shrinks from 236,555 to
235,792 lines; generated production delta is zero. There are 21 fewer callback
fields in the deleted wrapper files; existing workflow state owners are unchanged.

Validation of implementation `1c0514f2`: 74 focused screen/editor/board/line-save/
recovery tests pass, including actual context-menu `Clipboard.setData` payload,
workspace title changes and unchanged editor identity. Both Linux native journeys
pass: immutable annotations survive mode switches and reload, and receipt-backed
undo rejects an equal-text replacement. The four tests that previously inspected
the wrapper now obtain the existing `BuilderLifetime` through Provider; no test
accessor was added to production. Analyze/lint pass with no warnings/errors, 45
architecture checker cases and the unchanged 1,457-entry feature debt ledger.

An initial clipboard assertion waited indefinitely for a test-only clipboard
read response; interrupted attempts are not counted as passes. The final test
observes the actual outgoing platform clipboard payload and asserts the helper's
existing silent-success policy. No production behavior changed to satisfy it.

Fresh headless [wide 1600×1000](images/renewal-builder-editor-wide.png) and
[compact 900×900](images/renewal-builder-editor-compact.png) screenshots show the
same selected chapter/title, annotations and variation after resizing. Both were
visually inspected: the editor retains bounded height and the live Engine tab
remains separate. Only disposable driver data was used; the preview was stopped.
Independent review accepted the exact production commit and its simpler binding
graph. Whole Builder renewal remains Partial.

Combined integration `fe76fc0c` preserves both independently reviewed deletions
and the full union of nine retired paths. Against `e8355200`, Builder removes
1,887 production lines (21 added / 1,908 deleted); including the two earlier
trials, the delta against `fa7f309e` is **−1,967 handwritten production lines**
(389 added / 2,356 deleted), generated unchanged. The merged tree passes
analyze/lint (64 infos, no warnings/errors), 37 focused Builder/Viewer tests and
both Linux native annotation/reload and receipt-backed undo journeys. The first
focused command named a nonexistent Viewer test file: its 23 actual tests passed
but the command failed to load that path. The corrected 14-test Viewer leaf run
passes; the invocation error is not counted as a successful run. Both screenshots
were inspected again during integration, and 126 local documentation link targets
exist. The earlier 6,569-test full-suite result belongs to `e1286ced`; these focused
and native checks cover the subsequent Builder deletions. Whole renewal remains
Partial and total application size remains above the September 16 baseline.

### Chapter picker safety repair — 2026-09-18

Against `8c0537d3`, native file-backed widget regressions reproduced a competing
PGN being replaced between the picker's existence check and write, plus successful
rename/delete operations being reported as failures when the disposed picker tried
to refresh. Creation now requests the existing exclusive-write primitive and
captures its folder before awaiting; a closed picker starts no new creation and
does not refresh. This is a two-line net production safety repair, with no new
owner or abstraction, not catalog migration completion. All three regressions fail
on the baseline and pass with the repair; the combined five-test batch also retains
light/dark narrow-pane readability. The initial regression fixture's fake-zone wait
stalled and was corrected before the completed red/green runs; that interrupted
attempt is not a pass. Independent review verified the failure and repair evidence.
Analyze/lint passes with 64 infos, no warnings/errors and 45 checker cases. Shared
chapter mutation ownership, the temporary catalog adapter and Library organizer
remain explicit work in the active plan.

### Viewer movement consolidation — 2026-09-18

Implementation `0f23a5a4` removes the sole-consumer `PgnPaneRouter`; keyboard,
board and fullscreen commands use the existing reading owner with an explicit
reader where required. No new owner, callback supplier or stored selection was
introduced. Across the reading owner, router, screen and pane part, the complete
production scope falls from 3,620 to 3,576 lines: **−44** (67 added / 111 deleted)
against `8c0537d3`. The retirement gate rejects the old file and class.

The initial native regression exposed an inherited defect: fullscreen unmounted
the reader, so its navigation handle silently did nothing. The existing Scaffold
now stays mounted with hidden focus and tickers excluded. Fullscreen commands
use the primary reader; when covering a reference pane, the board reads the
already-owned primary position. Ordinary Game/tree/Solitaire board and move-trail
projections remain unchanged. Reference fullscreen coverage uses the existing
presentation command; normal Book/Line fullscreen availability is unchanged.

Independent review accepted the exact commit. The initial 108-test batch passed
before the lifetime repair; the final 12 affected owner/screen tests pass and
check autoplay interruption, primary/reference isolation, actual fullscreen
board FEN and restored Book cursor. Exact-commit Linux native coverage passes
one journey: F11, arrow buttons and keys move the game, Escape retains its
cursor, and saved content survives reopening. Analyze/lint passes with 64 infos,
no warnings/errors, 45 checker cases and unchanged 1,457-entry debt ledger.
Initial fixture setup/compilation failures and the pre-repair native failure are
not counted as successful runs. Whole Viewer renewal remains Partial.

The merged tree with chapter safety `69ad9189` passes analyze/lint and ten
combined Viewer/real-file chapter widget tests. The first command incorrectly
combined focused test paths with the analyze/lint step list and was rejected
before running; corrected separate gate and test invocations pass. All 116
local documentation file targets checked exist. Against the pre-trial baseline
`fa7f309e`, this integrated batch removes 2,009 handwritten production lines,
including the separately identified two-line chapter safety addition; generated
code is unchanged. Overall app size is still above the September 16 baseline.


### Training completion ownership — 2026-09-18

Implementation `e4468ea6`, based on `8c0537d3`, replaces the following workflow.
The baseline allowed the result widget to schedule auto-rating/auto-next while
linear persistence ran separately. Delayed or failed persistence could lose the
completion tally/error after Next invalidated its generation; automatic spaced
rating required a mounted widget. The initial controlled run reproduced three
failures (12 passes). The existing session now owns finish, captured persistence,
tally and advance; the result panel only renders available commands. The existing
progress store serializes captured outcomes, uses required attempt identity for
explicit retry, and releases abandoned retry snapshots without cancelling
admitted writes. Source reload waits for those writes to settle, not necessarily
succeed. No new controller, writer, interface or compatibility facade was added.

The screen's 17-field forwarding constructor, widget scheduling flags/callbacks,
public rating-button wrapper and duplicate all-caught-up panel are removed.
Interval formatting moves from the persistence service into the existing time
format utility. Complete six-file handwritten production scope versus `8c0537d3`
shrinks from 3857 to 3711 lines (146 net removed); generated Dart
and localization deltas are zero. Whole Training remains Partial: theme,
localization, crash-resume and other-platform gates are outside this cutover.

207 focused tests pass, plus the refined 20-test ownership suite, including
cancellation followed by a failed save and a successful distinct completion.
Coverage includes delayed/failed linear persistence, repeated completion/Next,
automatic rating without widgets, partial-write Retry, distinct same-line
attempts, queued source snapshots, same-source reload, frozen settings and the
existing error/Retry UI. An intermediate run had three fixture failures (a newly
asynchronous loader assumption and two unflushed widget-test timers), all repaired.
Analyze/lint pass with no warnings/errors and all 45 architecture-checker cases.
The Linux native journey passes: actual input callbacks complete two puzzles,
Next waits for completion, repeated completion does not duplicate the result,
and two distinct history rows/pass counts survive a source reload. Initial
native fixture runs incorrectly skipped the browser action, used an ambiguous
Learn finder, or failed to deliver the second input; these were corrected without
production hooks and are not passes. Final review accepted the exact commit.

A separate disposable headless app journey completed both puzzles and the final
summary through visible controls. The [second completion](images/renewal-training-completion-second.png)
and [summary](images/renewal-training-completion-summary.png) screenshots were
inspected by implementer and coordinator; the preview was stopped. Final
analyze/lint retains 64 infos, zero warnings/errors and 1,457 exact feature-debt
entries. Whole renewal remains Partial.

Combined integration with Viewer/chapter safety `4de86060` passes **217**
focused Training, scheduling, Viewer and real-file chapter widget tests, plus
analyze/lint. The sole merge conflict was the retirement manifest; the union
retains Viewer and both Training retired symbols. All 118 checked local
documentation file targets exist. Against `fa7f309e`, the completed batch has
725 production lines added and 2,880 deleted: **−2,155**, generated unchanged.
The entire current `lib/` still contains **237,327 Dart lines in 1,052 files**,
versus 218,957 lines at the September 16 baseline (`e477dc58`): +18,370 (8.4%).
These bounded deletions do not erase the earlier safety/recovery growth or
establish that all screens/features are simpler.

### Obsolete analysis workflow retirement — 2026-09-18

Against `cfdf999b`, the complete obsolete analysis/browse/expectimax workflow
removes **20 production files** and **5,077 net handwritten lines** (6 added /
5,083 deleted). The new lines only update existing comments and replace the live
inline engine's re-export import with its existing `DiscoveryResult` model path.
No new implementation, owner, callback supplier or compatibility layer was added.

An independent reviewer rebuilt the import/export/part graph, including
conditional URIs, from `lib/main.dart` and all 23 tracked external non-test Dart
entry roots (tools and Widgetbook included). None reached these panels. Whole-repo
caller checks confirmed the old candidate/suggestion pipeline and analysis
service had no live callers. The latter only survived as a model re-export for
`InlineEngineBar`, which already owns a `BoardEngineSession` directly. The live
Builder Engine and Database panes, Viewer analysis tab, BoardEngine/session,
coverage calculation and trick-probe `ExpectimaxLineService` are retained.

Six test files belonging solely to removed components are deleted (1,724 test lines).
The useful per-move undo regression now invokes the existing `addMovesAtPosition`
primitive and retains its original assertions. **152 focused tests pass** across
writer/undo, coverage, engine/session/protocol/settings/lifecycle, expectimax
continuations, ease calculations and the actual Builder/inline-engine widgets.
One Linux native Builder history journey passes, including equal-text replacement
rejection. Analyze/lint passes with 64 infos, zero warnings/errors and 45 boundary
checker cases; 48 checked local documentation file targets exist.

The feature ledger removes only the deleted paths' 41 debt entries (1,457 →
1,416), and the legacy theme ledger removes 11 consumers (241 → 230). The unused
`browse` directory is deleted, leaving 22 classified feature directories: six
enforced, 16 unfinished, none complete. Component/backlog descriptions now name
the actual live database/engine surfaces rather than the removed panels.

Including earlier completed simplifications, the batch against `fa7f309e` removes
**7,232 production lines**. All library Dart now totals **232,250 lines**, still
13,293 above September 16's 218,957 (6.1%). This is a verified retirement result;
the rest of the architecture renewal remains Partial.


### Obsolete eval-tree display retirement — 2026-09-18

Reviewed commit `5bcea12e` against `844aa08a` deletes the entire unused
`features/eval_tree/` presentation and derived snapshot/metrics implementation.
The complete 14-file production scope falls from 3,921 to 558 lines:
**−3,363 handwritten lines** (7 added / 3,370 deleted), with generated code
unchanged. The existing generation bundle no longer eagerly computes two
unconsumed display representations. Its live tree, FEN index, traps, configuration,
probes and position-selection behavior remain intact. Nine theme tokens used
only by the deleted presentation are removed. No replacement owner is added.

Independent review traced the actual bundle, generation, database and
serialization consumers. Four tests owned solely by removed components are
retired (402 lines); the serialization test/helper remains. Three retained owner
tests initially failed to compile against removed snapshot APIs; they now assert
the corresponding live tree/FEN/trap/perspective behavior, preserving meaningful
coverage. The corrected **132-test focused suite passes**, including three native
filesystem artifact journeys covering generate/reopen/update/reopen, interrupted
resume/cancel and artifact authority. Analyze passes with 64 infos and no
warnings/errors. Final lint passes after removing exactly 113 deleted-path debt
entries and the empty feature directory; no boundary gate was weakened.

The feature inventory is now **21 directories: six enforced, 15 unfinished,
none complete**. Recorded dependency violations fall from 1,416 to 1,303 and
legacy theme consumers from 230 to 224. Component/backlog descriptions name the
active position/database surfaces; old graph-display guidance is explicitly
historical. The active line metrics, trap calculations and artifact serialization
remain in use and are retained.

The full simplification batch against `fa7f309e` now removes **10,595 production
lines**. All library Dart totals **228,887**, still **9,930 above** September 16's
218,957 (+4.5%). The two unused-workflow removals account for 8,440 deleted lines;
they cannot offset growth when judging a separate active workflow. Current
Viewer/Builder/Study/Generation-session file counts are 1,954 / 1,459 / 1,049 /
1,455. Whole renewal and the larger consumer simplifications remain Partial.


### Chapter split source identity and partial-output safety — 2026-09-18

Backend `f317b8a1` and complete consumer `7e09cf81` replace the existing splitter's
uncaptured exhausted-source deletion with the shared document mutation boundary.
A valid baseline run against `cfdf999b` has six passing and two failing tests:
changed-content and equal-text native replacements were removed after destination
creation. The earlier attempted red run failed on a test storage fixture and is
not counted as defect reproduction.

The splitter now opens one snapshot, parses that captured content off the UI
thread, creates destinations exclusively, then conditionally saves the remainder
or quarantines the captured exhausted source. Only confirmed source mutation
allows training progress to move. The existing native storage implementation
validates native identity and raw bytes under its existing lock, retains recovery
bytes, uses the existing no-replace rename primitive and verifies the retained
object before acknowledging. A move whose acknowledgement cannot be established
returns explicit uncertainty with observed and recovery paths. External processes
can still race the last validation and rename; this is recoverable uncertainty,
not a claim of filesystem source compare-and-swap. Unsupported hosts reject an
exhausted-source split before creating destinations.

The existing outline owner rejects overlapping structural edits through refresh.
One app-selected document store and one composed outline service feed the actual
Builder, Library and planner consumers. Partial failures preserve confirmed output
paths separately from candidate paths; confirmed source removal followed by a
progress failure no longer leaves the active outline pointed at the removed file.
No automatic retry or rollback is claimed. The real desktop collision journey
saves One.pgn, then encounters an existing Two.pgn directory: original Course
bytes remain unchanged, One exists once and Two remains a directory. The
[inspected partial-output dialog](images/renewal-chapter-split-partial.png)
labels confirmed files and paths to inspect separately and offers Close only.
The headless preview used disposable data and was stopped.

Legacy repertoire import now uses the same pure import planner as native
publication, removing temporary Main-file creation, splitting and deletion.
Direct-publication failures report paths to inspect instead of incorrectly
claiming private preparation. The duplicate import choreography and catalog
callback remove 95 lines, but the **complete safety unit grows by 306 handwritten
production lines**: backend +201 and consumers +105. Generated localization adds
22 lines and ARB adds 18, counted separately. Native package code is line-neutral;
its existing rename method is renamed to reflect file and directory use.

Independent exact-commit review approved the backend and all production consumers.
Backend focused checks pass 94 tests. Corrected consumer checks pass 100 tests
across splitter, outline/controller/UI, imports, My books and native publication;
the final main composition test also passes. An earlier broad run had seven
fixture failures, all repaired and covered by that final run. Analyze/lint passes
with the 64 existing infos, no warnings/errors and 45 architecture checker cases.
This is a completed safety repair, not whole-catalog or whole-renewal completion.

Combined integration over `5e988e59` passes **90 focused tests** covering native
quarantine, splitter, outline/controller/UI and actual main/Builder screens, plus
analyze/lint. The merge preserves all retired paths; the inventory remains 21
features with 1,301 exact debt entries. All 119 checked local documentation file
targets exist. Current all-library Dart totals **229,215 lines** (+4.7% against
September 16). Against `fa7f309e`, the batch has 1,301 handwritten production lines
added and 11,590 deleted: **−10,289**, with generated localization +22 separate.
The validated safety growth does not change the independent simplification gates.


### Remaining unused presentation retirement — 2026-09-18

Against `72ff3519`, delete **14 unreachable production files, 2,154 lines**:
four old opponent dialogs, two old training dialogs, underboard/coherence panels,
the board navigation trail, unused date/filter controls, trap/engine indicators
and the superseded PGN prose-span helper. No surviving production code changes
and no replacement owner is added. An independent reviewer rebuilt the tracked
import/export/part graph, including conditional URIs, from main and all 22
external non-test Dart roots (including driver/tool entrypoints). None reaches
these files; tracked symbol scans confirm no live constructors/helpers, dynamic
registrations or re-exports. Only the obsolete Add opponent dialog calls the
obsolete person dialog.

The two exclusively owned tests are deleted (219 lines). Live PlayerImportPanel,
US Chess client, coherence computation and line-score presentation, current
bottom pane, trap navigation, training setup, engine settings, and movetext
comment-token/diagram rendering remain. Master-practice and pure algorithm/model
orphans are outside this presentation-only retirement. Documentation now names
the actual live consumers rather than these disconnected controls; the older
performance audit retains its historical reference.

The exact debt ledger removes 22 deleted-path entries (1,301 → 1,279), and the
theme ledger removes 13 consumers (224 → 211). Feature status is unchanged:
21 directories, six enforced, 15 unfinished, none complete. Independent actual-
diff review confirms those removals and the matching retirement gates.

All **78 focused tests pass** across the live opponents, coherence, trap
navigation, bottom-pane, engine-settings and chapter-setup paths. Analyze/lint
passes with 64 existing infos, no warnings/errors and 45 checker cases; all 131
checked local documentation file targets exist. No visible production surface
changed, so a new preview was unnecessary. Final all-library Dart is **227,061
lines**, 8,104 (+3.7%) above September 16. Against `fa7f309e`, the complete batch
now removes **12,443 handwritten production lines**, with generated localization
+22 separate. This remains retirement progress, not whole-renewal completion.


### Generation run/job ownership — 2026-09-18

Production commit `b034067f` against `72ff3519` closes the circular startup path:
previously the session announced a run, its screen listener created the job, and
the session resumed to configure that job. The existing session now receives the
existing concrete JobManager, registers a running job with captured request label,
configuration and actual root, then publishes its first notification. Its job
reference is read-only to consumers. A run with no mounted screen still has a
properly registered and settled job; tests use isolated concrete registries.

The existing GenerationProgress owns the one elapsed stopwatch and reuses the
existing notification throttle. Four runtime suppliers disappear. Ordinary stats
and phase changes share a **250 ms** budget, replacing 100 ms job statistics plus
a second 250 ms whole-screen timer. This intentionally slows ordinary job updates
to four per second; admission, pause/resume/cancel and terminal transitions remain
immediate. Paused time stays frozen, disposed callbacks cannot restart a clock or
timer, and settlement writes the retained job summary before unbinding/resetting
progress. The useful pure coherence/completion router remains; its redundant
coalescing result disappears. Jobs-panel controls call the session directly, and
the exporter directly borrows its stable progress and tree-builder references.

The complete declared 18-file consumer/helper scope falls from **7,947 to 7,893
handwritten production lines**: 129 added / 183 deleted, **−54**. Nonblank,
noncomment lines fall from 6,393 to 6,354 (−39). There is no new owner/interface,
generated code change or unrelated deletion credit. Tests verify zero-observer
startup/cancellation, fully configured first observer and resumed root, busy
rejection, disposed settlement, phase/stat burst bounds, paused elapsed time and
late callbacks. The final focused run passes **98 tests**, and the additional
caller/native batch passes **31**, including real native artifact publication/
reopen/resume, generation pane, Builder/main and the configured registry.
An initial run had an obsolete 200 ms timing assertion and an invalid fixture
argument; both were corrected and pass in the final checks.

The actual headless app generated from a disposable PGN using Engine + human
model, auto-opened Jobs, then accepted Pause → Resume → Cancel through its real
controls. The original PGN bytes stayed unchanged and the completed job retained
its 295-node cancellation summary. Implementer, independent reviewer and
coordinator inspected [paused](images/renewal-generation-job-paused.png) and
[cancelled](images/renewal-generation-job-cancelled.png) screenshots. The preview
was stopped. Analyze/lint passes with 64 existing infos, no warnings/errors and
45 checker cases. Combined integration over `f600070c` passes **92 tests** and
analyze/lint; the retirement-manifest merge keeps both branches' retired symbols.
Whole Generation, Builder and the renewal remain Partial.


### Chapter read/create ownership — 2026-09-18

Production `d010bd5b` replaces ChapterStore and picker/Builder creation choreography
with the existing injected catalog and the app-selected PgnDocumentStore.
The catalog validates names, preserves friendly case-insensitive collision
feedback, inherits color when needed, and performs authoritative exclusive
creation. Failed color reads fail creation rather than guessing. Only PgnSaved
supplies an acknowledged path for selection; failed or uncertain results never
select or automatically retry. The pure chapter header has one canonical home.

Builder's sibling cache and refresh fanout are deleted. Its
existing breadcrumb reads fresh siblings on demand, captures the current document
generation before awaiting, rejects overlapping menus and validates that same
capture before presenting or dispatching. Picker reads/course enrichment and
creation use one request identity; Builder outline/load continuations validate
its existing document generation. Controlled A/B/A and pre-frame replacement
checks caught and repaired stale-menu and stale-selection paths. Progressive
course reads, retry, selected chapter and original color semantics remain.

The complete 25-file app scope is **11,620 → 11,608 lines (−12)**. Widgetbook's
catalog fake adds 14, making the combined 11,967 → 11,969 (**+2**). The chapter
replacement itself removes three lines across that full scope; a discovered
isolate-capture defect requires five more. Its top-level preparation function
captures only immutable request/date values, avoiding accidental capture of a
document store and callbacks; both existing import callers reuse it. No new
controller, dependency bag, writer or forwarding facade is introduced. The
estimated 40–90-line reduction was not achieved; clearer ownership does not
justify reporting a material code-size win.

Independent exact-commit review approves the implementation and fixture repairs.
The final combined caller run passes **202 tests**; Linux native checks pass
**five journeys** across document-store failure and chapter creation, including
collision and uncertain post-install publication with no replay. Earlier runs
failed because of the real isolate capture and then fixture composition/real-time
pumping; the corrected combined run covers those callers. Analyze/lint passes
with 64 baseline infos, no warnings/errors and 45 architecture checker cases.
The actual headless Builder creates and adopts Sicilian, opens its fresh sibling
picker and shows the chapter list. Implementer, reviewer and coordinator inspect
[the breadcrumb](images/architecture-renewal-chapter-breadcrumb.png) and
[the list](images/architecture-renewal-chapter-list.png); preview is stopped.
Evidence-only commit `3576744a` contains those screenshots. Whole catalog,
Builder and renewal remain Partial.

Combined integration over `c7351f23` passes **162 tests** across the actual
Builder/main, chapter, Outline, import and Generation consumers, plus analyze/lint.
The retirement manifest preserves both branches’ entries; feature debt falls
from 1,279 to 1,276 exact entries. At `74a59d8c`, all library Dart totals
**226,995 lines**, still 8,038 (+3.7%) above September 16. Against `fa7f309e`,
handwritten library Dart adds 1,775 and deletes 14,284 (**−12,509**), with
generated localization +22 separate. Unused-code retirement still accounts for
10,594 of those removed lines and cannot certify simpler active consumers.

### Remaining chapter mutation regressions — 2026-09-18

These are reproduced defects, not implemented fixes or passing migration gates.
Two separately backed-up test branches preserve intentionally failing baseline
assertions; they are **not integrated into main**:

- `codex/chapter-delete-safety` at `e778e629`, based on `3acf6c3f`: the actual
  picker confirmation deletes a changed or equal-text replacement at the old
  path. The old inode stays alive elsewhere; real storage is only delayed, not
  mocked. Three existing tests pass and both new preservation assertions fail
  at the missing replacement. Independent review validates the reproduction.
- `codex/chapter-relocation-safety` at `cadce9fd`, also based on `3acf6c3f`:
  five real-filesystem/reference assertions fail for destination clobber,
  equal-text source replacement, incomplete reference migration, unrecovered
  post-move reference failure and late training writes recreating the old key.
  Independent review validates all five.

Both checkpoints pass analyze/lint. A proposed generalization of the directory
journal is not admitted: it could repair existing rows but cannot reject future
path-only writes from already active training. Lock ordering alone does not
solve stale writes or path reuse. Define source-identity/admission and recovery
semantics through the existing persistence owners before implementing that full
replacement; preserve captured-snapshot deletion and destination protection as
explicit safety obligations. No rename facade, redirect cache or second journal
was added to make the unresolved contract appear complete.


### Exclusive file-move destination protection — 2026-09-18

`e59c351b` against `cf8a37f7` replaces the general file boundary's
check-then-rename with the existing native exclusive move. A real destination
created after preflight survives, and source bytes remain intact. Native
collisions are translated back into the existing FileSystemException contract,
preserving reference-index winner reuse and other callers' error handling.
No new owner, API, injected mover or test hook is introduced. Production growth
is **11 Dart + 8 C lines**; this is a safety repair, not a simplification result.

Linux uses renameat2(RENAME_NOREPLACE), Windows its existing MoveFileExW without
replacement, and the existing native function now uses renamex_np(RENAME_EXCL)
on macOS. Apple header/test references and deployment compatibility are recorded
in the package README. Unsupported filesystems fail without a replacing fallback.
Linux is tested; macOS and Windows remain unverified on native hosts. No stronger
source-identity, transaction recovery or power-loss guarantee is implied.

The baseline test had one native collision control pass and one actual
check/rename race fail. IOOverrides schedules the competing creator after the
last absence observation; production still executes the real filesystem move.
All **73 final tests pass**: 41 native/helper/storage/update/reference-index/
tactics cases and 32 Outline/picker/Study callers. Analyze/lint passes with
64 baseline infos, no warnings/errors and 45 checker cases. Independent review
approves the exact commit. No visible control changed, so no new preview was
needed. The broader captured-source and training-reference defects remain open;
the historical relocation baseline above is not current passing evidence.


### Study chapter-action dispatch — 2026-09-18

`3ba80b27` against `cf8a37f7` deletes the six-callback StudyChapterActions holder.
Sidebar and compact menus call the screen's existing action dispatch directly;
the shared menu remains a plain function. Existing controller mutations and
dialog identity/mounted guards remain. No new owner or state mirror is added.
The complete four-file scope falls **1,593 → 1,564 lines (−29)**, 69 added and
98 deleted. The screen itself grows one line for direct dispatch/mounted checking;
its entire action graph loses a forwarding layer. This is a bounded improvement,
not a substantial Study rewrite or whole-feature graduation. The broader read-only
audit found that recent screen growth mostly implements actual import/recovery
and navigation safeguards; relocating those methods would not simplify them.

A valid baseline menu regression had two existing passes and one new failure:
an open compact menu acted on the newly selected chapter before the next frame.
Dispatch now resolves the captured chapter key, matching the sidebar. Final
**29 tests pass**, including eight actual wide/compact screen scenarios covering
clipboard payload, reordered/removed targets, confirmation identity and the
last-chapter restriction, plus rebuild/editor/chapter ordering checks. Initial
full-screen fixture clipboard/timer/button issues were repaired and are covered
by that final run. Analyze/lint passes with 64 baseline infos, no warnings/errors
and 45 checker cases. Root independently reviews the exact implementation.

The actual headless app's menus were inspected at
[1280×720](images/renewal-study-chapter-actions-wide.png) and
[900×1000](images/renewal-study-chapter-actions-compact.png); preview is stopped.
An earlier 750px full-screen test exposed a 17px production StudyPickerBar row
overflow at study_picker_bar.dart:88. It was not rerun on the baseline, so its
pre-existing status is unverified. Compact validation is limited to 900px; this
is an open layout finding, not a passed all-width acceptance gate.

### Unused master-practice review retirement — 2026-09-18

`def67780` against `eba9ada9` removes the unreachable master-practice dialog,
controller and pure review algorithm/models: **three production files, 1,163
lines**, without replacement code. Four exclusively owned tests/fixtures and one
unused test-helper parameter remove another 726 test lines. No surviving
production file changes. Live master-games database/service, explorer, Games
review and generation master-book algorithms remain reachable and retained.

The tracked import/export/part graph includes all conditional URIs, main and
22 external non-test roots (tools, drivers, Widgetbook and plugins), 1,831 Dart
files and no unresolved local edges. No root reaches this subtree; symbol and
registration scans independently confirm the graph. The component map's claimed
Home Openings entrypoint was stale and is corrected. Earlier evidence that
excluded this subtree from a narrower audit remains historical. Root reviewed
the graph, actual deletion diff and shared dependencies independently.

Retirement guards add three paths and eight symbols. The debt ledger removes
32 exact entries (1,276 → 1,244) and the theme ledger one consumer (211 → 210).
The feature inventory is **20 directories: six enforced, 14 unfinished, none
complete**. All **71 live-caller tests pass**, with two opt-in skips: the TWIC_PGN
benchmark fixture and TWIC_LIVE network check were not enabled. Analyze/lint
passes with 64 baseline infos, no warnings/errors and 45 checker cases.
No reachable visual surface changed, so no new preview was necessary.

Combined integration at `7f23b082` passes **99 tests, two opt-in skips and no
failures**, plus analyze/lint. The retirement manifest preserves both units.
All library Dart is **225,814 lines**, still 6,857 (+3.1%) above September 16.
Against `fa7f309e`, handwritten library code adds 1,859 and deletes 15,549
(**−13,690**), with generated localization +22 separately. Unused-code retirement
accounts for 11,757 removed lines; it cannot establish simpler active workflows.


### Compact Study toolbar repair — 2026-09-18

`78fb52cc` against `24a8f3fa` reproduces the previously observed 750px overflow
on the actual StudyScreen fixture, then repairs its two existing controls.
StudySaveButton uses its existing warning/save icon and localized tooltip at the
existing compact breakpoint; the wide labelled button and save command remain.
StudyPickerBar constrains its inline rename editor to the available width.
No new owner, layout framework or state mirror is introduced. Two-widget scope
**214 → 227 lines (+13)**; including the unchanged direct StudyScreen caller,
**1,264 → 1,277**. This is a layout repair, not a simplification pass.

The baseline fails with the 17px production overflow. Final **26 focused tests
pass**, including a named, renameable study at 750px with 100% and 150% text,
inline rename, switcher access and keyboard activation of the compact recovery
button after an uncertain save. Existing chapter actions and document save
behavior remain covered. An initial post-fix test selected an unrelated field;
the repaired fixture scopes the editor to the real StudyPickerBar. Analyze/lint
passes with 64 existing infos, zero warnings/errors and 45 checker cases.

The actual Linux app was resized to 750×1000. Its named study was selected,
renamed inline with Enter, and reopened in the existing save/recovery dialog.
Filesystem inspection confirms the old name absent and original movetext
preserved at the new name. Root inspected the [inline editor](images/renewal-study-picker-750-edit.png)
and [recovery dialog](images/renewal-study-picker-750-recovery.png) screenshots;
preview is stopped. Independent root review approves the exact source and tests.
The earlier 900px-only limitation is closed for these 750px interactions; no
arbitrary-width or other-host verification is implied. Reviewed integration
`a783a9f1` totals 225,827 library Dart lines, +6,870 (+3.1%) over September 16
and −11,164 against the growth-review snapshot.


### Captured manual chapter deletion — 2026-09-18

`c92ee2e6` completes the picker/Outline manual deletion responsibility through
existing owners. The catalog captures a native PgnSnapshot before confirmation,
validates the actual configured managed root and passes that constraint to the
selected document store. Quarantine repeats path validation under the existing
mutation lock. Trusted configured root aliases retain canonical identity and the
repertoire directory guard; aliases beneath the root and external files are
refused. Missing unrelated managed roots do not create directories or block
external document open/save. Generic splitter quarantine remains available.
No new owner, result hierarchy, journal or storage fallback is introduced.

The picker captures its existing request identity; Outline reuses edit admission
and viewRevision. Confirmed results can change only their still-current view.
Uncertain results invalidate/refresh observed rows without announcing removal or
following a missing source. A still-mounted caller shows original-file results
even after A→B→A navigation, preserving selectable recovery paths. Files remain
under sibling `.cap-pgn-history`, not OS trash or repertoire-folder recovery.
There is no chapter restore UI. Verified manual deletion is Linux-only;
unsupported hosts refuse before mutation.

The old path-only service forwarding method and cached-line-count Undo cleanup
are deleted. **Move lines to a new chapter → Undo** returns the moved lines but
keeps the chapter; both messages state that behavior. The retained file protects
later file/header additions from automatic deletion. Index-based line transfer
itself is not certified against arbitrary external replacement or reordering.
Full relocation/source-identity and late training-reference writes remain open.

Final handwritten scope is **15 library files, 7,170 → 7,442 (+272)**; two
Widgetbook files add eight lines, ARB adds 67 and generated localization adds
113 separately. This is safety growth, not a simplification pass. Original actual
picker regressions failed for changed and equal-text replacement. Restoring the
lexical-only guard also makes the new alias-lock test fail while native quarantine
is held; the repaired production guard passes. Final **192 focused tests pass**,
including policy, real native quarantine, duplicate admission/release, A/B/A,
selectable uncertainty and existing mutation callers. Analyze/lint passes with
64 existing infos, zero warnings/errors and 45 checker cases. Independent review
approves exact c92ee2e6. Its last change adds only braces to a guard and fixture.

Six Linux native journeys pass through real picker and Outline components:
confirmed deletion, equal-text replacement conflict and post-move uncertainty
for each. Actual main-app Library→Outline confirmation and replacement refusal
were also inspected at 1280×720. Root reviewed the [confirmation](images/renewal-chapter-delete-confirmation.png)
and [preserved replacement](images/renewal-chapter-delete-replacement.png)
screenshots; preview is stopped. These results do not graduate the whole catalog.

### Dormant Viewer custom-tab retirement — 2026-09-18

`cab63c49` against `24a8f3fa` removes the custom database picker/reference-tab
subsystem without adding a replacement. The tracked import/export/part inventory
covers 1,825 Dart files, main plus 22 external non-test roots and conditional
URIs, with no missing local edges. The imports still reach the two widgets;
**control flow**, not that graph alone, proves them dormant: the nullable picker
ID is never assigned a non-null value, the only database opener callback sits
behind that impossible picker branch, and both custom-tab allocation calls are
inside the same closed cycle. Workspace selection/history cannot invent titles.
Root and an independent agent reviewed the exact callers and removed code.

Deletes five screen maps, picker identity, custom ID/title allocation, database
and reference-reader branches, two exclusive widgets and the picker's exclusive
test. Existing PgnWorkspace has immutable fixed titles; Filters has an explicit
pane branch. The full seven-file production graph is **3,608 → 3,211 (−397)**,
35 added and 432 deleted. The Viewer screen falls **1,954 → 1,867 (−87)**.
Live Book cursor/fullscreen behavior, filter origin/return, database Tree,
collection operations, PGN/TXT opening, SCID export, copy, Add-to-Study and disposal
retain their existing owners. This retires dormant machinery in active consumers,
not a new capability or whole-Viewer completion.

Fixed-tab tests retain reorder, background close, reopening and narrow overflow
coverage previously exercised using artificial custom tabs. All **47 focused
tests pass**; three Linux native journeys cover filters, fullscreen/presentation
and collection order. Analyze/lint passes with 63 existing infos, no warnings/
errors and 45 checker cases. Retirement adds two paths/five unique symbols;
the unrelated player-selection database opener is retained. Theme consumers
fall **210 → 208**; feature inventory/debt remain 20 directories and 1,244 entries.


Final Viewer evidence commit `f1ff6df1` changes only component documentation and
two screenshots; production remains the independently approved cab63c49.
Root inspected the actual 1280×720 [fixed tabs and Filter](images/renewal-viewer-fixed-tabs.png)
and [Books pane](images/renewal-viewer-books.png); the disposable preview is
stopped. An attempted `.si5` last-file preference fixture was outside the live
PGN/TXT picker contract, not SCID-opening parity evidence. That screenshot was
excluded and preferences restored. The actual supported capability is SCID
export, covered by the existing writer roundtrip tests; no decoder was added.

Combined production integration `ad281842` passes **123 affected tests, zero
failures**, plus analyze/lint (63 existing infos, zero warnings/errors, 45 checker
cases). Final documentation lint and local-file links pass. The combined
retirement manifest and native no-clobber implementation are preserved. All
tracked library Dart totals **225,815 lines**: +6,858 (+3.1%) over September 16,
−11,176 against the reviewed growth snapshot. Against `fa7f309e`, handwritten
library changes are +2,265/−16,067 (**−13,802**), with generated localization
+135 separately. Unused/dormant retirement accounts for 12,154 removed lines;
it does not establish whole-workflow maintainability. Feature graduation remains
zero and the renewal remains Partial.


### Settings admission and notification consolidation — 2026-09-18

`e6016121` against `a5b3a393` removes the private SettingsSectionController.
Tracked callers show it was instantiated only by SectionSettingsOwner; its
pure-Dart/stream interface had no independent consumer. The existing owner now
contains that same serialized read/edit/retry state machine and directly notifies
its existing listeners. Three typed public owners, immutable configurations,
settings storage boundary and runtime/control APIs are unchanged. No new owner,
result, callback bag, compatibility shim or dependency mechanism is introduced.

The action path loses one forwarding object and the synchronous stream-to-notifier
relay. Stream creation, subscription cancellation and duplicate disposed state
are gone; SafeChangeNotifier owns disposal. The existing queue tail is installed
before notifications, so listener-submitted edits remain serialized. Already
admitted writes settle after disposal without notification; new writes reject.
Failed draft reconciliation, independent-field updates and explicit retry retain
their previous semantics. This is a responsibility consolidation, not a claim
that the old relay had a confirmed correctness defect.

The complete changed production scope is the owner/controller pair, **244→211
lines (−33)**. Including unchanged EngineSettings, BulkAnalysisSettings,
BoardDisplaySettings, SettingsSectionStatus and RuntimeSettings yields the
seven-file ownership/status/composition scope **487→454**. No code was moved
into another helper or consumer. Two new behavior tests cover disposal during
two admitted writes and an edit submitted by a notification listener; both pass
on the baseline, alongside its eight existing tests. Final **66 tests pass**
across owner, typed settings, control panels, runtime, engine lifecycle/budget
and Settings screen. Analyze/lint passes; final retirement/doc lint passes.
Independent review approves the actual state machine and exact e6016121.
No control layout or visible behavior changes, so no new preview is required.

The retirement manifest forbids the old controller path and symbol. Final
library Dart totals **225,782**, +6,825 (+3.1%) against September 16 and −11,209
against the growth-review snapshot. Handwritten changes against fa7f309e are
**−13,835**; generated localization remains +135. Unused/dormant retirement stays
12,154 lines: this additional 33-line reduction belongs to active settings
ownership. Whole renewal and feature graduation remain Partial/unproven.


### Growth audit and shared Study chapter list — 2026-09-18

The committed September 16/growth-review comparison reproduces exactly at `e477dc58`
and `a6238ff5`: 218,957→236,991 tracked library Dart lines. Independent tracked-blob
counts at `ea1b7547` give 225,782. These include comments, blanks and generated
Dart; generated localization is respectively 0, 2,272 and 2,982 lines. Provider
consolidation is already complete, but milestone 6/7 and whole-feature graduation
remain open. Two small passed simplification trials do not establish overall
maintainability. Every subsequent simplification must pass the same complete-
scope reduction, ownership and parity review; unrelated deletion gives no credit.

Study source `3fb4c491`, final evidence `c832d248`, consolidates the sidebar and
manager into the existing StudyChapterSidebar. Deletes the 221-line manager
and duplicate search/reorder/confirmation implementation. The screen composes
the bounded dialog using its existing action handlers; no new controller or
forwarding owner. Selection resolves the captured chapter identity, and reorder
rejects a changed projection or disposed widget. Search, inline Edit/Delete,
active-row reveal, Done/Escape and continued selection within the manager remain.

Full five-file scope **1,785→1,644 (−141 handwritten)** includes screen growth
**1,050→1,072 (+22)**. Generated localization adds 110 and ARB adds 53 separately.
Independent source/evidence review approves the final result. **43 focused tests**
cover chapter behavior, stale callbacks, disposal, light/dark components and
200% scaling with 100 chapters; **two Linux native journeys** cover restart
recovery and large documents. Analyze/lint passes (63 existing infos, no warnings
or errors, 45 checker cases). Earlier fixture/finder failures were corrected and
the final batch rerun; no tests skipped. The actual-app
[wide list](images/renewal-study-chapter-list-wide.png),
[manager](images/renewal-study-chapter-list-manager.png) and
[filtered list](images/renewal-study-chapter-list-filtered.png) were inspected;
the disposable preview is stopped. Three legacy-theme entries are removed
(208→205); the wider Study dark boundary remains necessary.

Combined library Dart is **225,751**: +6,794 (+3.1%) against September 16 and
−11,240 against the growth review. Against fa7f309e, handwritten reduction is
**13,976**, generated localization +245 separately. Unused/dormant retirement
still accounts for 12,154 removed lines. Zero features have graduated. Training
browser work remains outside main pending truthful bulk-save failure recovery
and native Read-line parity; a smaller diff alone does not pass its workflow gate.
Combined Study/settings integration passes 53 affected tests and analyze/lint;
the retirement manifest retains both independently deleted owners.


### Selected document store and one collection patch writer — 2026-09-18

`654898bf` against `d05f1d82` requires the selected PgnDocumentStore in the
collection repository and six collection/Study/Generation factories. All actual
production callers already supplied the same nonnull store. The platform factory
remains the sole Native-versus-Legacy choice; the legitimate AppDependencies test
override still selects through that factory when absent. No platform adapter or
verification claim changed. Collection patching always observes a snapshot,
computes the patch, then saves through the same store. The alternate
StorageService.updateFile writer and its independent receipt creation are gone.
Existing open/save result normalization handles unexpected adapter failures.

Four changed production files shrink **473→438 (−35)**; including unchanged main
composition, Legacy adapter and collection interface gives **965→930**. No new
owner, API hierarchy or helper. Eight existing test fixtures now choose their
adapter explicitly; fake storage implements the real delayed compare-and-swap
semantics instead of bypassing them. Review removed a now-redundant patch override
in the delayed notification fixture, leaving one gate/count per actual save.
Two added real-I/O Legacy cases prove changed-content conflict and lost-
acknowledgement before/observed receipts, forbidding the removed updateFile path.
Native equal-byte replacement and retained Viewer save/recovery behavior remain
covered. This is consolidation, not a newly verified legacy identity protocol.

**143 distinct tests pass** across 11 affected files: the first batch passed 142
actual tests but failed to load a mistakenly named screen test; the corrected
screen path and repaired notification fixture then pass six tests (five repeated).
Final analyze/lint passes with 63 existing infos, no warnings/errors and 45 checker
cases. Independent review approves production ownership and fixture semantics.
No visible layout/behavior changes require a new preview. Final library total is
**225,716**, +6,759 (+3.1%) from September 16 and −11,275 from the growth review.
Against fa7f309e, handwritten reduction is **14,011**, generated localization
+245 separately. No feature graduation; whole renewal remains Partial.


### Trainer reading uses the existing Viewer collection — 2026-09-18

`accadd1f` against `ec5be76f` completes the Read-lines handoff. Native validation
of the old browser found it wrote a relative cache path through StorageService,
then handed that relative path to the Viewer’s absolute-path document store;
the actual UI reported that it could not read the file. The temporary writer,
cache-path construction and Trainer’s storage singleton import are deleted.

The existing immutable OpenPgnViewer gains mutually exclusive file/content
constructors. Trainer synchronously captures ordered PGNs, source title, selected
index and ply after validating mounted/loading/source membership. Viewer uses
its existing leave approval, content decoder, collection owner and navigation
lifetime. Collection-owned title metadata resets/restores with the collection;
UI supplies display fallback copy. No new owner, queue or dependency mechanism.

Read now opens an independent fileless collection: edits use existing Save a copy,
export and unsaved-close protection, rather than autosaving an invisible cache
file. Original training PGNs remain unchanged. The complete five-file production
scope grows **4,404→4,442 (+38 handwritten)**, including Viewer **1,867→1,875**;
Trainer screen remains 1,001. Generated/ARB changes are zero. This removes one
writer and fixes a user-visible failure; it is not a net-size simplification.

Independent source review covers final `accadd1f`. **45 focused tests** exercise
content/index/ply, one-time handoff, leave cancellation, late decoding against a
newer file, edited copy bytes and restored title/cursor. The native Linux journey
uses the actual retained Trainer callback before source change and A→B→A, opens
two games, edits and saves via the real copy dialog, returns to Trainer, and
checks original bytes plus absence of the old cache file. The inspected
[actual Viewer](images/renewal-trainer-read-content.png) shows source title, notes,
two games and Save/recovery; its disposable preview is stopped. Final focused,
native and analyze/lint checks use the merged selected-store fixture with only
one publication gate. Wider Training safety/ownership completion remains open.

Library Dart totals **225,754**: +6,797 (+3.1%) against September 16 and −11,237
against the growth review. Against fa7f309e, handwritten reduction is **13,973**,
generated localization +245 separately. No feature graduation.


### Trainer browser binding and partial progress recovery — 2026-09-18

Final `22e28fa3` (production `5e122390`) against `f8b94ba9` completes the browser
binding together with the safety repair its actual workflow exposed. Browser
receives the existing TrainingSessionController, retaining only navigation
callbacks and local search/sort/checkbox state. Twenty forwarded values/callbacks,
the screen's bulk-save handler and duplicate chapter matching are removed. Existing
session and ReviewProgressStore remain the owners; no new notifier, queue, facade
or persistence adapter is introduced.

A baseline test against `a5b3a393` reproduced a real failure: failed bulk CSV saving
already changed in-memory learned state, so the same Save could return zero as if
successful. The repaired command captures every source batch before awaiting,
serializes through the existing outcome queue, and publishes only after all
schedule/history/header stages acknowledge. Exclusion follows the same admission
and acknowledgement policy. A partial failure blocks progress until a successful
durable load. Reload does not retry history or claim atomic multi-file persistence.
Rating/completion still use their existing captured resumable outcomes; abandoning
an unresolved failure requires reload before another progress edit.

Independent review repaired pending-header record identity, unrelated-source
mirror blocking, failure after abandoned rating/completion, source-load admission,
and retained checkbox drafts. Header settlement compares captured entry and owner
identities, and drains only the new bulk command's source paths after any existing
flush. Captured session generation suppresses old errors after A/B/A or disposal;
current line/list identity rejects stale callbacks even before the next frame.
A failed new-source load never authorizes old-source edits. These guards do not
establish native filesystem identity across source rename or replacement; that
larger training-reference contract remains open.

The exact seven-file union (screen, browser, cards, session, chapter scope,
progress store and selector panel) grows **4,440→4,576 (+136 handwritten)**:
binding −49, necessary safety +185. The complete library diff is +471/−335
handwritten; generated localization +19 and ARB +4 are separate. **The workflow's
net-reduction gate is unmet.** Clearer binding and passing safety checks do not
turn this into a simplification pass or authorize broad rewrite expansion.
Do not offset it with unrelated Read or unused-code deletions.

**273 focused tests and three Linux native journeys pass**, with analyze/lint
63 existing infos, zero warnings/errors and 45 checker cases. Native tests cover
partial CSV success/history failure → Reload → explicit new edit; ordinary line
completion/reload; and Trainer Read → edited Save copy → return with original
sources untouched. An actual disposable app used a history-path directory to
force the same partial failure. The inspected
[partial-save panel](images/renewal-trainer-bulk-partial.png) offers Reload saved
progress without blind Retry. After restoring the path, the
[reloaded browser](images/renewal-trainer-bulk-reloaded.png) shows one learned and
one untrained line, with original PGN bytes unchanged and no history replay.
The preview is stopped. Earlier fixture failures (root-zone async pumping,
loading-state setup and an ambiguous native row finder) were corrected; final
combined runs pass. Exact production review approved `5e122390`; the final commit
adds only the two screenshots.

Library Dart is **225,909**: +6,952 (+3.2%) against September 16, and −11,082
against the growth-review snapshot. Against fa7f309e, handwritten reduction is
**13,837**, generated +264 separately. Unused/dormant deletion still accounts for
12,154 removed lines; zero features have graduated. Study appearance closure is
private until its full shared consumer graph and legacy-boundary removal pass.


### Study appearance through final app wiring — 2026-09-18

Production `6270a265` against `7c8c5596` removes Study's forced-dark application
boundary after converting its actual PGN, engine, dialogs, setup and shared
controls together. The existing app appearance preference remains the sole
owner. `PgnTextStyles` now lives at `widgets/pgn/pgn_text_styles.dart`, requires
context and has no old-path shim; the retirement manifest rejects restoration.
Rendered editor rows invalidate on inherited appearance changes while preserving
the document index and editor lifetime. Floating engine previews resolve their
own inherited theme, without replacing the engine/preview owner. Board-coordinate
chrome receives explicit resolved ink; board pigments remain intentional.

Independent review found and repaired annotation contrast on hover and ChoiceField
rows clipping at 200% text scale. The same existing row-height computation now
serves rendering and keyboard scroll. Nested board setup uses vertical side
choices under constrained/scaled widths instead of shrinking the text. An open
notice uses paired theme colors for text, action and dismissal, preserving error
persistence and timed attention notices. Converted control labels and count
messages use localization; the sole-reader English import-source label getter
is deleted. No new coordinator, style owner, callback facade or runtime fallback.

The complete **45-file scope grows 15,127→15,404 (+277 handwritten)**, including
Study screen 1,072→1,101. The library diff is +1,209/−932 handwritten, generated
+2,199 and ARB +1,113 separately. Old/new canonical style paths account for two
diff paths but one scope responsibility. Six engine consumer files plus 17 other
retirements reduce the legacy-theme ledger **205→182**; one resolved feature-debt
entry leaves 1,243. This completes an appearance capability and removes its old
theme path; it does **not** pass a net-size simplification gate or certify Study.

**98 combined focused tests**, **44 additional retained-caller tests**, and
analyze/lint pass at the reviewed production source (the final handoff reports
64 infos, no warnings/errors, and 45 checker cases). The retained batch initially had 23 failures
from two bare widget hosts lacking app localization; fixture commit `f84ba7a2`
adds only their delegates/imports. A wider widget-directory run exposed
additional indirect hosts and old fixed-color assertions; it was stopped after
682 passes, 69 failures and a stalled Viewer copy scenario. That scenario passed
alone without changes. Independently reviewed fixture repairs preserve selection,
annotation classification and draft assertions; 140 focused cases pass. The
final **entire widget-directory rerun passes all 759 tests**, with no failures or
skips; the copy stall did not recur. No production change or timing workaround
was introduced for that stall. These overlapping batches are not additive unique
test counts.

**Seven Linux native tests across six targets pass**: actual app appearance and
inline draft retention; Study restart recovery; two Study save/recovery cases;
a 20,000-node Study; Viewer editing; and Builder native history. The new appearance
fixture `c77a66dd` exercises Dark, Light, System and simulated platform changes,
with the same chapter/cursor/flip, nonzero scroll, editor/field state, text
selection and dirty document contents. Its final Save closes the inline editor;
durable saves are proved by the separate existing targets. Initial native
fixture assumptions incorrectly required the selected chip to stay mounted after
scroll and treated typing as uncommitted to the in-memory document. Existing
production behavior disproved both; the corrected fixture passes independently
reviewed assertions. The large-document run reports debug open 1,902 ms, distant
jump 710 ms and RSS 824,782,848 bytes; this is diagnostic evidence, not a new
profile-mode performance-budget result.

The actual 1,280×720 app was inspected in
[Dark](images/study-appearance-dark.png),
[Light](images/study-appearance-light.png), and
[nested light setup](images/study-appearance-setup-light.png). These screenshots
use 100% text scale. Enlarged-text proof comes from the actual widget dialog/setup
tests, including an open en-passant picker and a retained FEN draft across themes;
no 200% native screenshot claim is made. The disposable preview is stopped.

**Whole Study remains Partial.** Its library namespace adapter still renames
without validating the captured source revision and deletes by path. Native
no-clobber already works and deletion retains quarantined bytes, so this is not a
claim of demonstrated destruction. Existing namespace coverage proves a later
save conflicts after external replacement; it does not prove source-safe
relocation. Training-reference/late-writer recovery remains a shared unresolved
contract. Controller-built save/recovery text reaches the PgnSaveStatus tooltip;
board validation diagnostics and some namespace failure presentation remain
English/incomplete. Whole-feature consumer simplicity, native accessibility and
other-host gates also remain open. Existing Linux stopped-profile restore and
profile-mode large-document evidence retain their original bounded credit.
Editing, save sessions, imports and app recovery already have final owners; these
remaining gaps do not call for another coordinator.

Library Dart is **228,385**: +9,428 (+4.3%) against September 16 and −8,606 against
the growth review. Against fa7f309e, handwritten reduction is **13,560**, generated
+2,463 separately. Unused/dormant retirement still accounts for 12,154 removed
lines. Zero features have graduated; no broader extraction program is authorized
by these capability and safety results.


### Builder dormant launch and trap wrapper retirement — 2026-09-18

Against `c91b9086`, the 17-file screen/form/handoff/trap graph shrinks
**7,340→7,101 (−239 handwritten; generated unchanged)**. Builder screen itself
shrinks 1,468→1,422. The scope includes the screen and its three parts, generation
tab, generation form and its six parts, AppState/PendingHandoff, and the trap
wrapper/browser/session. Independently approved production is `f8227f6e`;
final `708b58e4` adds only reviewed fixtures and three screenshots.

Tracked callers prove the external generation handoff has no production producer.
The presumed Discover entry is also unreachable: its only parent requires
`hasTraps`, defined as a nonempty list, while the button requires an empty list.
Deleted both retry chains, the outer widget-state key, public seeding/state APIs,
the generation handoff field/producer API and the entire `TrapsTabContent`. The
screen now supplies the same data, metrics, selection/tour callbacks and preview owner directly to the
existing `TrapsBrowser`; its parent visibility rule stays intact. Manual generation,
configuration defaults/presets, resume, publication and repeated cuts are unchanged.
No replacement owner, constructor overlay or automatic-start mechanism was added.

Attribution is deliberately bounded: 128 net lines outside the wrapper retire
dormant launch/API/caller machinery. The deleted 111-line wrapper mixes a 54-line
unreachable body with declarations, obsolete inputs and active forwarding. The
active improvement is one removed widget layer, not a claim that all 239 lines
simplify generation. Retirement checks forbid the deleted paths/APIs; six debt
rows and one theme-consumer entry disappear with the code. Whole Builder and
Generation remain Partial; delayed source changes behind configuration are not
resolved by this deletion. The initial bare widget host overflowed in the trap
summary and breadcrumb; the breadcrumb failure also reproduced on baseline
`c91b9086`. The actual 950×1,200 app did not reproduce it. Using the production
theme and bundled Inter/SourceCodePro fonts fixes both new widget cases at the
same viewport, with no production layout change or error suppression. Earlier
fixture failures also included animation readiness, a dynamic tab label, the
ChessDB depth field name and an identity-vs-value list assertion; all were
corrected before the final combined run.

**All 69 affected tests pass**, with no failures/skips: 24 actual Builder screen
cases and 45 retained trap/handoff cases. Analyze/lint passes with 64 existing
infos, no warnings/errors and 45 checker cases. Its diagnostic set matches the
preceding Study handoff; no new lint debt was added. The headless app was inspected
through [manual configuration](images/renewal-generation-manual-config.png),
[retained traps](images/renewal-generation-retained-traps.png) and
[the trap tour](images/renewal-generation-trap-tour.png). Actual selection shows
the expected board/annotations; the tour and chapter picker remain usable.
Manual configuration opens and cancels; the source PGN remains byte-for-byte
unchanged. This check did not start a generation job. The disposable preview is
stopped. Feature debt is 1,237 and the legacy-theme ledger is 181; neither is a
completion certificate.

### Builder handoff ownership and waiter retirement — 2026-09-18

Against `e05e8e86`, independently reviewed `57b10629` replaces the two detached
line/move continuations with one continuation that awaits its own load command.
The existing document generation, successful readable content and current
navigation intent determine whether it may apply. The shared `awaitLoaded`
API/list, completion plumbing and both old continuation names are deleted and
mechanically retired. No new controller, epoch or dependency boundary is added.

The complete eight-file graph—screen and its three parts, document session,
workspace, AppState and PendingHandoff—shrinks **4,989→4,969 (−20 handwritten;
generated unchanged)**. The screen grows four validation lines while the
document owner loses 24; other graph files are unchanged. Production diff is
+42/−62, and test code grows 328 lines. This is a bounded ownership improvement,
not whole-Builder graduation or a claim that every screen is smaller.

Five baseline cases fail for the intended behavior: a pending A move request
applies to B, a pending A line ID selects B's different line with the same ID,
A→B→A revives old navigation, failed decoding navigates the retained chapter,
and a missing chapter receives a composed draft. Controlled decoder gates and
the actual screen reproduce them; the missing-source case runs separately.
All pass after repair. Three additional cases preserve ready same-source
navigation without reloading, line-before-moves ordering, captured mutable
inputs during a fresh same-source load, and suppression after leaving Builder.
Owner tests now await their actual command while retaining late-adoption,
disposal, supersession and restore assertions; an idle-waiter-only test retires
with its removed API.

**106 affected tests pass, zero failures/skips**, covering screen, load,
document-session, workspace recovery and pending handoffs. Analyze/lint passes
with 64 existing infos, no warnings/errors, 45 checker cases and 1,237 unchanged
debt entries. The existing Linux `builder_projection_test.dart` also passes:
real app handoff, line selection, annotation editing/save, mode return and reload.
It checks native parity; the controlled widget tests prove the race interleavings.
There is no appearance change or new native race claim. Logs are
`/tmp/builder-handoff-{baseline-red,missing-red,combined-tests,gates,native}.log`.

Library Dart at this checkpoint is **228,126**, down 8,865 from the reviewed
growth snapshot but still 9,169 above September 16. Build/Cut source admission
remains a separate in-progress safety repair; native identity before mutation
reads, whole-feature simplicity and feature graduation remain open.

### Build/Cut source admission and repeated-cut parity — 2026-09-18

Independently reviewed `a50d2539` completes the source-admission repair planned
before implementation. At baseline `e05e8e86`, delayed inline chapter creation
can replace A with B behind an open Cut configuration. Its retained command then
admits deletion against B, or against a new A after A→B→A. The baseline tests use
the actual screen/catalog completion and a recording delete adapter: they prove
wrong destination/index admission, not native data loss. Early native-write
fixture attempts stalled in fake-clock scheduling and are not product failures.
The authoritative two-case RED is `451a148e` and
`/tmp/generation-source-admission-baseline-red.log`.

The screen captures chapter, position, side and move inputs before opening the
route. Existing route identity and document generation admit Start/Cut; canceled
callbacks cannot become valid when another route opens. Start captures a fresh
publication receiver before mutating configuration or quota state. An admitted
receiver remains document-scoped after the configuration closes. Cut uses the
existing document queue and its captured destination. Its typed result reports
the acknowledged removal count and carries remaining lines only with valid
source authority. A real empty-selection no-op retains admission without
inventing a refresh; a nonempty request returning zero must refresh because the
file may be missing. The exact successful load—not a post-await counter read or
an inferred increment—can renew the route. Failure, missing content or
supersession cannot return a newer chapter's projection.

Visible repeated-cut coverage also exposed a separate continuation problem:
after the first cut changes source bytes, the shared artifact may become
unavailable and the old UI clears its ranking/controls. The existing route now
retains its captured ranking with coherent tree/config/FEN inputs, while its
remaining-line projection advances only through acknowledged receipts. The
test deliberately makes the artifact unavailable, verifies the global tree is
null, and performs real PGN removals **3→2→1** through the actual Remove button.
This proves controlled artifact-unavailability behavior, not new native
artifact-validation coverage. Obsolete ranking reset branches are deleted.

Complete nine-file scope against `e05e8e86` is **4,859→4,963 (+104 handwritten)**:
screen +33, tab +39 and document session +32; screen parts, document repository
contract/adapter and configuration host remain unchanged. Generated localization
adds 51 lines and ARB adds 21 separately. There is no new controller, adapter
layer or independently advanced revision counter; the existing command gains
an explicit result contract. This is declared safety growth, **not a reduction
pass**. Combined with the separate handoff cut, the union of 12 production graph
files grows 6,230→6,314 (+84 handwritten); the 20-line deletion cannot hide that
net growth or justify broad rewrite expansion.

All **62 affected screen/mutation tests pass**, with no failures/skips; this
includes stale actual Start, canceled/reopened routes, successive visible cuts,
write failure, committed-cut refresh failure, missing files and superseded own
refresh. Independent reviews cover both production and meaningful behavioral
assertions. Exact analyze/lint passes with 64 existing infos, no warnings/errors
and 45 checker cases. Test-fixture corrections included menu readiness and a
stale localized-label expectation; no production error was suppressed.

The new Linux `builder_generation_admission_test.dart` presses the actual
Generate button after real document A→B→A transitions behind configuration. A
fresh rejection appears each time, no job starts, and both PGNs remain exactly
unchanged. The [inspected native screenshot](images/renewal-generation-source-rejected.png)
shows the original configuration and readable rejection. This fixture uses a
direct document transition to isolate production admission; widget tests
separately drive the delayed catalog completion. The first native attempt
stopped in an empty-finder loading wait, corrected before the passing run.
No engine generation run or non-Linux host coverage is claimed.

After merging this repair with `57b10629`, **144 combined tests pass, zero
failures/skips**, across the actual screen, document load/session, workspace
recovery, pending handoff and mutation-safety suites. This union includes the
agent suites above; their overlapping counts must not be added. The combined
log is `/tmp/renewal-source-admission-combined-tests.log`. The final merged Linux
Start case also passes, and its screenshot exactly matches the inspected image.
Final analyze/lint retains the same 64 infos, no warnings/errors; logs are
`/tmp/renewal-source-admission-exact-{native,gates}.log`.

At the admission checkpoint, library Dart was **228,281**, down 8,710 from the
reviewed snapshot and still 9,324 (+4.3%) above September 16. Native identity before the mutation's
initial read, remaining catalog/training writers, whole-feature consumer
simplicity and all feature graduations remain open. These results close the
named admission responsibility, not whole Builder, Generation or renewal.

## Builder layout responsibility retirement (`011bc833`)

The starting commit is `dff71ee3`. The complete production scope is the Builder
screen and its three parts, `RepertoireLayoutPrefs`, the old/new outline controls,
`RepertoireWorkspacePanel`, `RepertoireToolbar`, `RepertoireBoardPane` and the
retired `BoardZone` file: **4,167→3,912 lines (−255 handwritten)**. Generated code
is unchanged. The screen stays at 1,459 lines and its layout part shrinks by 11;
newly named controls are included in the total, not treated as free code.

Builder now constructs the existing `RepertoireBoardPane` inside the same
cursor-scoped listener. The toolbar places its existing trap navigation directly.
Deleting the 59-line `BoardZone`/`BoardZoneControls` file and one net toolbar line
removes **60 lines of live forwarding**. The other **195 lines** remove dormant
expanded-panel/header/right-panel-resize branches and unused Lines-width
preferences, simplify their callers and correct stale descriptions. That dormant
portion does not count as another workflow's simplification credit.

The outline strip and its resize handle expose only their actual commands. The
notation surface retains its clipping, border and child constraints. Analysis
collapse is named for the actual dock while retaining the existing stored
`repertoire.lines_panel_collapsed` key. No owner, state mirror, framework or
compatibility shim was added. The retired paths and public wrapper APIs are in
the unconditional retirement manifest. Four obsolete theme-debt entries are
removed; the renamed controls retain their existing debt classification.

Independent exact-source review passes. **56 focused tests pass**, zero
failures/skips: layout preferences, actual outline controls and the complete
Builder screen suite. The replacement resize test crosses both limits and checks
that the outline follows the pointer again after either limit; synthetic tests
for the unreachable right panel and expanded tabs are removed. Existing screen
checks retain wide/compact, persistence, annotations, trap preview/tour and
source-admission coverage. Log: `/tmp/renewal-layout-tests.log`.

The first test attempt found one missed renamed setter at a screen caller; it
was fixed before the passing run. Initial analyze/lint passed with two new style
infos; `011bc833` repairs those with a constant tooltip and a null-aware toolbar
collection element. Combined final native and analyzer evidence is recorded with
the batch below. Whole Builder and the renewal remain Partial.

## Jobs ownership and dialog lifetime (`65ccc3bc`)

From `dff71ee3`, the complete eleven-file graph is the Builder screen/three
parts, `JobsTabContent`, `JobsPanel`, `AuditSessionController`,
`GenerationSessionController`, `JobManager`, `SnapshotExportDialog` and
`BottomPane`: **6,069→6,026 lines (−43 handwritten)**, generated unchanged.

The existing JobsPanel owns its merged listener and concrete export interaction.
It receives the three existing owners and navigation commands, with no
BuilderWorkspace dependency or pause/resume/cancel/export forwarding callbacks.
Audit cancellation uses the audit owner's captured source, including queued and
fileless runs. `JobsTabContent` and its path/API are deleted and mechanically
retired. This removes **67 lines** from the live graph.

Actual-control tests exposed a baseline dialog use-after-dispose during its
closing animation. The existing dialog now owns its text controller in State
and releases it at disposal: **+22 safety lines**, admitted before coding.
Independent review then identified two adjacent command races, reproduced on
checkpoint `27b59527`: cancellation during a name lookup popped the underlying
page, and repeated Enter started two lookups. Capturing the existing route and
checking it plus the existing busy flag adds **two safety lines** and rejects
both continuations without a new owner, counter or interface.

The baseline disposal test fails on `dff71ee3` and passes after repair; the two
command cases fail on `27b59527` and pass on `65ccc3bc`. Logs:
`/tmp/builder-jobs-export-baseline-red.log`,
`/tmp/builder-jobs-command-lifetime-red.log` and
`/tmp/builder-jobs-final-tests.log`. **82 focused tests pass**, zero failures or
skips, across Jobs controls, audit session, generation session, job display and
registry, snapshot owner and snapshot generation. Seven real widget cases
exercise listening, owner replacement/disposal, controls, export choice/busy/
cancel/failure and the reproduced route races. Analyze/lint passes with the
existing 64 infos, no warnings/errors. Exact independent review passes.

This completes the forwarding retirement and named dialog repairs; it does not
claim to resolve export destination identity or the whole engine/jobs domain.

## Generation form state consolidation (`ff3db250`)

From `dff71ee3`, the complete ten-file scope contains all seven form files,
`TreeBuildConfig`, `RepertoireGenerationTab` and `PlanBuildScreen`:
**5,943→5,812 lines (−131 handwritten)**. Three existing form files change;
generated Dart and ARB are unchanged. There is no new public API or owner.

The form no longer stores 18 non-rendered TextEditingControllers and three
non-rendered booleans. Inherited settings stay in its existing typed config;
only rendered edits have mutable form controls. This removes seeding,
text-to-number round trips and redundant boolean normalization. Existing
`_NumSpec` range validation is shared by typed inherited values and editable
input, preserving inherited invalid-value rejection and Pure-mode exemptions.
Defaults, seed magnitude, clamps, trimming, global settings overrides, preset
replacement and mode-specific normalization remain covered. When both kinds of
input are invalid, editable errors intentionally appear first; this ordering
change was reviewed before acceptance and is explicitly tested.

**49 form tests pass**. The same 48 unchanged-behavior cases also pass against
detached baseline `dff71ee3`, including full serialized unseeded defaults for all
four modes and both colors, seventeen inherited constraints, non-finite values,
preset replacement, visible edits and mode switches. Logs:
`/tmp/generation-config-mirrors-all-form-tests.log` and
`/tmp/generation-config-mirrors-baseline-verified.log`. An initial unsupported
runner exclusion flag was a setup failure, not a product regression.

The caller batch passed 68 cases but initially failed nine Planner fixtures
because their MaterialApp hosts lacked localization. Adding the existing app
localization delegates and supported locales to those three test hosts fixes
all nine without production changes or weakened assertions. Final analyze/lint
passes with 64 existing infos and no warnings/errors. Independent exact-source
review passes. This replaces the hidden form-state round trip; Generation's
broader run/storage lifetime remains Partial.

## Combined consumer consolidation (`eaefa33a`)

The three reviewed units merge without production conflicts. The sole conflict,
retirement metadata, is resolved as the deduplicated union of both path/symbol
lists. Independent comparison against all three reviewed source commits confirms
that their production changes and retirements are preserved.

The complete union of the declared graphs is **13,349→12,920 handwritten
production lines (−429)**; shared screen files are counted once. Generated code
is unchanged. This comprises 258 lines removed from live forwarding/config
coordination, 195 from dormant layout branches and associated wiring/comments,
and 24 added for reproduced dialog safety. It neither credits dormant deletion
to another workflow nor hides the safety growth.

**223 combined tests pass, zero failures/skips**, in sixteen files covering the
three units and their actual Builder/Planner callers. This union includes the
individual 56/82/49 and caller suites above; do not add those overlapping counts.
Log: `/tmp/renewal-consumer-consolidation-tests.log`.

Library Dart totals **227,852 lines / 995 files**: 9,139 below review snapshot
`a6238ff5`, still 8,895 (+4.1%) above September 16. Viewer is 1,875 lines, Builder
1,459, Study 1,101 and Generation session 1,447. Legacy services remain 42,560
lines and widgets 49,712. Six feature directories are enforced, fourteen remain
unfinished and none is complete. Exact architecture debt falls by four to 1,233;
legacy-theme consumers remain 181. No milestone or whole-feature graduation is
claimed by this bounded batch.

The extended existing `integration_test/builder_projection_test.dart` passes as
one Linux native journey. It retains real edit/annotation/save/mode/reload checks
and additionally exercises outline collapse/expand/drag, analysis collapse,
wide→compact transition, and identical board tree/path/preview ownership. With
no active job, the fixture opens the existing bottom-pane owner directly and
renders the actual idle Jobs panel. It then opens the concrete export dialog,
types and cancels through its closing animation; this is deliberately **not** a
claim of native running-job export. Widget tests exercise that actual button
path. Native log: `/tmp/renewal-consumer-consolidation-native.log`.

Inspected native screenshots show intact board, notation and controls in
[wide layout](images/renewal-builder-wide-layout.png),
[compact layout](images/renewal-builder-compact-layout.png) and the
[snapshot dialog](images/renewal-builder-snapshot-dialog.png). Checks use the
bounded runner's private display and disposable profile; no visible user app or
user databases are used. No preview remains running.

Final combined analyze/lint passes: **64 pre-existing infos, no warnings/errors**,
45 architecture-checker cases, all retirement/debt/theme and mutation gates.
Log: `/tmp/renewal-consumer-consolidation-gates.log`. Local links in the plan,
evidence record and component map resolve. Windows/macOS native behavior and the
remaining whole-renewal exit gates were not run or claimed by this batch.


## September 18 size audit and midpoint hold

Independent inspection of tracked Git blobs reproduces the review's exact
`e477dc58`→`a6238ff5` table and the updated `8ccfe557` table in the
old plan at `449d5428` ("What the code establishes"). Use
`git ls-tree -r --name-only REF lib/`, filter `.dart`, and count physical lines
from `git cat-file --batch`; include comments, blanks and generated files.
No concurrent worktree is included in main's totals. The only generated Dart
identified is localization: 0→2,272→5,361 lines. Handwritten library code is
therefore 218,957→234,719→222,491: current main is still 3,534 handwritten lines
above September 16, even after removing 12,228 since the reviewed snapshot.

The historical 99 commits comprise 77 non-merges and 22 merges, with 57 commits
on the first-parent history. Counting each non-merge against its parent over
tracked library Dart gives 60 net increases, 13 zero deltas and four net
reductions. This refutes “all adding layers”; it does not establish better
architecture. Current feature/debt data reports 6 enforced, 14 unfinished,
0 complete and 1,233 exact debt entries. Source/package searches find no
Riverpod dependency or production import. Milestones 6–7 remain Not started.

**Historical midpoint decision: hold the evaluation-settings cutover for redesign.**
The resolution is recorded [below](#evaluation-settings-ownership-completed-after-redesign);
the failures here describe the incomplete checkpoint, not the final source. The
private `codex/eval-settings-ownership` checkpoint `2a585ef2`, based on
`8ccfe557`, adds 337 handwritten production lines before app composition,
job configuration capture and conditional deletion are wired. Its estimate
was +100–300, declared as safety/capability work rather than simplification.
The actual partial diff already exceeds it: UI +249, download controllers
+138, replacement settings model/owner −50. Duplicate UI load/error/status
handling and proposed conditional-retry bookkeeping need review before further
implementation; automatic growth-budget increases are not the remedy.

At that midpoint the checkpoint was backed up only, **not integrated into main**.
Owner/model checks passed 13 cases; the new UI check passes two and fails one because loading
notifies Provider during widget build. Download tests are not run. Whole-tree
analysis fails (25 errors, 1 warning, 66 infos), including the intentionally
unfinished app/caller wiring; lint rejects three stale debt entries. These are
failed gates, not completion evidence. Mutation and rule checks pass. Logs:
`/tmp/eval-settings-owner-model-verified.log`, `/tmp/eval-settings-ui-initial.log`,
`/tmp/eval-settings-midpoint-checks.log`, `/tmp/eval-settings-midpoint-lint.log`.
The environment doctor also reports the lint blocker; no containment bypass or
user-data check was used. No source from this experiment enters the docs audit.

Before resuming, settle a smaller complete contract: existing download owners
own artifact errors; each settings surface presents one settings status; app
composition owns resource shutdown; destructive deletion retains files if the
necessary settings change fails. Review queued A/B selection and failed-write
semantics before selecting an API. These are design requirements, not implemented
behavior or permission to add another owner/retry framework. The source branch
must pass independent correctness, complexity and combined behavior review
before integration. Full renewal remains Partial.


## Evaluation settings ownership completed after redesign

Source `d22d9202` completes the responsibility held at `2a585ef2`; it does not
complete Settings or the architecture renewal. The original +100–300 production
line allowance remains unchanged. The complete evaluation scope is
**14,074→14,365 (+291 handwritten)** against `8ccfe557`, with no generated growth.
An independently reproduced Library disposal repair adds **6** separately.
All library Dart is now **228,149 / 996 files**, including unchanged generated
localization **5,361**: handwritten **222,788**, still **3,831 above September 16**.
Exact debt is **1,229**, theme consumers **181**, feature status **6 enforced,
14 unfinished, 0 complete**. This cutover earns safety/ownership completion,
not net-reduction or feature-graduation credit.

The measured scope includes app dependencies/runtime settings/main; Generation
session; Databases and Settings screens; Builder screen and its three parts;
Planner data source/screen; section owner/configuration/state/storage contract
and preferences adapter; both download controllers; their five settings/card/
dialog widgets; evaluation-source controller/section; all seven generation-form
files; and the old settings model plus its two canonical replacements. That is
34 baseline files, 36 historical paths and 35 surviving files. Count physical
lines including blanks/comments; include unchanged consumers and new files.
The Library screen is separate. The all-library `git diff --numstat 8ccfe557 d22d9202 -- lib` delta is
**+996/−699 = +297**.

The final contract has one application-owned writer for the same seven persisted
keys, using the existing section queue and committed/draft state. Both existing
download owners receive that exact writer; app shutdown drains admitted work
before disposing settings. One admitted operation per resource rejects overlap;
pause/close cancel and await transfer/import settlement. Job and Planner commands
capture confirmed settings before async work. Unknown preferences refuse those
commands; later edits cannot rewrite the admitted operation's configuration.

Deletion conditionally clears only the selected directory it captured, verifies
persistence, then removes files. Failed clearing retains files and rethrows to
the download owner. Settings Retry cannot replay an unconditional deletion or
resurrect a deleted selection: it resolves the surviving failed edit when its
queued action executes. Failed selection B and unrelated failed edits survive
clearing A. Enabling a selection respects failed user intent without borrowing a
later pending command's path. The existing queue implements this ordering;
there is no additional retry registry, coordinator or settings owner.

The redesign removed duplicate UI error/status rendering, leaf initial-load
calls, download-only listener relays and optional card owner overrides. Each
settings surface renders one existing status component. Download owners retain
artifact failures and expose explicit metadata retry; a failed prepare cannot
start a transfer. Dialog completion validates its captured owner and target.
The old settings file and all three `.instance` APIs are deleted and rejected by
retirement lint; searches across production, tests, integration and Widgetbook
find no remaining callers. Independent implementation reviews covered these
contracts and repaired UI error/loading and queued-selection interleavings.

**Validation:** 240 tests across 25 owner, resource, composition, Generation,
Planner and UI files pass with zero failures/skips. After the native run exposed
an inherited Library bug, the final three-file lifecycle/caller run passes
11 tests (10 overlap that union; **241 distinct focused tests overall**).
Its first attempt exposed an incomplete Library test host; it now supplies the
actual outline factory, and still exercises mount/unmount before opening a
folder followed by the retained read/train/build journey. The source repair
constructs the existing outline in `initState`, so disposal never performs its
first Provider lookup. Databases also rejects late refresh before context access.

All **three Linux native tests pass**: a real read-only preferences file preserves
confirmed settings and visibly retains a failed edit; repairing permissions and
pressing Retry persists it; a fresh owner reloads the value. Existing appearance
failure/retry and creation-draft/restart journeys also pass. The initial native
run failed on the inherited Library disposal lookup; its full stack identified
the cause, the fix was independently reviewed, and the test was not weakened.
The [inspected failure screenshot](images/renewal-eval-settings-failure.png)
shows one persistent message and Retry without overflow. Runs use the private
display and disposable profile, with synthetic resource fixtures and no user data.
No real evaluation dump is downloaded and no preview remains running.

Analyze/lint passes with **64 pre-existing infos, no warnings/errors**, all
45 architecture-checker tests, and retirement/debt/theme/mutation checks. Logs:
`/tmp/eval-settings-combined-tests.log`, `/tmp/eval-settings-lifecycle-final.log`,
`/tmp/eval-settings-native-final.log`, `/tmp/eval-settings-handoff-gates.log`.
Preferences are serialized within the app, not a cross-process CAS transaction.
Windows/macOS native checks, credential migration and whole-renewal exit gates
remain open. The next simplification must remove code from its own complete live
workflow; this safety growth cannot satisfy that gate.


## Training settings state-machine consolidation

Source `8ea60830`, based on `779cae0d`, removes **314 handwritten production
lines (+142/−456)** with no generated changes or new production files. The
complete declared 40-file envelope falls **6,641→6,327**, with 39 files surviving.
It contains all `features/training/`, all `features/settings/{controllers,models}/`,
the shared settings storage contract, app dependencies/runtime/training composition,
both preferences adapters, the Trainer screen and its settings panel. Every
changed production file is inside this scope; no dormant or unrelated deletion
subsidizes the result. Whole library Dart is **227,835 lines / 995 files**, of
which **5,361** are generated; handwritten code is still **3,517 above September 16**.
Exact debt remains **1,229**, theme consumers **181**, and feature status remains
**6 enforced, 14 unfinished, 0 complete**.

**Design and review.** Parallel audits compared live Builder line-list forwarding,
Generation enrichment ownership, Solitaire controls and Training settings. The
chosen responsibility had two implementations of the same admitted-edit queue,
read-back confirmation, failed draft and retry rules. The design fixed nullable
removal, existing storage keys/migration, app-owned initial load, focused text
editing and the sitting boundary before parallel model/UI work. It required net
production reduction across all consumers, with no growth allowance. An independent
review checked the actual final caller graph and found no outstanding issues.

**Final shape.** Panels capture changed persisted fields → the existing
`SectionSettingsOwner` admits and confirms edits → the existing scalar preferences
adapter persists them. Training's concrete owner is now 12 lines, down from 192;
it selects its configuration type and defaults, without a second queue or relay.
The redundant Training repository/storage interfaces, patch type, field enum,
stream subscription and storage write switch are gone; retirement lint rejects
those APIs. Owner instances remain one per section: the reduction is one shared
state-machine implementation, not combining unrelated preferences into one object.
`TrainingConfiguration` retains immutable committed/draft values and creates
separate mutable snapshots for editing and active sittings.

The shared scalar contract now distinguishes an absent edit from an explicit null.
Null removes optional training depth and checks the platform acknowledgement;
other settings retain their normalized nonnullable defaults. Training's adapter
keeps its existing default-cap migration, with its completion flag written last.
Panels do not initiate loads during construction. App composition loads the
selected owner, disposes only its own default and leaves injected overrides to
their caller. Owner replacement detaches old UI listeners. Active and auto-next
lines continue using their captured committed settings; failed drafts never
become runtime configuration.

**Checks.** All **305 focused tests pass**, with no failures/skips: Training owner,
source, progress, phases, run and widgets; engine/bulk/display/evaluation settings;
shared settings controls and composition; main-screen integration. Added cases
exercise explicit-null merging/removal, false removal acknowledgement after a
partial write, unrelated edits followed by retry, interrupted migration and its
flag, scalar corruption, focused drafts, owner replacement and initial-load Retry.
The first analyzer run caught a test-only `TextFormField.focusNode` access; using
its actual focus scope repaired the fixture without weakening assertions.

The Linux native completion/settings journey also passes. Through the real UI,
clearing the depth limit removes the preference while the current sitting and its
next puzzle retain depth 10. Stopping the sitting adopts the new full-line setting;
a fresh owner reloads it from disk. Both puzzle results still persist exactly once
and survive source reload. The [inspected settings screenshot](images/renewal-training-shared-settings.png)
shows the saved-next-sitting status and whole-line control without overflow.
This uses a private display and disposable profile, with no user data or live
preview left running. Final analyze/lint passes with **64 pre-existing infos,
no warnings/errors**, 45 architecture-checker cases and all retirement/debt/theme,
mutation and rule gates. Logs: `/tmp/training-settings-combined-tests.log`,
`/tmp/training-settings-native.log`, `/tmp/training-settings-final-gates.log`.
Local documentation links resolve. Windows/macOS native checks and the remaining
Training/source-identity and whole-renewal gates stay open; this is a completed
settings simplification, not whole-feature graduation.

## Course enrichment consolidation

Source `78bf01f0`, based on `a4c00606`, removes **119 handwritten production
lines (+97/−216)**, with no generated changes or new production files. The
complete 12-file caller/probe/composer scope falls **4,396→4,277** (11 surviving
files). It includes `core/generation_{session_controller,session_types,run_summary}.dart`,
`services/generation/engine_tail.dart`, and the course builder, retired runner,
refutation prober, master improvements, model-game selector, composer, chapter
titles and opening namer. All changed production files are inside this scope.
The session controller itself falls **1,453→1,414**; the builder grows **319→365**
as it absorbs the runner's live work, while the 126-line runner disappears.
No dormant or unrelated deletion subsidizes this reduction.

The final path is session → existing course builder → existing probes/composer →
local course/count result → publication → summary. Previously the session also
constructed a runner with config/warmup callbacks, maintained its count-map reset
lifecycle and mirrored outline, note and count values. Those retained fields and
forwarding APIs are deleted; counts now derive from the pass results. Retirement
lint rejects the runner path and its three types. No replacement owner or
compatibility export is introduced. The pure summary module retains its count
record alias; it does not import the engine-bearing builder just to share a type.

Design review fixed pass order and failure semantics before parallel production
and test work. Refutations, alternatives, engine tails and improvements still run
in that order. Disabled, engine-free and cancelled passes skip preparation;
preparation errors fail export. Engine startup and probe failures remain best
effort, allowing later passes to run. A cold pool uses the captured config's
thread budget, and each pass/model selection reads the same live database
suppliers as before. Publication acknowledgement precedes Builder adoption;
uncertain writes, receipt-reconciliation notes and cancellation after saving
retain their previous outcomes. Independent production/test review found no
outstanding issues.

**Checks.** All **243 distinct focused tests pass** (31 publication/course/summary/
artifact cases plus 228 course/probe/verifier/session/publication cases, with 16
course-builder cases overlapping). The final 31-case run repeats after analyzer
repairs to test-only constructor/braces; no behavioral assertion was weakened.
The Linux native admission/publication suite passes **both cases** on a private
display and disposable profile: changed/ABA sources are rejected, and the actual
configuration route's controller/receipt receiver publishes a bounded completed
tree while preserving the old PGN and refreshing the open document. The positive
case calls `startBuild` directly; it does not certify a positive Start-button
click, native enrichment probes or network generation. Four-pass algorithm/output
coverage uses the existing fake engine boundary and real probes/composer.

Final analyze/lint passes: **64 pre-existing infos, no warnings/errors**, all 45
architecture-checker tests and the retirement/debt/theme/mutation/rule gates.
The first analyzer run found an unused optional test constructor parameter and
two new brace-style infos, repaired before the passing run. Logs are
`/tmp/course-enrichment-{tests,publication-tests,native,gates}.log`.
Updated local documentation links resolve. No live preview remains.

Whole library Dart is **227,716 lines / 994 files**, including **5,361 generated**
lines. Handwritten code is still **3,398 above September 16**. This reduction
establishes a simpler enrichment responsibility, not a simpler whole Generation
feature: its controller remains 93 lines above that historical baseline. Feature
status remains **6 enforced, 14 unfinished, 0 complete**; milestones 6–7 are still
not started. Windows/macOS native checks and whole-renewal acceptance remain open.

## Builder line-table and Viewer collection-load consolidation

Source `e64320ce`, based on `142b45cc`, completes two separately reviewed
responsibilities. The discovery review rejected Study's remaining small callback
moves: its save queue and projection caches still serve distinct correctness and
large-document requirements. Neither admitted change introduces a new owner,
interface, callback holder or compatibility export.

**Builder.** The existing browser owns filtering, sorting, indexes and scrolling
and now renders its own list/header. The sole-consumer `LinesListPanel` and private
`_TableHeader` forwarded 22 and four inputs respectively without owning state.
Their constructors/fields/call-site bindings are deleted; existing row/header
cells, coverage prompt and all filtering/metric algorithms remain. Independent
review caught a lazy-delegate capture difference; the renderer now captures its
list, widget and three index maps together, preserving the old snapshot's row
count, values and callbacks after parent replacement. A focused regression
exercises that retained delegate. No dormant dialog, navigation-stack or theme
code was removed for size credit. Removing the deleted widget's theme-ledger
entry is not a theme migration; its colors remain in the browser.

The complete 13-file graph contains the Builder screen and its three parts,
`repertoire_lines_browser.dart`, the deleted panel, `line_item_row.dart`,
`line_table_layout.dart`, `line_filter_controls.dart`, `line_metrics_panel.dart`,
`lines_filter_helpers.dart`, `coverage_helpers.dart` and `line_metrics_helpers.dart`.
It falls **5,324→5,219 (−105 handwritten lines)**; browser growth **420→630**
includes all moved rendering, while the 315-line panel disappears.

**Viewer.** The document owner now handles request admission → repository read →
decode/stat → replacement authorization → adoption/restoration. The injected
repository and isolate decoder remain the external boundaries. The private load
controller, success/failure wrappers and intermediate result translation
are deleted. There was one underlying request epoch before and after: it moves
from the loader into the existing adopting owner, removing proxy/dispose wiring
and the extra request invalidation. File/text/close/recovery invalidation, error
messages, leading banners, captured baseline/mtime, post-read draft protection
and saved-filter/reading restoration retain their contracts. Disposed/inactive
lifetimes reject before I/O; synchronous close during loading notification also
invalidates the request before opening a file.

Its complete 14-file graph contains document/retired-load/collection/reading/filter
controllers, the decoded collection model, repository/decoder contracts and both
adapters, Viewer lifetime and the Viewer screen with app-bar/panes parts.
It falls **5,308→5,207 (−101 handwritten lines)**. The document grows
**936→956**, while the 95-line loader and 26 model/import lines disappear.
All original read/decode safety cases move to tests of the actual adopting owner.

**Checks.** All **163 focused tests pass**: 72 Builder browser/layout/filter/metric/
screen cases and 91 Viewer load/revision/restoration/selection cases. Five new
browser tests exercise actual header/row actions, debounce/reset, retained lazy
delegates, coverage prompts and delete confirmation/cancellation. All nine old
loader cases move to the actual document owner, with six additional metadata,
lifetime, reentrant-listener and dirty-draft cases. No failures or skips remain.
Independent source/test review approved both final implementations.

All **three Linux native journeys pass** on private displays and disposable
profiles: Builder annotations/save/reload/layout plus real metrics search/reset;
Viewer file-order sorting/navigation/reopen; and saved-filter/selected-game
restoration and clearing without changing PGN bytes. The inspected
[Builder metrics screenshot](images/renewal-builder-line-metrics.png) shows the
retained list/header/filter layout. No visible user session or real databases
were used, and no preview remains running. Final analyze/lint passes with
**64 pre-existing infos, no warnings/errors**, all 45 architecture-checker cases
and the retirement/debt/theme/mutation/rule gates. Logs:
`/tmp/browser-consolidation-tests.log`, `/tmp/viewer-load-consolidation-tests.log`,
`/tmp/browser-load-consolidation-{gates,native}.log`. Updated document/image links
resolve. The active plan removes 26 redundant historical result rows whose source
commits already have detailed evidence here; unmet reduction and completion gates
remain explicit.

Together these changes remove **206 handwritten production lines (+311/−517)**,
with no generated changes or new production files. Whole library Dart is now
**227,510 lines / 992 files**, including **5,361 generated** lines. Handwritten
code remains **3,192 above September 16**. Exact architecture debt remains 1,229;
theme-ledger paths fall 181→180 only because the forwarding widget was deleted.

Both changes simplify their own complete workflow scopes; no unrelated deletion
subsidizes either result. Whole Builder/Viewer and the renewal remain Partial.
Feature status remains six enforced, fourteen unfinished and zero complete;
Windows/macOS native acceptance and milestones 6–7 remain open.
