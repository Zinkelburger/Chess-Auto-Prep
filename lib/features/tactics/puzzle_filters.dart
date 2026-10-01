import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/puzzle_queue.dart';
import '../../ui/check_row.dart';
import '../../ui/theme.dart';
import '../../ui/toggle_chip.dart';

/// Which puzzles Tactics plays and in what order, under the count they
/// change. Every change is kept at once; there is nothing to apply.
class PuzzleFilters extends StatelessWidget {
  const PuzzleFilters({
    super.key,
    required this.filter,
    required this.onChanged,
  });

  final PuzzleFilter filter;
  final ValueChanged<PuzzleFilter> onChanged;

  void _kind(MistakeKind kind, bool on) => onChanged(
    filter.copyWith(
      kinds: on ? {...filter.kinds, kind} : ({...filter.kinds}..remove(kind)),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _Chips(
            children: [
              for (final kind in MistakeKind.values)
                ToggleChip(
                  label: _kindLabel(kind),
                  selected: filter.kinds.contains(kind),
                  onSelected: (on) => _kind(kind, on),
                ),
            ],
          ),
          const SizedBox(height: Space.s),
          Text('Order', style: Theme.of(context).textTheme.labelSmall),
          const SizedBox(height: Space.xs),
          _Chips(
            children: [
              for (final order in PuzzleOrder.values)
                ToggleChip(
                  label: order.label,
                  selected: filter.order == order,
                  onSelected: (_) => onChanged(filter.copyWith(order: order)),
                ),
            ],
          ),
          ..._checks(),
          _Days(
            days: filter.days,
            onChanged: (days) => onChanged(filter.copyWith(days: () => days)),
          ),
        ],
      ),
    );
  }

  List<Widget> _checks() => [
    CheckRow(
      label: 'Group by game',
      value: filter.groupByGame,
      onChanged: (on) => onChanged(filter.copyWith(groupByGame: on)),
    ),
    CheckRow(
      label: 'Unreviewed only',
      value: filter.unreviewedOnly,
      onChanged: (on) => onChanged(filter.copyWith(unreviewedOnly: on)),
    ),
    CheckRow(
      label: 'Hide one-star',
      tooltip: 'One star is how a puzzle is hidden from training.',
      value: filter.hideOneStar,
      onChanged: (on) => onChanged(filter.copyWith(hideOneStar: on)),
    ),
  ];
}

/// `Blunders ??`, or `Custom` for the kind with no glyph.
String _kindLabel(MistakeKind kind) => kind == MistakeKind.custom
    ? 'Custom'
    : '${_capital(kind.plural)} ${kind.glyph}';

/// A row of chips that wraps in a narrow column.
class _Chips extends StatelessWidget {
  const _Chips({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: Space.xs, runSpacing: Space.xs, children: children);
}

String _capital(String word) =>
    word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);

/// `Last [14] days`, or every date. Counted from the game's date, today
/// being the first day; the number is taken when the box is left or Enter
/// is pressed.
class _Days extends StatefulWidget {
  const _Days({required this.days, required this.onChanged});

  final int? days;
  final ValueChanged<int?> onChanged;

  @override
  State<_Days> createState() => _DaysState();
}

class _DaysState extends State<_Days> {
  late final _number = TextEditingController(text: '${widget.days ?? 14}');
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      if (!_focus.hasFocus && mounted) _take(_number.text);
    });
  }

  @override
  void didUpdateWidget(_Days old) {
    super.didUpdateWidget(old);
    final days = widget.days;
    if (days != null && !_focus.hasFocus) _number.text = '$days';
  }

  @override
  void dispose() {
    _focus.dispose();
    _number.dispose();
    super.dispose();
  }

  void _take(String text) {
    if (widget.days == null) return;
    final days = int.tryParse(text.trim());
    if (days == null || days < 1) {
      _number.text = '${widget.days}';
      return;
    }
    if (days != widget.days) widget.onChanged(days);
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.days == null;
    final small = Theme.of(context).textTheme.bodySmall;
    return Tooltip(
      message: 'Counted from the date the game was played.',
      child: Row(
        children: [
          Checkbox(
            value: !all,
            onChanged: (on) => widget.onChanged(
              on ?? false ? int.tryParse(_number.text) ?? 14 : null,
            ),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Flexible(
            child: Text('Last', style: small, overflow: TextOverflow.clip),
          ),
          const SizedBox(width: Space.xs),
          SizedBox(
            width: dayCountWidth,
            child: TextField(
              controller: _number,
              focusNode: _focus,
              enabled: !all,
              textAlign: TextAlign.center,
              style: monoText.copyWith(
                color: Theme.of(context).colorScheme.onSurface,
              ),
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              onSubmitted: _take,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                  horizontal: Space.xs,
                  vertical: Space.xs,
                ),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          const SizedBox(width: Space.xs),
          Flexible(
            child: Text('days', style: small, overflow: TextOverflow.clip),
          ),
        ],
      ),
    );
  }
}
