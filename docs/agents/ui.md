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

## Theme and shared controls

`lib/ui/theme.dart` owns visual constants, `Space`, `IconSize`, text styles and
the application theme. Use theme colors and the shared type/spacing scale.
The readable type floor is 12px, except board coordinates. Fonts and figurine
fallback are bundled. Do not restore retired AppColors/AppTextStyles,
design_system, legacy theme boundaries or localization generation.

Reuse the controls in `lib/ui/`: search_field, choice_field, number_field,
name_dialog, confirm_dialog, row_actions, pane_tabs, selection and app_action.
Keep search visible, with its magnifier and clear action. Use compact searchable
Field / Rule / Value rows for filters and removable chips for selected sets.
Reserve the strongest filled action for applying or completing a task.

Keyboard bindings live in `ui/app_keys.dart`; controls display their binding in
the tooltip/action and Settings uses the same table for its shortcut reference.
Moves use `ui/move_notation.dart`. Keep product copy concise and implementation
details out of the user's workflow.

There is no separate Widgetbook target. Preview the production app through
`python3 scripts/app_driver.py start`; the driver owns its headless display and
isolated profile. Stop the preview before testing its checkout.
