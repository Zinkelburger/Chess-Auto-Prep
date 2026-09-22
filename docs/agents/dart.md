# Dart conventions

## Placement and dependencies

- Migrated features use `lib/features/<name>/{models,controllers,repositories,widgets}`.
  Repertoire catalog code lives in `features/repertoires/`; public PGN document
  contracts and the Viewer game, collection-load, filter and session owners live in `features/documents/`; Study ownership lives in
  `features/studies/`; pure PGN text/replay utilities live in `chess_core/pgn/`;
  stored engine verdicts and annotation transforms live in `chess_core/analysis/`;
  generated tree/trap values and pure artifact codecs live in
  `chess_core/generation/`; persistent FEN identity lives in `chess_core/position/`;
  training sessions/settings and injected persistence contracts live in
  `features/training/`; guarded generation publication lives in
  `features/generation/`;
  typed settings contracts and state live in `features/settings/`; the older singular
  `features/repertoire/` still owns unmigrated document/generation workflows.
- `lib/app/` constructs dependencies. `lib/infrastructure/` adapts external
  systems to injected feature contracts. Controllers never import storage,
  infrastructure or widgets. Domain models/repository contracts stay pure Dart.
  The rewrite in `lib/v2/` has its own layout; see [the renewal plan](../ARCHITECTURE_RENEWAL.md#layout).
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
  Extract a collaborator only for a coherent responsibility; otherwise simplify
  the existing flow. File length alone does not require another class/interface.
- Give each mutable state and external effect one owner. Pass stable owners
  directly and explicit immutable inputs to commands; capture values before an
  `await` when the operation must use that snapshot. Use a supplier only for a
  specific live value that cannot be passed at the call site. Do not wire a
  collaborator through one supplier per field or a bag of forwarding callbacks.
- Feature composition wires the owner graph. Leaf widgets receive the relevant
  owner or immutable state and commands; they do not discover collaborators by
  traversing other mutable owners. Ordinary `owner.state.value` access is fine.
- Keep interfaces for coherent domain/external boundaries and meaningful
  failure or lifecycle substitution. Internal pure algorithms normally use
  concrete functions/classes. A one-method interface is neither required nor
  forbidden; a single production adapter alone is not a reason to remove it.
- Use explicit constructors for domain/workflow dependencies and Provider for
  Flutter lookup/listening. Riverpod and the generic stored-game/display scopes
  are retired and mechanically rejected. Keep actual
  tree-local Flutter UI scopes; do not add a second generic dependency container.
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
