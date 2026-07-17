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

## Verifying changes

- Verify with `flutter analyze` + tests + code reading. Do **not** launch the
  app or run integration tests locally to verify — headless/Xvfb runs can leak
  onto the developer's real screen (Wayland). Integration tests run in CI only.
- Local Flutter lives at `~/flutter/bin/flutter` on the primary dev machine;
  plain `flutter` may not be on PATH.
