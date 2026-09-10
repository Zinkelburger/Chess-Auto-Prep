# Flutter UI conventions

## Lifecycle

- Guard `setState` in callbacks passed to children/controllers and in listeners
  with `if (!mounted) return;`, including synchronous callbacks. Guard before
  forwarding a callback to the parent too; retained children can outlive it.
- A dialog owning a `TextEditingController` must be a `StatefulWidget` that
  disposes it in `State.dispose`. Disposing after `await showDialog(...)` can
  race the route's exit animation.
- When moving or renaming boot-screen controls, update the text/tooltip
  assertions in `integration_test/app_test.dart` in the same change.

## Widget tests

Test user actions and resulting state. Use control keys or semantic finders
when wording and text layout are incidental; contrast tests should inspect the
rendered labels rather than duplicate their copy. Composite screen tests can
use `test/support/board_engine_fixture.dart` to supply a scripted engine.
Reserve native engine startup for explicit engine and desktop integration tests.

## Type, colour and controls

Use `AppTextStyles` from `lib/theme/app_text_styles.dart`: title 18, body 14,
secondary 13, small 12, mono 13. The readable type floor is 12px (board
coordinates excepted); `scripts/ci.sh lint` checks it. Use weight and
`AppColors.ink` / `AppColors.onSurfaceMuted` for hierarchy.

Inter is set by the theme. Use `AppTextStyles.monoFamily` for moves/FEN/evals
and `AppTextStyles.caption` for captions; never use OS-dependent `'monospace'`.

Reuse these widgets (paths relative to `lib/`):

| Need | Use |
|---|---|
| Search a list or catalog | `ListSearchField` in `widgets/common/list_search_field.dart` |
| Labelled number | `InlineStat` / `StackedStat` in `widgets/common/stat_display.dart` |
| Confirmation | `confirmAction` in `widgets/common/confirm_dialog.dart` |
| Name with validation | `showNameEntryDialog` in `widgets/common/name_entry_dialog.dart` |
| Pick from a list | `ChoiceField` in `widgets/common/choice_field.dart`; outside conditional editors, two or three fixed options use `SegmentedButton`, never `DropdownButton` |
| Set a whole number | `NumberStepper` in `widgets/common/number_stepper.dart`, never a fixed numeric menu |
| Findings report | `HolesReportPanel` in `features/holes/widgets/holes_report_panel.dart` |
| Threshold, disclosure, visible cap | `features/audit/widgets/hunt_controls.dart` |

Before creating a control, check this table and `lib/widgets/common/`. Extend
an existing control when the behavior is shared. Search stays a visible input
with a magnifier and clear action. Conditional filters use compact Field / Rule /
Value rows with searchable choices and cached source-value suggestions. Show the
search icon on empty filter inputs; selected fields/values remain searchable
without repeating the icon. Selected sets use removable chips; position previews
belong on hover over the value, not a separate eye button. Start with
one blank row and a labelled add-row control; avoid palettes of field buttons.
Use muted labels/rules, inset value inputs and whitespace; avoid explanatory
headings or sentences when a concise label or operator (`≥`, `≤`) suffices.
Collapse optional controls and reuse the Tree game list for PGN filter results.
Reserve the strongest filled action for applying or completing the task.

## Keyboard shortcuts

A control with a keyboard binding in its screen/panel must show that binding
in its tooltip. Use `lib/widgets/shortcut_tooltip.dart`: `actionTooltip` for
string tooltips, `ShortcutIconButton` for icons, `ShortcutTooltip` for other
controls, or `shortcutTooltip` for delayed hover. Format is `Description (Shortcut)`.
Do not hand-build suffixes or attach shortcut widgets without a binding.
Update the control's tooltip when adding/changing a key handler.
`test/widgets/shortcut_tooltip_test.dart` covers the shared formatting/widgets.
