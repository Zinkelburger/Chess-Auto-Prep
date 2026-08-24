import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../services/games_window.dart';

/// The "which of my games" picker: last N games, or last N days.
///
/// Controlled — it owns no setting. The caller holds the draft [window] and
/// decides when it becomes [GamesWindowSettings]; that is the analysis
/// settings dialog, so a Cancel there leaves the window where it was.
///
/// It used to sit on the tactics home's accounts card, permanently on screen
/// with both operands and both labels showing. It is one number you set and
/// forget, next to two username boxes and a card full of counts — so it moved
/// behind the gear that already owns *which games count* (time controls),
/// and the review strip still states the result ("your last 20 games") where
/// you can read it without opening anything.
class GamesWindowPicker extends StatefulWidget {
  const GamesWindowPicker({
    super.key,
    required this.window,
    required this.onChanged,
  });

  final GamesWindow window;
  final ValueChanged<GamesWindow> onChanged;

  @override
  State<GamesWindowPicker> createState() => _GamesWindowPickerState();
}

class _GamesWindowPickerState extends State<GamesWindowPicker> {
  late final TextEditingController _games;
  late final TextEditingController _days;

  @override
  void initState() {
    super.initState();
    _games = TextEditingController(text: '${widget.window.games}');
    _days = TextEditingController(text: '${widget.window.days}');
  }

  @override
  void dispose() {
    _games.dispose();
    _days.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final byGames = widget.window.isGameCount;

    Color dimmed(bool active) =>
        active ? AppColors.onSurfaceSoft : AppColors.onSurfaceDisabled;

    // Both modes on one line, phrased the same way ("Last [N] games" /
    // "Last [N] days") so no separator word is needed. Each row is tappable;
    // the active one keeps the primary left accent and the other fades.
    // (Andrew prefers this look over radio buttons — don't "fix" it.)
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: _FetchModeRow(
            selected: byGames,
            onTap: () => widget.onChanged(
              widget.window.copyWith(mode: GamesWindowMode.lastGames),
            ),
            child: _operand(
              // Keyed: the field has no label to find it by, and the e2e
              // review test types a game count into it.
              fieldKey: const Key('window-games-field'),
              controller: _games,
              enabled: byGames,
              noun: 'games',
              color: dimmed(byGames),
              onValue: (n) => widget.onChanged(
                widget.window.copyWith(games: n.clamp(1, GamesWindow.maxGames)),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _FetchModeRow(
            selected: !byGames,
            onTap: () => widget.onChanged(
              widget.window.copyWith(mode: GamesWindowMode.lastDays),
            ),
            child: _operand(
              fieldKey: const Key('window-days-field'),
              controller: _days,
              enabled: !byGames,
              noun: 'days',
              color: dimmed(!byGames),
              onValue: (n) => widget.onChanged(
                widget.window.copyWith(days: n.clamp(1, GamesWindow.maxDays)),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _operand({
    required Key fieldKey,
    required TextEditingController controller,
    required bool enabled,
    required String noun,
    required Color color,
    required ValueChanged<int> onValue,
  }) {
    return Row(
      children: [
        Text('Last', style: TextStyle(fontSize: 13, color: color)),
        const SizedBox(width: 8),
        SizedBox(
          width: 56,
          child: TextField(
            key: fieldKey,
            controller: controller,
            enabled: enabled,
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            keyboardType: TextInputType.number,
            onChanged: (value) {
              final n = int.tryParse(value);
              if (n != null && n > 0) onValue(n);
            },
          ),
        ),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            noun,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: color),
          ),
        ),
      ],
    );
  }
}

/// A selectable row: tapping anywhere selects the mode. The active row gets a
/// primary-colored left border accent; the inactive row dims.
class _FetchModeRow extends StatelessWidget {
  const _FetchModeRow({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: selected ? 1.0 : 0.40,
        duration: const Duration(milliseconds: 150),
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(
                color: selected ? scheme.primary : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          child: child,
        ),
      ),
    );
  }
}
