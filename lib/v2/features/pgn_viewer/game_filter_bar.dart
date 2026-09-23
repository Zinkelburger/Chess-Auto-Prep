import 'package:flutter/material.dart';

import '../../ui/choice_field.dart';
import '../../ui/theme.dart';
import '../../workspace/file_filter.dart';

/// The filter over the open file's games, under the search box: folded, a
/// `Filter games` button with the rules applied as chips that remove them
/// and how many games pass; unfolded, one Field / Rule / Value block per
/// rule, starting with one blank one, `Add rule`, `All` / `Any` once there
/// are two, and `Clear`.
///
/// Typing in a value applies a moment after it rests; adding, removing and
/// clearing apply at once. The explorer's `This file` reads the same
/// filter, so its table narrows with the list.
class GameFilterBar extends StatefulWidget {
  const GameFilterBar({super.key, required this.filter});

  final FileFilter filter;

  @override
  State<GameFilterBar> createState() => _GameFilterBarState();
}

class _GameFilterBarState extends State<GameFilterBar> {
  bool _unfolded = false;

  FileFilter get _filter => widget.filter;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _filter,
      builder: (context, _) => Padding(
        padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.s, Space.xs),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _heading(context),
            if (!_unfolded && _filter.applied.active.isNotEmpty) _chips(),
            if (_unfolded) ..._editor(),
          ],
        ),
      ),
    );
  }

  Widget _heading(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        TextButton(
          onPressed: () => setState(() => _unfolded = !_unfolded),
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Filter games'),
              Icon(
                _unfolded ? Icons.expand_less : Icons.expand_more,
                size: IconSize.menu,
              ),
            ],
          ),
        ),
        const Spacer(),
        if (_filter.narrowing)
          Text(
            '${_filter.kept} of ${_filter.total}',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  Widget _chips() {
    final applied = _filter.applied;
    return Wrap(
      spacing: Space.xs,
      runSpacing: Space.xs,
      children: [
        for (final rule in applied.active)
          InputChip(
            label: Text(rule.label),
            visualDensity: VisualDensity.compact,
            deleteButtonTooltipMessage: 'Remove this rule',
            onDeleted: () => _filter.apply(
              applied.copyWith(
                rules: [
                  for (final other in applied.rules)
                    if (other != rule) other,
                ],
              ),
            ),
          ),
      ],
    );
  }

  List<Widget> _editor() {
    final filter = _filter.filter;
    final rules = filter.rules.isEmpty ? const [HeaderRule()] : filter.rules;
    final fields = _fieldOptions();
    return [
      for (final (index, rule) in rules.indexed)
        _RuleBlock(
          key: ValueKey(index),
          rule: rule,
          fields: fields,
          values: _filter.valuesOf(rule.field),
          onChanged: (changed) => _filter.edit(
            filter.copyWith(rules: [...rules]..[index] = changed),
          ),
          onRemove: () => _filter.apply(
            filter.copyWith(rules: [...rules]..removeAt(index)),
          ),
        ),
      Row(
        children: [
          TextButton.icon(
            onPressed: () => _filter.apply(
              filter.copyWith(rules: [...rules, const HeaderRule()]),
            ),
            icon: const Icon(Icons.add, size: IconSize.menu),
            label: const Text('Add rule'),
          ),
          if (rules.length > 1)
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('All')),
                ButtonSegment(value: true, label: Text('Any')),
              ],
              selected: {filter.any},
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              onSelectionChanged: (any) =>
                  _filter.apply(filter.copyWith(any: any.single)),
            ),
          const Spacer(),
          if (!filter.isEmpty)
            TextButton(
              onPressed: () => _filter.apply(GameFilter.none),
              child: const Text('Clear'),
            ),
        ],
      ),
    ];
  }

  /// The usual fields by the names people call them, then every other
  /// header the file's games use.
  List<String> _fieldOptions() => [
    ...filterFields.values,
    for (final header in _filter.fields)
      if (!filterFields.containsKey(header)) header,
  ];
}

/// One rule: its field and how it compares on one line, the value under
/// them, and a button that removes it.
class _RuleBlock extends StatelessWidget {
  const _RuleBlock({
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
    return Padding(
      padding: const EdgeInsets.only(top: Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: ChoiceField(
                  text: fieldLabel(rule.field),
                  options: fields,
                  hint: 'Field',
                  onChanged: (typed) =>
                      onChanged(rule.copyWith(field: _fieldNamed(typed))),
                ),
              ),
              const SizedBox(width: Space.xs),
              SizedBox(
                width: filterRuleWidth,
                child: ChoiceField(
                  text: rule.rule.label,
                  options: [for (final r in FilterRule.values) r.label],
                  hint: 'Rule',
                  onChanged: (typed) {
                    if (_ruleNamed(typed) case final named?) {
                      onChanged(rule.copyWith(rule: named));
                    }
                  },
                ),
              ),
              IconButton(
                icon: const Icon(Icons.close, size: IconSize.menu),
                tooltip: 'Remove this rule',
                visualDensity: VisualDensity.compact,
                onPressed: onRemove,
              ),
            ],
          ),
          const SizedBox(height: Space.xs),
          Padding(
            padding: const EdgeInsets.only(right: IconSize.action + Space.m),
            child: ChoiceField(
              text: rule.value,
              options: values,
              hint: 'Value',
              onChanged: (typed) => onChanged(rule.copyWith(value: typed)),
            ),
          ),
        ],
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
