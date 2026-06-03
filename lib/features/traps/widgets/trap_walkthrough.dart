/// Guided tour through repertoire traps (prev/next over sorted trap list).
library;

import 'package:flutter/material.dart';

import '../../../widgets/shortcut_tooltip.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../../core/repertoire_controller.dart';
import '../../../theme/app_colors.dart';
import '../models/trap_line_info.dart';
import '../services/trap_index_service.dart';
import 'trap_detail_card.dart';
import 'trap_navigation_buttons.dart';

/// Sorted trap list with prev/next navigation and optional detail card.
class TrapWalkthrough extends StatefulWidget {
  const TrapWalkthrough({
    super.key,
    required this.trapIndex,
    required this.controller,
    required this.onClose,
    this.boardPreview,
    this.initialTrap,
  });

  final TrapIndexService trapIndex;
  final RepertoireController controller;
  final VoidCallback onClose;
  final BoardPreviewController? boardPreview;
  final TrapLineInfo? initialTrap;

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
  State<TrapWalkthrough> createState() => _TrapWalkthroughState();
}

class _TrapWalkthroughState extends State<TrapWalkthrough> {
  late final List<TrapLineInfo> _sortedTraps;
  late int _currentIndex;

  @override
  void initState() {
    super.initState();
    _sortedTraps = TrapWalkthrough.sortedTraps(widget.trapIndex.allTraps);
    final initial = widget.initialTrap;
    if (initial != null) {
      final idx = TrapWalkthrough.indexOfTrap(_sortedTraps, initial);
      _currentIndex = idx >= 0 ? idx : 0;
    } else {
      _currentIndex = 0;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _jumpToCurrent();
    });
  }

  TrapLineInfo get _currentTrap => _sortedTraps[_currentIndex];

  void _jumpToCurrent() {
    TrapNavigationButtons.jumpToTrap(widget.controller, _currentTrap);
  }

  void _goToIndex(int index) {
    if (index < 0 || index >= _sortedTraps.length) return;
    setState(() => _currentIndex = index);
    _jumpToCurrent();
  }

  @override
  Widget build(BuildContext context) {
    if (_sortedTraps.isEmpty) {
      return _TrapWalkthroughShell(
        onClose: widget.onClose,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'No traps in repertoire',
            style: TextStyle(color: Colors.grey[400]),
          ),
        ),
      );
    }

    final preview = widget.boardPreview;
    final trap = _currentTrap;

    return _TrapWalkthroughShell(
      onClose: widget.onClose,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          _TrapWalkthroughHeader(
            currentIndex: _currentIndex,
            total: _sortedTraps.length,
            canGoPrev: _currentIndex > 0,
            canGoNext: _currentIndex < _sortedTraps.length - 1,
            onPrevious: () => _goToIndex(_currentIndex - 1),
            onNext: () => _goToIndex(_currentIndex + 1),
          ),
          const Divider(height: 1),
          Flexible(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(8),
              child: preview != null
                  ? TrapDetailCard(
                      trap: trap,
                      index: _currentIndex,
                      boardPreview: preview,
                      onShowPath: _jumpToCurrent,
                    )
                  : _TrapWalkthroughSummary(trap: trap, index: _currentIndex),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrapWalkthroughShell extends StatelessWidget {
  const _TrapWalkthroughShell({
    required this.onClose,
    required this.child,
  });

  final VoidCallback onClose;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 8,
      color: AppColors.surfaceElevated,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
      child: SafeArea(
        top: false,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * 0.45,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 4, 0),
                child: Row(
                  children: [
                    Icon(Icons.tour, size: 18, color: AppColors.warning),
                    const SizedBox(width: 8),
                    const Text(
                      'Trap tour',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    ShortcutIconButton(
                      description: 'Close tour',
                      shortcut: 'T',
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: onClose,
                    ),
                  ],
                ),
              ),
              Flexible(child: child),
            ],
          ),
        ),
      ),
    );
  }
}

class _TrapWalkthroughHeader extends StatelessWidget {
  const _TrapWalkthroughHeader({
    required this.currentIndex,
    required this.total,
    required this.canGoPrev,
    required this.canGoNext,
    required this.onPrevious,
    required this.onNext,
  });

  final int currentIndex;
  final int total;
  final bool canGoPrev;
  final bool canGoNext;
  final VoidCallback onPrevious;
  final VoidCallback onNext;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ShortcutIconButton(
            description: 'Previous trap',
            shortcut: 'Shift+←',
            icon: const Icon(Icons.skip_previous, size: 22),
            color: AppColors.warning,
            onPressed: canGoPrev ? onPrevious : null,
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: AppColors.warning.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(
              '${currentIndex + 1} / $total',
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
          ShortcutIconButton(
            description: 'Next trap',
            shortcut: 'Shift+→',
            icon: const Icon(Icons.skip_next, size: 22),
            color: AppColors.warning,
            onPressed: canGoNext ? onNext : null,
          ),
        ],
      ),
    );
  }
}

class _TrapWalkthroughSummary extends StatelessWidget {
  const _TrapWalkthroughSummary({
    required this.trap,
    required this.index,
  });

  final TrapLineInfo trap;
  final int index;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Trap #${index + 1}',
            style: const TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            trap.movesText,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            trap.mistakeDescription,
            style: TextStyle(fontSize: 12, color: Colors.grey[400]),
          ),
          const SizedBox(height: 4),
          Text(
            trap.summary,
            style: TextStyle(fontSize: 11, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }
}
