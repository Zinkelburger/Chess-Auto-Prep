# Dart conventions

## Layout and dependencies

The renewal app is the only app. `lib/main.dart` boots it; production code
lives directly under `lib/`, with matching tests under `test/`.

- `chess/`: pure chess, PGN, generation, training and tournament values and algorithms.
- `storage/`: files, databases, settings, revisions, locking, recovery and backups.
- `engines/`: supervised engine processes; pure Dart, without Flutter.
- `net/`: remote services and login sockets.
- `ui/`: shared controls, theme, shortcuts and presentation helpers.
- `workspace/`: shared board, document session, engine/explorer and document tools.
- `features/`: mode owners and panels. One feature never imports another.
- `app/`: composition, cross-mode wiring, navigation, lifecycle and shutdown.
- `diagnostics/`: logging; `debug/`: opt-in driver and packaged-app checks.

`scripts/check_v2.py` enforces the dependency table, pure layers, write ownership
and complexity limits. See [the architecture contracts](../ARCHITECTURE_RENEWAL.md).
Do not recreate v1's services/core/models/widgets layers, dependency adapters,
Provider container, localization generator, debt ledgers or Widgetbook.

## Ownership and lifecycle

Give each mutable fact and external effect one owner. Pass concrete owners and
immutable inputs explicitly. `AppParts` composes them; `WorkspaceRequests`
coordinates navigation. Panels share the workspace document, board and move tree.
Capture inputs before awaits; reject stale results before publication.

Keep algorithms pure. Filesystem mutations belong to storage; UI calls owners.
Use the existing guarded document, relocation and training workflows rather than
writing directly. Accepted user-data writes belong to application `PendingWrites`
and survive a panel's disposal. Close flushes them before stopping engines.

Use `part` only for complete collaborator types, never to spread one class over
files. Split different responsibilities, not an arbitrary line count. Do not add
forwarding-only interfaces or duplicate state. Match the current notifier/owner
lifecycle and dispose subscriptions; widgets follow changing owners through
`ui/listening_state.dart` or `didUpdateWidget`.

## Paths and shared helpers

Import `package:path/path.dart` as `p`. Use its join, basename, dirname,
extension, relative and absolute helpers; do not parse filesystem paths as URLs.
Reuse `chess/pgn/`, `chess/fen.dart`, `ui/relative_time.dart`, `ui/move_notation.dart`
and the existing workspace/storage owners before adding helpers.

Stub HTTP and engine ports in focused tests; native engines belong in explicit
engine/desktop checks. Format only changed Dart files. Run analyze/lint and
relevant tests through `scripts/ci.sh`. Update affected documentation following
[Documentation](documentation.md) when behavior, API or layout changes.
