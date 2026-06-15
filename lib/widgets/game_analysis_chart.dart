/// Lichess-style eval chart for full game analysis.
///
/// Renders a line chart of winning chances per move with area fill
/// (white above zero, dark below). Marks inaccuracies, mistakes, and
/// blunders with colored dots. Clicking a point navigates to that move.
library;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../services/game_analysis_controller.dart';
import '../utils/chess_utils.dart' show formatEvalDisplay;

class GameAnalysisChart extends StatefulWidget {
  final List<MoveEval> evals;
  final double startWinChance;
  final int? currentPly; // highlighted ply
  final ValueChanged<int>? onPlySelected;

  const GameAnalysisChart({
    super.key,
    required this.evals,
    this.startWinChance = 0.0,
    this.currentPly,
    this.onPlySelected,
  });

  @override
  State<GameAnalysisChart> createState() => _GameAnalysisChartState();
}

class _GameAnalysisChartState extends State<GameAnalysisChart> {
  final ScrollController _scrollController = ScrollController();
  double _chartWidth = 0;
  double _availableWidth = 0;

  List<MoveEval> get evals => widget.evals;
  int? get currentPly => widget.currentPly;
  ValueChanged<int>? get onPlySelected => widget.onPlySelected;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPly());
  }

  @override
  void didUpdateWidget(GameAnalysisChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentPly != oldWidget.currentPly) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToPly());
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _scrollToPly() {
    if (!_scrollController.hasClients || _chartWidth <= _availableWidth) return;
    final ply = widget.currentPly;
    if (ply == null || evals.isEmpty) return;

    final plyCount = evals.last.ply.toDouble();
    if (plyCount <= 0) return;

    final fraction = ply / plyCount;
    final targetX = fraction * _chartWidth;
    // Center the current ply in view
    final target = (targetX - _availableWidth / 2)
        .clamp(0.0, _scrollController.position.maxScrollExtent);

    _scrollController.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (evals.isEmpty) {
      return const SizedBox.shrink();
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    const double defaultCap = 200;
    final spots = <FlSpot>[
      const FlSpot(0, 0),
      for (final e in evals) FlSpot(e.ply.toDouble(), _clampCp(e).toDouble()),
    ];

    final whiteColor = isDark ? Colors.white70 : Colors.white;
    final blackColor = isDark ? Colors.grey[850]! : Colors.black87;

    final maxAbs =
        spots.fold<double>(0.0, (m, s) => s.y.abs() > m ? s.y.abs() : m);
    final yBound = maxAbs <= defaultCap
        ? defaultCap
        : (maxAbs * 1.1).clamp(defaultCap, 800.0);

    const double minPxPerPly = 12.0;
    final plyCount = evals.isEmpty ? 1.0 : evals.last.ply.toDouble();

    return Padding(
      padding: const EdgeInsets.only(left: 4, right: 12, top: 8, bottom: 4),
      child: SizedBox(
        height: 180,
        child: LayoutBuilder(
          builder: (context, constraints) {
            _availableWidth = constraints.maxWidth;
            _chartWidth = (plyCount * minPxPerPly)
                .clamp(_availableWidth, double.infinity);

            final chart = LineChart(
              LineChartData(
                minY: -yBound,
                maxY: yBound,
                minX: 0,
                maxX: plyCount,
                clipData: const FlClipData.all(),
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  horizontalInterval: 100,
                  getDrawingHorizontalLine: (value) {
                    if (value.abs() < 1) {
                      // Zero line
                      return FlLine(
                        color: isDark ? Colors.grey[600]! : Colors.grey[400]!,
                        strokeWidth: 1,
                      );
                    }
                    if ((value - 100).abs() < 1 || (value + 100).abs() < 1) {
                      // ±1 pawn reference line
                      return FlLine(
                        color: isDark ? Colors.grey[600]! : Colors.grey[400]!,
                        strokeWidth: 0.5,
                        dashArray: [4, 4],
                      );
                    }
                    return const FlLine(
                        color: Colors.transparent, strokeWidth: 0);
                  },
                ),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineTouchData: LineTouchData(
                  touchCallback: (event, response) {
                    if (onPlySelected != null &&
                        response?.lineBarSpots != null &&
                        response!.lineBarSpots!.isNotEmpty &&
                        (event is FlTapUpEvent || event is FlPanUpdateEvent)) {
                      final x = response.lineBarSpots!.first.x;
                      final ply = x.round().clamp(0, evals.length);
                      if (ply > 0) onPlySelected!(ply);
                    }
                  },
                  touchTooltipData: LineTouchTooltipData(
                    getTooltipColor: (_) => theme
                        .colorScheme.surfaceContainerHighest
                        .withAlpha(230),
                    fitInsideHorizontally: true,
                    fitInsideVertically: true,
                    getTooltipItems: (touchedSpots) {
                      return touchedSpots.map((spot) {
                        final ply = spot.x.round();
                        if (ply == 0) {
                          return LineTooltipItem(
                            'Start',
                            TextStyle(
                                fontSize: 11,
                                color: theme.textTheme.bodySmall?.color),
                          );
                        }
                        final idx = ply - 1;
                        if (idx < 0 || idx >= evals.length) return null;
                        final e = evals[idx];
                        final moveNum = (ply + 1) ~/ 2;
                        final dots = ply % 2 == 1 ? '.' : '...';
                        final evalStr = _formatEval(e);
                        final classStr = _classSymbol(e.classification);
                        return LineTooltipItem(
                          '$moveNum$dots ${e.san}$classStr  $evalStr',
                          TextStyle(
                            fontSize: 11,
                            color: _classColor(e.classification) ??
                                theme.textTheme.bodySmall?.color,
                            fontWeight:
                                e.classification != MoveClassification.normal
                                    ? FontWeight.bold
                                    : FontWeight.normal,
                          ),
                        );
                      }).toList();
                    },
                  ),
                ),
                extraLinesData: ExtraLinesData(
                  verticalLines: [
                    if (currentPly != null &&
                        currentPly! >= 0 &&
                        currentPly! <= evals.length)
                      VerticalLine(
                        x: currentPly!.toDouble(),
                        color: theme.colorScheme.primary.withAlpha(180),
                        strokeWidth: 2,
                        dashArray: [4, 3],
                      ),
                  ],
                ),
                lineBarsData: [
                  // White advantage area (above zero)
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.2,
                    preventCurveOverShooting: true,
                    color: Colors.transparent,
                    barWidth: 0,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(show: false),
                    aboveBarData: BarAreaData(show: false),
                  ),
                  // Main eval line with area fill
                  LineChartBarData(
                    spots: spots,
                    isCurved: true,
                    curveSmoothness: 0.2,
                    preventCurveOverShooting: true,
                    color: isDark
                        ? const Color(0xFFD08030)
                        : const Color(0xFFD85000),
                    barWidth: 2,
                    isStrokeCapRound: true,
                    dotData: FlDotData(
                      show: true,
                      getDotPainter: (spot, percent, barData, index) {
                        final ply = spot.x.round();
                        if (ply == 0) {
                          return FlDotCirclePainter(
                              radius: 0, color: Colors.transparent);
                        }
                        final idx = ply - 1;
                        if (idx < 0 || idx >= evals.length) {
                          return FlDotCirclePainter(
                              radius: 0, color: Colors.transparent);
                        }
                        final e = evals[idx];
                        final cls = e.classification;
                        if (cls == MoveClassification.normal) {
                          if (currentPly == ply) {
                            return FlDotCirclePainter(
                              radius: 4,
                              color: theme.colorScheme.primary,
                              strokeWidth: 1.5,
                              strokeColor: Colors.white,
                            );
                          }
                          return FlDotCirclePainter(
                              radius: 0, color: Colors.transparent);
                        }
                        final color = _classColor(cls) ?? Colors.grey;
                        final radius =
                            cls == MoveClassification.blunder ? 5.0 : 4.0;
                        return FlDotCirclePainter(
                          radius: radius,
                          color: color,
                          strokeWidth: 1.5,
                          strokeColor: isDark ? Colors.black : Colors.white,
                        );
                      },
                    ),
                    belowBarData: BarAreaData(
                      show: true,
                      color: whiteColor.withAlpha(isDark ? 30 : 50),
                      cutOffY: 0,
                      applyCutOffY: true,
                    ),
                    aboveBarData: BarAreaData(
                      show: true,
                      color: blackColor.withAlpha(isDark ? 40 : 30),
                      cutOffY: 0,
                      applyCutOffY: true,
                    ),
                  ),
                ],
              ),
              duration: const Duration(milliseconds: 150),
            );

            if (_chartWidth <= _availableWidth) {
              return chart;
            }
            return Scrollbar(
              controller: _scrollController,
              thumbVisibility: true,
              child: SingleChildScrollView(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: _chartWidth, child: chart),
              ),
            );
          },
        ),
      ),
    );
  }

  /// Clamp centipawns for chart display — mate becomes ±800.
  static double _clampCp(MoveEval e) {
    if (e.scoreMate != null) {
      return e.scoreMate! > 0 ? 800.0 : -800.0;
    }
    return (e.scoreCp ?? 0).toDouble().clamp(-800, 800);
  }

  static String _formatEval(MoveEval e) =>
      formatEvalDisplay(scoreCp: e.scoreCp, scoreMate: e.scoreMate);

  static String _classSymbol(MoveClassification cls) => switch (cls) {
        MoveClassification.blunder => '??',
        MoveClassification.mistake => '?',
        MoveClassification.inaccuracy => '?!',
        MoveClassification.interesting => '!?',
        MoveClassification.normal => '',
      };

  static Color? _classColor(MoveClassification cls) => switch (cls) {
        MoveClassification.blunder => const Color(0xFFDB3B21),
        MoveClassification.mistake => const Color(0xFFE69F00),
        MoveClassification.inaccuracy => const Color(0xFF56B4E9),
        MoveClassification.interesting => const Color(0xFF9C27B0),
        MoveClassification.normal => null,
      };
}

/// Summary stats panel shown below the chart.
class GameAnalysisSummary extends StatelessWidget {
  final List<MoveEval> evals;

  const GameAnalysisSummary({super.key, required this.evals});

  @override
  Widget build(BuildContext context) {
    if (evals.isEmpty) return const SizedBox.shrink();

    final whiteEvals = evals.where((e) => e.isWhiteMove).toList();
    final blackEvals = evals.where((e) => !e.isWhiteMove).toList();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Row(
        children: [
          Expanded(
              child:
                  _buildSideStats(context, 'White', whiteEvals, Colors.white)),
          const SizedBox(width: 12),
          Expanded(
              child: _buildSideStats(
                  context, 'Black', blackEvals, Colors.grey[700]!)),
        ],
      ),
    );
  }

  Widget _buildSideStats(BuildContext context, String label,
      List<MoveEval> sideEvals, Color accent) {
    final blunders = sideEvals
        .where((e) => e.classification == MoveClassification.blunder)
        .length;
    final mistakes = sideEvals
        .where((e) => e.classification == MoveClassification.mistake)
        .length;
    final inaccuracies = sideEvals
        .where((e) => e.classification == MoveClassification.inaccuracy)
        .length;
    final interesting = sideEvals
        .where((e) => e.classification == MoveClassification.interesting)
        .length;
    final acpl = _computeAcpl(sideEvals);

    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: accent,
                  border: Border.all(color: Colors.grey),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 6),
              Text(label,
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13)),
              const Spacer(),
              if (acpl != null)
                Text('ACPL: $acpl',
                    style: TextStyle(fontSize: 11, color: Colors.grey[500])),
            ],
          ),
          const SizedBox(height: 6),
          _StatRow(
              icon: '??',
              color: const Color(0xFFDB3B21),
              label: 'Blunder',
              count: blunders),
          _StatRow(
              icon: '?',
              color: const Color(0xFFE69F00),
              label: 'Mistake',
              count: mistakes),
          _StatRow(
              icon: '?!',
              color: const Color(0xFF56B4E9),
              label: 'Inaccuracy',
              count: inaccuracies),
          _StatRow(
              icon: '!?',
              color: const Color(0xFF9C27B0),
              label: 'Interesting',
              count: interesting),
        ],
      ),
    );
  }

  /// Compute ACPL as mean centipawn loss per move for this side.
  /// Uses the Lichess approach: for each move by this side, compute
  /// how much the evaluation (from that side's POV) dropped.
  int? _computeAcpl(List<MoveEval> sideEvals) {
    if (sideEvals.isEmpty) return null;

    // Build a list of all evals in ply order (both sides) to compute deltas
    final allSorted = List.of(evals)..sort((a, b) => a.ply.compareTo(b.ply));
    final evalByPly = <int, MoveEval>{};
    for (final e in allSorted) {
      evalByPly[e.ply] = e;
    }

    double totalLoss = 0;
    int count = 0;
    for (final e in sideEvals) {
      // Find the eval BEFORE this move (the previous ply's eval)
      final prevPly = e.ply - 1;
      double prevCp;
      if (prevPly <= 0) {
        prevCp = 0.0; // starting position is roughly equal
      } else {
        final prev = evalByPly[prevPly];
        if (prev == null) continue;
        prevCp = prev.effectiveCp.toDouble();
      }

      final currCp = e.effectiveCp.toDouble();
      // Loss from this side's POV:
      // If White moved, loss = prevCp - currCp (eval dropped for White)
      // If Black moved, loss = currCp - prevCp (eval rose for White = bad for Black)
      final loss = e.isWhiteMove
          ? (prevCp - currCp).clamp(0.0, 1000.0)
          : (currCp - prevCp).clamp(0.0, 1000.0);

      totalLoss += loss;
      count++;
    }

    if (count == 0) return null;
    return (totalLoss / count).round();
  }
}

class _StatRow extends StatelessWidget {
  final String icon;
  final Color color;
  final String label;
  final int count;

  const _StatRow({
    required this.icon,
    required this.color,
    required this.label,
    required this.count,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 1),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            child: Text(
              icon,
              style: TextStyle(
                  fontWeight: FontWeight.bold, fontSize: 12, color: color),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 4),
          Text(label, style: const TextStyle(fontSize: 12)),
          const Spacer(),
          Text(
            '$count',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              fontSize: 13,
              color: count > 0 ? color : Colors.grey[600],
            ),
          ),
        ],
      ),
    );
  }
}
