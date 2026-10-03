import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';

import '../../chess/fen.dart';
import '../../chess/game_filter.dart';
import '../../ui/choice_field.dart';
import '../../ui/theme.dart';
import '../../workspace/board_view.dart';
import '../../workspace/file_filter.dart';
import 'export_dialog.dart';
import 'pgn_viewer.dart';

/// The Filter tab: which of the open file's games the list shows. How many
/// pass, one Field / Rule / Value row per rule starting with a blank one,
/// `Add rule`, the position on the board as a rule, `All` / `Any` once
/// there are two, and what can be done with the games that pass.
///
/// Typing in a value applies a moment after it rests; adding, removing and
/// clearing apply at once. The explorer's `This file` reads the same
/// filter, so its table narrows with the list.
class ViewerFilterPane extends StatelessWidget {
  const ViewerFilterPane({
    super.key,
    required this.viewer,
    required this.filter,
    this.onPosition,
    this.onSaveToStudy,
    this.say,
  });

  final PgnViewer viewer;
  final FileFilter filter;

  /// Keeps the games that reach the position on the board; the filter's
  /// own board when the host has no other.
  final VoidCallback? onPosition;

  /// The games that pass, into a study.
  final VoidCallback? onSaveToStudy;
  final void Function(String?)? say;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([viewer, filter]),
    builder: (context, _) {
      if (viewer.file == null) {
        return Padding(
          padding: const EdgeInsets.all(Space.l),
          child: Text(
            'Open a file to filter its games.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      }
      final editing = filter.filter;
      final rules = editing.rules.isEmpty
          ? const [HeaderRule()]
          : editing.rules;
      final fields = [
        ...filterFields.values,
        for (final header in filter.fields)
          if (!filterFields.containsKey(header)) header,
      ];
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(Space.m, Space.s, Space.s, Space.m),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Count(filter: filter),
            for (final (index, rule) in rules.indexed)
              _RuleRow(
                key: ValueKey(index),
                rule: rule,
                fields: fields,
                values: filter.valuesOf(rule.field),
                onChanged: (changed) => filter.edit(
                  editing.copyWith(rules: [...rules]..[index] = changed),
                ),
                onRemove: () => filter.apply(
                  editing.copyWith(rules: [...rules]..removeAt(index)),
                ),
              ),
            const SizedBox(height: Space.s),
            Wrap(
              spacing: Space.s,
              runSpacing: Space.xs,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => filter.apply(
                    editing.copyWith(rules: [...rules, const HeaderRule()]),
                  ),
                  icon: const Icon(Icons.add, size: IconSize.menu),
                  label: const Text('Add rule'),
                ),
                if (filter.applied.position case final position?)
                  _PositionChip(
                    position: position,
                    onRemove: () => filter.apply(
                      filter.applied.copyWith(clearPosition: true),
                    ),
                  )
                else
                  TextButton.icon(
                    onPressed: onPosition ?? filter.reachingBoardPosition,
                    icon: const Icon(Icons.grid_on, size: IconSize.menu),
                    label: const Text('Reaching this position'),
                  ),
                if (rules.length > 1)
                  SegmentedButton<bool>(
                    segments: const [
                      ButtonSegment(value: false, label: Text('All')),
                      ButtonSegment(value: true, label: Text('Any')),
                    ],
                    selected: {editing.any},
                    showSelectedIcon: false,
                    style: const ButtonStyle(
                      visualDensity: VisualDensity.compact,
                    ),
                    onSelectionChanged: (any) =>
                        filter.apply(editing.copyWith(any: any.single)),
                  ),
              ],
            ),
            if (filter.narrowing) ...[
              const Divider(height: Space.xl),
              _matching(context),
            ],
          ],
        ),
      );
    },
  );

  /// What can be done with the games the filter found.
  Widget _matching(BuildContext context) {
    final ready =
        !filter.busy && filter.problem == null && viewer.visible.isNotEmpty;
    return Wrap(
      spacing: Space.xs,
      children: [
        TextButton(
          onPressed: ready
              ? () => exportViewerPgn(context, viewer, say ?? (_) {})
              : null,
          child: const Text('Export matching games…'),
        ),
        if (onSaveToStudy case final save?)
          TextButton(
            onPressed: ready ? save : null,
            child: const Text('Save to study…'),
          ),
      ],
    );
  }
}

/// How many of the file's games pass, or why that cannot be said, and the
/// way back to all of them.
class _Count extends StatelessWidget {
  const _Count({required this.filter});

  final FileFilter filter;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final games = filter.total == 1 ? '1 game' : '${filter.total} games';
    final words = filter.busy
        ? 'Filtering games…'
        : filter.problem ??
              (filter.narrowing ? '${filter.kept} of $games' : games);
    return SizedBox(
      // The height of the button, held while there is none, so the rules
      // under it stay where they are when the filter starts to narrow.
      height: filterCountHeight,
      child: Row(
        children: [
          Expanded(
            child: Text(
              words,
              key: const ValueKey('filter-count'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(
                color: filter.problem != null && !filter.busy
                    ? theme.colorScheme.error
                    : theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          if (!filter.filter.isEmpty)
            TextButton(
              onPressed: () => filter.apply(GameFilter.none),
              child: const Text('Clear'),
            ),
        ],
      ),
    );
  }
}

/// The position the filter keeps games through, shown on hover, and the
/// way to stop.
class _PositionChip extends StatelessWidget {
  const _PositionChip({required this.position, required this.onRemove});

  final Fen position;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) => InputChip(
    avatar: const Icon(Icons.grid_on, size: IconSize.menu),
    label: Tooltip(
      richMessage: WidgetSpan(
        child: SizedBox(
          width: diagramSize,
          child: BoardView(
            fen: position,
            orientation: Side.white,
            onMove: (_) {},
            movable: false,
            coordinates: false,
          ),
        ),
      ),
      child: const Text('Reaching a position'),
    ),
    deleteButtonTooltipMessage: 'Remove position filter',
    onDeleted: onRemove,
  );
}

/// One rule: its field, how it compares and the value on one line when the
/// pane has room for the three, else the value under the other two; and a
/// button that removes it.
class _RuleRow extends StatelessWidget {
  const _RuleRow({
    super.key,
    required this.rule,
    required this.fields,
    required this.values,
    required this.onChanged,
    required this.onRemove,
  });

  final HeaderRule rule;
  final List<String> fields;
  final List<String> values;
  final ValueChanged<HeaderRule> onChanged;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final field = ChoiceField(
      text: fieldLabel(rule.field),
      options: fields,
      hint: 'Field',
      onChanged: (typed) => onChanged(rule.copyWith(field: _fieldNamed(typed))),
    );
    final how = ChoiceField(
      text: rule.rule.label,
      options: [for (final r in FilterRule.values) r.label],
      hint: 'Rule',
      onChanged: (typed) {
        if (_ruleNamed(typed) case final named?) {
          onChanged(rule.copyWith(rule: named));
        }
      },
    );
    final value = ChoiceField(
      text: rule.value,
      options: values,
      hint: 'Value',
      onChanged: (typed) => onChanged(rule.copyWith(value: typed)),
    );
    final remove = IconButton(
      icon: const Icon(Icons.close, size: IconSize.menu),
      tooltip: 'Remove this rule',
      visualDensity: VisualDensity.compact,
      onPressed: onRemove,
    );
    return LayoutBuilder(
      builder: (context, constraints) => Padding(
        padding: const EdgeInsets.only(top: Space.s),
        child: constraints.maxWidth >= filterRowWidth
            ? Row(
                spacing: Space.xs,
                children: [
                  SizedBox(width: filterFieldWidth, child: field),
                  SizedBox(width: filterRuleWidth, child: how),
                  Expanded(child: value),
                  remove,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                spacing: Space.xs,
                children: [
                  Row(
                    spacing: Space.xs,
                    children: [
                      Expanded(child: field),
                      SizedBox(width: filterRuleWidth, child: how),
                      remove,
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(
                      right: IconSize.action + Space.m,
                    ),
                    child: value,
                  ),
                ],
              ),
      ),
    );
  }
}

/// The header [typed] names: a usual field by what people call it, else
/// the header as typed.
String _fieldNamed(String typed) {
  final wanted = typed.trim().toLowerCase();
  for (final MapEntry(:key, :value) in filterFields.entries) {
    if (value.toLowerCase() == wanted || key.toLowerCase() == wanted) {
      return key;
    }
  }
  return typed.trim();
}

/// The rule [typed] names, by its label, its name or `>=` / `<=`; null
/// while it names none.
FilterRule? _ruleNamed(String typed) {
  final wanted = typed.trim().toLowerCase();
  for (final rule in FilterRule.values) {
    if (rule.label == wanted || rule.name.toLowerCase() == wanted) return rule;
  }
  return switch (wanted) {
    '>=' || 'at least' => FilterRule.atLeast,
    '<=' || 'at most' => FilterRule.atMost,
    _ => null,
  };
}
