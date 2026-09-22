import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../chess/tactics/puzzle.dart';
import '../../chess/tactics/puzzle_queue.dart';
import '../../ui/theme.dart';

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
    final label = Theme.of(context).textTheme.labelSmall;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.m, 0, Space.m, Space.s),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              for (final kind in MistakeKind.values)
                FilterChip(
                  label: Text(
                    kind == MistakeKind.custom
                        ? 'Custom'
                        : '${_capital(kind.plural)} ${kind.glyph}',
                  ),
                  selected: filter.kinds.contains(kind),
                  onSelected: (on) => _kind(kind, on),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          const SizedBox(height: Space.s),
          Text('Order', style: label),
          const SizedBox(height: Space.xs),
          Wrap(
            spacing: Space.xs,
            runSpacing: Space.xs,
            children: [
              for (final order in PuzzleOrder.values)
                ChoiceChip(
                  label: Text(order.label),
                  selected: filter.order == order,
                  onSelected: (_) => onChanged(filter.copyWith(order: order)),
                  visualDensity: VisualDensity.compact,
                ),
            ],
          ),
          _Check(
            label: 'Group by game',
            value: filter.groupByGame,
            onChanged: (on) => onChanged(filter.copyWith(groupByGame: on)),
          ),
          _Check(
            label: 'Unreviewed only',
            value: filter.unreviewedOnly,
            onChanged: (on) => onChanged(filter.copyWith(unreviewedOnly: on)),
          ),
          _Check(
            label: 'Hide one-star puzzles',
            value: filter.hideOneStar,
            onChanged: (on) => onChanged(filter.copyWith(hideOneStar: on)),
          ),
          _Days(
            days: filter.days,
            onChanged: (days) => onChanged(filter.copyWith(days: () => days)),
          ),
        ],
      ),
    );
  }
}

String _capital(String word) =>
    word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);

/// A box and its label, one line, the whole line clickable.
class _Check extends StatelessWidget {
  const _Check({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => onChanged(!value),
      child: Row(
        children: [
          Checkbox(
            value: value,
            onChanged: (on) => onChanged(on ?? false),
            visualDensity: VisualDensity.compact,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

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
          const Flexible(child: Text('Last', overflow: TextOverflow.clip)),
          const SizedBox(width: Space.xs),
          SizedBox(
            width: dayCountWidth,
            child: TextField(
              controller: _number,
              focusNode: _focus,
              enabled: !all,
              textAlign: TextAlign.center,
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
          const Flexible(child: Text('days', overflow: TextOverflow.clip)),
        ],
      ),
    );
  }
}
