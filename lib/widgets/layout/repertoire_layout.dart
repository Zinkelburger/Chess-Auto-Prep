/// Three-zone layout orchestrator for the repertoire builder (spec 003 / B4).
///
/// Wide layout (width >= [kCompactBreakpoint]): board | main | context in a
/// single row at 40% / 30% / 30% ([kBoardZoneFlex] : [kMainZoneFlex] :
/// [kContextZoneFlex]).
///
/// Compact layout (width < breakpoint): stacks zones vertically with the same
/// flex ratios, unless [compactLayout] is provided — then the parent owns the
/// compact UX (e.g. board + PGN/Context tabs).
library;

import 'package:flutter/material.dart';

import '../../constants/ui_breakpoints.dart';
import 'repertoire_mode.dart';

/// Flex weight for the board column — 40% of wide layout width.
const int kBoardZoneFlex = 4;

/// Flex weight for the main column (PGN editor or analyze tabs) — 30%.
const int kMainZoneFlex = 3;

/// Flex weight for the context column (engine/browse or detail pane) — 30%.
const int kContextZoneFlex = 3;

/// Top-level layout orchestrator for Edit and Analyze modes.
///
/// Accepts pre-built zone widgets so screens wire content without this class
/// owning repertoire or engine state.
class RepertoireLayout extends StatelessWidget {
  const RepertoireLayout({
    super.key,
    required this.boardZone,
    required this.editMainZone,
    required this.editContextZone,
    required this.analyzeMainZone,
    required this.analyzeContextZone,
    required this.mode,
    this.statusBar,
    this.compactLayout,
    this.breakpoint = kCompactBreakpoint,
  });

  /// Chess board column ([BoardZone]).
  final Widget boardZone;

  /// PGN editor column in Edit mode ([EditMainZone]).
  final Widget editMainZone;

  /// Engine / browse / tree panel in Edit mode ([EditContextZone]).
  final Widget editContextZone;

  /// Lines / coverage / traps tabs in Analyze mode ([AnalyzeMainZone]).
  final Widget analyzeMainZone;

  /// Eval tree graph / trap detail in Analyze mode ([AnalyzeContextZone]).
  final Widget analyzeContextZone;

  /// Active operational mode — selects main and context zone widgets.
  final RepertoireMode mode;

  /// Optional metrics bar rendered below the zones ([RepertoireStatusBar]).
  final Widget? statusBar;

  /// When set, used instead of the default vertical stack below [breakpoint].
  final Widget? compactLayout;

  /// Width threshold for wide three-column vs compact layout.
  final double breakpoint;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: LayoutBuilder(
            builder: (context, constraints) {
              final mainZone = _mainZoneForMode(mode);
              final contextZone = _contextZoneForMode(mode);

              if (constraints.maxWidth >= breakpoint) {
                return _WideThreeZoneLayout(
                  boardZone: boardZone,
                  mainZone: mainZone,
                  contextZone: contextZone,
                );
              }

              if (compactLayout != null) {
                return compactLayout!;
              }

              return _CompactStackedLayout(
                boardZone: boardZone,
                mainZone: mainZone,
                contextZone: contextZone,
              );
            },
          ),
        ),
        if (statusBar != null) statusBar!,
      ],
    );
  }

  Widget _mainZoneForMode(RepertoireMode mode) {
    return switch (mode) {
      RepertoireMode.edit => editMainZone,
      RepertoireMode.analyze => analyzeMainZone,
    };
  }

  Widget _contextZoneForMode(RepertoireMode mode) {
    return switch (mode) {
      RepertoireMode.edit => editContextZone,
      RepertoireMode.analyze => analyzeContextZone,
    };
  }
}

/// Horizontal three-column layout: board 40% | main 30% | context 30%.
class _WideThreeZoneLayout extends StatelessWidget {
  const _WideThreeZoneLayout({
    required this.boardZone,
    required this.mainZone,
    required this.contextZone,
  });

  final Widget boardZone;
  final Widget mainZone;
  final Widget contextZone;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: kBoardZoneFlex, child: boardZone),
        _verticalZoneDivider(),
        Expanded(flex: kMainZoneFlex, child: mainZone),
        _verticalZoneDivider(),
        Expanded(flex: kContextZoneFlex, child: contextZone),
      ],
    );
  }
}

/// Default compact layout: board on top, main and context stacked below.
class _CompactStackedLayout extends StatelessWidget {
  const _CompactStackedLayout({
    required this.boardZone,
    required this.mainZone,
    required this.contextZone,
  });

  final Widget boardZone;
  final Widget mainZone;
  final Widget contextZone;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(flex: kBoardZoneFlex, child: boardZone),
        const Divider(height: 1),
        Expanded(flex: kMainZoneFlex, child: mainZone),
        const Divider(height: 1),
        Expanded(flex: kContextZoneFlex, child: contextZone),
      ],
    );
  }
}

Widget _verticalZoneDivider() {
  return Container(width: 1, color: Colors.grey[700]);
}
