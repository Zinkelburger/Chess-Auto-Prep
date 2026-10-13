# Flutter UI conventions

The app uses the shared workspace and controls in `lib/ui/`; each mode supplies
its own panel and owner under `lib/features/`. There is one board, move tree,
document session and engine/explorer composition.

## Lifecycle and tests

Guard retained callbacks with `mounted` before `setState` or forwarding work.
A dialog owning a text controller is a StatefulWidget and disposes it in
`State.dispose`, not after `showDialog` returns. Follow replaced owners through
`ListeningState` or `didUpdateWidget`; cancel subscriptions on disposal.

Test user actions and resulting state with semantic/control finders. Use the
fixtures under `test/support/` and actual production widgets. Script engines and
network calls for widget tests; native engine startup belongs in explicit
integration checks. Update `integration_test/v2_desktop_test.dart` when changing
boot controls. Use the run-chess-auto-prep skill for a headless screenshot with
disposable data after visible changes.

## Look, controls and copy

[DESIGN.md](../../DESIGN.md) is the visual and copy specification: colours,
type scale, spacing, the shared `lib/ui/` controls, one filled button per
surface, filters, and the Do's and Don'ts. Read it before changing anything
the player sees, and update it when a deliberate design rule changes.

In code, `lib/ui/theme.dart` owns every visual value (`Space`, `IconSize`,
text styles, colours); widgets never hard-code them. Keyboard bindings live in
`ui/app_keys.dart`, which controls show in their tooltips and Settings lists.
Moves are rendered through `ui/move_notation.dart`.

Preview the production app through `python3 scripts/app_driver.py start`; the driver owns its headless display and
isolated profile. Stop the preview before testing its checkout.
