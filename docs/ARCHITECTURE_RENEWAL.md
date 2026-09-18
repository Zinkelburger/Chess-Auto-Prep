# Architecture renewal

**Status: Partial — S0 verified on Linux; milestones 1/2–5 in progress; milestones 6–7 not started.** Planning baseline: 2026-09-16. This is the canonical
rewrite plan. [FUTURE_FEATURES.md](FUTURE_FEATURES.md) tracks feature backlog;
[COMPONENT_MAP.md](COMPONENT_MAP.md) describes implemented behavior. Update
milestone evidence and selected decisions here as work proceeds. The active
cutover plan and acceptance contracts live here. Historical results live in
[the evidence record](ARCHITECTURE_RENEWAL_EVIDENCE.md); they do not authorize
new transitional layers or establish present-day completion.

The new hierarchy is implemented for migrated owners: `app/`, `design_system/`,
`chess_core/`, `infrastructure/`, and feature-local controllers, models,
repositories and widgets. Repertoire catalog, shared documents, Study and selected
settings use these boundaries. Legacy `core/`, `services/`, `screens/` and
`widgets/` still contain substantial production behavior. Their removal requires
completing the workflow migrations and parity tests below; the full rewrite is
not complete.

**Scope and authority.** This document specifies future work; writing it does
not implement, test or publish that work. Automatic checks use disposable data.
Retain proven code that satisfies the contracts. Non-goals are changing chess
semantics for visual polish, rewriting third-party engines, introducing cloud
sync or remote telemetry by default, translating every language at launch,
buying services, and replacing all storage formats at once. Product/data
behavior changes remain explicit; release publication follows the repository's
existing policy. These constraints apply throughout the plan.

## Execution contract and evidence

At kickoff, record the scope
actually authorized by the product owner (the person directing this project).
The recommended first increment is safety prerequisite S0 plus inventory 0;
produce their evidence and bounded estimates before expanding the rewrite.
Existing explicit authorization takes precedence; do not invent another approval
step for routine work already in scope. End users are the people using the app;
the product owner selects UX direction and scope. Sessions with unfamiliar chess
players are valuable **when feasible**, not a mandatory dependency for graduation.

The implementing agent owns technical decisions and evidence for its increment.
Apply the defaults below without a new package-selection discussion. A failing
rejection check triggers the stated fallback and a recorded reason; changes to
product behavior, compatibility or scope go to the product owner. Time-box spikes
using the milestone 0 budget; do not keep evaluating equivalent packages.

The following stable IDs are the acceptance register. Detailed contracts in the
linked sections define their test cases; principles and references explain the
rationale. Cite IDs in tests/check results and milestone evidence rather than
copying slightly different versions into each feature. Add or amend the owning
ID when a requirement changes. IDs stay stable if milestones are rearranged.

| ID | Required outcome and evidence | Owning contract |
|----|-------------------------------|-----------------|
| PLAN-01 | Record authorized scope, parity inventory, named owners, defaults and bounded time/performance budgets before widening implementation. | [Working method](#working-method-checks-and-sizing) |
| PLAN-02 | After the first slice, record continue, bounded repair or stop against the baseline; unresolved gates are not passes. | [Continuation](#continuation-decision-after-milestone-2) |
| ARCH-01 | Completed replacements use injected final owners throughout their production call graph; widgets/controllers cannot bypass domain boundaries. No newly introduced bridge to a superseded singleton is an accepted cutover. Verify imports and actual runtime wiring. | [Dependencies](#target-layout-and-dependency-rules) |
| ARCH-02 | A completed workflow deletes its superseded owners, forwarding APIs and production consumers; no re-export shims, duplicate writers or permanent legacy bridge remain. All feature directories are covered by the final boundary gate. Report concrete deletions and parity evidence; line counts alone are not proof. | [Retirement gate](#retirement-is-part-of-each-workflow) |
| ARCH-03 | A replacement simplifies the complete consumer/owner graph for the same capability: fewer coordination paths, no duplicated mutable state or pass-through owner layers, and an explained production-size delta. Growth in a screen or its helpers blocks the simplicity claim until reviewed against a concrete capability change. | [Maintainability gate](#maintainability-correction-and-next-cutovers) |
| ARCH-04 | One Flutter dependency lookup mechanism: constructor-injected owners exposed through Provider. Retire the remaining Riverpod ownership and bindings together, preserving lifetimes, retry policy and settings/catalog behavior; no new parallel container or forwarding provider layer. | [Composition decision](#one-composition-policy) |
| DATA-01 | Reproduce each reported overwrite/undo race on current code; independently fix confirmed cases and retain regressions before rewrite-dependent writes. | [Safety prerequisite](#safety-prerequisite-on-current-code) |
| DATA-02 | Create never replaces; every save/update validates its baseline through the shared mutation boundary. Exercise concurrent creation, stale saves and competing writers. | [PGN API](#one-safe-pgn-mutation-api-and-shared-save-interaction) |
| DATA-03 | Undo snapshots come from the validated mutation baseline; only a proven history chain may advance its expected revision after undo. Preserve external edits and per-move/successive undo; test conflicts and failures. | [Undo receipts](#undo-receipt-provenance-and-history) |
| DATA-04 | Revision checks distinguish raw bytes and observed file identity; identity change/unavailability never silently authorizes replacement. Test BOM, aliases and replacement. | [Filesystem contracts](#filesystem-and-cross-process-contracts) |
| DATA-05 | Measure lock wait/hold times; interrupted and synced-file operations preserve recoverable content with bounded retries and explicit durability limits. | [Filesystem contracts](#filesystem-and-cross-process-contracts) |
| DATA-06 | Restore a consistent database/document backup into a disposable profile; migration and adapter rollback preserve new work and stable references. | [Coexistence](#data-preservation-and-coexistence) |
| DATA-07 | Generation commits only against its source/run identity and preserves edited artifacts. Exercise stale completion and interrupted publication. | [Storage gate](#storage-baseline-and-overwrite-prevention-gate) |
| STATE-01 | Each action scope has one state owner and an explicit reject/coalesce/queue policy; retries, offscreen listeners and stale callbacks cannot duplicate jobs or publish stale state. | [Runtime state](#runtime-state-and-large-documents) |
| STATE-02 | Large projections are immutable, cheaply comparable and scoped to their dependencies; receive-side decoding and measured edits/rebuilds meet the baseline budgets. | [Runtime state](#runtime-state-and-large-documents) |
| STATE-03 | Continuous analysis produces bounded periodic UI updates without losing terminal events; verify with fake-time burst tests. | [Runtime state](#runtime-state-and-large-documents) |
| SET-01 | One writer per settings key; failed reads/saves stay visible, unknown preferences cannot authorize startup work, and active-job configuration is explicit. Test concurrent panels, startup/toggle ordering, retry and restart. | [Settings](#settings-and-credentials) |
| SEC-01 | Before migrating Accounts, verify native vault migration, restart and disconnect with synthetic secrets; no silent plaintext fallback. | [Credentials](#settings-and-credentials) |
| PROC-01 | Owned workers/ports/processes terminate on the specified cancellation/shutdown paths; test failed startup and return to resource baseline. | [Supervision](#worker-and-engine-supervision) |
| PROC-02 | A verified containment or parent-liveness mechanism is active before engine work; forced app death cleans up the supported descendant tree on each verified host. | [Supervision](#worker-and-engine-supervision) |
| UI-01 | Slice controls share production tokens, ARB copy and Widgetbook fixtures; keyboard, contrast, long text and scaling checks pass. | [Visual direction](#visual-direction-a-calm-responsive-dark-workspace) |
| UI-02 | Ordinary navigation retains shell/context; Back, picker cancellation and focus return preserve the document session. | [Shell](#persistent-shell-and-reusable-panels) |
| UI-03 | Shared split panels respect size bounds, keyboard adjustment and saved-layout recovery; test narrow and wide windows. | [Panels](#persistent-shell-and-reusable-panels) |
| UI-04 | Complete the representative user task and record usability findings; product-owner visual review is distinguished from optional unfamiliar-player studies. | [Human factors](#frontend-principles-human-factors-as-acceptance-criteria) |
| OPS-01 | Diagnose root, worker and engine failures with redacted local evidence; record unavailable native coverage. | [Desktop foundations](#early-desktop-foundations) |
| OPS-02 | Native packaging/licensing and platform checks match the supported hosts; release gates pass before user-requested publication. | [Desktop foundations](#early-desktop-foundations) |
| TEST-01 | Slice-specific contract, failure, algorithm and integration checks pass; changed formats have fixtures and legacy removal has parity evidence. | [Working method](#working-method-checks-and-sizing) |

For each exit gate record `requirement ID | scope/host | check or test path |
result | commit | remaining limitation`. Results are pass, fail or unverified;
mark genuinely inapplicable requirements with a reason. No test coverage or
implementation is implied by this empty evidence template.

## Current execution order: complete replacements

This section supersedes the sequencing and temporary-bridge allowances in the
historical execution record. Milestone numbers and acceptance IDs remain stable
for traceability; they are outcome groups, not permission to land partial layers.
The current work is consolidation: finish existing replacements and simplify
their consumers before widening into more features. Owner retirement, workflow
parity and maintainability are separate findings. Whole renewal is still Partial.

**Integration unit.** Replace a complete production responsibility, including its
entry points, state/writers, consumers and lifecycle. A large screen may contain
several independent responsibilities, but extracting a class while retaining its
forwarding owner is not a cutover. Final infrastructure adapters are useful
boundaries; adapters whose only purpose is keeping a superseded owner alive are
scaffolding. Preserve proven algorithms without rebuilding them for appearance.

**Before coding.** Inspect the owner/caller graph, write the final dependency
shape and deletion list, and identify unresolved behavior. Reuse existing final
contracts; add an abstraction only for a concrete responsibility or external
boundary. If a dependency prevents deletion, complete it first or include it in
the cutover. Do not plan an interface, wrapper, error mirror or second writer
whose deletion is already the intended next step. Tests should exercise user
behavior, contract failures and actual production wiring, not encode the old
facade merely to keep its tests green.

| Order / owner | Complete replacement and required deletions | Integration proof |
|---|---|---|
| Retired: Viewer facade (`141b5271` ancestry); consumer simplification still open | Deleted `PgnViewerController`, forwarding methods and mirrored errors; all consumers use the collection/editor/filter/presentation/tree owners. One session transition contract owns abandonment across the six reviewed paths. | Zero class/API references; no replacement facade; delayed work cannot publish after replacement; open/edit/save/recovery/navigation/close parity through final app wiring. |
| Completed: Builder history (`09aeb6ed`) | Native append/undo provenance and private opening graph ownership. Deleted decoded-only history authorization, old append APIs and mutable graph exposure. | Native revision/history conflicts, successive/per-move undo, failed mutation retention and all graph consumers use the final projection. Whole Builder remains Partial beyond this history responsibility. |
| Retired: Builder facade; durable workspace recovery implemented (`a7352bb2`) | Deleted `RepertoireController` and widget autosave timers; final workspace owns retained drafts/copy intent, document saves are bounded, and app lifetime owns recovery/close. Builder chapter lookup uses the injected catalog. | Independent review repaired unresolved-copy draft loss, unsafe outline reattachment and late-load replacement of scratch. Native restart/source identity and visible copy failure/retry pass. Net +976 handwritten Dart lines for added safety; whole Builder maintainability/theme work remains Partial. |
| Replaced: Study import/publication (`a559b1a3`) | One admitted publication owner handles collection, Lichess and Builder-created studies; deleted old `services/study_import/` and duplicate `createStudyFromPgn`. Scoped transport closes retries; rejected input and uncertain publication remain accessible. | Independent review plus native conflict/copy and UI admission/retry/adoption checks. Net +941 handwritten Dart lines for added safety; whole Study maintainability/theme work remains Partial. |
| Completed: generation publication, read-only recovery and pure artifact domain | Versioned publication and all authoritative readers use the artifact repository; old artifact writers/path ownership, persistence methods and loader shims are deleted. Builder Actions provides retained PGN/model-game proposals, artifact history and legacy tree/probe/trap/partial inspection with original-byte export through that final repository. The same recovery dialog discovers deleted chapter namespaces even without a loaded chapter. Artifact codecs/models have one pure `chess_core/generation` home; the old serialization/model paths and mixed probe-codec dependency are removed. | Stale/interrupted output cannot replace current artifacts; existing files remain accessible and untouched. Legacy source identity is unproven, so automatic legacy resume/current-analysis adoption remain explicitly unsupported. Recovery never adopts/resumes retained output; receipt/selection evidence stays explicitly uncertain. Other Generation workflows, retention policy and platform gates remain open. |
| Completed: settings/engine (`f1109c5b`) | Typed engine/bulk/board settings and constructor-owned engines. Deleted the three old settings singletons, engine service global access and interim bind APIs; application composition injects BoardEngine, StockfishPool and EngineSearchBudget configuration. | One writer per key, serialized changes/failure/retry/restart, captured job configuration, production caller cutover and resource/scheduling parity. No temporary settings-to-engine binding. |
| Next: finish existing migrated workflows | Close catalog, Study, Builder, Viewer and Training end to end: remaining host/provider/lifetime bridges, durable Builder recovery, final settings/session ownership, and all applicable UI/parity gates. Keep separate dependency-ordered cutovers where each deletes a complete responsibility. | No remaining temporary owner in each declared-complete workflow. Existing extracted code is reused or simplified; do not restart another extraction cycle. |
| Then: engine/jobs and remaining domains | Replace each remaining workflow from the capability inventory, including actual worker/process ownership and all writers/readers. Consolidate singular `repertoire/` into its final domain as its remaining responsibilities retire. Adopt design-system controls while deleting each superseded control/theme dependency. | Dependency-ordered cutovers, shared-file parity and safety, native resource cleanup, feature and UI contracts; no second implementation or leftover theme owner for migrated surfaces. |
| Last: application audit | Verify all features, formats, recovery, platforms, performance and release readiness. | No deferred retirement work, no hidden boundary exclusions, no production fallback; unverified host/release gates stay explicitly open. Publication still requires the user's request. |

The rows identify replacement boundaries. Viewer and Builder facade retirement
is verified; Builder workspace/scratch recovery and Study import/publication
have independent review evidence. These safety additions grew production code
and do not satisfy the two simplification trials below.
Generation retained-output inspection/export now uses the same recovery UI,
including deleted chapter namespaces. Builder closure also requires bounded
autosave admission: replacing widget debounce with an unbounded queue of PGN
snapshots is not an acceptable final behavior.
The generation publication/read-only recovery and pure artifact domain
responsibilities are complete as specified above; it does not certify the whole Generation feature. Do not count
an infrastructure decoder alone as user-facing
migration parity. Each agent must report final runtime wiring, concrete deletions
and behavior/failure evidence before integration.

Each replacement records a bounded estimate including validation, and a midpoint
with the complete caller/recovery inventory and final dependency shape. The
parent reconciles shared composition files and validates combined callers. When
remaining work exceeds the estimate, back up the branch and revise it; do not
land an incomplete layer to report a checkpoint. These
estimates do not change the full renewal objective or authorize transitional
engine bindings, replacement facades or duplicate writers.

**Make incompleteness visible.** The architecture checker now discovers every
`lib/features/` directory and checks its imports, singleton access and widget
theme boundaries. [The explicit debt ledger](../scripts/architecture_feature_debt.json)
classifies all 20 remaining directories: six `enforced` directories retain their
zero-debt gate, and 14 are `unfinished`. The unused legacy `browse`, `eval_tree`
and `master_games` features are retired rather than classified as completed replacements. No directory is
declared `complete`.
`enforced` certifies only these static boundaries, not workflow completion or
runtime wiring. The ledger records 1,493 exact existing dependency/offending-line
entries at initialization; repeated lines retain their occurrence counts. This
replaces file-wide singleton/theme allowances, so another violation in an
already indebted file still fails. The baseline records debt, not certification.

Unknown directories, new violations, stale classifications and resolved entries
left in the baseline fail `scripts/ci.sh lint`. Remove resolved entries with the
code change; do not expand the ledger to silence a regression. When a source-line
fingerprint changes without resolving its existing violation, review that exact
entry rather than regenerating the baseline. New directories require an explicit
classification and start without debt. Both `enforced` and `complete` require
zero baseline entries. Completion additionally requires the production/parity
proof below; the final application gate requires an empty baseline.

[The retirement manifest](../scripts/architecture_retirements.json) rejects
restored library paths (including forwarding shims), imports of those paths,
and retired API names anywhere in production Dart outside comments. A trailing
slash retires a whole directory. Retirement is unconditional and cannot be
accepted into the debt ledger. Add each deleted path/API with its completed
cutover. Existing transitive purity, infrastructure, design-system, catalog and
legacy-theme-consumer checks remain active. These static checks do not prove
runtime ownership or certify code outside their declared boundary rules. Moving
code to `legacy_features/` alone earns no migration credit and is not a
replacement for the full inventory and parity checks.

**Review corrections to the completion gates (2026-09-17).** These requirements
apply to the complete replacement, including its existing UI and helper files:

- ARCH-01/ARCH-02: continue inventorying the whole production dependency graph,
  including feature services and shared `lib/models/` types. Enforced/complete
  feature `services/` folders now reject transitive legacy-service imports, exports,
  conditional alternatives and parts; regression cases cover renamed/nested
  service paths. Pure generation artifact codecs/models also pass the transitive
  pure-Dart gate, closing that service loophole. Wider shared-model and workflow
  coverage remains open: an `enforced` classification alone does not certify a
  complete workflow. Close remaining edges through final pure algorithms or
  injected contracts, move each canonical domain type with all consumers, and
  never rename files to evade a rule or expand the debt baseline to claim success.
- UI-01: controllers expose typed failure/status data; widgets resolve ARB copy,
  including retry, empty, recovery and error states. Remove English error mirrors
  and raw exception display in the same consumer cutover. Keep the ban on
  localization imports in controllers. ARB message counts or a static boundary
  pass are not localization evidence; exercise the rendered states, long labels
  and text scaling. Existing controller English remains unfinished UI work.
- STATE-01: document each action's owner, admission policy, invalidation events
  and publication checks. Independent open/selection/cache revisions are allowed
  when their scopes differ. Fewer integer counters alone neither prove nor
  disprove correctness. Verify overlapping commands, invalidation before
  cancellation, disposal and late results across the real owners; do not add a
  generic token wrapper merely to conceal the same competing ownership.
- SET-01: distinguish unavailable preferences from a successfully read absent
  key. A failed initial read must remain retryable and cannot silently enable
  analysis using defaults. Startup, toggles and generation transitions share
  lifecycle ordering. Normalize edits once in the canonical configuration;
  setters and explicit edit commands follow the same invalid-input policy.
- TEST-01: every changed production provider must be installed by its affected
  widget fixtures before integration. Cache/database fixtures select disposable
  storage themselves, including direct test invocations, and test only their own
  rows. The bounded runner's disposable XDG profile is additional containment;
  its potentially warm cache is not test isolation. Never inspect or clear the
  user's database to make a test pass. Record the test process's actual exit
  status, not that of a trailing log command. Known failing affected tests block
  integration. Focused repairs do not turn an earlier red full suite into a
  green result; rerun the combined suite before claiming that result.

**Definition of done per cutover.** Final production wiring + deleted old
owner/APIs/callers + ARCH-03 consumer/ownership review + no temporary scaffolding + passing behavior/failure checks +
required visible-workflow evidence + committed, verified local-main integration.
Report owners and dependency edges removed, with production line additions and
deletions as supporting information. Do not impose a raw line-ratio quota that
can be met by code compression or unrelated deletions. No feature is complete
merely because it has a new path, constructor injection or passing unit tests.

## Maintainability correction and next cutovers

The 2026-09-17 review identifies a real failure of the process: improved safety
and testability have not established simpler consumers. A retired facade is a
completed deletion, not proof that its replacement workflow is maintainable.
Do not repeat the present composition pattern across the remaining unfinished features.
Finish the safety work already in flight, then simplify the existing graph.

### What the code establishes

Measurements below compare the recorded renewal baseline `e477dc58` with local
main `a6238ff5`, excluding concurrent worktrees. They count physical lines,
including comments and blanks, in tracked `lib/**/*.dart` files. Generated Dart
is included in this historical comparison; subsequent cutovers must report it
separately. These are review baselines, not implementation-size targets.

| Tracked scope | Baseline | Main snapshot | Finding |
|---|---:|---:|---|
| All production Dart | 218,957 lines / 890 files | 236,991 lines / 1,055 files | +18,034 lines (8.2%); no overall size reduction |
| `screens/pgn_viewer_screen.dart` | 1,909 | 1,977 | Consumer grew despite facade retirement |
| `screens/repertoire_screen.dart` | 1,191 | 1,333 | Consumer simplification remains open |
| `screens/study_screen.dart` | 880 | 926 | Consumer simplification remains open |
| `core/generation_session_controller.dart` | 1,321 | 1,455 | Orchestration remains unfinished |

At this snapshot, generated localization accounts for 2,272 lines of the total;
excluding it still leaves growth of 15,762 lines. `services/` contains 43,968
lines and `widgets/` 55,788. There are 99 commits since the baseline, including
merges (57 on the first-parent history). Commit count is activity, not completion.
At that snapshot, six enforced and 17 unfinished features included zero complete
features. The current inventory above separately records later deletions.

The same measurement at Trainer bulk-recovery checkpoint `22e28fa3`, including
reviewed reading-handoff, document-store, settings and Study consolidation, is:

| Tracked scope | September 16 | Current checkpoint | Change from September 16 |
|---|---:|---:|---:|
| All library Dart, including generated code | 218,957 | 225,909 | +6,952 (+3.2%) |
| Viewer screen | 1,909 | 1,875 | −34 |
| Builder screen | 1,191 | 1,468 | +277 |
| Study screen | 880 | 1,072 | +192 |
| Generation session controller | 1,321 | 1,447 | +126 |

All-library code is down 11,082 lines from the reviewed `a6238ff5` snapshot,
with Viewer now 34 lines below September 16; the other three consumers remain
larger. Legacy `services/` still holds 42,560 lines and `widgets/` 49,506. Riverpod's production
imports and package dependency are now deleted; the current inventory is six
enforced and 14 unfinished feature directories, with none complete. The three
removed feature directories contained unused code, not graduated workflows.

Against the separate simplification baseline `fa7f309e`, the completed batch
removes 13,837 handwritten library lines, with generated localization +264
reported separately. Chapter read/create and deletion Widgetbook changes add 22 lines, outside
that library total. Of the removals, 12,154 lines come from unused analysis,
eval-tree and other presentation/custom-tab retirement. These unrelated deletions cannot
satisfy another workflow's simplicity gate. Its screen and entire helper/owner
graph must improve together. The current decision is **continue bounded
consolidation**, not expand a broad rewrite or declare the architecture simpler
overall. New safety findings need their own complete contract and evidence;
their implementation growth cannot count as a simplification pass.

The criticism needs three qualifications, not a dismissal:

- `features/documents/` has 8,780 lines in 60 files at this snapshot. It contains
  shared mutation/save/close/restart recovery and Viewer responsibilities; it is
  not an equivalent denominator to the old Viewer controller and satellites.
  Account for reused shared capabilities and new safety behavior explicitly;
  this does not excuse unexplained growth or predict a 400k-line final app.
- Its `repositories/` has 17 files, not 21. `ViewerComputation` is a cancellable
  worker handle with an isolate adapter and controlled-worker tests;
  `DesktopClosePort` isolates native window events and has a memory test adapter;
  `PgnCollectionDecoder` isolates heavy decoding and has delayed/failure fakes.
  Those are meaningful boundaries. File length and one production implementation
  do not establish that an interface is wasteful.
- At the original review snapshot, Provider imports occurred in 45 production
  files and Riverpod imports in seven; the latter are now retired.
  Constructor injection is ordinary dependency passing, not a third container.
  Four InheritedWidget subclasses and one InheritedNotifier subclass also exist;
  a UI protocol scope is not automatically a competing dependency framework.
  The actual problem is duplicated lookup/lifetime policy and unclear ownership.

The confirmed structural concerns are the Viewer constructors' supplier/callback
networks and consumer knowledge of nested mutable owners, such as
`reading.solitaire.controller`. Accessing a public immutable value such as
`editor.state.uncertain` is normal; counting dots cannot diagnose coupling.
Safety boundaries, meaningful fakes and native failure tests remain valuable.

### Required simplicity review (ARCH-03)

Before a cutover, record one bounded owner/consumer inventory and representative
open, edit/save, failure/retry and close traces. After it, compare the same scope:

1. **Consumer coordination:** screen, parts, mixins, action helpers and widgets
   together. Identify which branching, cancellation, error selection, persistence
   and mode-transition decisions left the UI, and which final owner now makes
   each decision. Moving methods into a `part`, helper or new pass-through class
   earns no simplification credit. A screen's growth triggers a blocking review
   of its same-capability paths; only necessary, explicitly named new behavior
   can explain growth. Unexplained growth leaves maintainability incomplete.
2. **Ownership and coupling:** list mutable state/writers, owner-to-owner edges,
   supplier callbacks and action forwarding along those traces. Remove redundant
   owners and mirrored state. Widgets receive their relevant final owner or
   immutable projection and commands directly; only feature composition wires
   the owner graph. Do not rebuild the deleted god object as a flat facade or
   hide the same graph inside a dependency bag.
3. **Abstraction cost:** for each new interface/collaborator, name its coherent
   responsibility, lifecycle or external effect, and failure/interleaving test
   enabled by the boundary. Use a concrete pure function/class for an internal
   algorithm without such a boundary. A fake written solely to justify an
   interface is not evidence. Combine contracts only when their semantics and
   ownership match; fewer files alone is not the objective.
4. **Size and parity:** report additions/deletions for the complete production
   scope, separating generated code, tests and genuinely new capabilities.
   Shared code is counted once with its real callers. Retain the native safety,
   stale-result, disposal and recovery checks while simplifying. No raw LOC
   quota, formatting compression or unrelated deletion substitutes for evidence.

A reviewer must be able to trace a representative action from its widget to the
owning command and external boundary without opening pass-through layers. Do
not add an architecture-metrics framework for this review. Use the diff, caller
searches and the existing boundary/retirement checks. Record retirement,
behavioral parity and maintainability outcomes separately; all applicable gates
must pass before calling the workflow complete.

**Binding stop rule for the next two simplifications.** Complete composition
and Viewer simplification as two bounded, independently reviewed trials before
expanding renewal into another domain. Each must reduce handwritten production
code across its entire agreed scope, including moved methods, new helpers and
all callers, and make the representative action traces easier to follow. Report
exact base/head commits, additions/deletions, ownership/callback changes and
behavioral evidence; count generated code and capability additions separately.
Do not expand either trial to manufacture unrelated deletion credit.

If either trial fails the reduction, clarity or parity test, stop broad rewrite
expansion. Retain the proven safety improvements, finish any necessary repairs
to preserve user data, and return to targeted fixes. Passing tests alone, retiring
a facade or promising a later cleanup cannot override this decision. Unverified
results do not authorize expansion. The coordinator enforces this rule without
seeking another permission round; the existing in-flight safety repairs finish
before these trials are assessed. Both trials have passed, but their combined
80-line reduction is only evidence for those two scopes. Apply the same
reduction, ownership and parity tests to every subsequent simplification.
Unused-code deletion and separately justified safety growth cannot offset a
failing active workflow or authorize another broad extraction program.

### One composition policy

The final choice is **explicit constructors for domain/workflow owners, with
`package:provider` as the Flutter dependency lookup and listening mechanism**.
This revises the initial Riverpod default using repository evidence: most final
owners and their tests already use plain objects/ChangeNotifier and explicit
lifetimes; the smaller Riverpod island owned catalog presentation and two settings
subscriptions. Converting the larger working graph would add migration work
without resolving the identified ownership and callback problems.

The complete composition cutover removes Riverpod's catalog/settings bindings,
all production consumers and its package dependency. `StoredGameScope` and
`DisplaySettingsScope` are also deleted; repository and display consumers use the
existing Provider tree directly. One app-owned catalog controller retains two
private read snapshots, with independent load failures and no implicit mutation
retry. Mutations now reject overlap across catalog kinds and invalidate both
views' older reads. Catalog re-entry refreshes explicitly; listener loss does not
destroy an active commit. Repository replacement starts a new keyed dependency
lifetime and unsubscribes the previous appearance stream. The stream subscribes
before starting a load so synchronous repository emissions cannot be lost.
Retirement checks forbid the old scopes/provider symbols and Riverpod imports.
No new dependency container or settings-state owner was added. The existing
settings process singleton used by legacy Games/storage remains separate debt.

Retain Flutter scopes only for actual tree-local UI protocols, such as close
registration, focus or a scoped document view. Generic repository/owner lookup
uses the chosen composition mechanism. A change may not register two independently
constructed instances of the same owner through different mechanisms.

### Next complete integration units

Each integration unit uses the following execution cycle. The coordinating agent
owns this process and resolves design changes without repeatedly asking the
product owner to choose implementation details.

1. **Plan the final workflow.** Inspect the current production graph and record
   one short design card: user behavior; state/resource owners; public commands
   and typed results; admission/cancellation/close policy; concrete app wiring;
   old APIs/callers to delete; relevant failure and parity checks. Include the
   whole consumer/helper scope and its starting commit/handwritten production
   size. Define boundary semantics before coding, not every private helper.
2. **Review the design.** The coordinator checks that each owner has a distinct
   responsibility and that the proposed action traces are shorter or clearer.
   Prefer the existing final owner over another controller, forwarding adapter
   or generic context object. Disjoint implementation tasks may then proceed
   in parallel; overlapping ownership is resolved first.
3. **Implement a complete replacement.** The subagent chooses algorithms,
   internal structure and tests within the agreed contracts. Discoveries may
   change the design; new owners, public contracts, state mirrors or dependency
   mechanisms require coordinator review before expanding the implementation.
   Keep private work backed up, but do not integrate incomplete scaffolding.
4. **Review the implementation independently.** A different agent reviews the
   actual base-to-head diff and production callers, not just the implementer's
   report. Check correctness, lifecycle, unnecessary abstractions, complexity
   moved into consumers and the deleted paths/APIs. Reproduce actionable
   findings. The implementer or reviewer may repair them; another agent checks
   the repair. A green test suite alone is not a design review.
5. **Measure and integrate.** Compare the same user-action traces, owner and
   dependency counts, callbacks, and full-scope handwritten code size. Record
   whether each improved, regressed or remains unverified. Every simplification
   requires net handwritten production-code removal across its complete scope
   as well as clearer ownership; new helper files count against that result.
   Do not compress formatting or omit safety behavior to achieve a reduction.
   Reconcile shared files, run affected combined checks, and integrate only the
   reviewed/tested commit into local main with a verified backup.
6. **Use the result to choose the next unit.** Keep working designs and remove
   failed abstractions. Finish the current responsibility before spreading its
   pattern to another feature. A capability addition may add code; account for
   that separately and never label it a simplification merely because an old
   owner was deleted. Put detailed evidence in the evidence record, with one
   current status update here.

| Order | Final result | Required removals and evidence |
|---|---|---|
| Reviewed safety/recovery cutovers | Builder durable workspace, native recovery identity and bounded autosave; Study app-owned import/publication; Generation retained-output recovery | Named old owners/callers removed and independent repairs reviewed. These are safety/retirement results with production growth; keep their evidence separate from the two required net-reduction trials. |
| Composition trial passed (`e1286ced`) | Constructors plus Provider throughout catalog/settings/app presentation | Riverpod owners/bindings/dependency and generic stored-game/display scopes deleted; −48 handwritten production lines against `fa7f309e`, independently reviewed with lifecycle/settings parity. |
| Bounded Viewer trial passed (`e1286ced`); wider consumer work remains open | Shared leave approval and existing collection/reader owners replace duplicate prompts and five suppliers | −32 handwritten production lines against `4ebb3a36`; native approval never discards early and screen discard validates click-time revision. Both trials together pass 6,569 tests with 12 skips and no failures. This permits the next bounded deletion, not whole-Viewer graduation. |
| Trainer reading handoff repaired (`accadd1f`) | Existing Viewer loads captured PGN content and owns edits/copy/close | Deletes the relative temporary-file writer that produced an unreadable Viewer path. Existing immutable handoff carries ordered content/title/index/ply; collection metadata restores its title through navigation. Five-file scope 4,404→4,442 (+38 handwritten): correctness growth, not a simplification pass. Independent review, 45 focused tests and actual Linux Read/edit/Save-copy/return pass; original sources remain unchanged. Browser ownership/bulk-save repair is recorded separately below. |
| Trainer browser binding and bulk recovery repaired (`22e28fa3`); reduction gate unmet | Browser uses the existing session directly; one existing progress queue owns admitted bulk/exclusion writes and durable reload after partial failure | Deletes 20-value/callback forwarding and duplicate chapter matching (−49 lines), but necessary partial-save/source-lifetime repair adds 185. Complete seven-file scope 4,440→4,576 (+136 handwritten); generated +19 separately. Independent review, 273 focused tests, three Linux native journeys and inspected recovery/reload screenshots pass. This is a correctness repair with clearer binding, **not a simplification pass**; it does not authorize broader extraction. No new progress owner or queue; stable filesystem source identity remains open. |
| Document-store selection consolidated (`654898bf`) | Collection, Study and Generation require the one store chosen by app composition | Deletes six consumer-level fallback selections and the collection’s alternate patch writer. Four-file scope 473→438 (−35 handwritten); seven-file composition/store/contract scope 965→930. Explicit adapter fixtures, real legacy conflict/uncertain receipts and native identity checks pass with affected Viewer/Study/main tests. Platform selection and unverified-host limitations remain unchanged. |
| Study chapter list consolidated (`c832d248`) | Sidebar and manager share the existing list and screen commands | Deletes the duplicate manager, search/reorder state and delete-confirmation implementation. Whole five-file scope 1,785→1,644 (−141 handwritten), including screen growth of 22 lines; generated localization +110 separately. Independent review, 43 focused tests, two Linux native journeys and inspected wide/manager/search screenshots pass. Captured chapter identity and projection guards reject stale selection/reorder. Three legacy-theme consumers retired; the app’s wider Study dark boundary and whole-feature completion remain open. |
| Settings admission/notification consolidated (`e6016121`) | Existing section owner directly serializes read/edit/retry and publishes state for the three typed settings owners | Deletes the private SettingsSectionController, synchronous stream relay, subscription and duplicate disposal state. Whole declared owner/status/composition scope 487→454 lines (−33), no new owner/API and no consumer changes. Independent review plus 66 owner/runtime/control tests pass, including admitted writes after disposal and listener-submitted edits. This completes the redundant settings relay’s retirement, not whole Settings graduation. |
| Document contracts reviewed; retain justified boundaries | The 17 current contracts cover publication/recovery, worker cancellation, storage, engines, readers and native windows | Read-only audit found no substantial redundant contract: `DocumentSaveActions` has three production implementations; decoder/filter substitutes exercise real failure and stale-result ordering. A trivial path-helper forwarder is routine cleanup, not a reason to create another architectural workstream. |
| Builder editor and orphan layout retired (`1c0514f2`, `2ead1e6c`) | Builder directly composes its existing editor; unused layout implementations are deleted | Nine files removed, net −1,887 production lines across both reviewed scopes. Existing clipboard, annotation, title, branch undo, editor identity and Viewer splitter retained. Independent review, focused/native checks and compact/wide screenshots pass. Whole Builder renewal remains Partial. |
| Training completion consolidated (`e4468ea6`) | Existing session owns finish → persistence → tally → advance; results widget only renders and sends commands | Deleted widget scheduling, the 17-field forwarding constructor, rating wrapper and duplicate completion panel; complete six-file scope removes 146 production lines. Attempt identity, ordered captured writes, one invalidation path and reload ordering preserve completion through retry/source changes. Independent review, focused tests, Linux native persistence/reload and inspected screenshots pass. Whole Training remains Partial. |
| Viewer movement consolidated (`0f23a5a4`) | Existing reading owner dispatches navigation to the selected reader or its existing game/tree/Solitaire owners | Deleted `PgnPaneRouter` and duplicate supplier routing; full screen/parts/reading scope removes 44 production lines. Native fullscreen navigation now retains the primary reader; reference cursors, mode-specific board projection, autoplay cancellation and filter editing are preserved. Independently reviewed with focused and Linux native checks; whole Viewer remains Partial. |
| Obsolete analysis surfaces retired | Active Builder/Viewer engine and database panes remain the only app routes | Twenty unused files and the writer's suggestion forwarder deleted: net −5,077 production lines, with no replacement owner. The live inline engine imports its existing result model directly. Independent import/caller and implementation reviews pass; 152 focused tests, Linux native Builder history and analyze/lint pass. Live coverage, engine-session and per-move undo behavior remain covered. |
| Obsolete eval-tree display retired (`5bcea12e`) | Live generation bundles retain only consumed tree/FEN/trap/config/probe data | Twelve unused feature files, nine private theme tokens and eager snapshot/metrics derivation deleted; complete 14-file production scope removes 3,363 lines. Independent review, 132 focused tests including native artifact reopen/resume/cancel paths, and analyze/lint pass. Retained tests assert the live tree and serialization contracts. This removes an unused feature, not an active workflow graduation. |
| Remaining unused presentation retired | Existing live people, training, lines, board and engine surfaces retain their owners | Fourteen unreachable dialogs/panels/helpers deleted with their two exclusively owned tests: −2,154 production lines, no replacement code. Independent tracked-entrypoint/caller and implementation reviews pass. Active algorithms and rendering helpers remain; this is retirement, not credit toward another workflow’s simplicity gate. |
| Generation run/job ownership consolidated (`b034067f`) | The existing session registers and settles its job directly; progress owns the clock and one notification schedule | Deletes screen-driven job creation, duplicate UI throttling, four runtime suppliers, two stable exporter suppliers and four Jobs-panel command callbacks. Complete 18-file scope shrinks by 54 handwritten lines; independent review, focused/native tests and inspected Pause/Resume/Cancel screenshots pass. Ordinary job statistics now share the 250 ms UI budget; lifecycle updates remain immediate. Whole Generation remains Partial. |
| Chapter read/create consolidated (`d010bd5b`) | Existing catalog handles reads and exclusive creation through the app-selected document store; consumers accept only acknowledged writes | Deletes `ChapterStore`, its duplicate results, the Builder sibling cache and refresh fanout. Progressive course reads and captured selection guards survive A/B/A navigation, delayed creation, collisions and uncertainty. Complete scope: app −12 lines, Widgetbook fixture +14, combined +2 after a necessary isolate-capture repair. Ownership is clearer; this is not a substantial size reduction. Independent review, caller/native tests and desktop evidence pass. |
| Study chapter actions consolidated (`3ba80b27`) | Menus dispatch directly to the screen’s existing commands using the captured chapter identity | Deletes the six-callback holder: whole four-file scope −29 lines, including the compact-menu stale-target repair. Independent review, 29 focused tests and wide/900px compact desktop evidence pass. The observed 750px toolbar overflow is repaired separately (`78fb52cc`, +13 production lines): existing save/rename controls adapt to compact width, with 26 focused tests and inspected native evidence. This is layout correctness growth; it does not change this action-dispatch scope’s −29 result. Whole Study remains Partial. |
| Unused master-practice review retired (`def67780`) | Existing live entrypoints retain their database, explorer and generation behavior | Three unreachable production files and four exclusive tests/fixtures removed: −1,163 production lines, no replacement. Independent tracked-entrypoint review and 71 live-caller tests pass, with two explicit opt-in skips. This retires an unused feature, not an active workflow. |
| Dormant Viewer custom tabs retired (`cab63c49`) | Fixed workspace tabs use immutable titles; the screen uses its live Book, filter and game owners directly | Deletes an unreachable picker/database/reference-tab cycle, five maps, custom ID/title allocation and two widgets. Whole seven-file graph −397 production lines, including 87 removed from the screen. Independent control-flow/caller review, 47 focused tests and three native journeys pass. This removes dormant machinery from active consumers; it is not whole-Viewer graduation. |
| Captured manual chapter deletion repaired (`c92ee2e6`) | Existing catalog captures the selected document revision before confirmation and validates managed roots before native quarantine | Removes path-only deletion from picker/Outline and cached-count automatic Undo cleanup. Conflicts preserve replacements; uncertainty retains selectable evidence without retry or stale selection effects. Undo returns lines but keeps the created chapter. Independent review, 192 focused tests and six native journeys pass. +272 handwritten app lines, +8 Widgetbook and +113 generated localization: safety growth, not simplification. Verified manual deletion is Linux-only; unsupported hosts refuse before mutation. |
| Catalog remaining mutations are open | Captured document identity, recoverable namespace changes and training-reference ownership must agree before rename/move/delete can be complete | Splitter safety is repaired (`7e09cf81`, +306 handwritten lines). Manual replacement deletion is repaired above; baseline regressions still prove incomplete/late training-reference updates. Destination clobber is repaired at the existing native move boundary (`e59c351b`, +19 Dart/C lines); source identity and full relocation remain open. Do not add a rename journal facade before resolving stale training writes and path reuse; the proposed wider rewrite is not admitted. Existing-chapter mutation, line transfers, the temporary catalog adapter and legacy Library organizer still block whole-catalog completion. |
| Complete the next domain | One domain's commands, consumers, design-system controls and legacy retirement finish together | Apply the same ownership/consumer review before expanding. Singular/plural repertoire consolidation follows actual remaining responsibilities, not another directory-only move. |

The active plan contains decisions, remaining work and acceptance contracts.
Append detailed test runs, checkpoint narratives and screenshots to
[the evidence record](ARCHITECTURE_RENEWAL_EVIDENCE.md); update the owning status
row here instead of adding another execution diary. Historical "completed"
entries establish only their explicitly named responsibility and tested commit.

## Reading map

- [Maintainability correction](#maintainability-correction-and-next-cutovers),
  [evidence history](ARCHITECTURE_RENEWAL_EVIDENCE.md),
  [principles](#engineering-principles-and-useful-abstraction),
  [boundaries](#target-layout-and-dependency-rules),
  [packages](#package-decisions), [settings](#settings-and-credentials) and
  [runtime state](#runtime-state-and-large-documents).
- [Desktop foundations](#early-desktop-foundations) and
  [engine supervision](#worker-and-engine-supervision).
- [Human factors](#frontend-principles-human-factors-as-acceptance-criteria),
  [dark UI](#visual-direction-a-calm-responsive-dark-workspace),
  [UI experiments](#presentation-experiments-without-data-model-churn) and
  [shell and panels](#persistent-shell-and-reusable-panels).
- [Data coexistence](#data-preservation-and-coexistence),
  [shared PGN API](#one-safe-pgn-mutation-api-and-shared-save-interaction),
  [overwrite gates](#storage-baseline-and-overwrite-prevention-gate) and
  [OS storage contracts](#filesystem-and-cross-process-contracts).
- [Milestones](#milestones-and-exit-gates),
  [continuation decision](#continuation-decision-after-milestone-2) and
  [working method](#working-method-checks-and-sizing).

## Outcome and scope

### Retirement is part of each workflow

The product owner's 2026-09-17 direction is explicit: retain the new architecture,
demolish the old one. Ownership extraction and removal of an old *path* are
checkpoints, not retirement when the same forwarding owner survives elsewhere.
Every workflow declared complete must satisfy ARCH-02:

- Name its superseded owner types, APIs and production callers before editing.
  Delete them at cutover, with zero remaining imports, re-exports or callers.
- Route widgets to the substantial state/command owners they actually use.
  Composition and cross-owner transactions may have a small lifetime owner;
  it must not reproduce the old forwarding facade under a different name.
- Keep one state authority and writer. Old on-disk formats may be decoded by the
  new infrastructure adapter; this does not require retaining the old service.
- Run failure/lifecycle and user-workflow parity checks against the new wiring,
  and add guards against restoring retired owner paths/types.
- Publish production additions/deletions separately from tests and generated
  files. A mandatory added-lines/deleted-lines ratio is not the gate: it rewards
  compressed code, unrelated deletions and missing tests. Actual retired owners,
  callers, writers and dependency edges are the required evidence.

Remaining transitional bridges make their replacement unfinished and block its
integration into local main. Milestone 7 audits retirement already completed
within each cutover. Temporary working checkpoints may be committed and backed
up on isolated task branches; finish and delete their scaffolding before
integration. Existing integrated scaffolding is retirement debt, not precedent
for adding more. A standalone safety fix that adds no transitional architecture
may still land independently with its regression evidence.

Immediate Viewer removal scope: delete `PgnViewerController` itself, migrate
screen/widget consumers to collection/editor/filter/presentation/tree/Solitaire
owners, and consolidate document-session cancellation before or with cutover.
Invalidation must precede cancellation; cleanup must be idempotent, terminate
owned workers/timers and prevent late publication while preserving pending save
and recovery semantics. A single helper must not indiscriminately reset unrelated
state or pretend an in-flight storage commit has been cancelled. The supplied
six-row review identifies recovery adoption, file open, decoded adoption, pasted
content load, retained-context replacement and close. Exercise every path with
delayed collection/game/filter/index/analysis work, autoplay and Solitaire setup;
verify the shared cancellation contract plus each path's explicit retained state.
Keep data/cache revisions distinct from cancellation tokens. Remove mirrored
editor/presentation errors with the facade so consumers observe the owning state.
Parent owns this slice from `d6abb6d1`, with five active hours including one
validation reserve; midpoint is direct consumer wiring with the facade removed.

The Viewer host was still 1,609 lines after its path move. The initial
read-only audit applied the six-feature checker's direct rules to all 23
directories and found 414 coarse file/rule diagnostics. The implemented
whole-feature gate above replaces that hidden exclusion with an exact debt
ledger; its 1,493 initial entries count individual offending lines and duplicate
occurrences, so the counts use different units. Neither passing the ratchet nor
moving code to `legacy_features/` certifies migration. The named owners and
consumers still have to be deleted with the actual workflow cutovers.

Make the entire first-party application understandable, testable and consistent:
each workflow has a clear owner, each datum has one authoritative writer, and
each recurring interaction uses a documented component. Every existing module
will eventually be reviewed, moved, replaced or explicitly retired. A complete
architectural replacement does not require retyping correct algorithms or
rewriting third-party chess engines and libraries.

Deliver complete replacements incrementally in the existing product. Parallel
agents own independent cutovers with disjoint write ownership and agreed final
contracts. A dependency between cutovers is completed first or included in the
same integration batch; it is not solved by adding a transitional adapter. The
working application and its data remain usable throughout.

The capability inventory must cover all current modes: Tactics, Player analysis,
Repertoire builder, Repertoire trainer, PGN Viewer, Study, Engine tournament,
Bughouse lab, Databases, Repertoires, and Players & prep. Also inventory accounts,
settings, OS file opening, navigation history, imports/exports, background work,
recovery, offline behavior, optional assets, installers and updates. Include
first-party MCP/offline tools and their shared-file contracts in the migration
review; do not rewrite their runtime merely to match Flutter folders.
Use [the component map](COMPONENT_MAP.md) and actual code as starting evidence;
historical documentation and existing tests are not unquestionable specifications.

## Engineering principles and useful abstraction

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

## Target layout and dependency rules

Paths are relative to the repository. Migrated slices already use this layout
under the canonical Dart/UI guides. Remaining legacy owners move as their
workflows migrate; the feature directories below describe the target hierarchy,
not a claim that every workflow is complete.

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

Terminology mapping: infrastructure adapters perform the external-access role
called services in Flutter's architecture guide; repositories own domain data
and caching/retry policy. Retain the infrastructure name for a clear I/O
boundary. Connections and process supervisors necessarily have resource state;
do not force them into a stateless API solely for vocabulary alignment.

A separate internal Flutter package for the design system is an option after
the first catalog proves its API. Its dependency graph must exclude the app and
features; package boundaries still need import enforcement. Keep contracts near
the concept they serve: repository contracts with their domain, diagnostic
contracts in `diagnostics/`. Add a common result type only when callers share
its semantics, rather than creating a miscellaneous directory of interfaces.

Dependencies follow these rules:

1. App startup constructs final infrastructure, repositories and state owners
   and injects them. A replacement must not acquire an old singleton through a
   newly introduced wrapper. Follow dependencies to their actual owner: either
   an existing implementation meets the final contract and remains as final
   infrastructure, or replace it and its affected callers in the same cutover
   (or a completed prerequisite). An injected legacy bridge is still legacy.
2. Feature widgets use their controllers, models and the design system. Shared
   design-system widgets receive values/callbacks, never feature repositories.
3. Controllers call repository contracts or substantial workflow collaborators.
   They do not open files, execute SQL, start processes or depend on widgets.
4. Repositories orchestrate domain data through injected adapter contracts.
   Concrete infrastructure implementations are selected at app startup.
   A feature repository contract implemented directly by infrastructure is
   sufficient; do not add another port/adapter layer that repeats the same API.
   Cross-feature workflows use explicit public contracts; dependency cycles
   and imports of another feature's private controller state are rejected.
5. Pure Dart services, repositories and infrastructure receive dependencies
   explicitly through constructors; factories may assemble them. They do not
   accept `Ref`/`ProviderContainer` or look up dependencies globally. Provider
   declarations wire dependencies at the app boundary using the
   [selected composition policy](#one-composition-policy). Test domain classes without a
   provider container so hidden service-location cannot creep in.
6. Chess core and domain values do not depend on Flutter, Riverpod or concrete
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

Flutter dependency lookup and listening never introduce a second durable
source of truth: repositories
own persistence through the appropriate document, database or preference adapter.
Controllers translate user intent into repository/workflow calls; JSON parsing,
SQL execution and isolate/process supervision belong behind those boundaries.

## Package decisions

Use these defaults for remaining work; the composition decision above supersedes
the initial Riverpod experiment. Resolve SDK-compatible versions only
when needed, recording desktop support, license, transitive dependencies and
code removed. Retain already-working dependencies outside the migrated slice.
The implementing agent owns each technical check and fallback under PLAN-01.

| Decision | Default | Rejection check | Fallback / revisit trigger |
|----------|---------|-----------------|----------------------------|
| Catalog | Widgetbook with only first-slice production controls and fixtures. | Cannot run isolated/headless on the pinned SDK within the spike budget. | Use an isolated Flutter catalog harness temporarily; record the blocker and keep Widgetbook as the target. |
| Visual checks | Native Flutter widget/golden tests with readable bundled fonts. | Fixtures become costly to maintain or miss required scenarios. | Add Alchemist only if the same scenarios are simpler; retain native host checks. |
| State/DI | Explicit constructors plus Provider at Flutter composition; existing final owners retain their state and lifetimes. | Catalog/settings cutover loses retry, mutation lifetime, disposal or observation behavior. | Repair that complete cutover before integration; do not introduce another container or wrapper. Keep catalog/settings parity gates for subsequent composition changes. |
| Database | Existing SQLite adapters, schemas and migrations; defer Drift. | A scoped new store or replacement demonstrably needs safer typed queries/migrations. | Evaluate Drift for that ownership boundary only, with one schema/migration owner and migration/performance fixtures. |
| Models/codegen | Plain immutable Dart values/sealed classes and manual providers; retain existing codecs. Flutter ARB generation is allowed. | Boilerplate produces evidenced defects or excessive maintenance cost. | Introduce only the relevant Freezed or JSON generator after a timed clean/incremental build check; no blanket codegen stack. |
| Files | Retain atomic writer; inject narrow filesystem adapters with deterministic fakes and real OS tests. | Failure injection needs extensive ad hoc fake filesystem behavior. | Add package:file inside adapters; keep the native contract suite. |
| Network | Keep http behind existing API clients with one retry owner. | A concrete cancellation/streaming/auth contract cannot be met economically. | Trial Dio on that client with the same fixtures; no global replacement. |
| Navigation | App-owned typed destinations using existing Navigator under a persistent shell. | Back, deep-link/file-open or restoration fixtures require substantial custom routing machinery. | Evaluate go_router against the same session fixtures. It is not inherently incompatible with explicit session ownership. |
| Credentials | flutter_secure_storage behind CredentialStore when Accounts migration starts. | Native vault/restart/packaging tests fail on a supported host. | Preserve unmigrated credentials for recovery; defer that Accounts migration or implement a native adapter. Never downgrade new secrets to plaintext. |
| Panels | Defer splitting until workspace 3; then trial flutter_resizable_container behind SplitPane. | Bounds, keyboard, semantics or restoration checks fail within the spike budget. | Keep accessible fixed/reflowing panels; implement a narrow splitter only if the actual workspace needs it. |
| Stream shaping | stream_transform for periodic latest snapshots when analysis migrates. | Burst/terminal/cancellation tests fail or required semantics need awkward workarounds. | Small tested transformer; RxDart only for demonstrated wider needs. |
| Diagnostics/testing | Existing logging through a narrow interface, injected clock and hand-written boundary fakes. | Deterministic time or useful fake behavior requires excess plumbing. | Add clock/mocktail for that need; remote reporting and leak tooling remain separately justified. |

Retaining an adapter is not permission to write a routing framework, ORM or
code generator. In milestone 0, compare actual first-slice needs against these
rejection checks; include a bounded Drift query/migration spike only if that
slice needs a database change. Keep existing schema ownership otherwise. If
navigation starts accumulating generic URL parsing, restoration or branch-stack
machinery, trigger the go_router comparison before expanding the wrapper.
[Router restoration still needs explicit configuration](https://pub.dev/documentation/go_router/latest/topics/State%20restoration-topic.html)
and cannot restore arbitrary document/engine state for the app.
Do not combine Provider, Riverpod and Bloc as permanent parallel choices. The
retired Riverpod consumers must not return under ARCH-04; Provider is the
template for new features. No provider wrapper, code generator or automatic major
upgrade is required for this consolidation. Record the tested SDK and lockfile;
test retry, disposal and observation on that exact combination. A future codegen
exception records iteration cost and generated-file policy without changing
resource ownership or input validation.

## Settings and credentials

Introduce one injected `AppSettingsRepository` entry point with typed engine,
eval-database, training and display sections. Separate sections are useful;
duplicate ownership of the same setting is the problem. Each persisted key has
one writer, validation/default rules and an observable committed value. Retain
existing keys through adapters until each section migrates; legacy and new
callers must reach that same owner. Avoid a giant mutable settings object and
whole-app rebuilds: callers observe only the section they use. Keep account
secrets out of settings snapshots, serialization and diagnostic exports.

Define loading, draft, saving and failed states; do not show a failed write as
saved. Serialize updates or apply field-level changes against the latest state
so two open panels cannot overwrite unrelated values. Engine jobs capture a
validated effective configuration at start. Changing a preference during a job
must follow an explicit apply-now, queue or next-run rule; distinguish pending
preferences from the active job's configuration. Test conflicting panel edits,
load failure, invalid/legacy keys, save failure/retry, restart and a preference
change during a job. Establish the owner in milestone 1; prove the settings
used by the first slice in milestone 2 and migrate the rest with their features.

Use a separate `CredentialStore` for OAuth/PAT secrets. Evaluate
[flutter_secure_storage](https://pub.dev/packages/flutter_secure_storage) on
Linux, Windows and macOS, including Linux libsecret/keyring availability,
macOS Keychain configuration and the actual packaged Windows application.
Mobile platform support does not establish desktop readiness. Test a locked or
unavailable vault; keep offline features usable and show an actionable account
state. Do not silently fall back to plaintext for new credentials.

Before migrating the Accounts UI, implement an idempotent per-account migration:
read existing preferences, write and read back the vault entry, then remove
legacy secret keys only after verification. Persist progress without secrets;
restart after any step must neither lose the account nor restore a stale token
over a newer vault value. Serialize migration with login, refresh and disconnect;
disconnect clears both locations and any migration state so old tokens cannot
reappear. A failed transfer preserves the original for explicit retry rather
than pretending migration succeeded. Use synthetic credentials to test every
failure boundary and native restart. Exclude secrets from logs, Widgetbook and
ordinary settings backups. Define legacy-backup cleanup and old-app behavior
explicitly; migration cannot erase already-created external backups. Evaluate
the vault immediately before Accounts migration and complete its gate first,
even if the full settings/accounts UI remains in milestone 6.

## Runtime state and large documents

Provider composition does not own retries. Catalog refresh coalesces reads;
mutations reject overlap and failed mutations require explicit user action.
Appearance keeps its repository's failed draft and committed value separate;
subscribing or rebuilding does not replay a failed save. Tests cover repository
override replacement, listener disposal and synchronous initial emissions.

Use the feature notifier/controller as the sole UI action-state owner, with
an explicit repeated-execution policy (reject, coalesce or queue). Use typed
operation state within it, or AsyncValue for a simple load; do not wrap the same
operation in an independently mutable Command state machine. Shared helpers may
implement execution policy without owning a second copy of state. Domain
results remain typed; long jobs expose a job handle and progress. After
an async gap, validate the notifier's `ref.mounted` and captured session/request
identity before updating presentation. Persisted writes independently validate
the document revision. A liveness check alone does not reject a stale request
within the same still-mounted controller.

Shape engine presentation updates before they reach presentation state, after
protocol parsing and authoritative job-state updates. Keep completion, errors,
`bestmove`, cancellation and persistence events lossless and prompt. For a
continuous analysis stream, publish the latest accumulated analysis snapshot
on a bounded cadence (start by measuring approximately 200 ms), with immediate
terminal delivery and no delayed timer able to overwrite terminal state. A
snapshot must retain the latest relevant MultiPV lines, not just the last raw
protocol message. Clear pending output on position/job changes and reject stale
IDs. This limits UI notifications without slowing engine protocol consumption.

For a backend already running in a worker, aggregate presentation snapshots
in that worker before `SendPort` delivery. Do not send every raw engine line
only to discard it on the UI isolate. Keep protocol completion/errors and
explicit job results on a lossless control path; presentation messages carry
job/position/revision IDs and bounded payloads. Test send counts/bytes, slow
consumers and pending-message bounds as well as UI rebuilds. A cadence alone
does not bound queues when the receiver stalls: allow one in-flight snapshot
and coalesce the next until acknowledged, or prove an equivalent bounded design.
For direct async subprocess adapters, apply shaping at their producer boundary;
move parsing into a worker when profiling warrants it, not solely to add an
isolate. STATE-03 covers both backends and preserves terminal-event ordering.

Pure trailing [debounceTime](https://pub.dev/documentation/rxdart/latest/rx/DebounceExtensions/debounceTime.html)
waits for a quiet interval and can starve updates during continuous search;
reserve that behavior for inputs such as search text. Evaluate a tested
[stream_transform](https://pub.dev/packages/stream_transform) audit/sampling
operator or a small equivalent against the required leading/trailing behavior.
Use fake time to test an endless burst, sparse output, final output, errors,
position switches, cancellation and re-subscription. Assert bounded buffering
and periodic progress; widgets should not each implement their own timer.

Regardless of the listening mechanism, for every large document state,
record the cost of copying, equality and selector evaluation. Prefer a private
session-owned mutable document core with immutable revision-keyed projections
for the first workspace experiment; structural sharing is an alternative to
benchmark. Neither design may expose an old "snapshot" that changes later via
an aliased mutable tree. Keep immutable values for small configuration/state.
Do not deep-copy or structurally compare a whole move tree for every hover or
cursor change. Emit a new immutable projection when its observed data changes;
equality uses session ID, projection kind/key and its relevant revision, never
tree structure. A document revision alone is insufficient for cursor/filter-only
changes: use a separate view revision or small selection value. Different
projections from one document revision must not compare equal accidentally.
Never place an aliased mutable tree inside a Freezed value. The storage
baseline is a separate content-sensitive revision used at commit.

Mutations enter through explicit session methods; the mutable core is never
exposed as provider/UI state. After an accepted change, build the immutable
projection and assign it to notifier `state` (or `AsyncData(projection)` for
async state). State assignment and the equality contract drive notification;
do not mutate an exposed object and compensate with manual `ref.notifyListeners()`
or introduce a second ChangeNotifier around the same state. STATE-02 checks
edit/cursor updates, unchanged projections and old snapshots: meaningful changes
notify, old snapshots remain unchanged, and unrelated projections stay stable.

Include receive-side decoding, object construction, projection building and
garbage collection in STATE-02 measurements, not just message-send time. For
large documents, the session may own its heavy mutable tree through a persistent
worker; keep parsing, indexing and expensive traversal there and request bounded
visible-node/ancestor projections by stable IDs. Do not reconstruct the entire
tree on the UI isolate after every worker response. Add paging and bounded
prefetch for expansion/search, ordered edit commands, revision-tagged responses
and stale-response rejection. The UI holds immutable projections and small
interaction state; the worker is not a second independent document authority.
Choose worker residency when the profile shows UI decoding/traversal exceeds the
budget; retain the simpler session-local implementation for small documents if
it passes. Test rapid navigation, edits during pending requests, worker restart
and rehydration from committed data plus explicitly retained unsaved commands;
a worker restart must not silently discard a draft.

Milestone 3 must benchmark annotated PGNs with tens of thousands of nodes,
wide/deep variations and repeated edits/undo/navigation. Capture per-edit time,
allocations, retained memory and frame timings against milestone 0 budgets.
Choose data structures from those results; no collection package, rope or
piece table is mandated without a measured need. Profile rebuild/repaint scope:
watch small projections, isolate expensive board/graph repainting where it
helps, and virtualize long lists with lazy builders/slivers and stable keys.
Use `itemExtent` or `prototypeItem` only for uniformly sized rows. Wrapped PGN
comments, variations and enlarged text need variable-height layout; fixed
extents are not a blanket performance requirement. Test scrolling and selecting
across those cases without truncation or eager construction of the full list.

Profile image memory alongside STATE-02's tree benchmarks. Flutter's
[ImageCache](https://api.flutter.dev/flutter/painting/ImageCache-class.html) already
has entry/byte limits; its live-image references and total process/GPU memory
need separate measurement. Retain defaults until representative piece sets,
textures and avatars justify a different budget. Decode near display size,
bound prefetch and release owned listeners/resources; tune maximumSize and
maximumSizeBytes at startup only with evidence, not as a substitute for fixing
retained images. Test repeated asset/theme changes for memory growth.

## Early desktop foundations

Inventory these requirements in milestone 0 and prove those used by the first
slice in combined milestones 1/2; defer unrelated foundations to their feature.

**Localization readiness (milestone 1).** Start with Flutter's standard
`flutter_localizations` and `gen_l10n`/ARB workflow unless a measured requirement
justifies an alternative. English is the initial source locale; translating
other languages is separately scoped. Migrated user-facing copy, validation,
tooltips and accessibility labels use localized messages with typed placeholders
and plural rules. Design-system controls accept resolved labels from callers.
Use locale-aware UI numbers/dates and directional layout. Keep inexpensive
long-label and text-scaling checks in the first slice; full pseudo-localization
and RTL catalog matrices wait until another/RTL locale is scoped. Keep PGN/FEN,
engine protocols,
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
retention limits and offline behavior.

Use structured diagnostic records (JSON Lines or typed key/value events) with
schema version, timestamp, severity, event name, operation/run ID and error cause.
Keep human-readable messages alongside stable fields; tools must not parse them
with regex to discover state. Redact secrets and sensitive user content before
writing/export, bound record size and test malformed/truncated log handling.

Wire framework errors through `FlutterError.onError`, uncaught root-isolate
errors through the SDK-compatible `PlatformDispatcher.onError`/zone setup, and
worker errors/exits through explicit error and exit ports. Preserve stack
traces, deduplicate reports and test asynchronous startup failures. The root
hook does not directly catch worker errors or every fatal native failure;
do not remove existing zone behavior without checking SDK initialization and
error routing. The process supervisor records `Process.exitCode` with platform
interpretation and engine/run identity.

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
release. Preserve release-tag-only GitHub CI and user-requested publication.

Include native macOS menus where supported, scoped `Shortcuts`/`Actions`/
`Intent`s, focus traversal groups for workspace zones, and focus restoration.
Text editing takes precedence over mode commands and needs actual tests even
with framework shortcut routing. Validate saved window bounds when monitors
change. Record screen-reader coverage, renderer and rendering-test setup per
desktop target instead of assuming identical behavior. Include Flatpak file
portals, engine execution and platform-owned updating in the distribution
matrix; record a policy for user-supplied/quarantined executables on macOS.

Keep existing `integration_test` and headless driver coverage, and extend real
desktop journeys rather than assuming a new runner is necessary. Native OS
dialogs, signing and installers need host-specific checks beyond Flutter widget
automation. Patrol can be evaluated for a supported target, but its currently
listed targets do not include Linux or Windows, so it is not the default
three-desktop test harness.

## Worker and engine supervision

Own child processes and their descendants through one supervisor. Its shutdown
contract includes unexpected parent death, not just orderly disposal. For each
bundled and supported custom engine, test stdin EOF while searching and idle;
do not assume all UCI implementations exit promptly. Keep stdout and stderr
drained even with no visible UI, retaining bounded ring buffers and dropping
diagnostic excess. Test a chatty fake engine so output cannot deadlock search.

Before adding a native launcher, run a bounded PROC-02 spike against the
existing Dart Process/engine-lifecycle path and supported engine versions.
Test forced parent termination during startup, idle and search, stdin EOF,
descendants and redirected-output handling on available hosts. Reuse that path
where it passes; reuse a maintained adapter/helper where it meets the same
contract before writing new native code. A cleanup callback in the app cannot
run after the app is killed, so orderly `dispose`/Process.kill tests alone are
not enough. Record exact engine/host coverage, gaps and spike effort under
PLAN-01; no fixed multiweek native project is implied by this plan.

If existing mechanisms fail, the following are fallback designs for the affected
backend, not a prerequisite to unrelated first-slice UI work. A helper is scoped
to launching/supervising an engine; it is not an installed background daemon.

Windows fallback: a native engine-launch adapter creates children inside
a kill-on-close Job Object before execution, using a creation-time job list
on supported Windows versions or suspended creation, assignment and resume.
Keep the owning job handle non-inheritable. A failed assignment must terminate
the still-suspended child, not run it uncontained. Exercise nested-job and
launcher constraints. This avoids attaching the entire app (including external
openers/updaters) to an engine job or killing the app when its job handle closes.
App-level membership is an alternative only after those lifecycle effects are
accepted. [Microsoft's creation-time job design](https://devblogs.microsoft.com/oldnewthing/20230209-00/?p=107812)
is a native alternative to the race in start-then-assign wrappers.

Linux/macOS fallback: a small persistent supervisor launches the engine
in a separate process group and monitors a dedicated parent-liveness pipe.
Only the app owns the write end; engines/descendants must not inherit it. EOF
triggers group TERM, bounded wait, then KILL and reaping. The supervisor must
remain alive outside the killed group; it cannot exec into the engine and
still watch the pipe. Test startup handshakes, parent death before launch,
normal shutdown and inherited-descriptor leaks. Linux
[parent-death signals](https://man7.org/linux/man-pages/man2/PR_SET_PDEATHSIG.2const.html)
are thread-parent-sensitive and are only a supplemental mechanism.

Process groups do not contain descendants that escape via a new session/group.
Linux [subreaper mode](https://man7.org/linux/man-pages/man2/PR_SET_CHILD_SUBREAPER.2const.html)
helps adopt/reap orphans; it does not automatically signal all escaped children
and is not a macOS API. Engines using this fallback must remain in its
supervised group. Explicitly test engines requiring stronger containment and
withhold support until their tracked-descendant strategy passes. Package/sign the helper
on macOS and exercise Flatpak engine permissions. Keep engines inside the
sandbox by default; host spawning needs a separately justified support policy.

Scope forced-exit tests to the disposable app's tracked process tree. Establish
the verified containment or parent-liveness mechanism before useful work, then
kill the app during idle and active search; verify the bounded cleanup deadline and document/lock recovery on restart.
If a host mechanism fails its acceptance tests, retain an already-proven backend
or mark that backend unavailable; never claim cleanup coverage without the
verified mechanism. Failed checks stay explicit while unrelated work proceeds.
Record native checks not yet run as unverified, and never kill by process name.

Give every worker, `ReceivePort`, subscription and timer a named owner and an
idempotent shutdown path for success, failure, cancellation and partial startup.
Use a lifecycle table to distinguish view subscriptions, document-session
resources and app-owned jobs. Widget disposal releases view resources; it must
not kill a shared worker or continuing job. Job/session/app shutdown cancels
work cooperatively, escalates if needed, observes worker exit and closes ports
and subscriptions in an order that still permits shutdown acknowledgement.
Repeated open/close, failed startup and cancelled-job tests must return resource
counts to baseline, while route changes preserve deliberately continuing jobs.

Measure worker startup, input serialization, transfer and output costs before
moving large trees between isolates. `TransferableTypedData` makes transfer
cheap but constructing the buffer still costs proportional to its size;
immutable objects and `Isolate.exit` have different transfer behavior. Repeated
work may justify a persistent worker and typed protocol, with bounded queues and
cooperative cancellation. A worker isolate is not an OS memory-limit boundary.

Native handles have deterministic close/release owners. Use `NativeFinalizer`
only as an eligible cleanup backstop; it cannot guarantee cleanup on app crash.
Choose callbacks according to the library's thread and return-value contract:
`NativeCallable.listener` supports asynchronous void callbacks from foreign
threads, with argument memory kept alive until delivery. Record close ordering
and thread-local constraints; do not assume an isolate pins work to one OS
thread. Evaluate Dart/Flutter native build hooks against the pinned SDK and
actual libraries before replacing existing native packaging glue.

## Frontend principles: human factors as acceptance criteria

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

Evaluate representative scenarios with the product owner and, when feasible, chess
players unfamiliar with the app. Record completion, assistance, mistakes,
recovery, time and perceived effort. Scripted UI tests and heuristic review
cannot substitute for observing a person. Set numerical targets after measuring
the baseline; do not invent improvement percentages or count clicks as the
only measure of usability.

Under UI-01/UI-03, exercise the migrated workflow with NVDA on Windows,
VoiceOver on macOS and Orca on Linux before declaring that host verified. Record
OS/Flutter/reader versions, keyboard operation, focus and announcements; missing
host access remains unverified. For the board, expose square, piece, selection
and available actions (for example, “e4, white pawn, selected”); for splitters,
expose label, value and increase/decrease actions. Use Flutter
[Semantics](https://api.flutter.dev/flutter/widgets/Semantics-class.html) and
appropriate actions or render-object semantics. Do not merge a board or several
independent controls into one node: [MergeSemantics](https://api.flutter.dev/flutter/widgets/MergeSemantics-class.html)
is for content representing one semantic control. Widget semantics tests
complement real-reader checks; neither a class name nor default labels establish
usability. Preserve a keyboard-accessible path for custom pointer interactions.

## Visual direction: a calm, responsive dark workspace

The rewrite should feel clean, modern, minimal and
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

Implement custom theme roles with a typed
[ThemeExtension](https://api.flutter.dev/flutter/material/ThemeExtension-class.html),
registered in every production/catalog theme with `copyWith` and `lerp`.
Keep standard roles in `ColorScheme` and `TextTheme`; extend only app-specific
roles such as evaluation colors and workspace surfaces. Supply explicit light
and dark values: the extension does not choose accessible colors automatically.
A shared accessor resolves the current theme instead of reading a global color
constant. Keep invariant spacing in shared tokens without forcing it into an
extension. Migrate each component completely and retire its obsolete constants;
new migrated code must not introduce screen-local colors or text sizes. Maintain
a shrinking legacy exception list with owners. Widgetbook and focused checks
cover theme switching, contrast, interpolation and enlarged text using the same
production widgets; token types alone do not prove visual consistency.

Wire the shared appearance preference to `MaterialApp.theme`, `darkTheme` and
[themeMode](https://api.flutter.dev/flutter/material/MaterialApp/themeMode.html).
System mode follows OS brightness; explicit light/dark choices remain stable
when the OS changes. Preserve the product's chosen default. Widgets read the
resolved theme rather than each subscribing to platformDispatcher. Test OS
brightness changes, explicit overrides and restart, with the same ThemeExtension
roles present in both themes and no loss of focus or document state.

Dark appearance is a design preference, not a universal claim of reduced eye
strain. Inspect the actual app on ordinary displays in both dim and bright
rooms, with platform scaling and larger text. Large bright surfaces and dense
low-contrast gray text both need deliberate review. Ensure diagrams and images
remain legible; do not invert chess piece assets or illustrations automatically.

Milestone 1 is the design work inside the first slice, not a separate framework
phase. Build/catalog only controls used by that slice. Keep the following visual
loop within its estimate; defer unused widgets, vault and split-pane spikes:

1. Start with one restrained visual treatment; compare a second only if a
   concrete usability/style question remains. Use the same repertoire task with
   real-looking long names, counts, selection and error states. Compare density,
   surface separation and accent treatment without changing the task itself.
2. Review the working slice or unresolved alternatives with the product owner, including
   keyboard use. Choose one direction and record the decision here before
   migrating its appearance across the app.
3. Encode the selected values in the production theme and reusable components.
   Include interactive examples for the state combinations above in Widgetbook.
   The catalog consumes production code; it must not maintain prettier copies.
4. For each migrated screen, review an actual workflow with representative data,
   a narrow window, enlarged text, failed/slow work and repeated clicks. Check
   task clarity and interaction feel as well as screenshots. Record usability
   findings and fix shared causes in the component/theme owner.

Use these references for complementary purposes. The reading shortlist was
selected from author/publisher descriptions and publicly available material.

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

## Persistent shell and reusable panels

Keep Actions/View/Settings and the owning mode context available while opening
repertoire/chapter pickers or generation planning within that mode. Compose
these destinations under a persistent shell; compare a body switch/nested
Navigator by default. Use the package-decision rejection checks before a
[go_router ShellRoute](https://pub.dev/documentation/go_router/latest/go_router/ShellRoute-class.html)
trial. Deliberate modal tasks may cover the shell, but ordinary
navigation should not discard it. Route retention alone does not preserve a
document: sessions own board position, drafts, selection and history, while
features own scroll/filter state with an explicit restore policy. Define Back,
picker cancel/results, deep links, focus return and unsaved-work handling once.
Test opening a picker, cancelling it, switching modes and returning with the
same position/draft; toolbar commands must target the visible destination.
Include the persistent shell in milestone 2 and full workspace restoration in
milestone 3. Hidden branches still follow the job/visibility policies above.

If the routing fallback adopts go_router, distinguish shell chrome from branch
history. [StatefulShellRoute](https://pub.dev/documentation/go_router/latest/go_router/StatefulShellRoute-class.html)
provides independent branch navigators; prefer its indexed-stack form when
modes need retained nested stacks. A plain ShellRoute alone is not evidence of
that retention, and retained widgets do not replace session ownership or restart
restoration. Under UI-02, test a nested destination, scroll/filter selection and
board draft across a mode round trip, then separately test disposal/recreation
from the session. Bound retained-branch memory and keep hidden interactive
resources subject to visibility policy. The current Navigator-based default
must satisfy the same tests without adopting a router merely for its name.

In milestones 2/3, profile navigation with DevTools frame/rebuild evidence
under STATE-02/UI-02, using the selected Navigator or router. Keep dependencies
scoped to the panels that need them and use const constructors where useful.
The goal is bounded work and preserved state, not zero shell builds: theme or
layout changes legitimately rebuild it. Auto-dispose follows resource ownership;
it is not a remedy for rebuilds and must not discard retained sessions/jobs.

Create one reusable `SplitPane` with named panel slots, minimum usable sizes,
resize commands, focus/semantics and an optional layout-change callback. Evaluate
[flutter_resizable_container](https://pub.dev/packages/flutter_resizable_container)
behind that boundary so feature widgets do not depend on its controller/types.
It provides sizing constraints and programmatic resizing; keyboard behavior
and accessibility must be demonstrated by the shared component. Allow arrow-key
adjustment with visible focus, an announced value and a discoverable reset;
respect text-field shortcut scope. Prevent accidental zero-width panels and
support deliberate collapse with a clear reopen action where useful.

When minimum sizes no longer fit, reflow/collapse/scroll deliberately rather
than forcing a four-column layout at a fixed breakpoint. Restore validated
layout preferences by workspace and available size, clamping stale values when
monitors or text scale change. Persist at resize completion or a bounded cadence,
not on every pointer event. Catalog/test nested splits and long labels,
keyboard-only resizing, pointer drags, cancellation, small/ultrawide windows,
200% text and saved-layout recovery; add RTL when scoped. Prototype and prove
the control with the workspace in milestone 3; keep panel composition
flexible for later UX experiments.

## Presentation experiments without data-model churn

Revisit how expectimax, generated lines, chapters,
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
unchanged.

## Data preservation and coexistence

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

**Adapter cutover and rollback (DATA-06).** Drift is deferred, so the first slice
has no Drift/legacy production cutover. Any later adoption must first rehearse
this procedure on disposable database copies. Share one connection owner and
migration authority for the file; don't run independent old/new writer pools
or migration hooks. Coordinated SQLite connections are not inherently invalid,
but busy handling and cache invalidation must be explicit. Drift documents that
[independent instances do not synchronize stream queries](https://drift.simonbinder.eu/isolates/);
external/legacy writes therefore need a tested refresh path if allowed.

On repeated contention or a failed cutover, stop admitting mutations for that
store, retain pending intents/drafts, and let tracked transactions finish or
roll back before closing the replacement connections. Verify the actual schema
and latest committed data. A separately invoked recovery tool or previous application version may reopen
through its adapter only if it is compatible with the current schema, then
reconcile pending operation IDs before retry so committed work is not duplicated.
Do not retain the old adapter as a runtime fallback in the replacement app. Never delete live WAL/SHM files to
clear a lock or switch adapters while the old pool still owns transactions.
If quiescence or compatibility cannot be established, keep that store in a
recoverable unavailable/read-only state; use the tested reverse migration/export
path or a forward repair. Do not restore a pre-cutover backup over newer commits.
Inject held-reader/writer contention, failures during switching, process restart
and post-cutover writes, and verify recovered records and subscription freshness
before enabling this migration in a normal profile.

## One safe PGN mutation API and shared save interaction

Centralization is the intended solution to the PGN
overwrite concern. Callers should not need to remember a checklist of locking,
existence, revision, backup and error-handling steps. Implement one injectable
`PgnDocumentStore` (working name) as the domain-facing boundary for every
user-document PGN mutation. It delegates to the tested atomic filesystem
adapter; it does not duplicate its low-level implementation or absorb unrelated
database/cache responsibilities.

```text
Feature action / editor / import / generated result
                -> PgnDocumentStore
                   -> atomic filesystem adapter
                <- typed outcome, validated before-content and committed revision
                -> shared save status / conflict interaction
```

The public API expresses intent. These are proposed operations to refine with
the first slice, not implemented method signatures:

| Intent | Safe contract |
|--------|---------------|
| Open a document | Return a snapshot containing document identity, revision and content. Distinguish absence from unreadable or malformed content. |
| Create a document or save a copy | Exclusively create at the requested destination; return a name collision without replacing anything. |
| Save an edited snapshot | Require the loaded identity/revision; reject replacement if the persisted baseline changed. There is no optional revision or default overwrite flag. |
| Append/import games or apply an edit | Use a bounded locked transformation or validate a prepared snapshot at commit. Return its validated before-content/baseline and committed content/revision together; never derive undo from stale controller memory. Check source-game/line preconditions and preserve unrelated text. |
| Undo a committed edit | Validate current storage against the history head's expected revision, initially the mutation's committed revision. On mismatch reject, retain history and offer a copy. After a confirmed commit, consume the entry and advance only a proven predecessor using the returned revision (DATA-03). No implicit merge or operational inverse. |
| Rename, move or recoverably delete | Use the same document ownership boundary, with collision checks and an explicit protocol for associated references/artifacts. Coordinate with saves so a queued edit cannot recreate or target the wrong chapter. |

The store owns validation, serialization against other app mutations, commit
checks, recoverable prior versions, failure propagation and committed revision
receipts. Protect the read-to-commit baseline through either a locked bounded
transformation or optimistic preparation with commit-time revision validation.
Parse/transform large snapshots outside the critical section; reject a changed
baseline or recompute against a fresh one under the operation's bounded policy. Do not claim
that in-app locks exclude arbitrary external editors.

Expose distinct outcomes such as saved, conflict, name collision, invalid
document and I/O failure, including enough information to preserve the user's
draft and offer recovery. Only a saved outcome advances the session's baseline
or clears dirty state. Features receive the store via repository/session
dependencies; raw `writeFile`, `File.writeAsString` and generic overwrite APIs
are unavailable to migrated PGN callers. Enforce this with import/API checks
and switch every affected entry point to the final store contract in the same
cutover; delete superseded write APIs rather than leaving a temporary adapter.

Build a reusable save-status component and conflict/collision interaction on
top of these outcomes. They show consistent saving/saved/unsaved states and
appropriate actions such as keep editing, save a copy, or inspect/reload the
newer document. Reload must preserve or explicitly resolve the dirty draft.
Any user-requested replacement is an explicit command checked against the
latest revision; dismissing a dialog never grants overwrite permission.
The UI receives state and callbacks and performs no disk operations itself,
so its appearance can be changed freely in Widgetbook. Background jobs consume
the same outcomes and surface them through job state without opening dialogs.

Test the central contract once thoroughly, then test that each feature calls
it correctly. The shared contract suite covers exclusive creation, stale saves,
concurrent append, lossless edits, conflicting undo, rename/delete versus queued
saves, interrupted commit/recovery and disk/read failure using disposable real
files and deterministic failure injection. Run relevant cases on native desktop
platforms. Fakes make feature tests fast but do not establish filesystem safety.
Separately test the reusable widget's actions, draft preservation, keyboard
focus and failure states with scripted outcomes; expose them in Widgetbook.

Add focused feature wiring tests for editor save, import, generation, undo and
chapter operations. They must prove that the correct captured document/revision
reaches the store and that failure is not reported as success. Do not copy the
atomic-write algorithm or its entire suite into every feature. Milestone 2
establishes this boundary and shared interaction; subsequent document-writing
slices must adopt it before their old writer is retired.

## Undo receipt provenance and history

DATA-03 has two separate guarantees: a valid expected revision prevents undoing
over later work, and a valid before-snapshot prevents undo itself from deleting
work that preceded the mutation. Require both at the shared mutation boundary.

A successful undoable mutation returns one storage-produced receipt containing
operation/document identity, the actual validated before-content and baseline,
committed content/revision, and any ordered logical step snapshots. Produce
these from the same accepted transformation/commit, including when preparation
occurs outside the lock. If validation causes a recompute, replace the receipt's
before-content and steps too. Do not reread after the operation to manufacture
a receipt from a different writer's content, or fill missing before-content from
controller memory. S0 uses exact decoded content under the existing storage
contract; the later native revision adapter preserves exact bytes/identity as
specified by DATA-04. An in-memory-only document instead uses its session's
validated state; it must never supply a fallback for a file-backed mutation.

Keep immutable mutation provenance separate from the undo history's current
expected-storage revision. Link a new receipt to the prior history head only
when its validated before-baseline matches that head's expected revision and
its before-content matches the predecessor's logical after-content. Record that
link when accepting the mutation. An intervening external edit or unrelated
mutation breaks the link; equal-looking content alone cannot repair it.

Example: edits produce A -> B -> C, and the current storage revision is rC.
Undo C validates rC and restores its actual before-snapshot B, returning rB2
because atomic replacement may change file identity. After confirmed success,
consume C and set B's undo expectation to rB2 only if the recorded predecessor
link and restored content prove B is the next logical state. Keep B's original
commit revision as provenance. The next undo validates rB2 inside the storage
mutation; an intervening write still conflicts. Never rebase an expectation by
reading arbitrary current disk content or attaching a fresh revision to old
snapshots. If C started from an external edit E instead of B, undo C restores E
and cannot re-arm the older B entry, even though C's own undo succeeded.

For a batched suggestion, the storage transformation creates logical states
S0 -> S1 -> ... -> Sn from the validated S0, but commits only Sn. Only the top
undo entry initially expects that commit revision; intermediate steps have
logical identities, not invented native file revisions. Each successful undo
commits the preceding logical snapshot and arms its proven predecessor with
the newly returned storage revision. Preserve one undo per actual added move;
duplicates/no-ops create no invented history. Validate complete ordered step
metadata before publishing the batch. Missing/short metadata must not silently
fall back to stale memory or leave a partially installed history; reject before
commit, or explicitly reconcile an already-committed result as a recoverable
contract failure. Preserve non-file-backed behavior through a separate session
contract rather than fabricating disk receipts.

Serialize mutation, undo and history publication in the owning document session.
A definite write failure/conflict neither pops entries nor advances expectations.
Reconcile an uncertain commit before changing history or replaying work. Once
a commit is confirmed, a later UI refresh failure must not replay the undo:
retain the committed outcome and recover presentation from it. Publish receipt
and stack changes coherently before accepting another session action.

Required DATA-03 regressions (S0 with content guards; later repeat with native
identity changes and shared-store fixtures):

| Scenario | Required observation |
|----------|----------------------|
| Controller loads A; external annotation produces E; single append produces C; undo | Restore E, including the annotation, on disk and in the session; never restore stale A. |
| External edit before a multi-move suggestion; undo every added move | All intermediate undos retain the external content and the final undo returns to validated E; no extra per-ply forward disk commits. |
| A -> B -> C; undo twice, changing native identity on every replace | Return to B then A without a false conflict; expect each actual returned commit revision. |
| External edit after append or between successive undos | Reject the affected undo, preserve external content and history; do not refresh its expectation to bypass conflict. |
| Local edit, external edit, append, then two undo attempts | Undo only the append to its validated baseline; do not bridge the external edit into older snapshot history. |
| Failed/uncertain undo, failed batch, duplicate add or malformed receipt | No false success, phantom entry or unsafe revision advance; retry/reconciliation preserves the actual commit outcome. |

Extend [the existing writer undo tests](../test/features/repertoires/repertoire_writer_undo_test.dart)
without losing successive undo, bounded history, per-move suggestion undo or
load/reset behavior. Adapt the missing-snapshot fixture to the explicit receipt
failure contract rather than preserving its unsafe memory fallback. Also audit
all pushUndo callers, including deletes, for the same baseline provenance.
These are required future tests, not claims of reproduced runtime failures.

## Safety prerequisite on current code

**S0 — Complete for the scoped Linux/current-code cases; see exit evidence above.** Recheck the findings below on
current code. Reproduce all three controller actions and snapshot undo with
interleaved writes and failure injection; record any finding already fixed with
its regression evidence. Fix confirmed lost updates using the existing locked
update/expected-content API. Verify conflicts propagate and preserve drafts;
for undo, implement DATA-03's storage-derived before-snapshots, verified history
links and successive/per-move expectation advancement. Include external edit
before append, as well as after append and between undos. Return the validated
before-content and committed baseline together through the existing editor API;
consume history only after a confirmed commit. Adding expectedContent alone
cannot fix a stale before-snapshot. Keep existing formats and dependencies.

Deliver this as a focused maintenance increment on local main with its backup,
before any rewrite slice changes document writes. It does not depend on new
providers, a byte-revision FFI adapter or a design system. Publishing remains
user-requested. Scope/estimate comes from reproduction, not an assumption that
all fixes are small. Broader inventory can proceed independently; no runtime
fix or test execution is authorized by this planning-document edit.

## Storage baseline and overwrite-prevention gate

The following records the starting inspection at `e477dc58` on 2026-09-16.
The controller/undo findings were reproduced and repaired in S0 (evidence above);
generation artifact publication remains unverified. Complete the ownership
inventory in milestone 0 and retain evidence for every migrated writer.

| Data | Current representation and ownership evidence | Rewrite requirement |
|------|-----------------------------------------------|---------------------|
| Repertoires and chapters | Documents `repertoires/` folders with chapter PGNs; the injected catalog creates through the selected document store; only `PgnSaved` authorizes adoption. Studies use multi-chapter PGNs in Documents `studies/`. | Keep user-authored text, annotations and stable references; separate user-visible grouping from physical storage decisions. |
| User/source games | Support `app_games.db`, with collection-scoped games and position indexes. Some tactics source games have no remaining standalone PGN copy. Player-analysis PGN generations also have an authoritative manifest. | Classify authority per collection; never treat the whole database or Support directory as disposable merely because some indexes can be rebuilt. |
| Analysis/build artifacts | Versioned analysis bundles and model games use `GenerationArtifactRepository`; legacy chapter-adjacent artifacts remain accessible through read-only recovery. | Track document revision, run/config identity and publication state. Expensive saved analyses and resumable work need an explicit retention policy; user edits to a companion PGN cannot be silently discarded as cache. |
| Training state | Review/progress/history CSV and attempt JSONL stores retain path references. Directory migration has recovery; chapter-file relocation and late-write identity remain incomplete. | Preserve scheduling/history and reference identity through chapter rename, move, split and import. Inventory all newer stores as well as legacy CSVs. |
| Recovery and upgrades | Atomic-write journals/backups, quarantined files, PGN recovery snapshots, SQL `game_trash`, and schema-upgrade backups serve different recovery purposes. | Define retention, restore and user-export behavior for each; do not equate temporary atomic replacement with a permanent version history. |

The shared atomic writer already supports exclusive creation, expected-content
checks, locked read/modify/write, and interrupted-write recovery. Those protect
only callers that use the correct operation. An atomic replacement can still
atomically install stale content over a newer edit.

Specific call sites to reproduce in S0 or the indicated artifact inventory:

| Inspection finding | Failure scenario to test | Required behavior |
|--------------------|--------------------------|-------------------|
| `RepertoireController.setRepertoireColor`, `setRootPosition` and `importPgnContent` read content then call `writeFile` without `expectedContent`. | Another writer commits between the read and replacement. | Apply a narrowly scoped change to current content under the storage transaction, or reject a stale revision without replacing the newer document. |
| `RepertoireWriter.addMoveAtPosition` and the first batch snapshot use controller-memory previousPgn, while the editor appends to freshly read disk content. | An external annotation precedes append; undo restores the older controller snapshot even if a post-append guard passes. | DATA-03: return validated before-content and committed baseline together from the mutation; derive every batch step from that baseline. |
| `RepertoireWriter.undo` removes its entry and writes an unguarded snapshot; the planned native revision adds identity changes on replacement. | A later annotation is overwritten, a failed write consumes history, or successive/per-move undo falsely conflicts under the proposed identity checks. | DATA-03: preserve receipts on failure, validate the history head and advance only proven predecessor expectations after a confirmed commit. |
| Generation artifacts include a replaceable `_model_games.pgn` companion and independently written analysis files. | Regeneration encounters an edited companion, or a crash/stale run leaves artifacts from different revisions. | Distinguish generated ownership from user edits, validate run/document identity at commit, and expose recoverable or stale output rather than replacing newer work. |

These are observable code patterns and plausible failure cases; they are not
proof of which incident the user previously experienced. Review exports, Save
As, study saves, generation completion, chapter moves and database imports too;
these examples are not an exhaustive inventory.

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
[Builder workspace](../lib/features/repertoires/controllers/builder_workspace_controller.dart),
[undo writer](../lib/features/repertoires/controllers/repertoire_writer.dart),
[chapter creation](../lib/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart),
[game store](../lib/services/game_store/game_store.dart),
[generation artifacts](../lib/infrastructure/generation/storage_generation_artifact_repository.dart) and
[schema guards/backups](../lib/services/storage/schema_guard.dart).

## Filesystem and cross-process contracts

In milestone 0, give each store a permitted-writer matrix: app instances,
workers, MCP/offline tools and external editors. "One writer" means one mutation
contract with serialization across cooperating processes, not one Dart singleton.
Current file mutations use a SQLite-transaction mutex across isolates/processes,
and `GameStore` already sets a busy timeout. Preserve those guarantees; do not
replace them with an in-memory lock or POSIX record lock without equivalent
tests. Tools documented as read-only keep read-only connections. Define bounded
contention handling, lock identity/order and supported filesystems for writers.

Measure lock wait and hold time separately with large PGNs and delayed I/O;
set budgets in milestone 0. The existing mutex is per normalized directory,
not the application data database: unrelated directories need not wait behind
one global lock. Prepare decoding/transforms and unique staged output outside
the lock when safe, then validate current bytes/identity, publish and record
recovery state within the transaction. Keep validation-to-replace serialized;
don't release a lock on timeout while its I/O can still complete. Budget digest,
flush and rename costs too; never skip validation to meet a latency target.
A one-app-per-profile policy is deferred unless the product owner selects it;
it cannot replace contracts for tools, external editors or multiple isolates.

V1 does not implement CFAPI/NSFileProvider hydration handlers or a cloud-sync
engine. Use normal [asynchronous file I/O](https://api.dart.dev/dart-io/File-class.html),
truthful pending/error state and the preservation contract below; waiting for
remote data is not by itself synchronous UI-isolate blocking. Keep outstanding
I/O bounded: a UI timeout may abandon a result but does not necessarily cancel
the underlying operation. Reject late results and do not launch unbounded retries.

Known sync-folder/capability hints may support actionable guidance to make a
file available offline or save a copy locally; path-name heuristics are not
reliable detection and cannot replace commit checks. Do not ban or relocate
user PGNs automatically. Live SQLite remains subject to the separate local-store
policy below. Native placeholder cases may use fault-injected fixtures plus
manual host checks; provider-specific APIs require a demonstrated requirement
and a separately budgeted increment. A warning does not make a failed save safe.

Treat Documents and external PGNs as potentially synced, remote or redirected.
Test unavailable/delayed placeholder reads, interrupted hydration, disk-full
errors, Windows sharing violations and independently created conflict copies.
Use bounded cancellable retries only for classified transient errors; access
denied can be permanent, and any retry must revalidate the source/destination.
Never treat a failed read as empty, automatically merge/delete similarly named
files or infer a conflict solely from a filename suffix. Show unresolved copies
for inspection. Watcher events are refresh hints; commit validation is required
even when no event arrived. Detect location capabilities where feasible and
handle failures safely when sync-provider detection is unavailable.

Choose an explicitly local, non-synced location for live SQLite stores and
cross-process locks; a folder called Support is not proof of that property if
the user/system redirects it. Existing locations need a separate copy/verify/
switch migration if unsuitable. Do not run WAL on unsupported shared-network
storage. Specify busy handling, transaction duration, long-reader/checkpoint
behavior and background query ownership. Any later Drift trial must retain a
single schema/migration owner and pass background-query and migration fixtures.
Backup through SQLite's snapshot
facilities; copying a live db/WAL/SHM file set is not a consistent backup protocol.

Distinguish UI revisions from persisted content identity. For the new typed
revision API, default to SHA-256 over exact stored PGN bytes (including BOM and
line endings, before decoding), together with the observed native file identity
and the app's document identity. Use device/inode on POSIX and volume serial plus
128-bit [FileIdInfo](https://learn.microsoft.com/en-us/windows/win32/api/winbase/ns-winbase-file_id_info)
on Windows. [Dart FileStat](https://api.dart.dev/dart-io/FileStat-class.html)
does not expose those IDs; implement the probe in an infrastructure native
adapter. Read bytes and identity from the same open object and revalidate the
path binding before commit. A mismatch, disappearance or unavailable identity
requires conflict/re-verification or save-as-copy; it never grants overwrite.

Native identity is an observation, not a permanent app document ID: replacement
and sync hydration can change it, and IDs can be reused after deletion. Test
same-byte replacement, symlink/hardlink aliases, BOM changes and unavailable
identity; define unsupported cases rather than promise detection of every
historical delete/recreate. Track cooperating app deletion/recreation using the
document lifecycle. External editors can still race between validation and
replacement; native IDs do not turn an ordinary rename into filesystem CAS.
Capture the new revision after each successful app replacement. The current
`expectedContent` compares decoded text; S0 uses that existing contract, never
passes a digest in its place, and does not wait for this native adapter.

Baseline durability remains recovery from app/worker termination, with a
specific flush protocol for the new adapter rather than an implied power-loss
promise. Preserve recovery artifacts until outcome is known:

| Platform | Planned commit protocol and validation |
|----------|----------------------------------------|
| POSIX local filesystems | Same-filesystem temp, write, fsync temp, validated rename, fsync parent directory; include both affected directories for moves. Use native support where Dart lacks directory flush. Inject failures at each step, including unsupported directory sync. [fsync reference](https://man7.org/linux/man-pages/man2/fsync.2.html). |
| macOS | Same recovery/namespace protocol; measure and explicitly select fsync versus F_FULLFSYNC for the data flush. Default full-sync for committed user-document saves where supported; exclude rebuildable caches. Record unsupported cases and latency before broad adoption. [Apple flush semantics](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/fsync.2.html). |
| Windows | Flush the staged file, use same-volume ReplaceFileW for replacement with tested backup/ACL behavior, and a separate exclusive-create path. Reconcile documented partial-failure states before retry. REPLACEFILE_WRITE_THROUGH is unsupported; MoveFileExW WRITE_THROUGH documents copy/delete flushing and is not by itself a same-volume namespace durability proof. [ReplaceFileW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-replacefilew), [MoveFileExW](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw). |

A flush failure after replacement may mean content was installed but durability
is uncertain. Reconcile the actual file and preserve recovery data; don't report
an ordinary pre-commit failure and blindly retry an append. Classify Windows
sharing/lock violations separately from permanent access denial. For retryable
replacement failures, use cancellable capped exponential backoff with a total
attempt/time budget and renewed revision checks; inject time in tests. A unique
same-directory temp avoids naming collisions/cross-volume publication, but does
not remove destination sharing violations. Test transient recovery, exhausted
retries and a destination edit during backoff. Reconcile uncertain commits before
retrying; never repeat the entire logical append blindly.
Filesystem/device/remote-cache guarantees
remain explicit. Current SQLite WAL/NORMAL settings can lose latest commits
after power loss; any stronger guarantee needs a separate measured policy.
Use deterministic crash points and seeded process-termination tests; killing
a process does not simulate lost hardware caches.

## Milestones and exit gates

S0 is **complete for the scoped Linux cases** and milestone 0 has a
**partial inventory** in the [evidence record](ARCHITECTURE_RENEWAL_EVIDENCE.md#persisted-authority-and-native-inventory-2026-09-17).
Milestone 1/2 is **Partial**; milestone 3 is **Partial**; milestones
4–5 are **Partial** (parallel ownership repairs below); 6–7 are **Not started**. Each row yields a reviewable result; later
rows depend on the contracts established earlier, not on an unbounded framework
build. Reorder later feature slices after the dependency inventory, with a
recorded reason. No current mode is silently dropped.

The implementing agent must revisit the storage baseline against the code at
the time of implementation, turn the overwrite-prevention cases above into
passing regression evidence, and report any unresolved cases explicitly. This
is a required acceptance gate for every slice that writes user data, including
UI work that introduces or changes save/import/generate/undo commands. Planning
entries and visual approval are not evidence that data safety has been tested.

| Milestone | Deliverable | Exit gate / evidence IDs |
|-----------|-------------|--------------------------|
| S0. Current-code safety prerequisite | Reproduce controller and undo findings; fix confirmed races independently using existing storage primitives. | DATA-01, DATA-03, TEST-01: external-before-append, successive/per-move undo and caller failure regressions pass; unresolved cases explicit; integrated/backed up without waiting for rewrite. |
| 0. Inventory and baseline | Parity/data/owner maps, host prerequisites, authorized scope, default decisions, first-slice effort/spike caps, validation reserve, midpoint checkpoint and performance/usability budgets. | PLAN-01: evidence report and bounded next increment; record platform gaps under OPS-01/OPS-02. S0 may proceed independently. |
| 1/2. First complete slice with its design foundation | Repertoire list/search/create/rename/open/recoverable delete, persistent shell, injected contracts and only the theme, ARB, settings and catalog components this workflow uses. Retain formats; rehearse the desktop/native paths it invokes. | ARCH-01; DATA-01 through DATA-06 for paths used; STATE-01; SET-01; PROC-01/PROC-02 on applicable hosts; UI-01/UI-02/UI-04; OPS-01/OPS-02; TEST-01. Product-owner visual review recorded, duplicated slice code retired, PLAN-02 continuation decision recorded. |
| 3. Document workspace | PGN editing/studies/chapters, board navigation, retained sessions and shared resizable panels built on demand. | ARCH-01; DATA-02 through DATA-06; STATE-02; UI-01 through UI-04; TEST-01: round-trip, undo/conflict, context and large-document budget evidence. |
| 4. Training | Training/tactics/scheduling/history on stable identities; a storage migration only if separately justified. | ARCH-01; DATA-06; SET-01; UI-01/UI-04; TEST-01: preserved history and deterministic scheduling, cancellation and resume. |
| 5. Analysis and long jobs | Analysis/generation/audit/ingestion through owned jobs and bounded presentation updates. | ARCH-01; DATA-02/DATA-05/DATA-07; STATE-01 through STATE-03; PROC-01/PROC-02; UI-01/UI-04; OPS-01; TEST-01: stale-result, burst, cleanup and resource-budget checks. |
| 6. Remaining workflows and platform surface | Remaining modes, accounts/settings, tools, assets and distribution complete the inventory. Perform vault feasibility/migration before Accounts. | PLAN-01; ARCH-01; SET-01; SEC-01; OPS-01/OPS-02; TEST-01, plus applicable data/process/UI IDs from the inventory. Every retained capability has evidence or an explicit scope decision. |
| 7. Whole-application verification and release readiness | Verify retirement already completed in each cutover; no deferred cleanup phase. Update current-state docs and finish cross-workflow/platform checks. | PLAN-01; ARCH-01/ARCH-02; DATA-06; OPS-02; TEST-01: every feature covered, no transitional bridges or retired production owners, parity/recovery evidence complete, full release gates pass before requested publication. |

Milestone numbers are retained for existing references: “milestone 1” now means
the on-demand design work within milestone 2, not a separate foundation project.
ARCH-02 blocks integration of every implementation cutover in milestones 1–6.
All applicable IDs remain binding on later slices; the table highlights checks
introduced there. In milestone 0 enumerate inherited IDs per workflow/host;
use explicit ID rows in evidence rather than leaving ranges unexpanded.
Unfamiliar-player studies are optional when feasible under UI-04; record whether
the product owner or another end user completed the representative task.

A module is not considered migrated because it moved folders. Each completed
slice must demonstrate the new ownership, tests, UX behavior and removal of its
superseded code. Preserve existing data compatibility in the final codec or
infrastructure implementation. Compatibility is not permission to retain the old
application owner, writer, forwarding API or runtime fallback.

## Continuation decision after milestone 2

PLAN-01 requires a filled budget record before combined milestones 1/2 start:
implementation-effort cap in hours, a separate cap for each spike, validation
reserve, owner and a midpoint checkpoint. Milestone 0 supplies the numbers from
scope and baseline evidence; a missing cap fails readiness rather than implying
unlimited time. Record active effort separately from queued tools or unavailable
host checks. Count design experiments and framework integration within the cap.

At the midpoint, compare completed acceptance scenarios with remaining effort
and narrow optional work if needed. At the cap, stop expanding implementation,
complete a safe checkpoint with drafts/data preserved, and record PLAN-02's
continue-with-revised-scope, bounded repair or stop decision. An extension must
state the added budget, scope and reason within the product owner's authorized
scope; it cannot be silently renewed. Never cut safety gates or interrupt a
storage commit to meet a timebox. This is an effort limit, not a calendar promise.

Compare the first complete slice with its baseline: task success/effort,
save/recovery reliability, feature-test setup, implementation effort, amount of
legacy code removed, runtime cost and unresolved platform dependencies. Continue
only with evidence that the pattern is tractable and improves maintainability
without worsening essential workflows or safety.

Stop expansion if the slice cannot remove its old owner, needs pervasive
cross-layer exceptions, regresses accepted data/performance requirements, or
costs substantially more than its bounded estimate without a credible fix.
Record the reason and narrow the next work to a time-bounded repair/evaluation.
If that does not resolve the evidence, end the broad renewal program and retain
useful shared components/safety boundaries through ordinary incremental
refactoring. Preserve all user data and valuable completed work. Sunk effort
and new-folder coverage are not reasons to continue. Set the estimate and
acceptance budgets before implementing the slice, then report actual results.

## Working method, checks and sizing

For each slice, keep a compact execution brief with its milestone evidence in
this document; do not duplicate the whole plan into a new prompt. The brief is:

- Exact starting commit, complete responsibility being replaced and observable
  user behavior; explicit non-goals cannot exclude a dependency required to
  delete that responsibility’s old owner.
- Final owner graph and contracts, all production callers/writers, and exact
  legacy types/APIs/files/dependency edges to delete. Inspect transitive wiring.
- Required acceptance IDs, failure scenarios, fixtures/UI examples, bounded
  check commands and required hosts; exercise the final production composition.
- Effort/spike caps, dependency order and data-format compatibility in final
  infrastructure. If deletion does not fit, revise the cutover before coding.
- Integration evidence: final wiring, zero references to retired APIs, no
  temporary layers, parity/failure results, production additions/deletions and
  exact committed branch. An incomplete checkpoint stays on its task branch.

Refresh the brief when the code or accepted scope changes. An agent resuming work
reads it, the linked contracts and applicable repository guidance, then verifies
the checkout; a stale prompt cannot override current code/evidence. Present a
reviewable diff and evidence at each milestone, identifying native or data-safety
uncertainties for review. Product-owner UX/scope decisions follow the existing
gates; routine already-authorized work needs no extra per-edit approval.
Implement the smallest end-to-end case, exercise failure paths, inspect it, and
then widen coverage.

Record substantial choices with status, alternatives, evidence and consequences
beside their owning section. Create a short ADR only when a cross-cutting choice
has actually been selected and needs its own history; do not predeclare every
candidate package as an accepted ADR. Update the component map only when a
change actually exists.

Estimate test work from a reuse inventory under PLAN-01: existing ci.sh checks,
headless driver, integration_test, storage fixtures and engine doubles first;
list only missing tests/harness changes for the slice. Separate feature, test,
packaging and host-validation effort within the cap and keep a validation reserve.
Do not mandate a 40–50% split without evidence or require every candidate tool
before the first workflow. Widgetbook grows with its controls; Alchemist and new
runners remain conditional. Reduce optional scope if validation does not fit;
never drop preservation or lifecycle checks to meet the budget.

Enforce architecture with import checks and analyzer rules: no widget I/O, no
domain-to-UI dependencies, no new singleton access in migrated code and no
unreviewed control styling outside the design system. Discover every feature
and ratchet exact existing violations; unknown features and new violations fail,
completed features have no exemptions, and the final baseline is empty. Do not
normalize violations by growing allowlists. Code generation must be reproducible and validated for drift.

Prefer an analyzer-based import/export check if regex guards cannot express
the boundary reliably. Verify the actual rules and SDK compatibility of any
lint/plugin; linting does not prove async lifetime correctness. Choose
one generated-file policy and validate regeneration in the existing bounded
checks/release pipeline. When generators are actually adopted, run their pinned
commands in a clean disposable check worktree (including gen_l10n where used),
then reject modified, deleted or newly untracked expected generated files.
`git diff --exit-code` alone misses untracked output. Use build_runner only when
needed; `--delete-conflicting-outputs` belongs only in that disposable check,
never as a cleanup shortcut on a shared dirty checkout. Do not regenerate/rewrite
approved golden images during verification or add branch-triggered CI here.

Use the existing bounded headless Linux environment for golden verification;
pin SDK, fonts, locale, scale, renderer and assets. Containerization is optional,
not proof of deterministic rendering. If native Windows/macOS goldens are added,
keep separate host baselines and enforce them on their configured hosts; missing
hosts are unverified rather than silently passing. Alchemist normalization does
not replace readable-text baselines or real interaction/semantics checks.

Under TEST-01, changes to chess codecs/rules need bounded seeded property tests
alongside explicit regressions. Generate legal move sequences and annotated
PGNs, verify agreed semantic round-trips and undo/invariants, then separately
mutate inputs to test invalid/truncated data. Align variant, en-passant, castling,
promotion, null-move and FEN normalization policies; exact-byte preservation is
required only by the relevant storage contract. Retain/minimize failing seeds
and inputs and keep independent reference fixtures so matching encoder/decoder
bugs cannot validate each other. Choose a generator/shrinker only if useful;
package:checks is an assertion API, not a property-input generator
([package documentation](https://pub.dev/packages/checks)). Evaluate leak tracking
for owned controllers/subscriptions alongside explicit lifecycle tests.

Retain the lockfile and native asset manifest, with a deliberate dependency
update/vulnerability-review process and a clear owner. Check existing bundled
license registration and distribution/source obligations during native packaging
changes; license UI alone is not the complete release obligation. No new
dependency, scanner, schedule or platform plugin is required solely because it
appeared in external review. Apply the package defaults and record deviations
against their rejection checks.

Use layered evidence: pure algorithm tests; repository contract/failure tests;
real filesystem and schema-migration fixtures; deterministic engine doubles;
widget interaction/semantics tests; selected screenshot comparisons; headless
end-to-end journeys; native platform integration and measured performance.
Compare semantic results against the old implementation where it is correct;
do not require identical nondeterministic engine output. Preserve existing
storage and engine regression tests until equivalent coverage is established.

Follow the normal task-worktree, bounded-check and automatic local-main
integration workflow. Each completed cutover remains independently usable and backed up. Backing up
an unfinished task branch does not authorize integrating its scaffolding.
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

## Design references

- [Riverpod 3 migration semantics](https://riverpod.dev/docs/3.0_migration),
  [Flutter commands](https://docs.flutter.dev/app-architecture/design-patterns/command),
  [transferable buffers](https://api.dart.dev/dart-isolate/TransferableTypedData-class.html),
  [native callbacks](https://api.dart.dev/dart-ffi/NativeCallable/NativeCallable.listener.html),
  [native finalizers](https://api.dart.dev/dart-ffi/NativeFinalizer-class.html),
  [root error handling](https://api.flutter.dev/flutter/dart-ui/PlatformDispatcher/onError.html)
  and [Windows process jobs](https://learn.microsoft.com/en-us/windows/win32/procthread/job-objects):
  runtime/lifecycle constraints verified during review.
- [SQLite corruption pitfalls](https://www.sqlite.org/howtocorrupt.html),
  [WAL](https://www.sqlite.org/wal.html),
  [synchronous settings](https://www.sqlite.org/pragma.html#pragma_synchronous),
  [Windows cloud-file placeholders](https://learn.microsoft.com/en-us/windows/win32/cfapi/build-a-cloud-file-sync-engine)
  and [Pillai et al., OSDI 2014](https://www.usenix.org/conference/osdi14/technical-sessions/presentation/pillai):
  storage/backup and crash-consistency references.
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
  primary documentation for selected defaults and deferred alternatives.
