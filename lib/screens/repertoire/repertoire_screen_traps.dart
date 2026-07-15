// Trap tour and trap-line handling for the repertoire screen. Split out of
// repertoire_screen.dart (pure code motion).
part of '../repertoire_screen.dart';

mixin _RepertoireTrapHandlers on _RepertoireScreenStateBase {
  void _openTrapTour({TrapLineInfo? startTrap}) {
    if (_trapIndex == null || _traps.isEmpty) return;
    setState(() {
      _trapTourVisible = true;
      _trapTourInitialTrap = startTrap;
    });
  }

  void _closeTrapTour() {
    if (!_trapTourVisible) return;
    setState(() {
      _trapTourVisible = false;
      _trapTourInitialTrap = null;
    });
  }

  Future<void> _loadTraps(String filePath) async {
    final traps = await TrapExtractor.loadFromFile(filePath);
    if (mounted) {
      setState(() {
        _traps = traps ?? [];
        _trapIndex = _traps.isEmpty ? null : TrapIndexService(_traps);
      });
    }
  }

  Widget? _buildTrapNavigation() {
    final trapIndex = _trapIndex;
    if (trapIndex == null) return null;
    return TrapNavigationButtons(
      trapIndex: trapIndex,
      controller: _controller,
      onStartTour: _openTrapTour,
      tourActive: _trapTourVisible,
    );
  }

  /// Load a trap as an annotated, explorable line: the path to the trap as
  /// mainline, opponent replies (with play rates and our punish) as
  /// continuations, cursor at the trap position — or at [ply] when given.
  /// Always lands in the PGN tab so the line is clickable right away.
  void _showTrapLine(TrapLineInfo trap, {int? ply}) {
    final built = TrapLineBuilder.build(trap);
    if (built == null) {
      // Stale/corrupt trap file: fall back to the bare sequence.
      _controller.loadMoveSequence(trap.movesSan);
      _toolsTabController.animateTo(0);
      return;
    }
    _controller.loadAnnotatedTree(
      built.tree,
      cursor: built.cursor,
      label: _trapTitle(trap),
    );
    if (ply != null) _controller.jumpToMoveIndex(ply);
    _toolsTabController.animateTo(0);
  }

  /// "Trap #N · Opening" — N is the trap's rank in tour order (trick
  /// surplus), so the browser, tour bar, and PGN title all agree.
  String _trapTitle(TrapLineInfo trap) {
    final idx = TrapTourBar.indexOfTrap(TrapTourBar.sortedTraps(_traps), trap);
    final number = idx >= 0 ? 'Trap #${idx + 1}' : 'Trap';
    final opening = trap.openingName;
    return opening != null ? '$number · $opening' : number;
  }
}
