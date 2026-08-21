# Chess Auto Prep — agent instructions

Flutter desktop app (Linux/Windows/macOS) for chess prep: tactics from your own
games, repertoire building/training, player analysis, studies.

## Keeping CI green (non-negotiable)

CI (`.github/workflows/ci.yml`) runs format check → analyze → unit tests, plus a
headless integration test job — but **only on `v*` tags or manual dispatch**, to
conserve free Actions minutes. That means local checks are the *only* gate on
regular pushes, which makes them mandatory, not advisory. Before **every**
commit:

1. **`dart format lib test integration_test`** — CI's first gate is
   `dart format --set-exit-if-changed`; one unformatted file fails the job and
   skips everything after it.
2. **`flutter analyze lib test --no-fatal-infos`** — must report **zero
   `error •` or `warning •` lines**. Warnings are fatal in CI; only info-level
   hints are tolerated. Don't trust the exit banner alone — grep the output.
3. **`flutter test`** — full unit/widget suite must pass.

CI pins Flutter (see `flutter-version` in `ci.yml`) so formatter output can't
drift between stable releases. If you bump the pin, re-run `dart format` in the
same commit.

## Conventions that CI enforces indirectly

- **`SafeChangeNotifier`** (`lib/utils/safe_change_notifier.dart`): any
  `ChangeNotifier` service that starts fire-and-forget async work (file loads,
  network fetches) must mix it in, or the integration boot test fails with
  "used after being disposed" teardown races. Already applied to `AppState`,
  `StudyController`, `TacticsDatabase`, `TacticsImportCoordinator`,
  `TacticsSessionController` — follow suit for new notifier services.
- **Integration tests** (`integration_test/app_test.dart`) assert real UI text
  and tooltips on the boot screen (e.g. `find.byTooltip('Engine settings…')`).
  If you rename or move boot-screen controls, update the test in the same
  commit.

## Where code goes

Two layouts coexist. Both are intentional; the rule for choosing is:

- **`lib/features/<name>/`** — everything owned by one feature, in
  `controllers/ models/ services/ widgets/`. Use this for new features and
  when growing an existing one (`audit`, `browse`, `coverage`, `eval_tree`,
  `holes`, `traps`).
- **`lib/core/ models/ services/ widgets/`** — genuinely cross-cutting code
  used by three or more features or screens. `TrapLineInfo` lives in
  `lib/models/` for exactly this reason: 27 files across four layers use it,
  so it is a shared domain model rather than a `traps` internal.

A feature's *pipeline* code can stay in `lib/services/` when it belongs to
that pipeline rather than to the feature UI — `services/generation/
trap_extractor.dart` produces traps during a build; `features/traps/` consumes
them. That boundary is deliberate.

Never re-export a type from a second path to make both layouts work. Two
`trap_line_info.dart` files (one a shim) meant half the codebase imported each
one and neither was obviously canonical. Pick the home, move the file, fix the
imports.

**Layering, enforced by review:** `core/`, `models/`, `services/`, and `utils/`
must not import from `widgets/` or `screens/`. This now holds with **no
exceptions** — keep it that way. Check with:

```
grep -rlE "import '.*(widgets/|screens/)" lib/core lib/models lib/services lib/utils
```

The same rule applies to a feature's non-widget layers. That grep does not
cover them, so widen it when touching `lib/features/`:

```
grep -rlE "import '.*(widgets/|screens/)" lib/features/*/controllers \
  lib/features/*/services lib/features/*/models
```

One known violation remains: `features/repertoire/controllers/build_launcher.dart`
imports two form widgets.

## Decomposition

`part`/`part of` splits a file, not a class — every part still sees the host's
private state, so a god class spread over parts is still a god class. Use parts
to separate *types*, never to shrink one class. When a class is too big, extract
a real collaborator with its own constructor and tests (see
`services/training/chapter_scope.dart` and `review_progress_store.dart`, both
carved out of `TrainingSessionController`).

Collaborators that read owner state which the owner *reassigns* (a settings
reload, a new file) should take supplier callbacks (`TrainingSettings Function()`)
rather than cached references, so the two cannot desync. But pass a value
explicitly when the caller deliberately snapshotted it across an `await` —
`ChapterScope.resolveLayout` takes `isStudy` for that reason.

## Verifying changes

- Verify with `flutter analyze` + tests + code reading. Do **not** launch the
  app or run integration tests locally to verify — headless/Xvfb runs can leak
  onto the developer's real screen (Wayland). Integration tests run in CI only.
- Local Flutter lives at `~/sdk/flutter/bin/flutter` on the primary dev machine;
  plain `flutter` may not be on PATH.
