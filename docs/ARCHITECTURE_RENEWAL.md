# Architecture renewal

**Status: Not started.** Planning baseline: 2026-09-16. This is the canonical
rewrite plan. [FUTURE_FEATURES.md](FUTURE_FEATURES.md) tracks feature backlog;
[COMPONENT_MAP.md](COMPONENT_MAP.md) describes implemented behavior. Update
milestone evidence and selected decisions here as work proceeds.

**Scope and authority.** This document specifies future work; writing it does
not implement, test or publish that work. Automatic checks use disposable data.
Retain proven code that satisfies the contracts. Non-goals are changing chess
semantics for visual polish, rewriting third-party engines, introducing cloud
sync or remote telemetry by default, translating every language at launch,
buying services, and replacing all storage formats at once. Product/data
behavior changes remain explicit; release publication follows the repository's
existing policy. These constraints apply throughout the plan.

## Execution contract and evidence

This is a plan, not an implementation kickoff. At kickoff, record the scope
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
| ARCH-01 | Migrated widgets/controllers cannot bypass injected domain boundaries; legacy singleton access is confined to injected bridge adapters. Verify import boundaries and feature wiring. | [Dependencies](#target-layout-and-dependency-rules) |
| DATA-01 | Reproduce each reported overwrite/undo race on current code; independently fix confirmed cases and retain regressions before rewrite-dependent writes. | [Safety prerequisite](#safety-prerequisite-on-current-code) |
| DATA-02 | Create never replaces; every save/update validates its baseline through the shared mutation boundary. Exercise concurrent creation, stale saves and competing writers. | [PGN API](#one-safe-pgn-mutation-api-and-shared-save-interaction) |
| DATA-03 | Snapshot undo requires the post-edit revision; mismatch preserves the current file and undo receipt, with snapshot-as-copy recovery. Test conflict and failed commit. | [PGN API](#one-safe-pgn-mutation-api-and-shared-save-interaction) |
| DATA-04 | Revision checks distinguish raw bytes and observed file identity; identity change/unavailability never silently authorizes replacement. Test BOM, aliases and replacement. | [Filesystem contracts](#filesystem-and-cross-process-contracts) |
| DATA-05 | Measure lock wait/hold times; interrupted and synced-file operations preserve recoverable content with bounded retries and explicit durability limits. | [Filesystem contracts](#filesystem-and-cross-process-contracts) |
| DATA-06 | Restore a consistent database/document backup into a disposable profile; migration preserves new work and stable references. | [Coexistence](#data-preservation-and-coexistence) |
| DATA-07 | Generation commits only against its source/run identity and preserves edited artifacts. Exercise stale completion and interrupted publication. | [Storage gate](#storage-baseline-and-overwrite-prevention-gate) |
| STATE-01 | One action-state owner implements reject/coalesce/queue; retries, offscreen listeners and stale callbacks cannot duplicate jobs or publish stale state. | [Runtime state](#runtime-state-and-large-documents) |
| STATE-02 | Large projections are immutable, cheaply comparable and scoped to their dependencies; measured edits/rebuilds meet the baseline budgets. | [Runtime state](#runtime-state-and-large-documents) |
| STATE-03 | Continuous analysis produces bounded periodic UI updates without losing terminal events; verify with fake-time burst tests. | [Runtime state](#runtime-state-and-large-documents) |
| SET-01 | One writer per settings key; failed saves stay visible and active-job configuration is explicit. Test concurrent panels and restart. | [Settings](#settings-and-credentials) |
| SEC-01 | Before migrating Accounts, verify native vault migration, restart and disconnect with synthetic secrets; no silent plaintext fallback. | [Credentials](#settings-and-credentials) |
| PROC-01 | Owned workers/ports/processes terminate on the specified cancellation/shutdown paths; test failed startup and return to resource baseline. | [Supervision](#worker-and-engine-supervision) |
| PROC-02 | Containment is established before engine execution; forced app death cleans up the supported descendant tree on each verified host. | [Supervision](#worker-and-engine-supervision) |
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

## Reading map

- [Principles](#engineering-principles-and-useful-abstraction),
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

1. App startup constructs infrastructure, repositories and state owners and
   injects them. Singleton access is confined to the temporary legacy bridge.
   For unmigrated services, startup injects adapters wrapping their existing
   singleton; a new feature never reaches `.instance` directly. Each adapter
   records callers and a removal milestone and passes the same contract tests.
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

## Package decisions

Use these defaults for the first slice. Resolve SDK-compatible versions only
when needed, recording desktop support, license, transitive dependencies and
code removed. Retain already-working dependencies outside the migrated slice.
The implementing agent owns each technical check and fallback under PLAN-01.

| Decision | Default | Rejection check | Fallback / revisit trigger |
|----------|---------|-----------------|----------------------------|
| Catalog | Widgetbook with only first-slice production controls and fixtures. | Cannot run isolated/headless on the pinned SDK within the spike budget. | Use an isolated Flutter catalog harness temporarily; record the blocker and keep Widgetbook as the target. |
| Visual checks | Native Flutter widget/golden tests with readable bundled fonts. | Fixtures become costly to maintain or miss required scenarios. | Add Alchemist only if the same scenarios are simpler; retain native host checks. |
| State/DI | Manual Riverpod providers/notifiers, one presentation action state per operation. | First-slice lifecycle/retry/override tests fail or integration exceeds its budget. | Retain injected current controllers for that slice; record why, with no second competing state library. |
| Database | Existing SQLite adapters, schemas and migrations; defer Drift. | A scoped new store or replacement demonstrably needs safer typed queries/migrations. | Evaluate Drift for that ownership boundary only, with one schema/migration owner and migration/performance fixtures. |
| Models/codegen | Plain immutable Dart values/sealed classes and manual providers; retain existing codecs. Flutter ARB generation is allowed. | Boilerplate produces evidenced defects or excessive maintenance cost. | Introduce only the relevant Freezed or JSON generator after a timed clean/incremental build check; no blanket codegen stack. |
| Files | Retain atomic writer; inject narrow filesystem adapters with deterministic fakes and real OS tests. | Failure injection needs extensive ad hoc fake filesystem behavior. | Add package:file inside adapters; keep the native contract suite. |
| Network | Keep http behind existing API clients with one retry owner. | A concrete cancellation/streaming/auth contract cannot be met economically. | Trial Dio on that client with the same fixtures; no global replacement. |
| Navigation | App-owned typed destinations using existing Navigator under a persistent shell. | Back, deep-link/file-open or restoration fixtures require substantial custom routing machinery. | Evaluate go_router against the same session fixtures. It is not inherently incompatible with explicit session ownership. |
| Credentials | flutter_secure_storage behind CredentialStore when Accounts migration starts. | Native vault/restart/packaging tests fail on a supported host. | Preserve unmigrated credentials for recovery; defer that Accounts migration or implement a native adapter. Never downgrade new secrets to plaintext. |
| Panels | Defer splitting until workspace 3; then trial flutter_resizable_container behind SplitPane. | Bounds, keyboard, semantics or restoration checks fail within the spike budget. | Keep accessible fixed/reflowing panels; implement a narrow splitter only if the actual workspace needs it. |
| Stream shaping | stream_transform for periodic latest snapshots when analysis migrates. | Burst/terminal/cancellation tests fail or required semantics need awkward workarounds. | Small tested transformer; RxDart only for demonstrated wider needs. |
| Diagnostics/testing | Existing logging through a narrow interface, injected clock and hand-written boundary fakes. | Deterministic time or useful fake behavior requires excess plumbing. | Add clock/mocktail for that need; remote reporting and leak tooling remain separately justified. |

Do not combine Provider, Riverpod and Bloc as permanent parallel choices.
Riverpod experimental persistence/mutations do not own durable data. No
riverpod_generator or go_router_builder is needed for the first slice. A future
codegen exception records iteration cost and generated-file policy; it does not
change resource ownership or input validation.

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

If Riverpod is selected, disable implicit provider retry at the composition
root (`retry: (retryCount, error) => null`); opt in only for bounded idempotent reads with
one retry owner. Provider computations must not start jobs or perform document
mutations. A dependency provider can expose an explicitly owned service, but
visibility, rebuilds and listener counts must not own its active work.
Test a failed observation, repeated clicks and route departure: one requested
job starts once and continues or stops according to its declared policy.
Observe paused/offscreen subscriptions under `TickerMode`, then return and
verify the latest job state without duplicated work or unbounded buffering.

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

Pure trailing [debounceTime](https://pub.dev/documentation/rxdart/latest/rx/DebounceExtensions/debounceTime.html)
waits for a quiet interval and can starve updates during continuous search;
reserve that behavior for inputs such as search text. Evaluate a tested
[stream_transform](https://pub.dev/packages/stream_transform) audit/sampling
operator or a small equivalent against the required leading/trailing behavior.
Use fake time to test an endless burst, sparse output, final output, errors,
position switches, cancellation and re-subscription. Assert bounded buffering
and periodic progress; widgets should not each implement their own timer.

Riverpod 3 filters updates using equality. For every large document state,
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

Milestone 3 must benchmark annotated PGNs with tens of thousands of nodes,
wide/deep variations and repeated edits/undo/navigation. Capture per-edit time,
allocations, retained memory and frame timings against milestone 0 budgets.
Choose data structures from those results; no collection package, rope or
piece table is mandated without a measured need. Profile rebuild/repaint scope:
watch small projections, isolate expensive board/graph repainting where it
helps, and virtualize long lists. Fixed item extents are appropriate only for
actually fixed-height rows; preserve variable movetext and text-scale layouts.

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

Default Windows design: a native engine-launch adapter creates children inside
a kill-on-close Job Object before execution, using a creation-time job list
on supported Windows versions or suspended creation, assignment and resume.
Keep the owning job handle non-inheritable. A failed assignment must terminate
the still-suspended child, not run it uncontained. Exercise nested-job and
launcher constraints. This avoids attaching the entire app (including external
openers/updaters) to an engine job or killing the app when its job handle closes.
App-level membership is an alternative only after those lifecycle effects are
accepted. [Microsoft's creation-time job design](https://devblogs.microsoft.com/oldnewthing/20230209-00/?p=107812)
is a native alternative to the race in start-then-assign wrappers.

Default Linux/macOS design: a small persistent supervisor launches the engine
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
and is not a macOS API. Default supported engines must remain in the supervised
group. Explicitly test any engine requiring stronger containment and withhold
support until its tracked-descendant strategy passes. Package/sign the helper
on macOS and exercise Flatpak engine permissions. Keep engines inside the
sandbox by default; host spawning needs a separately justified support policy.

Scope forced-exit tests to the disposable app's tracked process tree. Establish
containment before useful work, then kill the app during idle and active search;
verify the bounded cleanup deadline and document/lock recovery on restart.
If a host mechanism fails its acceptance tests, retain an already-proven backend
or mark that backend unavailable; never silently launch without containment.
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
                <- typed save outcome and committed revision
                -> shared save status / conflict interaction
```

The public API expresses intent. These are proposed operations to refine with
the first slice, not implemented method signatures:

| Intent | Safe contract |
|--------|---------------|
| Open a document | Return a snapshot containing document identity, revision and content. Distinguish absence from unreadable or malformed content. |
| Create a document or save a copy | Exclusively create at the requested destination; return a name collision without replacing anything. |
| Save an edited snapshot | Require the loaded identity/revision; reject replacement if the persisted baseline changed. There is no optional revision or default overwrite flag. |
| Append/import games or apply an edit | Use a bounded locked transformation or prepare from a snapshot and validate its revision inside the commit transaction. Check source-game/line preconditions; preserve unrelated text and annotations. |
| Undo a committed edit | V1 snapshot undo requires current revision to equal the receipt's post-edit revision. On mismatch, reject, retain the receipt and offer the snapshot as a new copy. Consume undo only after commit; no implicit three-way merge or operational inverse. |
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
and route legacy entry points through a temporary adapter during migration.

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

## Safety prerequisite on current code

**S0 — Not started; independent of the rewrite.** Recheck the findings below on
current code. Reproduce all three controller actions and snapshot undo with
interleaved writes and failure injection; record any finding already fixed with
its regression evidence. Fix confirmed lost updates using the existing locked
update/expected-content API. Verify conflicts propagate and preserve drafts;
for undo, verify the post-edit baseline and consume its receipt only after a
successful commit. Adding an expected-content argument without checking the
outcome at callers is insufficient. Keep existing formats and dependencies.

Deliver this as a focused maintenance increment on local main with its backup,
before any rewrite slice changes document writes. It does not depend on new
providers, a byte-revision FFI adapter or a design system. Publishing remains
user-requested. Scope/estimate comes from reproduction, not an assumption that
all fixes are small. Broader inventory can proceed independently; no runtime
fix or test execution is authorized by this planning-document edit.

## Storage baseline and overwrite-prevention gate

The following is a code-inspection baseline from 2026-09-16. The findings need
reproduction and resolution in S0 for the controller/undo paths. Build the full ownership
inventory in milestone 0; retain evidence for each migrated writer.

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

Specific call sites to reproduce in S0 or the indicated artifact inventory:

| Inspection finding | Failure scenario to test | Required behavior |
|--------------------|--------------------------|-------------------|
| `RepertoireController.setRepertoireColor`, `setRootPosition` and `importPgnContent` read content then call `writeFile` without `expectedContent`. | Another writer commits between the read and replacement. | Apply a narrowly scoped change to current content under the storage transaction, or reject a stale revision without replacing the newer document. |
| `RepertoireWriter.undo` removes its undo entry and writes a previous whole-document snapshot without an expected revision. | A later annotation/import changed the file, or writing the undo fails. | Apply DATA-03: on revision mismatch reject snapshot undo, retain its receipt and offer a copy; on write failure keep recoverable undo state. Never replace later edits. |
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
sharing/lock violations separately from permanent access denial, with bounded
retry and renewed revision checks. Filesystem/device/remote-cache guarantees
remain explicit. Current SQLite WAL/NORMAL settings can lose latest commits
after power loss; any stronger guarantee needs a separate measured policy.
Use deterministic crash points and seeded process-termination tests; killing
a process does not simulate lost hardware caches.

## Milestones and exit gates

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

| Milestone | Deliverable | Exit gate / evidence IDs |
|-----------|-------------|--------------------------|
| S0. Current-code safety prerequisite | Reproduce controller and undo findings; fix confirmed races independently using existing storage primitives. | DATA-01, DATA-03, TEST-01: regressions and caller failure handling pass; unresolved cases explicit; integrated/backed up without waiting for rewrite. |
| 0. Inventory and baseline | Parity/data/owner maps, host prerequisites, authorized scope, default decisions, first-slice estimate and performance/usability budgets. | PLAN-01: evidence report and bounded next increment; record platform gaps under OPS-01/OPS-02. S0 may proceed independently. |
| 1/2. First complete slice with its design foundation | Repertoire list/search/create/rename/open/recoverable delete, persistent shell, injected contracts and only the theme, ARB, settings and catalog components this workflow uses. Retain formats; rehearse the desktop/native paths it invokes. | ARCH-01; DATA-01 through DATA-06 for paths used; STATE-01; SET-01; PROC-01/PROC-02 on applicable hosts; UI-01/UI-02/UI-04; OPS-01/OPS-02; TEST-01. Product-owner visual review recorded, duplicated slice code retired, PLAN-02 continuation decision recorded. |
| 3. Document workspace | PGN editing/studies/chapters, board navigation, retained sessions and shared resizable panels built on demand. | ARCH-01; DATA-02 through DATA-06; STATE-02; UI-01 through UI-04; TEST-01: round-trip, undo/conflict, context and large-document budget evidence. |
| 4. Training | Training/tactics/scheduling/history on stable identities; a storage migration only if separately justified. | ARCH-01; DATA-06; SET-01; UI-01/UI-04; TEST-01: preserved history and deterministic scheduling, cancellation and resume. |
| 5. Analysis and long jobs | Analysis/generation/audit/ingestion through owned jobs and bounded presentation updates. | ARCH-01; DATA-02/DATA-05/DATA-07; STATE-01 through STATE-03; PROC-01/PROC-02; UI-01/UI-04; OPS-01; TEST-01: stale-result, burst, cleanup and resource-budget checks. |
| 6. Remaining workflows and platform surface | Remaining modes, accounts/settings, tools, assets and distribution complete the inventory. Perform vault feasibility/migration before Accounts. | PLAN-01; ARCH-01; SET-01; SEC-01; OPS-01/OPS-02; TEST-01, plus applicable data/process/UI IDs from the inventory. Every retained capability has evidence or an explicit scope decision. |
| 7. Retirement and release readiness | Retire bridges/duplicate dependencies and obsolete readers where compatible; update current-state docs. | PLAN-01; ARCH-01; DATA-06; OPS-02; TEST-01: parity and recovery evidence complete, no production fallback to legacy, full release gates pass before requested publication. |

Milestone numbers are retained for existing references: “milestone 1” now means
the on-demand design work within milestone 2, not a separate foundation project.
All applicable IDs remain binding on later slices; the table highlights checks
introduced there. In milestone 0 enumerate inherited IDs per workflow/host;
use explicit ID rows in evidence rather than leaving ranges unexpanded.
Unfamiliar-player studies are optional when feasible under UI-04; record whether
the product owner or another end user completed the representative task.

A module is not considered migrated because it moved folders. Each completed
slice must demonstrate the new ownership, tests, UX behavior and removal of its
superseded code. Keep the old module only when a documented compatibility need
requires it, with a removal condition and owning milestone.

## Continuation decision after milestone 2

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

For each slice, produce a short contract before coding: user task, current
entry points, state owner, repository methods, failure/cancellation semantics,
fixtures, UI examples and the old files to remove. Implement the smallest
end-to-end case, exercise failure paths, inspect it, and then widen coverage.
Record substantial choices with status, alternatives, evidence and consequences
beside their owning section. Create a short ADR only when a cross-cutting choice
has actually been selected and needs its own history; do not predeclare every
candidate package as an accepted ADR. Update the component map only when a
change actually exists.

Enforce architecture with import checks and analyzer rules: no widget I/O, no
domain-to-UI dependencies, no new singleton access in migrated code and no
unreviewed control styling outside the design system. Ratchet migrated paths
first with explicit legacy scope; do not normalize violations by growing
allowlists. Code generation must be reproducible and validated for drift.

Prefer an analyzer-based import/export check if regex guards cannot express
the boundary reliably. Verify the actual rules and SDK compatibility of any
Riverpod lint/plugin; linting does not prove async lifetime correctness. Choose
one generated-file policy and validate regeneration in the existing bounded
checks/release pipeline; do not wait for hypothetical future codegen features.
Evaluate leak tracking for owned controllers/subscriptions alongside explicit
lifecycle tests. Property-generated PGN round-trips and differential chess
fixtures are useful additions when variant, null-move and FEN normalization
conventions are aligned; retain failing seeds as regression cases.

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
