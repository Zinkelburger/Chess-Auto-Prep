# Dart conventions

## Placement and dependencies

- Migrated features use `lib/features/<name>/{models,controllers,repositories,widgets}`.
  Repertoire catalog code lives in `features/repertoires/`; public PGN document
  contracts live in `features/documents/`; Study ownership lives in
  `features/studies/`; pure PGN text utilities live in `chess_core/pgn/`;
  typed settings contracts and state live in `features/settings/`; the older singular
  `features/repertoire/` still owns unmigrated document/generation workflows.
- `lib/app/` constructs dependencies. `lib/infrastructure/` adapts external
  systems to injected feature contracts. Controllers never import storage,
  infrastructure or widgets. Domain models/repository contracts stay pure Dart.
  See [the renewal dependency rules](../ARCHITECTURE_RENEWAL.md#target-layout-and-dependency-rules).
- Unmigrated code retains its existing `core/`, `models/`, `services/` and
  `widgets/` locations until its owning workflow migrates. Do not add new
  catch-all shared layers or move files without changing ownership.
- Choose one canonical type path; move it and fix imports instead of adding
  re-export shims.
- Non-UI layers must not import `widgets/` or `screens/`, including within
  features. `scripts/ci.sh lint` also enforces the migrated catalog and
  infrastructure boundaries using `scripts/check_architecture_boundaries.py`.

## State and lifecycle

- Use `part` to separate types, never to spread one large class over files.
  Extract a collaborator with its own constructor and tests instead.
- If the owner reassigns state, pass a supplier callback to collaborators
  rather than caching the old reference. Pass a value when intentionally
  snapshotting state across an `await`.
- A `ChangeNotifier` service that launches fire-and-forget work must mix in
  `SafeChangeNotifier` (`lib/utils/safe_change_notifier.dart`) to avoid notifying
  after disposal.
- Stub HTTP clients in Flutter unit tests: `flutter test` blocks real HTTP
  with empty 400 responses. Deliberate network benchmarks are separate.

## Filesystem paths

Import `package:path/path.dart` as `p`. Use `p.isAbsolute`, `p.basename`,
`p.basenameWithoutExtension`, `p.dirname`, `p.extension`, `p.withoutExtension`
and `p.join` for filesystem paths. Avoid `startsWith('/')`, `split('/')`,
manual extension slicing or replacing every `.pgn` occurrence. URL paths and
FEN strings use `/` and are not filesystem paths.

## Shared helpers

Before implementing these, use the existing helper (paths relative to `lib/`):

| Need | Helper |
|---|---|
| Relative time, duration, ETA | `utils/time_format.dart` |
| Centipawn/mate display | `formatEvalDisplay` / `formatPackedEval` in `utils/chess_utils.dart` |
| Numbered moves | `buildNumberedMovetext` in `utils/movetext_builder.dart` |
| NAG symbol/colour | `utils/pgn_nags.dart` |
| Cooperative pause/cancel | `RunControl` in `services/run_control.dart` |
| Hunt report persistence | `HuntReportStore` in `features/audit/services/hunt_report_store.dart` |

For changed public behavior, API or file layout, update the affected existing
section following [Documentation](documentation.md).
