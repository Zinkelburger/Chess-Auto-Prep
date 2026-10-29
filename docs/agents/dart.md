# Dart conventions

## Layout and dependencies

`lib/main.dart` boots the app; production code lives directly under `lib/`,
with matching tests under `test/`.

- `chess/`: pure chess, PGN, generation, training and tournament values and algorithms.
- `storage/`: files, databases, settings, revisions, locking, recovery and backups.
- `engines/`: supervised engine processes; pure Dart, without Flutter.
- `net/`: remote services and login sockets.
- `ui/`: shared controls, theme, shortcuts and presentation helpers.
- `workspace/`: the shared workspace, grouped into `document/`, `board/`, `reading/`,
  `analysis/`, `review/`, `explorer/`, `book/` and `search/`.
- `features/`: mode owners and panels. One feature never imports another.
- `app/`: composition, cross-mode wiring, navigation, lifecycle and shutdown.
- `diagnostics/`: logging; `debug/`: opt-in driver and packaged-app checks.

`scripts/check_architecture.py` enforces the dependency table, pure layers, write ownership
and complexity limits. See [the architecture contracts](../ARCHITECTURE.md).
Do not add parallel layers (`services/`, `models/`, `widgets/`), a dependency
container, code generation, a localization step or debt ledgers.

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
relevant tests through `scripts/ci.sh`. Analyze stays at zero issues: infos are
fatal, so fix a new lint (or disable the rule with a reason), never leave it.
Update affected documentation following [Documentation](documentation.md) when
behavior, API or layout changes.
