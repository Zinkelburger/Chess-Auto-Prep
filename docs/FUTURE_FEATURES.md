# Future Features

**Backlog only — not current-state documentation.** For what exists today, see [`COMPONENT_MAP.md`](COMPONENT_MAP.md).

Consolidated list of planned or incomplete capabilities (from `tree_builder/TODO_cloud_evals.md` and gap analysis vs `lib/`). Many foundation pieces from earlier design docs are already shipped; this file lists what is **still missing or incomplete**, de-duplicated and ordered by priority.

**Legend**

| Status | Meaning |
|--------|---------|
| **Not started** | No meaningful implementation in `lib/` |
| **Partial** | Core exists; UX or edge cases remain |
| **Deferred** | Explicitly postponed or open product question |

---

## Architecture renewal and eventual replacement

**Status: Not started.** Planning baseline: 2026-09-16. This is a proposed
destination and migration sequence, not a description of the current app or
authorization to publish a release. Existing foundation code can be retained
when it satisfies the new contracts. No package migration is implemented by
this plan. The smaller backlog below remains valid; renewal does not silently
remove features or mark old proposals as shipped.

### Outcome and scope

Make the entire first-party application understandable, testable and consistent:
each workflow has a clear owner, each datum has one authoritative writer, and
each recurring interaction uses a documented component. Every existing module
will eventually be reviewed, moved, replaced or explicitly retired. A complete
architectural replacement does not require retyping correct algorithms or
rewriting third-party chess engines and libraries.

Deliver complete workflows incrementally in the existing product. Keep at most
one feature slice actively migrating until the first two slices establish a
repeatable method. Temporary legacy adapters have named callers, contract tests
and an explicit removal milestone. They must not become a second permanent
architecture. The working application and its data remain usable throughout.

The capability inventory must cover all current modes: Tactics, Player analysis,
Repertoire builder, Repertoire trainer, PGN Viewer, Study, Engine tournament,
Bughouse lab, Databases, Repertoires, and Players & prep. Also inventory accounts,
settings, OS file opening, navigation history, imports/exports, background work,
recovery, offline behavior, optional assets, installers and updates. Include
first-party MCP/offline tools and their shared-file contracts in the migration
review; do not rewrite their runtime merely to match Flutter folders.
Use [the component map](COMPONENT_MAP.md) and actual code as starting evidence;
historical documentation and existing tests are not unquestionable specifications.

### Engineering principles and useful abstraction

Knuth's literate-programming emphasis is on programs understandable to people.
The following are this project's practical interpretation, combined with modern
software-engineering practices; they are not a purported canonical list of
"Knuth principles" or a requirement to adopt WEB/CWEB.

- Explain the problem, representation, invariants and reason for a non-obvious
  algorithm close to the code. Include a small worked example where it makes
  the reasoning inspectable. Comments should explain decisions, not paraphrase
  assignments. Keep long algorithm explanations in [ALGORITHM.md](ALGORITHM.md).
- Choose data structures deliberately. Document units and score perspective,
  ordering, identity, ownership, mutation rules and expected complexity where
  relevant. Use names such as `DocumentRevision` and `Centipawns` when they
  prevent real mistakes; do not wrap every primitive reflexively.
- Establish correctness before clever optimization. Measure realistic workload
  time, allocation and memory; optimize demonstrated bottlenecks. Keep a simple
  reference implementation or invariant tests for optimized algorithms.
- Abstract a coherent concept or external boundary. A repository exposes
  `renameChapter` or `saveDocument(expectedRevision: ...)`, not a bag of generic
  database operations. Extract collaborators with their own responsibilities
  instead of splitting one oversized class across files.
- Prefer composition and explicit constructors. Add an interface when it
  isolates an external dependency, protects a domain boundary or supports a
  meaningful alternate implementation. Avoid generic base controllers,
  all-purpose managers, global event buses and widget APIs with many unrelated
  Boolean switches.
- Keep feature-specific code local. Share concepts when their semantics and
  lifecycle match, rather than extracting visually similar snippets too early.
  Each concept has one canonical type and import path after migration.
- Optimize for a maintainer tracing one user action. A reviewer should be able
  to identify its state owner, persistence boundary, failure behavior and tests
  without following a chain of pass-through classes.

### Target layout and dependency rules

Proposed paths are relative to the repository; adopt them for migrated slices,
and update the canonical Dart/UI guides and their generated references when
implementation starts. Until then, current placement rules remain in force.

```text
lib/
  app/                    # startup, dependency wiring, routes, app lifetime
  design_system/          # theme, design values, controls, layout primitives
  diagnostics/            # narrow logging/failure contracts, no vendor SDK
  chess_core/             # pure Dart chess concepts and algorithms
  infrastructure/         # filesystem, SQLite, HTTP, engine-process adapters
  features/
    repertoires/
      models/             # feature values and validated state
      controllers/        # actions and presentation state
      repositories/       # domain-facing contracts and data orchestration
      widgets/            # screens and feature-specific composition
    training/
    analysis/
    ...
widgetbook/               # developer catalog using production widgets
test/                     # mirrors ownership; shared contract fixtures
```

Start with directories, not a separate package for every feature. Extract a
pure Dart package only when shared CLI use or enforceable isolation warrants
it. Do not create a new catch-all `core` or `utils` directory.

A separate internal Flutter package for the design system is an option after
the first catalog proves its API. Its dependency graph must exclude the app and
features; package boundaries still need import enforcement. Keep contracts near
the concept they serve: repository contracts with their domain, diagnostic
contracts in `diagnostics/`. Add a common result type only when callers share
its semantics, rather than creating a miscellaneous directory of interfaces.

Dependencies follow these rules:

1. App startup constructs infrastructure, repositories and state owners and
   injects them. Singleton access is confined to the temporary legacy bridge.
2. Feature widgets use their controllers, models and the design system. Shared
   design-system widgets receive values/callbacks, never feature repositories.
3. Controllers call repository contracts or substantial workflow collaborators.
   They do not open files, execute SQL, start processes or depend on widgets.
4. Repositories orchestrate domain data through injected adapter contracts.
   Concrete infrastructure implementations are selected at app startup.
   Cross-feature workflows use explicit public contracts; dependency cycles
   and imports of another feature's private controller state are rejected.
5. Chess core and domain values do not depend on Flutter, Riverpod or concrete
   I/O. File-format codecs and transport models stay at their boundaries unless
   their representation is itself a domain concept.

Use immutable feature state and explicit alternatives such as idle, running,
failed, cancelled and completed. Keep widget-local focus/hover state local.
Document state belongs to a document session; persisted entities belong to a
repository; application jobs belong to an app-lifetime job service. Screen
navigation must not accidentally cancel an ongoing import or retain an unused
interactive engine. Define cancellation, progress, resource limits, shutdown
and stale-result rejection for each job type. Reuse existing lifecycle and
RunControl behavior until the replacement passes its contract tests.

Riverpod may compose dependencies and expose repository streams as well as own
presentation state. It is never a second durable source of truth: repositories
own persistence through the appropriate document, database or preference adapter.
Controllers translate user intent into repository/workflow calls; JSON parsing,
SQL execution and isolate/process supervision belong behind those boundaries.

### Package decisions

Resolve stable, SDK-compatible versions at implementation time. Every adoption
records the code it replaces, desktop support, transitive dependencies, license,
maintenance status, code-generation cost and a focused validation result.

| Decision | Proposed choice and acceptance condition |
|----------|-------------------------------------------|
| Component catalog | Widgetbook first; production theme and controls, isolated fixtures, no engine/network/account initialization. Local development use does not require cloud hosting. |
| Visual checks | Flutter widget/golden tests; trial Alchemist for scenario organization. Use readable text with bundled fonts on a pinned Linux baseline, plus native platform checks. Obscured-text goldens alone cannot validate typography. |
| State and dependency composition | Riverpod is the preferred candidate for migrated presentation state. Prove disposal, test overrides, retry behavior and app-owned jobs in one slice before committing to broad conversion. Keep domain/repository contracts framework-independent. |
| Database | Trial Drift for ordinary structured metadata/progress, with migration fixtures and measured large-data behavior. Existing SQLite schemas and specialized master/eval stores remain authoritative until separately migrated. |
| Models | Freezed and json_serializable where they remove substantial boilerplate; plain Dart sealed classes/records for small types. Generated code never replaces input validation or format versioning. |
| Files | Consider package:file inside adapters for deterministic tests. Retain real OS tests for locks, symlinks, atomic replacement and interrupted recovery. |
| Network | Evaluate Dio behind API-specific clients; preserve rate limits, streaming and authentication behavior. One retry policy per operation; never retry a mutation blindly. Keep http if it already meets the contract more simply. |
| Navigation | Evaluate go_router with go_router_builder for typed internal navigation against retained document sessions, Back behavior, external PGN opening and deep links. External URLs and missing/deleted IDs still need runtime validation. A route identifies a destination; it does not own an engine job. |
| Diagnostics/testing | Standardize logging behind one interface; consider clock and mocktail where useful. Use structured run IDs, stages and error causes, with token redaction and bounded log retention. |

Do not run Provider, Riverpod and Bloc as competing permanent choices. Riverpod
3's experimental persistence/mutation APIs are not the foundation for durable
user data. Native isolates and engine processes remain explicit infrastructure;
do not introduce mobile background schedulers for desktop analysis work.

Prefer Riverpod generation if the slice already uses a validated Freezed/JSON
generation pipeline and the readability benefit justifies its build cost;
manual typed providers are also supported. Record one convention for migrated
code. Generated auto-disposal is a default, not proof of correct lifetime:
explicitly test screen departure, retained documents, active jobs and disposal.

### Early desktop foundations

These requirements extend milestones 0-2; they must not wait until the final
platform sweep. They are planned work, not claims that signing, telemetry or
translation support already exists.

**Localization readiness (milestone 1).** Start with Flutter's standard
`flutter_localizations` and `gen_l10n`/ARB workflow unless a measured requirement
justifies an alternative. English is the initial source locale; translating
other languages is separately scoped. Migrated user-facing copy, validation,
tooltips and accessibility labels use localized messages with typed placeholders
and plural rules. Design-system controls accept resolved labels from callers.
Use locale-aware UI numbers/dates and directional layout; exercise expanded
pseudo-localized text and RTL in the catalog. Keep PGN/FEN, engine protocols,
stored IDs and canonical formats locale-independent, and preserve the chess
board's explicit orientation rather than mirroring its rules with UI direction.

**Native execution contracts (milestones 0 and 2).** Inventory each engine,
FFI library and native plugin, including architecture/ABI, packaging, memory
ownership, thread affinity, callbacks, initialization, shutdown and license.
Generated bindings and process wrappers live in `infrastructure/`; an adapter
owns handles, buffers and disposal. Use worker isolates or appropriate native
workers for blocking/CPU-heavy calls, respecting library threading constraints.
An asynchronous `Process.start` wrapper does not inherently need a Dart worker:
the executable already runs separately. Bound stdout/stderr buffering and move
expensive protocol parsing off the UI isolate when measurements warrant it.
An isolate cannot contain a fatal in-process native crash. Prefer existing
subprocess engine boundaries when crash isolation matters. Specify cooperative
cancel, graceful stop, timeout escalation and disposal for every backend; do
not report cancellation as complete while native work still owns resources.

**Failure diagnostics (milestones 0 and 2).** Define a vendor-neutral reporting
contract and a per-platform coverage matrix for Flutter errors, unhandled Dart
errors, worker-isolate failures, app-native crashes and child-engine exits.
Forward worker errors explicitly; retain engine identity, job ID, exit status
and bounded diagnostic output in the supervisor. Sentry is a candidate, subject
to verifying native support and symbolication on each actual desktop target.
Installing its Flutter SDK does not automatically produce native crash dumps
for independently launched Stockfish or other executables. Retain matching
release symbols/build IDs and prove a deliberately induced failure is useful
to diagnose. Provide bounded local diagnostics and user-controlled export;
remote reporting requires an explicit product/privacy decision, redaction,
retention limits and offline behavior. Do not enable a remote service as part
of a dependency-only change.

**Build and distribution rehearsal (milestones 0 and 2).** Inventory host
builders, native dependencies, certificates/accounts and release artifacts in
milestone 0. Build/package the first new slice on Linux, Windows and macOS and
smoke-test a small real-engine job with disposable data, cancellation and restart.
Exercise install/launch/update and native-library loading early. For the intended
signed macOS distribution, plan Developer ID signing, appropriate entitlements,
notarization and stapling, including embedded native code. For Windows, select
a suitable trusted signing route; an EV certificate is not a universal app
requirement or a guarantee of no SmartScreen warning. Keep credentials out of
source and ordinary test jobs. Mark unavailable host/signing checks explicitly
unverified, and complete actual signed-artifact checks before the corresponding
release. Preserve release-tag-only GitHub CI and user-requested publication;
rehearsing builds does not authorize publishing or buying signing credentials.

Keep existing `integration_test` and headless driver coverage, and extend real
desktop journeys rather than assuming a new runner is necessary. Native OS
dialogs, signing and installers need host-specific checks beyond Flutter widget
automation. Patrol can be evaluated for a supported target, but its currently
listed targets do not include Linux or Windows, so it is not the default
three-desktop test harness.

### Frontend principles: human factors as acceptance criteria

Start with user tasks and observed difficulties, not a component shopping list.
Use consistent chess vocabulary and visible context: current game/repertoire,
side, board orientation, selected line, active filters, data source and save
state. Avoid exposing architecture vocabulary in ordinary product controls.

| Human-factors concern | Design requirement | Evidence before a slice graduates |
|-----------------------|--------------------|----------------------------------|
| Working-memory load | Keep the board, relevant moves and current task context available; preserve selection and filters across navigation. Prefer recognition through visible choices and recent destinations. | Complete a task, leave it, and resume without reconstructing context. |
| Perception and visual hierarchy | Use semantic color/typography/spacing tokens, proximity for grouping, consistent alignment and restrained emphasis. Essential state has text or shape as well as color. | Inspect real data, long labels, disabled states and error states in Widgetbook. |
| Action discoverability | Label important actions, show shortcut hints, give controls clear affordances and visible focus. Hover previews have focus/click equivalents. | Keyboard-only completion and focus-order checks; no essential hover-only action. |
| Motor effort and accidental activation | Provide comfortable hit areas and spacing, keyboard alternatives, and deliberate placement of destructive actions. Keep controls stable when progress text changes. | Pointer, keyboard, window-scaling and long-text checks on desktop. |
| Feedback and trust | Distinguish unsaved, saving, saved, failed and conflicted. Report job phase and progress; show indeterminate progress when totals are unknown. | Slow/failing storage and jobs remain understandable without false completion or invented ETA. |
| Error prevention and recovery | Validate before committing, preserve drafts, explain conflicts, support undo/quarantine where meaningful and make recovery actionable. | Inject a failed save, cancel work, undo a supported action, and recover after restart. |
| Expert efficiency | Keep common actions direct; use progressive disclosure for advanced options without hiding current values or critical state. Standardize shortcut scope and text-entry guards. | Compare common-task steps and completion time with the baseline; test shortcuts while typing. |
| Accessibility and adaptability | Use semantic labels, readable contrast, text scaling, reduced motion and layouts that reflow or scroll appropriately. Preserve a legible board/movetext relationship. | Semantics tests, contrast checks, 100/150/200% text-scale cases and native assistive-technology smoke checks. |

Use WCAG 2.2 as an accessibility design/testing reference, not as a claim that
a Flutter desktop app is automatically web-conformant. Translate web CSS-pixel
guidance into verified desktop logical hit areas; retain the current 12px UI
type floor and prefer comfortable body text above it. Check actual target
spacing, contrast and platform scaling. Historical HTML wireframes are
inspiration, not a second authority for production fonts or tokens.

Evaluate representative scenarios with the user and, when feasible, chess
players unfamiliar with the app. Record completion, assistance, mistakes,
recovery, time and perceived effort. Scripted UI tests and heuristic review
cannot substitute for observing a person. Set numerical targets after measuring
the baseline; do not invent improvement percentages or count clicks as the
only measure of usability.

### Visual direction: a calm, responsive dark workspace

**Status: Not started.** The rewrite should feel clean, modern, minimal and
pleasant to operate. Treat these as reviewable product qualities alongside
correctness. Preserve information needed for chess decisions and visible
affordances when simplifying a screen. Removing decoration should not require
users to memorize hidden commands or open menus for every common action.

The proposed direction is a quiet charcoal workspace with clearly separated
surfaces, comfortable typography, restrained accent color and crisp feedback.
The board, moves and user's current task receive visual priority. Establish
the direction in milestone 1 before rolling it across feature migrations.

| Concern | Proposed design contract |
|---------|--------------------------|
| Dark surfaces | Give workspace, panel, input and floating surface explicit semantic roles. Tune a small set of neutral tones together; use tonal separation and selective outlines where shadows are insufficient. Start from existing AppColors/ColorScheme rather than inventing screen-local palettes. |
| Readability | Use legible foreground and secondary text on every actual surface. Test ordinary text at at least 4.5:1 contrast, with stronger contrast for small text where practical. Muted labels remain readable; opacity stacking must not silently erase contrast. |
| Accent and meaning | Choose one principal interaction accent after comparing prototypes. Keep error/success/warning and chess evaluation colors semantically separate. Selected, hovered, focused and disabled controls need distinct treatments beyond hue alone. |
| Composition | Use a consistent spacing scale and alignment. Prefer grouping and whitespace to repeated card-inside-card borders. Keep forms at readable widths and let analytical workspaces use available space. Avoid making every number, chip and action equally prominent. |
| Typography and symbols | Retain a compact type hierarchy and one icon family. Align numerical columns and use tabular figures; moves/FEN use the shared mono style. Keep important actions labelled and make tooltips supplementary. |
| Board and data | Validate both piece colors on both square colors, coordinates, last-move highlights, arrows, selection and evaluation graphics against the surrounding dark UI. Check user-selected board themes and dense tables, not just empty mockups. |
| Interaction feel | Every actionable component has designed rest, hover, pressed, keyboard-focus, disabled and busy states. Provide immediate acknowledgement, stable geometry and predictable focus return. Loading indicators must describe actual work and never imply that an uncommitted save succeeded. |
| Motion and delight | Use short transitions to connect actions with outcomes: selection changes, opening a panel, dropping a piece, completing a training step. Reuse AppMotion timings as a starting point and tune through interaction tests. Respect reduced motion and keep repeated training input responsive. |
| Pleasant details | Give a valid drop a clear landing response; make a completed exercise feel resolved; show a compact copy acknowledgement; reveal useful previews without changing the committed position. Avoid repeated modal praise, compulsory sound or decorative motion that interrupts concentration. |

Dark appearance is a design preference, not a universal claim of reduced eye
strain. Inspect the actual app on ordinary displays in both dim and bright
rooms, with platform scaling and larger text. Large bright surfaces and dense
low-contrast gray text both need deliberate review. Ensure diagrams and images
remain legible; do not invert chess piece assets or illustrations automatically.

Milestone 1 should include this visual-design loop:

1. Build two restrained visual treatments of the same repertoire task using
   real-looking long names, counts, selection and error states. Compare density,
   surface separation and accent treatment without changing the task itself.
2. Review the alternatives with the user in a clickable prototype, including
   keyboard use. Choose one direction and record the decision here before
   migrating its appearance across the app.
3. Encode the selected values in the production theme and reusable components.
   Include interactive examples for the state combinations above in Widgetbook.
   The catalog consumes production code; it must not maintain prettier copies.
4. For each migrated screen, review an actual workflow with representative data,
   a narrow window, enlarged text, failed/slow work and repeated clicks. Check
   task clarity and interaction feel as well as screenshots. Record usability
   findings and fix shared causes in the component/theme owner.

Use these references for complementary purposes. The reading shortlist is
based on author/publisher descriptions and publicly available material; book
recommendations do not imply that their complete paid texts have been reviewed.

- **[Refactoring UI — Adam Wathan and Steve Schoger](https://refactoringui.com/):**
  primary practical visual-design reference for hierarchy, spacing, typography
  and finishing details. Its web examples need adaptation to desktop chess
  workflows; it is not a dark-mode-specific standard.
- **[Don't Make Me Think, Revisited — Steve Krug](https://sensible.com/dont-make-me-think/):**
  usability companion for understandable navigation and evaluating whether
  people can identify and complete the next action.
- **[Microinteractions — Dan Saffer](https://www.oreilly.com/library/view/microinteractions/9781449342760/):**
  reference for the small interactions that make controls feel responsive and
  satisfying, complementing whole-workflow usability evaluation.
- **[Apple Human Interface Guidelines: Dark Mode](https://developer.apple.com/design/human-interface-guidelines/dark-mode)**
  and **[Flutter ColorScheme](https://api.flutter.dev/flutter/material/ColorScheme-class.html):**
  free dark-appearance and implementation references. Use semantic colors,
  legible assets and tested surface contrast; preserve desktop platform
  conventions without mechanically copying another platform's visual effects.

### Presentation experiments without data-model churn

**Status: Not started.** Revisit how expectimax, generated lines, chapters,
saved analysis and training sources are explained and arranged. Their present
labels, tabs and folder-shaped navigation are not a product specification for
the rewrite. Test alternative task flows before committing to terminology or
layout; retain accurate score meaning, source identity and save behavior.

- Keep domain operations and data identities stable while changing their
  presentation. A chapter's display name, panel location or UI grouping must
  not become its persistent identity. Renaming a concept on screen must not
  implicitly rename files, rewrite PGN tags or move training progress.
- Give UI collaborators immutable presentation models and narrow commands such
  as preview, start analysis, cancel, save a selected result and open a document.
  They must not infer storage operations from label text, tab indexes or paths.
- Provide Widgetbook/full-workflow fixtures for empty, existing, running,
  completed, stale, failed and conflicted data. Multiple visual prototypes
  consume the same fixtures and command contracts with fake repositories.
- Lower-cost models can explore copy, layout and interactions within that
  sandbox. Persistence, concurrency, score interpretation and migrations remain
  separately reviewed engineering work. Any prototype command wiring receives
  real integration checks before it becomes production UI.
- Compare at least two representations of the same task, such as inspecting a
  suggested continuation and saving it into a chapter. Show the user clickable
  alternatives and assess comprehension, effort and recoverability. Record the
  selected direction and retire rejected prototypes; avoid permanent duplicate
  navigation modes or configurable layouts without a demonstrated need.

This expands milestone 1's prototype work and milestone 5's analysis UX. A
visual redesign can be substantial while the repository/storage contracts stay
unchanged. UI experimentation does not authorize changes to persisted data.

### Data preservation and coexistence

Use [DATA_INTEGRITY.md](DATA_INTEGRITY.md) as the starting safety contract.
Inventory every persisted format and distinguish user-authored documents,
authoritative structured records, credentials, preferences and rebuildable
caches. Record external tools/readers, stable IDs and references, schema versions,
file locations and migration ownership. Work only on disposable copies during
automatic validation; never inspect or migrate the user's real databases as a
test fixture.

- Initially keep formats and the existing storage adapters; changing UI/state
  architecture does not require changing the on-disk format simultaneously.
- Give each document/data domain exactly one writer. Route old and new entry
  points through that owner. Shadow comparisons are read-only; never dual-write
  real user data to old and new persistence implementations.
- For necessary format changes, copy/stage, validate counts, identities and
  content, then switch the authority with a recoverable commit point. SQLite
  transactions cannot atomically commit unrelated filesystem writes; use an
  explicit publication/recovery protocol for cross-store operations.
- Preserve PGN comments, variations, NAGs, unknown headers, line identities and
  progress references. Compare verbatim bytes where required and semantic
  equivalence only where normalization is intentional and documented.
- A rollback must preserve work created after migration. Once formats diverge,
  implement a tested reverse/export path or make the old reader refuse the
  unsupported schema. Restoring an old snapshot alone loses new work and is
  not an acceptable rollback procedure.

### Storage baseline and overwrite-prevention gate

**Status: Not started.** The following is a code-inspection baseline from
2026-09-16, not a completed safety audit or a claim that the identified paths
have been repaired. This planning pass did not open the user's databases,
modify PGNs or run application safety tests. Build the full ownership inventory
in milestone 0 and reproduce/fix the relevant risks before each slice graduates.

| Data | Current representation and ownership evidence | Rewrite requirement |
|------|-----------------------------------------------|---------------------|
| Repertoires and chapters | Documents `repertoires/` folders with chapter PGNs; `ChapterStore` creates files with `createOnly`. Studies use multi-chapter PGNs in Documents `studies/`. | Keep user-authored text, annotations and stable references; separate user-visible grouping from physical storage decisions. |
| User/source games | Support `app_games.db`, with collection-scoped games and position indexes. Some tactics source games have no remaining standalone PGN copy. Player-analysis PGN generations also have an authoritative manifest. | Classify authority per collection; never treat the whole database or Support directory as disposable merely because some indexes can be rebuilt. |
| Analysis/build artifacts | Chapter-adjacent tree, partial-tree, expectimax and trap JSON, plus a model-games PGN companion, are owned by `GenerationArtifactStore`. | Track document revision, run/config identity and publication state. Expensive saved analyses and resumable work need an explicit retention policy; user edits to a companion PGN cannot be silently discarded as cache. |
| Training state | Review/progress/history CSV files and their document/line references are covered by existing migration and concurrency protections. | Preserve scheduling/history and reference identity through chapter rename, move, split and import. Inventory all newer stores as well as legacy CSVs. |
| Recovery and upgrades | Atomic-write journals/backups, quarantined files, PGN recovery snapshots, SQL `game_trash`, and schema-upgrade backups serve different recovery purposes. | Define retention, restore and user-export behavior for each; do not equate temporary atomic replacement with a permanent version history. |

The shared atomic writer already supports exclusive creation, expected-content
checks, locked read/modify/write, and interrupted-write recovery. Those protect
only callers that use the correct operation. An atomic replacement can still
atomically install stale content over a newer edit.

Specific call sites to reproduce and resolve in the implementation phase:

| Inspection finding | Failure scenario to test | Required behavior |
|--------------------|--------------------------|-------------------|
| `RepertoireController.setRepertoireColor`, `setRootPosition` and `importPgnContent` read content then call `writeFile` without `expectedContent`. | Another writer commits between the read and replacement. | Apply a narrowly scoped change to current content under the storage transaction, or reject a stale revision without replacing the newer document. |
| `RepertoireWriter.undo` removes its undo entry and writes a previous whole-document snapshot without an expected revision. | A later annotation/import changed the file, or writing the undo fails. | Bind undo to document/session identity and the revision it reverses; preserve unrelated edits or report conflict. Keep recoverable undo state until the write commits. |
| Generation artifacts include a replaceable `_model_games.pgn` companion and independently written analysis files. | Regeneration encounters an edited companion, or a crash/stale run leaves artifacts from different revisions. | Distinguish generated ownership from user edits, validate run/document identity at commit, and expose recoverable or stale output rather than replacing newer work. |

These are observable code patterns and plausible failure cases; they are not
proof of which incident the user previously experienced. Review exports, Save
As, study saves, generation completion, chapter moves and database imports too;
the three examples are not an exhaustive inventory.

Before accepting a replacement storage path, require disposable-fixture tests
for: concurrent creation of the same name; stale editor save; two app writers;
failed decode; interrupted replacement/rollback; undo after another edit; queued
save after switching chapters; generation finishing after its source changes;
destination collisions; and failed migration or database/file publication.
Assert preservation of original and newer content, comments/variations/unknown
headers, stable IDs and progress, with truthful unsaved/conflict state. Test
both semantic round-trips and exact text preservation where the contract needs
it. Only a committed save may clear dirty state or announce completion.

Stage derived results separately from source documents. Default generated output
to a new owned artifact; replacing an existing user document must be an explicit
operation checked against its current revision, with a recoverable prior version.
Audit generic overwrite APIs so migrated document callers must select create,
revision-checked replace or atomic update. UI prototypes cannot bypass them.

Backup and restore are part of this gate: test a consistent SQLite snapshot
including committed WAL data, the associated authoritative PGNs/manifests and
references, then restore into an empty disposable profile. A database transaction
does not commit filesystem changes, and app locks cannot force arbitrary external
editors to cooperate. Preserve revisions/recovery copies and document those
limits rather than promise that atomic writes alone eliminate every loss mode.

Implementation evidence lives in [DATA_INTEGRITY.md](DATA_INTEGRITY.md). Starting
code references: [storage operations](../lib/services/storage/io_storage_service.dart),
[atomic writer](../lib/utils/atomic_file.dart),
[repertoire controller](../lib/core/repertoire_controller.dart),
[undo writer](../lib/core/repertoire_writer.dart),
[chapter creation](../lib/features/repertoire/services/chapter_store.dart),
[game store](../lib/services/game_store/game_store.dart),
[generation artifacts](../lib/core/generation_artifacts.dart) and
[schema guards/backups](../lib/services/storage/schema_guard.dart).

### Milestones and exit gates

All milestones are **Not started**. Each row yields a reviewable result; later
rows depend on the contracts established earlier, not on an unbounded framework
build. Reorder later feature slices after the dependency inventory, with a
recorded reason. No current mode is silently dropped.

The implementing agent must revisit the storage baseline against the code at
the time of implementation, turn the overwrite-prevention cases above into
passing regression evidence, and report any unresolved cases explicitly. This
is a required acceptance gate for every slice that writes user data, including
UI work that introduces or changes save/import/generate/undo commands. Planning
entries and visual approval are not evidence that data safety has been tested.

| Milestone | Deliverable | Exit gate |
|-----------|-------------|-----------|
| 0. Inventory and baseline | Workflow/parity matrix, persisted-format ownership map, dependency/native-runtime map, desktop build/signing prerequisites, diagnostic coverage matrix, representative fixtures, known-bug decisions, performance and usability scenarios. | Every current mode/support capability has an owner, migration disposition and observable acceptance scenarios. Known bugs are separated from behavior to preserve; unavailable host/credential checks are explicit. |
| 1. Design foundation | Widgetbook with production search/choice/stepper/stat/dialog components; typography, spacing, focus, error and progress examples; localization-ready copy and a small theme/component cleanup. | Catalog runs headlessly without user data or real jobs; controls work with keyboard, long/pseudo-localized text, RTL and scaling; approved visual baselines and behavior checks pass. |
| 2. First complete slice | Repertoires: list/search, create, rename, open and recoverably delete, using injected repository contracts and an explicit presentation-state owner. Keep current storage formats. Rehearse desktop packages, native execution and failure diagnostics. | Old/new entry points share one writer; conflict, failure, restart and navigation tests pass; user can complete the task; duplicate implementation removed. Record Riverpod/abstraction decisions and host/diagnostic verification from evidence. |
| 3. Document workspace | PGN viewing/editing, study/chapter management and board/move navigation; shared document sessions and reusable workspace components. | Representative annotated PGNs round-trip; unsaved edits survive failures; undo, external-file conflict, Back/context restoration and large-document performance pass. |
| 4. Training | Repertoire training, tactics, review scheduling/history and game-review handoffs on stable document/line identities. Trial a progress-storage migration only as a separate increment. | Historic progress fixtures migrate without loss; time-dependent scheduling and cancelled sessions are deterministic; complete training/resume scenarios pass. |
| 5. Analysis and long jobs | Interactive analysis, generation/planning, audit/holes/traps, player analysis and database ingestion use explicit job ownership and resource policies. | Deterministic core invariants and differential fixtures pass; stale results cannot publish; pause/cancel/restart and engine crash cleanup pass; realistic throughput/memory budgets hold. |
| 6. Remaining workflows and platform surface | Players & prep, engine tournaments, bughouse, accounts/settings, external tools, asset discovery, packaging and updates complete the parity matrix. | Each mode has functional parity or a separately agreed redesign; shared-file tool contracts and Linux/Windows/macOS native checks pass. Missing optional assets remain handled. |
| 7. Retirement and release readiness | Remove legacy bridges, unused controllers/widgets, duplicate dependencies and obsolete schemas/readers where compatibility policy permits; update current-state docs. | No production route falls back to legacy code; all retained data is readable and recovery is tested; full release gates pass. Publishing remains a separate user-requested action. |

A module is not considered migrated because it moved folders. Each completed
slice must demonstrate the new ownership, tests, UX behavior and removal of its
superseded code. Keep the old module only when a documented compatibility need
requires it, with a removal condition and owning milestone.

### Working method, checks and sizing

For each slice, produce a short contract before coding: user task, current
entry points, state owner, repository methods, failure/cancellation semantics,
fixtures, UI examples and the old files to remove. Implement the smallest
end-to-end case, exercise failure paths, inspect it, and then widen coverage.
Record substantial choices and consequences in this section; update the
component map only when a change actually exists.

Enforce architecture with import checks and analyzer rules: no widget I/O, no
domain-to-UI dependencies, no new singleton access in migrated code and no
unreviewed control styling outside the design system. Ratchet migrated paths
first with explicit legacy scope; do not normalize violations by growing
allowlists. Code generation must be reproducible and validated for drift.

Use layered evidence: pure algorithm tests; repository contract/failure tests;
real filesystem and schema-migration fixtures; deterministic engine doubles;
widget interaction/semantics tests; selected screenshot comparisons; headless
end-to-end journeys; native platform integration and measured performance.
Compare semantic results against the old implementation where it is correct;
do not require identical nondeterministic engine output. Preserve existing
storage and engine regression tests until equivalent coverage is established.

Follow the normal task-worktree, bounded-check and automatic local-main
integration workflow. Each slice remains independently usable and backed up.
Run documentation lint/link checks for this plan; implementation requires
analyze/lint, relevant tests and headless screenshot inspection for visible
changes. Full release, offline-tool, integration and engine gates are required
before a separately requested publication; branch pushes do not run release CI.

Do not promise a calendar completion date from line count. Treat this as a
multi-milestone program; estimate after milestone 0 and recalibrate after the
first two migrated slices using measured effort, uncovered compatibility work
and user feedback. Stop expanding a slice when it needs unrelated abstractions;
record that dependency and return to the smallest usable workflow. Track
completed user journeys, removed legacy owners, data-safety evidence and UX
results rather than generated code volume or number of new classes.

### Design references

- [Flutter internationalization](https://docs.flutter.dev/ui/internationalization),
  [Riverpod generation](https://riverpod.dev/docs/concepts/about_code_generation),
  [typed routing](https://pub.dev/packages/go_router_builder),
  [Dart subprocesses](https://api.dart.dev/dart-io/Process/start.html),
  [Sentry Flutter](https://pub.dev/packages/sentry_flutter),
  [Patrol targets](https://pub.dev/packages/patrol),
  [Windows signing options](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/code-signing-options)
  and [macOS notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution):
  primary references used to qualify external architecture feedback on 2026-09-16.
- [Knuth: Literate Programming](https://cs.stanford.edu/~knuth/lp.html):
  human-readable program explanation and algorithmic reasoning.
- [Flutter architecture recommendations](https://docs.flutter.dev/app-architecture/recommendations):
  separation, dependency injection, immutable models and conditional use cases.
- [Nielsen's usability heuristics](https://www.nngroup.com/articles/ten-usability-heuristics/):
  feedback, consistency, control, recognition and recovery.
- [WCAG 2.2](https://www.w3.org/TR/WCAG22/),
  [target size](https://www.w3.org/WAI/WCAG22/Understanding/target-size-minimum.html)
  and [text resizing](https://www.w3.org/WAI/WCAG22/Understanding/resize-text.html):
  accessibility references to adapt and test on desktop.
- [Widgetbook](https://pub.dev/packages/widgetbook),
  [Alchemist](https://pub.dev/packages/alchemist),
  [Riverpod 3 behavior](https://riverpod.dev/docs/whats_new) and
  [Drift migrations](https://drift.simonbinder.eu/migrations/):
  primary documentation for the initial package evaluations.

---

## P0 — Foundation gaps (blocks polish / daily use)

### Engine lifecycle hardening

| Item | Status | Notes |
|------|--------|-------|
| Worker crash recovery | **Done** | Dead workers fail in-flight evals, leave the pool, and respawn up to the last `ensureWorkers` target. `EngineConnection.done` signals unexpected process exit. |
| App backgrounding (`paused` / `hidden`) | **Done** | `MainScreen` suspends on `paused`/`hidden`/`detached` (skips transient `inactive`); resumes on `resumed` when the current mode uses an interactive engine |
| Analysis output debouncing (~200 ms) | **Not started** | Spec throttling for UI updates not wired |
| Document / tab visibility awareness | **Not started** | Engine runs when user is not on engine-relevant panels |
| Default 1 worker for interactive analysis | **Deferred** | Still uses full `EngineSettings.workers` for interactive |
| Inline PGN viewer engine unified with lifecycle | **Deferred** | Spec recommends keeping separate; still a separate worker path |
| Integration perf tests (toggle ON/OFF timing, process count) | **Not started** | Unit tests exist; no automated process/RSS checks |
| `enterGeneration` / `exitGeneration` race safety | **Done** | Wrapped in `EngineLifecycle._serialExec` (June 2026 remediation) |

### Layout & navigation

| Item | Status | Notes |
|------|--------|-------|
| Preserve mode toolbar in material pickers | **Partial** | Player Analysis now embeds its picker. `RepertoireSelectionScreen` and `RepertoireChaptersScreen` still push full-screen routes with only a Back action, hiding Actions / View / Settings; embed them beneath their owning mode toolbar. |
| Bound simple lists and forms | **Partial** | Player Analysis caps its picker at 1040px; Settings and Databases already cap forms. Repertoire/chapter lists are capped at 920px and the library organizer at 1040px. `TournamentsScreen` group cards still fill the window; bound these, while retaining room for multi-column player tables and board workspaces. |
| Preserve navigation in planning workflows | **Partial** | Players & prep now keeps people and groups under a persistent mode bar. `BuildConfigScreen` and `PlanBuildScreen` still replace it with route-specific controls; planner boards/tables benefit from width, but question/review forms should have a readable cap. |
| My games UI within Tactics | **Not started** | Keep the workflow in Tactics; improve download status, catalog/filtering and opening-review navigation, reusing helpers with Viewer and Player analysis. |
| Contextual repertoire builds | **Partial** | Keep builds attached to a repertoire; make the output chapter explicit and improve planning/jobs/history in that context. |
| Audit follow-ups in Builder | **Partial** | Guarded run lifecycle, reliable partial resume, Priority/search and source warnings implemented. Still needed: saved-report staleness detection after line edits and explicit whole-repertoire chapter aggregation. Keep review beside the source lines and board. |
| Repertoire organization follow-ups | **Partial** | Standalone Repertoires and shared creation are implemented. Existing outline moves chapters into folders and reorders lines. Arbitrary sibling chapter ordering, cross-repertoire dragging and importing directly into an existing folder remain follow-ups. |
| Ultrawide four-zone layout (≥ 1600 px) | **Not started** | `kWideBreakpoint` exists; no fourth column |
| Draggable zone dividers | **Not started** | Fixed flex ratios only (`RepertoireLayout`) |
| Eval bar docked on board (Lichess-style) | **Not started** | Engine output lives in context panel / analysis dock, not under board |
| Dedicated **Expectimax toggle** on board toolbar | **Partial** | `EngineToggleButton` only; expectimax visibility via dock settings (`showExpectimaxDock`) |
| Repertoire keyboard shortcuts (`RepertoireShortcuts`) | **Done** | Letter shortcuts E/X/G/A/I/F/L/T/N/P/D with text-field guards; no digit bindings — see COMPONENT_MAP |
| Typed `RepertoireMetadata` (replace repertoire maps) | **Done** | `Map<String, dynamic>` replaced across selection, controller, storage, generation, training |
| Full unified keyboard shortcuts (all modes) | **Partial** | Letter shortcuts restored across repertoire, PGN viewer, tactics, training, audit findings; digit shortcuts remain removed; still missing global Tab |
| Remove legacy tab hybrid in Edit wide mode | **Partial** | Wide Edit still uses `RepertoireTabBar` (Browse + PGN tabs) while context is a separate zone |
| Status bar expectimax / coherence metrics | **Partial** | `RepertoireStatusBar` shows coverage, traps, lines, engine, tree nodes — not V% or coherence |

### Storage and update follow-ups

| Item | Status | Notes |
|------|--------|-------|
| Broader historical file fixtures | **Partial** | Frozen saved-games schema fixture, data-integrity and eval migrations are gated. Add fixtures whenever custom PGN/CSV/JSON formats change; no blanket compatibility promise. |
| One namespaced Documents root / relocatable data home | **Deferred** | Existing named folders and root-level legacy files remain addressable. A future move needs copy/verify/switch migration and external-path handling. |
| Windows bulk data outside roaming profiles | **Deferred** | Existing support databases use AppData/Roaming. New update payloads use local cache; moving old databases requires a separate migration. |
| OS credential vault | **Not started** | OAuth/PAT tokens currently use SharedPreferences. Migrate without discarding accounts when vault storage is introduced. |
| Additional auto-update formats and cleanup | **Partial** | Windows Setup, deb/rpm and marked Linux portable bundles supported. Flatpak/Windows ZIP/macOS use manual updates; install logs, downloaded releases and previous portable bundles need a retention UI. |
| Native update smoke matrix | **Partial** | Linux portable helper tests and Windows helper tests with disposable fake programs are gated. Test actual Windows Setup and Linux authorization/cancellation before publishing. |

### Global settings completeness

| Item | Status | Notes |
|------|--------|-------|
| Central `SettingsService` | **Not started** | Persistence lives on `EngineSettings`, `EvalDatabaseSettings`, `TrainingSettings` separately |
| **Accounts** section (Lichess OAuth UI, disconnect, Chess.com username) | **Not started** | `LichessAuthService` exists; settings screen has no account panel (login via `LichessDbInfoIcon` elsewhere) |
| **Training** settings in global settings | **Not started** | Training settings only in trainer UI |
| **Display** settings (board theme, piece set, coordinates, default Edit/Analyze mode) | **Not started** | |
| Shared `AppTextStyles` + gradual UI token migration | **Partial** | `AppTextStyles` / `PgnTextStyles` + `ThemeData.textTheme` landed; many legacy `Colors.grey` / hard-coded `fontSize` call sites remain |
| Stockfish binary path picker + validation | **Not started** | Auto-detect only |
| ChessDB.cn API quota display / toggle | **Not started** | |
| Queue engine setting changes during generation + toast | **Not started** | |
| CdbDirect path validation on settings open | **Partial** | Panel exists; spec-level startup warning flow not fully implemented |

---

## P1 — Core repertoire workflow

### Browse mode polish

| Item | Status | Notes |
|------|--------|-------|
| **Add as trainable line** | **Not started** | No `savePathAsTrainable`; no `[Trainable "1"]` PGN header |
| **Split as named line** | **Not started** | No `splitAsNamedLine` / `parentLineId` on `RepertoireLine` |
| **Next Gap / Biggest Gap** in browse nav bar | **Not started** | Gap buttons live in `LineMetricsPanel` (Lines tab), not `BrowsePanel` |
| Inline **expectimax continuation** on candidate hover | **Not started** | Hover previews FEN only; no `ClickableMoveLineWidget` under row |
| **Coverage ring** per opponent candidate | **Partial** | `coverageDelta` chip exists; no visual ring |
| **W/D/B result bar** for opponent moves | **Partial** | DB frequency/games shown; full win/draw/loss bar not in `CandidateRow` |
| `RepertoireTreeExplorer` DB frequency columns | **Not started** | Explorer shows engine metrics, not Lichess W/D/B |
| Entry: **Build manually** (empty repertoire, DB-only) | **Partial** | DB fallback in `CandidateService` works; no dedicated entry CTA |
| Entry: **Browse Result** after generation | **Partial** | Tree loads; no explicit post-gen browse button |
| PGN editor writes exclusively through `RepertoireWriter` | **Partial** | Clipboard/persist I/O extracted to `EditMainZone` callbacks (`onAutoSave`, `onCopyToClipboard`, `onDirty`); structural edits still via controller/service |
| Tree-path navigation (single source of truth) | **Done** | `MoveTree` + `TreePath` cursor in `RepertoireController`; PGN editor is a pure view; no `addPostFrameCallback` sync; arrow keys always go through controller |

### Generation & bottom pane UX

| Item | Status | Notes |
|------|--------|-------|
| **Simplified generation config** | **Done** | Only Max Depth + Engine Depth visible by default; selection mode, thresholds, opponent model, PGN export under "Advanced settings" |
| **Friendlier mode names** | **Done** | "Expectimax (recommended)", "Quick Build (no engine)", "From Your Games (PGN database)" |
| **Trap detection info banner** | **Done** | Amber banner below build mode: "Traps are automatically detected after building" |
| **Inline config in Jobs tab** | **Done** | Generation and audit config show inline in Jobs tab (bottom pane), replacing floating dialogs |
| **Rich progress display** | **Done** | C-like stats: depth, nodes, rate (n/min), elapsed, ETA — monospace row in Jobs panel |
| **Finish Now button** | **Done** | Stops Phase 1 BFS, proceeds to Phase 2 on partial tree; controller `finishNow()`/`clearFinishNow()` |
| **Enriched job tiles** | **Done** | Status labels, type labels, subtree indicator, differentiated icons for completed/failed/cancelled |
| **Findings empty state** | **Done** | Descriptive text + "Start Audit" button |
| **Auto-switch to Lines tab** | **Done** | Tools column switches to Lines tab after generation completes |
| **Line probability display** | **Done** | Reach probability badge on each `LineItemRow` when `importance > 0` |
| Extract `GenerationConfigForm` from generation tab | **Done** | `lib/widgets/generation/generation_config_form.dart`; tab owns build orchestration only |
| Lines browser performance (debounce, lazy list) | **Done** | 300 ms search debounce, single `setState` filter reset, grouped `ListView.builder` in `LinesListPanel` |
| PGN editor move-widget memoization | **Done** | `_buildMoveWidgets` cached when tree + path unchanged |

### Expectimax lines & hover

| Item | Status | Notes |
|------|--------|-------|
| `ExpectimaxToggleButton` on board toolbar | **Not started** | Toggle via settings / analysis dock |
| **Shift+click** add full line to repertoire | **Not started** | Click navigates; no bulk add |
| **Ctrl+click** add-with-confirm for out-of-repertoire moves | **Not started** | |
| Inline move **annotations** on lines (prob %, ★ repertoire, ⚠ trap) | **Not started** | `MoveAnnotation` model not on `ClickableMoveLineWidget` |
| Side-by-side Engine + Expectimax panels | **Partial** | `RepertoireAnalysisDock` tabs; not simultaneous split |
| Hover preview on **all** move surfaces | **Partial** | Engine, expectimax, browse, traps, suggestions, PGN trap dots, lines browser — **not** eval-tree explorer rows, all PGN moves |
| Independent persist of expectimax panel toggle | **Partial** | `showExpectimaxDock` persisted; not spec’s toolbar toggle semantics |

### Trap UI

| Item | Status | Notes |
|------|--------|-------|
| **TrapsBrowser in tools column** | **Done** | Lines tab → Traps segmented view; rich rows with mini board, per-reply stats, classification badges, sort by Eval Drop/Most Common/Trap%/Surplus; filter: All Explored vs In Repertoire |
| **Opponent-mistake weight** | **Removed** | Shipped as `TreeBuildConfig.mistakeWeight`, then deleted: expectimax already values a line by how opponents play it, so the weight double-counted the effect — and it read a value computed in a later pass, so it tilted selection without tilting the values selection compared against. See `docs/ALGORITHM.md` §5b. |
| **Enriched trap tooltips in PGN** | **Done** | Multi-line tooltip: mistake description, popularity, reach probability, score |
| **Traps empty state** | **Done** | Prompts "Generate Repertoire" with button when no traps detected |
| Trap detail when **current position is a trap** (browse context) | **Partial** | Expanded trap list under candidates; not full card in context zone |
| Eval bar → tap trap indicator → detail | **Not started** | |
| Detail card actions: **Show Refutation**, **Train This Line** | **Partial** | Refutation move extracted and displayed in detail card + browse panel; interactive "Show Refutation" navigation and "Train This Line" not wired |
| Sort lines by **ETV** (expected trap value) | **Partial** | Trap count sort exists; ETV sort not exposed |

### Coverage suggestions

| Item | Status | Notes |
|------|--------|-------|
| **Accept all** suggestions | **Not started** | Per-row accept only |
| **Needs generation** row with focused mini-build | **Not started** | Unresolvable gaps omitted or empty |
| Target-unreachable messaging | **Partial** | Service logic exists; UI messaging may be minimal |

### My Ease / playability

| Item | Status | Notes |
|------|--------|-------|
| **Dream sort** (playability × opponent difficulty × expectimax × traps) | **Not started** | Individual sorts exist (`playability`, `hardestFirst`) |
| **Bottleneck ply** warning on hard lines | **Done** | Shown in trainer `_LineRow` + builder `_HardMoveWarning` when quality < 0.3 |
| Training review weighted by **inverse playability** | **Done** | `ReviewOrder.hardestFirst` sorts by ascending playability; trainer loads `tree.json` and computes per-line playability |
| On-demand `myEase` for manually added moves (Maia lookup) | **Not started** | Defaults to neutral when absent from tree |
| **"Needs scoring" banner** in trainer | **Done** | Shown when no `tree.json` exists; links to Builder for generation |

---

## P2 — Coherence & analytics

### FP-Growth coherence

| Item | Status | Notes |
|------|--------|-------|
| Lines browser **grouped by coherence cluster** | **Not started** | Groups by PGN event / first moves (`getLineGroupName`), not clusters |
| **Coherence** in status bar | **Not started** | |
| **Tradeoff sliders** (eval / ease / coherence) in generation | **Not started** | |
| Coherence-aware **generation selection** modifier | **Not started** | |
| Prominent **risk-line** warnings in lines list | **Partial** | `CoherencePanel` shows risk; not inline on every line row |
| FP-Growth off UI thread | **Done** | `CoherenceService.compute` runs mining in `Isolate.run` |
| **v2**: PrefixSpan sequence mining, FEN collapse, pawn-structure tags | **Deferred** | Explicitly future in spec |

---

## P3 — Platform, infra & other modes

### Tactics trainer

| Item | Status | Notes |
|------|--------|-------|
| Mate-in-1 positions shown / scored incorrectly | **Open bug** | "Position to next position" eval measurement suspected broken for last-move-of-game SF evaluations |
| Positions with many equivalent winning moves | **Open design** | No filtering strategy for "any move maintains eval" (e.g. opponent blunders in equal position -- almost any reply is good) |

### Tree builder / eval database (`tree_builder/TODO_cloud_evals.md`)

| Item | Status | Notes |
|------|--------|-------|
| Download & import Lichess **cloud eval JSONL** (~369M positions) | **Not started** | Separate from Flutter app; CdbDirect + SQLite chain exists |
| FEN normalization for Lichess EP convention | **Not started** | Lookup misses possible |
| MultiPV depth vs breadth tradeoff for cloud evals | **Not started** | Design open |
| PGN game filters for db-explorer (`--min-year`, avg Elo) | **Partial** | `--min-elo` implemented in both C and Flutter; year/avg-elo filters not yet added |
| Leaf **Best game** PGN annotation from source database | **Deferred** | Was db-seed export metadata; not in db-explorer pipeline |

### README / docs drift

| Item | Status | Notes |
|------|--------|-------|
| README reflects repertoire builder scope | **Partial** | Updated to point at `docs/COMPONENT_MAP.md`; expand feature list over time |
| `docs/ALGORITHM.md` file paths | **Partial** | Flutter-side paths; top-level doc links to `tree_builder/ALGORITHM.md` for C CLI |
| `docs/COMPONENT_MAP.md` reflects June 2026 remediation | **Done** | Typed metadata, API removals, new widgets, performance fixes documented |

---

## Cross-cutting open questions

These remain **undecided**; pick one before implementing dependent UI:

1. **Browse vs Eval Tree tab** — Coexist vs merge. Current: coexist via chips + eval tree in Analyze mode.
2. **Expectimax + Engine both ON** — Side-by-side vs tabbed on narrow screens. Current: tabbed dock.
3. **On-the-fly auto-compute** — Off by default (recommended). Not implemented.
4. **Engine toggle persist on restart** — Implemented (`engine_lifecycle.toggle_on`); verify product preference for first-install default.
5. **Hover preview on main board vs mini-board tooltip** — Main board chosen; mini-board not planned.

---

## Implementation priority (suggested)

1. **Engine crash recovery + background CPU** — stability
2. **Accounts + training in Settings** — discoverability
3. **Browse gap navigation + trainable lines** — completes manual prep loop
4. **Expectimax toolbar toggle** — differentiator polish
5. **Cluster-grouped lines + dream sort** — repertoire quality insight
6. **Cloud eval import** — build-time speed (tree_builder scope)

---

## Related reference docs (not backlog)

- `docs/COMPONENT_MAP.md` — current implementation
- `docs/ALGORITHM.md` — Flutter pipeline description
- `tree_builder/ALGORITHM.md` — C `tree_builder` CLI (db-explorer, expectimax)
- `docs/tree-display-architecture.md` — eval-tree graph performance principles
- `tree_builder/TODO_cloud_evals.md` — infra backlog
