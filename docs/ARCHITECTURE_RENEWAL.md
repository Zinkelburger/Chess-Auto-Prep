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
| Credentials | Evaluate flutter_secure_storage behind a CredentialStore; require native desktop setup and restart-safe migration before migrating Accounts. See the settings contract below. |
| Resizable workspace | Trial flutter_resizable_container behind one shared SplitPane component; adoption requires constraint, keyboard, semantics and restoration tests. |
| Stream shaping | Prefer a focused transformer or stream_transform for bounded presentation updates; use RxDart if its wider operators justify it. Verify operator semantics instead of adding a package for its name. |
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
the vault in milestone 1 and complete its migration gate before Accounts work,
even if the full settings/accounts UI remains in milestone 6.

## Runtime state and large documents

If Riverpod is selected, disable implicit provider retry at the composition
root (`retry: (_, _) => null`); opt in only for bounded idempotent reads with
one retry owner. Provider computations must not start jobs or perform document
mutations. A dependency provider can expose an explicitly owned service, but
visibility, rebuilds and listener counts must not own its active work.
Test a failed observation, repeated clicks and route departure: one requested
job starts once and continues or stops according to its declared policy.
Observe paused/offscreen subscriptions under `TickerMode`, then return and
verify the latest job state without duplicated work or unbounded buffering.

Use a shared async Command abstraction for UI-triggered operations, carrying
running/result/failure state and an explicit repeated-execution policy (reject,
coalesce or queue). Domain-specific results remain typed; long jobs expose a
job handle and progress rather than making widget lifetime their owner. After
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
cursor change. A local session ID/revision identifies UI updates; the storage
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

These requirements extend milestones 0-2; they must not wait until the final
platform sweep.

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

Evaluate Windows Job Objects with kill-on-last-handle-close and platform
launcher/watchdog mechanisms where EOF is insufficient. Establish containment
before useful work starts, prevent inherited handles from defeating cleanup,
and handle descendants. A Linux parent-death signal needs a correctly designed
launcher and parent-race handling; it is not portable Dart configuration.
Scope tests to the test app's tracked process tree. In milestone 2, forcibly
terminate only that disposable app during analysis, then verify within a bounded
deadline that its engines stop and that restart recovers documents/locks. Never
kill unrelated engines by name. Native host availability remains explicit.

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

Evaluate representative scenarios with the user and, when feasible, chess
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
Navigator with [go_router ShellRoute](https://pub.dev/documentation/go_router/latest/go_router/ShellRoute-class.html)
in the routing trial. Deliberate modal tasks may cover the shell, but ordinary
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
not on every pointer event. Catalog/test nested splits, long labels, RTL,
keyboard-only resizing, pointer drags, cancellation, small/ultrawide windows,
200% text and saved-layout recovery. Prototype the control in milestone 1 and
prove the chosen workspace arrangement in milestone 3; keep panel composition
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
| Append/import games or apply an edit | Run the bounded PGN transformation against the current document inside its mutation transaction. Check any source-game/line preconditions; preserve unrelated text and annotations. |
| Undo a committed edit | Accept a receipt bound to the document and the revision being reversed; reject a conflict, preserve recovery state and consume undo only after committing. |
| Rename, move or recoverably delete | Use the same document ownership boundary, with collision checks and an explicit protocol for associated references/artifacts. Coordinate with saves so a queued edit cannot recreate or target the wrong chapter. |

The store owns validation, serialization against other app mutations, commit
checks, recoverable prior versions, failure propagation and committed revision
receipts. A read/modify/write transaction must protect the whole transformation,
not merely the final file replacement. CPU-heavy parsing may be prepared outside
the critical section with revision revalidation before commit. Do not claim
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

## Storage baseline and overwrite-prevention gate

The following is a code-inspection baseline from 2026-09-16. The findings need
reproduction and resolution during implementation. Build the full ownership
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

## Filesystem and cross-process contracts

In milestone 0, give each store a permitted-writer matrix: app instances,
workers, MCP/offline tools and external editors. "One writer" means one mutation
contract with serialization across cooperating processes, not one Dart singleton.
Current file mutations use a SQLite-transaction mutex across isolates/processes,
and `GameStore` already sets a busy timeout. Preserve those guarantees; do not
replace them with an in-memory lock or POSIX record lock without equivalent
tests. Tools documented as read-only keep read-only connections. Define bounded
contention handling, lock identity/order and supported filesystems for writers.

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
behavior and background query ownership. Drift trials include background
execution and schema-snapshot/migration tests. Backup through SQLite's snapshot
facilities; copying a live db/WAL/SHM file set is not a consistent backup protocol.

Distinguish UI revisions from persisted content identity. Never use mtime/size
alone for overwrite validation. Use exact baseline content or a specified
collision-resistant digest with document identity and deletion/recreation
semantics; if hashing bytes, define compression/encoding behavior. The current
`expectedContent` parameter compares decoded text and does not accept a hash.
Introduce a typed revision API rather than silently changing that parameter.

The baseline durability target is recoverability from app/worker termination
on supported local filesystems. Power-loss durability is a separate design
decision: document SQLite synchronous/checkpoint settings and filesystem flush,
rename and directory-metadata requirements before making that stronger promise.
Current WAL/NORMAL settings do not guarantee retention of every latest commit
after power loss. A successful atomic rename alone is not a durability proof.
Use deterministic crash-point tests first, then seeded process-termination
stress tests with reproducible failure records for save/move/import. A process
kill test does not simulate lost hardware caches or establish power-loss safety.

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

| Milestone | Deliverable | Exit gate |
|-----------|-------------|-----------|
| 0. Inventory and baseline | Workflow/parity matrix, persisted-format ownership map, dependency/native-runtime map, desktop build/signing prerequisites, diagnostic coverage matrix, representative fixtures, known-bug decisions, performance and usability scenarios. | Every current mode/support capability has an owner, migration disposition and observable acceptance scenarios. Known bugs are separated from behavior to preserve; unavailable host/credential checks are explicit. |
| 1. Design foundation | Widgetbook with production search/choice/stepper/stat/dialog components; typography, spacing, focus, error and progress examples; localization-ready copy, typed theme tokens, a split-pane trial, settings ownership and a desktop vault feasibility check. | Catalog runs headlessly without user data or real jobs; controls work with keyboard, long/pseudo-localized text, RTL and scaling; approved visual baselines, theme and splitter behavior checks pass. Settings ownership is mapped; vault host gaps are recorded. |
| 2. First complete slice | Repertoires: list/search, create, rename, open and recoverably delete, using injected repository contracts and an explicit presentation-state owner. Keep current storage formats. Retain the mode shell and prove settings used by this slice. Rehearse desktop packages, native execution and failure diagnostics. | Shared writer and overwrite gates pass, including process contention and unavailable/synced-file cases; user completes the task with context restored; settings failure/restart tests pass; duplicate implementation removed. Provider retry/visibility and forced-parent-exit tests pass on available native hosts. Record outstanding host checks and the continuation decision. |
| 3. Document workspace | PGN viewing/editing, study/chapter management and board/move navigation; shared document sessions and reusable workspace components. | Annotated PGNs round-trip; unsaved edits survive failures; undo, external conflicts, context restoration and accessible split-panel resizing pass. Large/deep document edit, equality, allocation and frame-time benchmarks meet the agreed baseline budgets. |
| 4. Training | Repertoire training, tactics, review scheduling/history and game-review handoffs on stable document/line identities. Trial a progress-storage migration only as a separate increment. | Historic progress fixtures migrate without loss; time-dependent scheduling and cancelled sessions are deterministic; complete training/resume scenarios pass. |
| 5. Analysis and long jobs | Interactive analysis, generation/planning, audit/holes/traps, player analysis and database ingestion use explicit job ownership and resource policies. | Deterministic core invariants and differential fixtures pass; stale results cannot publish; pause/cancel/restart, port/worker cleanup and engine crash cleanup pass; burst-output tests preserve terminal events and periodic progress; realistic throughput/memory budgets hold. |
| 6. Remaining workflows and platform surface | Players & prep, engine tournaments, bughouse, accounts/settings, external tools, asset discovery, packaging and updates complete the parity matrix. | Each mode has functional parity or a separately agreed redesign; shared-file tool contracts and Linux/Windows/macOS native checks pass. Credential migration/restart/disconnect gates pass before the new Accounts UI ships. Missing optional assets remain handled. |
| 7. Retirement and release readiness | Remove legacy bridges, unused controllers/widgets, duplicate dependencies and obsolete schemas/readers where compatibility policy permits; update current-state docs. | No production route falls back to legacy code; all retained data is readable and recovery is tested; full release gates pass. Publishing remains a separate user-requested action. |

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
appeared in external review. Evaluate an app-owned typed destination stack
alongside go_router's retained-shell approach using the same navigation fixtures.

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
  primary documentation for the initial package evaluations.
