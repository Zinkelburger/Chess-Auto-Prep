# Maintenance pass — 2026-08-26

A polish run over the Flutter code aimed at five things the previous audits
left open: state that could desync or leak, UI copy that explained itself
instead of the behaviour, option density in the repertoire builder,
destructive actions with no confirmation, and — in a second sitting — the
generation form's `GlobalKey` reach-ins, which the two previous passes had
deferred.

Verified after every change: `dart format` clean, `flutter analyze lib test`
**0 errors / 0 warnings**, **2877 tests pass** (2859 before, +18 new).

## Bugs fixed

**Two leaked `TextEditingController`s.** `_bookTailMaxPlyCtrl` and
`_bookTieBreakCtrl` were declared in `_GenerationConfigFormStateBase` but
absent from the 35-line hand-written `dispose()` in
`generation_config_form.dart` — the failure mode that list invites, and the
second time knobs were added without reaching it.

Fixed by construction rather than by adding two lines: controllers are now
made by `_ctrl()`, which registers them in `_ownedControllers`, and the base
class disposes the list. Declarations became
`late final … = _ctrl('default')`, so a lazy initialiser can call an instance
method; the three that were assigned in `initState` because they read
`widget` (`_engineThreadsCtrl`, `_minEvalCtrl`, `_maxEvalCtrl`) fold into the
same form, and `initState` no longer touches controllers at all. Adding a
knob can no longer leak one.

**`PlanController` and `PlanRunner` notified after dispose.** Both are
`ChangeNotifier`s that start fire-and-forget async work, which CLAUDE.md says
must mix in `SafeChangeNotifier`; neither did, and neither had a `dispose`
override at all. `PlanController._fillEvals` is launched with `unawaited`,
awaits a database lookup and then an engine evaluation per candidate, and
calls `notifyListeners()` through `_patchCandidate` when each lands. Its only
guard was `_epoch`, which tracks *question changes*, not teardown — so a
planner disposed mid-fill tripped the used-after-dispose assertion.

Both now mix in `SafeChangeNotifier`, and `_fillEvals` checks `isDisposed` at
each of its three await boundaries, so it stops doing the work rather than
merely swallowing the notification.

**Discarding an unfinished build had no confirmation.** In
`repertoire_generation_tab.dart`, *Discard* deleted the partial-tree file on
one click — a search that may have run for hours, with no undo — while
deleting a saved *preset* asked first. It now confirms, naming the node count
and depth being thrown away.

A sweep for the same class across `lib/` turned up 20 other destructive
controls; every one either confirms already (repertoire delete, tactics
wipe, tournament delete, the generation lock overlay's discard) or is
trivially reversible (clear filter/search/path). This was the only gap.

## Not bugs, checked

- **Undisposed resources elsewhere:** none. Every `TextEditingController`,
  `ScrollController`, `FocusNode`, `TabController`, `Timer` and
  `StreamSubscription` owned by a `State` or notifier in `lib/` is disposed.
- **Leaked listeners:** none. All 8 `addListener` sites that survive their
  widget (`AppState`, `MyRepertoireSettings`) pair with a `removeListener` in
  `dispose`, usually through a stored `_appState` field.
- **`TreeBuildConfig`'s 76 fields** all appear in the constructor, `fromJson`,
  `toJson` and `copyWith`. The one `toJson` key not pinned by
  `generation_config_wire_format_test.dart` is `root_reply_exclude`, which is
  emitted conditionally and has its own test in the round-trip suite.
- **`SelectionMode.trappy`** is a real algorithm — `_pickByOpponentCpl` in
  `repertoire_selector.dart`, with opponent-CPL tracking in `BuildTreeNode`
  and `EcaCalculator` — not a bundled preset. The preset system itself
  already stores whole named configs only, with no "style" or "effort"
  bundles that rewrite several knobs at once.
- **`BuildMode.trapFinder`** is correctly-retired legacy, not dead weight: the
  C builder still accepts it, the dropdown no longer offers it, and
  `_applyInitialConfig` falls an old snapshot back to `stockfishExpectimax`
  with a test covering it. The enum value has to stay to deserialise those
  snapshots.

## The builder's option density

The complaint was that each step has a billion options. The two-layer split
was already right; the problem was inside Advanced, where one **PGN export**
section carried twelve controls across five unrelated domains, and knobs that
could not apply were rendered greyed out rather than omitted.

**Sections that cannot apply now say so in one sentence.**
`AdvancedSection.unavailable` returns a reason or null; `_SectionCard` renders
the reason *instead of* calling the section's builder, and the section keeps
its table-of-contents entry so it stays discoverable. Used by ChessDB book
(unless that is the build source), Verification (no-verify sources) and PGN
source filters (unless building from PGN files). Four tests, including that
an unavailable section does not build its controls at all, and that it
recovers without reopening the dialog — the knob that unblocks it is always
in another section, because nothing in an unavailable one is tappable.

**Six sections became ten, each short enough to scan.** `_exportSection` — the
257-line omnibus the 2026-08-21 audit called the worst method in the codebase,
already split into five private builders that still rendered as one card — is
gone. Its builders are now sections in their own right: Coverage & line order,
Chapters, Explanatory variations.

**Three knobs were in the wrong section.** `bookTailMaxPly`, `bookTieBreak`
and `bookEngineFallback` sat in the master-games group, where they were dead
weight for every other build source: three controls greyed out with three
different reasons, none of which had anything to do with master games. They
are their own **ChessDB book** section now, gated on the build source, so
their `enabled`/`disabledReason` pairs disappear entirely.

Sections run in build order — Opponent model · Move choice · Search tuning ·
Master games · ChessDB book · Verification · Coverage & line order · Chapters ·
Explanatory variations · PGN source filters — inputs, then search, then what
verifies it, then what comes out.

**On the main form,** `PgnSourcesPanel` was rendered at 45% opacity behind an
`IgnorePointer` whatever the build source was: half a screen of dead UI for
the three sources that never read it. It is simply absent now outside DB
Explorer — the file list it used to guard by staying visible moved into a
controller (below), so nothing is lost by not building it.

## Copy

Tooltips and mode descriptions had grown into essays: 27 ran past 28 words and
the worst was 109. They explained *why* a setting exists, recorded build
history ("on a real Benko tree 92% was 300 lines"), and argued with themselves
("as before") — but often took three clauses to say what the knob does.

About 25 were rewritten to one house rule: **first sentence says what the
setting does; an optional second says what the default or an extreme means.**
Nothing operative was dropped — the rationale was. The longest is now 53
words, for the coverage target, which genuinely has three parts.

Also rewritten: the five `BuildMode` descriptions and the `trappy` selection
mode's, which buried the behaviour under its justification.

## Smaller things

- `MediaQuery.of(context).size` → `MediaQuery.sizeOf(context)` at 9 sites, so
  they stop rebuilding on every unrelated `MediaQuery` change (keyboard
  insets, text scale). `advanced_settings_dialog.dart` was mixing both forms
  in a single expression.
- Four bare `catch (_) {}` blocks in `opening_tree.dart` and
  `plan_data_source.dart` say what they are swallowing and why. The other two
  in `lib/` were already commented.

## The `GlobalKey` reach-ins, lifted

Two passes deferred this one because the fix lands in
`generation_config_form_io.dart`, which carries the in-flight ChessDB
mainline-book diff. It is done now, in that file and beside it.

`GenerationConfigForm` read three children's `State` through `GlobalKey` at
`toConfig` time — `_evalSourcesKey`, `_skeletonKey`, `_pgnSourcesKey` — and
that one decision had spread:

- two of the three children had to stay **mounted while collapsed**
  (`Offstage`, not a conditional build), because a collapsed child has no
  `State` to read;
- `_applyInitialConfig` seeded two of them from a **post-frame callback**, for
  the mirror-image reason: during `initState` their `State` does not exist
  yet;
- every read carried a **null fallback** (`?? const SkeletonPlan()`,
  `eval?.enableChessDbApi ?? false`), so a value the user really had set was
  indistinguishable from a child that happened not to be mounted;
- `_effectivePgnPaths()` existed purely to paper over the resulting seeding
  race, reading the panel's list when the form's own copy was empty.

The state moved out of the widgets into three controllers the form owns:

| controller | holds | replaces |
| --- | --- | --- |
| `EvalSourcesController` | the lookup chain's settings + today's API spend | `EvalSourcesSectionState` |
| `SkeletonPlanController` | typed lines, active vetoes, the veto palette | `SkeletonPlanCardState` |
| `PgnSourcesController` | the attached `PgnSource` list | `PgnSourcesPanelState` |

All three widgets are now views: `SkeletonPlanCard` and `EvalSourcesSection`
are `StatelessWidget`s over a `ListenableBuilder`, and `PgnSourcesPanel` keeps
only which row is expanded, which is genuinely view state. Every consequence
above goes with them — both `Offstage`s became `if`s, the post-frame hop is
gone, `_effectivePgnPaths` is gone, and `toConfig`'s eval half is one call to
`EvalSourcesController.applyTo`, which sits directly beside the `applyConfig`
that is its inverse.

Two dead methods went too: `GenerationConfigFormState.canStart` and
`updateChessDbApiUsage`, neither called from anywhere.

The behaviour is unchanged with one deliberate exception, now commented in
`_applyInitialConfig`: an empty `pgnFilePaths` (which every non-DB-Explorer
config has) means "this config says nothing about PGN files", not "drop the
files the user attached" — the same effect the old `_effectivePgnPaths`
fallback had, stated on purpose instead of falling out of a race guard.

Tests: `skeleton_plan_card_test.dart` drives the controller instead of a
`GlobalKey`, and gains a case for the plan surviving the card being unmounted;
`eval_sources_controller_test.dart` is new — 13 cases pinning the depth
floor's three cases, the API clamps, the cdb-direct gate, and the picker.
`generation_config_form_roundtrip_test.dart` is unchanged and still green,
which is the point: the config contract did not move.

## Left alone deliberately

- **Backlog #6, `generation_config_form_advanced` → a knob-descriptor table.**
  The file is now ten named sections instead of six lopsided ones, which takes
  most of the readability win. A pure-data table is awkward here anyway:
  roughly half the knobs have `enabled`/`disabledReason` predicates over live
  form state, so the "data" would be closures either way.
- **`plan_build_screen.dart` (1428 lines, backlog #8).** Well sectioned, with
  its leaf widgets already extracted. Splitting the three big card builders
  means moving state-heavy code with no widget tests behind it, and CLAUDE.md
  forbids running the app locally to check the layout.

## Working-tree caveat

This pass ran against a tree carrying the in-flight ChessDB mainline-book work
(32 modified files, 6 new). **Nothing was committed.**

Its first sitting kept changes to files with an in-flight diff additive or
copy-only — new tooltips, the section regrouping, the controller-lifetime fix.
The second sitting deliberately lifted that restriction for
`generation_config_form_io.dart`, on the owner's instruction, since deferring
the `GlobalKey` work a third time would have meant deferring it indefinitely.
The ChessDB build path itself is still untouched: in that file the ChessDB diff
is `validateBeforeStart`'s `chessDbBook` branch and `toConfig`'s
`selectionMode` pin, both of which move through this refactor unedited except
for reading `_evalSources` instead of `_evalSourcesKey.currentState`.
