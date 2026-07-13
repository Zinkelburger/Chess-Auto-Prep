/// Trap tour — a slim bar docked above the bottom pane.
///
/// Prev/next (P/N) walk the sorted trap list; each stop loads the trap's
/// full line onto the board and into the PGN tab, where the moves are
/// clickable. The bar itself only carries the narrative — never a copy of
/// the movetext.
library;

import 'package:flutter/material.dart';

import '../../../theme/app_colors.dart';
import '../../../widgets/shortcut_tooltip.dart';
import '../models/trap_line_info.dart';
import '../services/trap_index_service.dart';

class TrapTourBar extends StatefulWidget {
  const TrapTourBar({
    super.key,
    required this.trapIndex,
    required this.onShowTrap,
    required this.onClose,
    this.initialTrap,
  });

  final TrapIndexService trapIndex;
  final VoidCallback onClose;

  /// Trap to start on (e.g. the trap at the current position); first trap
  /// in tour order when null.
  final TrapLineInfo? initialTrap;

  /// Loads a tour stop onto the board / PGN tab (host decides how — e.g.
  /// as an annotated explorable line).
  final void Function(TrapLineInfo trap) onShowTrap;

  /// Sort traps by trick surplus (matches [TrapsBrowser] default).
  static List<TrapLineInfo> sortedTraps(List<TrapLineInfo> traps) {
    final sorted = List<TrapLineInfo>.from(traps);
    sorted.sort((a, b) => b.trickSurplus.compareTo(a.trickSurplus));
    return sorted;
  }

  static bool sameTrap(TrapLineInfo a, TrapLineInfo b) {
    if (identical(a, b)) return true;
    if (a.fen != null && b.fen != null && a.fen == b.fen) return true;
    if (a.movesSan.length != b.movesSan.length) return false;
    for (var i = 0; i < a.movesSan.length; i++) {
      if (a.movesSan[i] != b.movesSan[i]) return false;
    }
    return true;
  }

  static int indexOfTrap(List<TrapLineInfo> sorted, TrapLineInfo trap) {
    for (var i = 0; i < sorted.length; i++) {
      if (sameTrap(sorted[i], trap)) return i;
    }
    return -1;
  }

  @override
  TrapTourBarState createState() => TrapTourBarState();
}

class TrapTourBarState extends State<TrapTourBar> {
  late List<TrapLineInfo> _sortedTraps;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _sortedTraps = TrapTourBar.sortedTraps(widget.trapIndex.allTraps);
    final initial = widget.initialTrap;
    _currentIndex =
        initial != null ? TrapTourBar.indexOfTrap(_sortedTraps, initial) : 0;
    if (_currentIndex < 0) _currentIndex = 0;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _showCurrent();
    });
  }

  @override
  void didUpdateWidget(covariant TrapTourBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.trapIndex, widget.trapIndex)) return;
    // Traps regenerated mid-tour: rebuild the list, stay on the same trap
    // when it survived, otherwise clamp.
    final current =
        _sortedTraps.isNotEmpty ? _sortedTraps[_currentIndex] : null;
    _sortedTraps = TrapTourBar.sortedTraps(widget.trapIndex.allTraps);
    final idx =
        current != null ? TrapTourBar.indexOfTrap(_sortedTraps, current) : -1;
    _currentIndex = idx >= 0
        ? idx
        : _currentIndex.clamp(0, _sortedTraps.isEmpty ? 0 : _sortedTraps.length - 1);
  }

  TrapLineInfo get _currentTrap => _sortedTraps[_currentIndex];

  /// Advance to the next trap. Returns false when already at the last one.
  bool next() => _goToIndex(_currentIndex + 1);

  /// Step back to the previous trap. Returns false at the first one.
  bool previous() => _goToIndex(_currentIndex - 1);

  bool _goToIndex(int index) {
    if (index < 0 || index >= _sortedTraps.length) return false;
    setState(() => _currentIndex = index);
    _showCurrent();
    return true;
  }

  void _showCurrent() {
    if (_sortedTraps.isEmpty) return;
    widget.onShowTrap(_currentTrap);
  }

  @override
  Widget build(BuildContext context) {
    if (_sortedTraps.isEmpty) return const SizedBox.shrink();
    final trap = _currentTrap;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.warning.withValues(alpha: 0.07),
        border: Border(
          top: BorderSide(color: AppColors.warning.withValues(alpha: 0.45)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LinearProgressIndicator(
            value: (_currentIndex + 1) / _sortedTraps.length,
            minHeight: 2,
            color: AppColors.warning,
            backgroundColor: AppColors.warning.withValues(alpha: 0.15),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(10, 4, 4, 6),
            child: Row(
              children: [
                const Icon(Icons.tour, size: 16, color: AppColors.warning),
                const SizedBox(width: 6),
                const Text(
                  'Trap Tour',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.warning,
                  ),
                ),
                const SizedBox(width: 6),
                ShortcutIconButton(
                  description: 'Previous trap',
                  shortcut: 'P',
                  icon: const Icon(Icons.chevron_left, size: 20),
                  color: AppColors.warning,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: _currentIndex > 0 ? previous : null,
                ),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppColors.warning.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    '${_currentIndex + 1} / ${_sortedTraps.length}',
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 12,
                    ),
                  ),
                ),
                ShortcutIconButton(
                  description: 'Next trap',
                  shortcut: 'N',
                  icon: const Icon(Icons.chevron_right, size: 20),
                  color: AppColors.warning,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed:
                      _currentIndex < _sortedTraps.length - 1 ? next : null,
                ),
                const SizedBox(width: 10),
                Expanded(child: _TrapTourNarrative(trap: trap)),
                const SizedBox(width: 6),
                Tooltip(
                  message: 'The trap line is loaded in the PGN tab — click '
                      'any move to step through it.\n'
                      'Shift+←/→ jumps between traps inside the line.',
                  child: Icon(Icons.help_outline,
                      size: 14, color: Colors.grey[600]),
                ),
                const SizedBox(width: 2),
                ShortcutIconButton(
                  description: 'Close tour',
                  shortcut: 'Esc',
                  icon: const Icon(Icons.close, size: 16),
                  visualDensity: VisualDensity.compact,
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Opening name plus a one-line "what they do wrong / how you punish it".
class _TrapTourNarrative extends StatelessWidget {
  const _TrapTourNarrative({required this.trap});

  final TrapLineInfo trap;

  @override
  Widget build(BuildContext context) {
    final tempted =
        '${trap.popularMove} (${(trap.popularProb * 100).toStringAsFixed(0)}%)';
    final gain = '+${(trap.evalDiffCp / 100).toStringAsFixed(1)}';
    final reach = '${(trap.cumulativeProb * 100).toStringAsFixed(1)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          trap.openingName ?? trap.movesText,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 1),
        Text.rich(
          TextSpan(
            style: TextStyle(fontSize: 11, color: Colors.grey[400]),
            children: [
              const TextSpan(text: 'They\'re tempted by '),
              TextSpan(
                text: tempted,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: AppColors.danger,
                ),
              ),
              if (trap.refutationMove != null) ...[
                const TextSpan(text: ' — punish with '),
                TextSpan(
                  text: trap.refutationMove!,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: AppColors.evalPositive,
                  ),
                ),
              ],
              TextSpan(text: ' · $gain gain · reaches $reach of games'),
            ],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}
