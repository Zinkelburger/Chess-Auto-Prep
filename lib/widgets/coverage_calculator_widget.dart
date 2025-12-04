/// Coverage Calculator Widget
/// Beautiful visualization of repertoire coverage analysis
library;

import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/coverage_service.dart';
import '../models/opening_tree.dart';

/// Coverage Calculator Widget with beautiful metrics visualization
class CoverageCalculatorWidget extends StatefulWidget {
  final OpeningTree? openingTree;
  final bool isWhiteRepertoire;

  const CoverageCalculatorWidget({
    super.key,
    required this.openingTree,
    required this.isWhiteRepertoire,
  });

  @override
  State<CoverageCalculatorWidget> createState() => _CoverageCalculatorWidgetState();
}

class _CoverageCalculatorWidgetState extends State<CoverageCalculatorWidget>
    with TickerProviderStateMixin {
  // Service and state
  CoverageService? _service;
  CoverageResult? _result;
  bool _isAnalyzing = false;
  String _progressMessage = '';
  double _progress = 0.0;
  String? _error;
  
  // Detected root info (populated after analysis)
  String? _detectedRootMoves;
  int? _detectedRootGameCount;

  // Configuration
  double _targetPercent = 1.0;  // Target as percentage of root (default 1%)
  LichessDatabase _database = LichessDatabase.lichess;
  String _ratings = '2000,2200,2500';  // Default to 2000+
  final String _speeds = 'blitz,rapid,classical';

  // Animation controllers
  late AnimationController _progressController;
  late AnimationController _resultsController;

  // Preset percentages
  static const _percentPresets = [
    ('0.5%', 0.5),
    ('1%', 1.0),
    ('2%', 2.0),
    ('5%', 5.0),
    ('10%', 10.0),
  ];

  @override
  void initState() {
    super.initState();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
    _resultsController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    
    // Detect root position on init
    _detectRootPosition();
  }

  @override
  void dispose() {
    _progressController.dispose();
    _resultsController.dispose();
    super.dispose();
  }
  
  /// Detect the root position from the repertoire tree
  void _detectRootPosition() {
    if (widget.openingTree == null) return;
    
    final service = CoverageService(
      database: _database,
      ratings: _ratings,
      speeds: _speeds,
    );
    
    final (moves, _) = service.findRepertoireRoot(widget.openingTree!);
    setState(() {
      _detectedRootMoves = moves.isEmpty ? 'Starting position' : moves.join(' ');
    });
  }

  Future<void> _startAnalysis() async {
    if (widget.openingTree == null) {
      setState(() => _error = 'No repertoire loaded');
      return;
    }

    setState(() {
      _isAnalyzing = true;
      _result = null;
      _error = null;
      _progress = 0.0;
      _progressMessage = 'Initializing...';
    });
    _progressController.forward();

    _service = CoverageService(
      database: _database,
      ratings: _ratings,
      speeds: _speeds,
    );

    try {
      // Root position is auto-detected from the tree
      final result = await _service!.analyzeOpeningTree(
        widget.openingTree!,
        targetPercent: _targetPercent,
        isWhiteRepertoire: widget.isWhiteRepertoire,
        onProgress: (message, progress) {
          if (mounted) {
            setState(() {
              _progressMessage = message;
              _progress = progress;
            });
          }
        },
      );

      if (mounted) {
        setState(() {
          _result = result;
          _detectedRootMoves = result.rootDescription;
          _detectedRootGameCount = result.rootGameCount;
          _isAnalyzing = false;
        });
        _progressController.reverse();
        _resultsController.forward(from: 0);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Analysis failed: $e';
          _isAnalyzing = false;
        });
        _progressController.reverse();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            colorScheme.surface,
            colorScheme.surface.withOpacity(0.95),
          ],
        ),
      ),
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(theme),
            const SizedBox(height: 20),
            _buildConfigurationCard(theme),
            const SizedBox(height: 16),
            _buildActionButton(theme),
            if (_isAnalyzing) ...[
              const SizedBox(height: 24),
              _buildProgressCard(theme),
            ],
            if (_error != null) ...[
              const SizedBox(height: 16),
              _buildErrorCard(theme),
            ],
            if (_result != null) ...[
              const SizedBox(height: 24),
              _buildResultsSection(theme),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: theme.colorScheme.primaryContainer,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Icon(
            Icons.analytics_outlined,
            size: 28,
            color: theme.colorScheme.onPrimaryContainer,
          ),
        ),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Coverage Calculator',
                style: theme.textTheme.titleLarge?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                'Analyze how well your repertoire covers opponent responses',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConfigurationCard(ThemeData theme) {
    // Calculate target game count for display
    final targetGames = _detectedRootGameCount != null 
        ? (_detectedRootGameCount! * _targetPercent / 100).round()
        : null;
    
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Root Position (auto-detected)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: theme.colorScheme.primaryContainer.withOpacity(0.3),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.account_tree,
                    size: 20,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Root Position (auto-detected)',
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurface.withOpacity(0.7),
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _detectedRootMoves ?? 'Analyzing...',
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_detectedRootGameCount != null)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        _formatNumber(_detectedRootGameCount!),
                        style: theme.textTheme.bodySmall?.copyWith(
                          fontWeight: FontWeight.bold,
                          color: theme.colorScheme.onPrimary,
                        ),
                      ),
                    ),
                ],
              ),
            ),
            
            const SizedBox(height: 20),

            // Target percentage
            Row(
              children: [
                Text(
                  'Target Threshold',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                if (targetGames != null)
                  Text(
                    '≤ ${_formatNumber(targetGames)} games',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Positions with fewer games than this are considered "sealed"',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: _percentPresets.map((preset) {
                final isSelected = (_targetPercent - preset.$2).abs() < 0.01;
                return ChoiceChip(
                  label: Text(preset.$1),
                  selected: isSelected,
                  onSelected: _isAnalyzing ? null : (selected) {
                    if (selected) {
                      setState(() => _targetPercent = preset.$2);
                    }
                  },
                  selectedColor: theme.colorScheme.primaryContainer,
                );
              }).toList(),
            ),
            
            const SizedBox(height: 20),
            const Divider(),
            const SizedBox(height: 12),

            // Database selection
            Text(
              'Database',
              style: theme.textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            SegmentedButton<LichessDatabase>(
              segments: const [
                ButtonSegment(
                  value: LichessDatabase.lichess,
                  label: Text('Lichess'),
                  icon: Icon(Icons.computer, size: 16),
                ),
                ButtonSegment(
                  value: LichessDatabase.masters,
                  label: Text('Masters'),
                  icon: Icon(Icons.star, size: 16),
                ),
              ],
              selected: {_database},
              onSelectionChanged: _isAnalyzing ? null : (selection) {
                setState(() => _database = selection.first);
              },
            ),

            if (_database == LichessDatabase.lichess) ...[
              const SizedBox(height: 16),
              // Rating range
              Text(
                'Rating Range',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 4,
                children: [
                  _buildRatingChip('2000+', '2000,2200,2500'),
                  _buildRatingChip('2200+', '2200,2500'),
                  _buildRatingChip('1800+', '1800,2000,2200,2500'),
                  _buildRatingChip('All', '1600,1800,2000,2200,2500'),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildRatingChip(String label, String value) {
    final isSelected = _ratings == value;
    return FilterChip(
      label: Text(label, style: const TextStyle(fontSize: 12)),
      selected: isSelected,
      onSelected: _isAnalyzing ? null : (selected) {
        if (selected) {
          setState(() => _ratings = value);
        }
      },
    );
  }

  Widget _buildActionButton(ThemeData theme) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      child: FilledButton.icon(
        onPressed: _isAnalyzing || widget.openingTree == null ? null : _startAnalysis,
        icon: _isAnalyzing
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: theme.colorScheme.onPrimary,
                ),
              )
            : const Icon(Icons.play_arrow),
        label: Text(_isAnalyzing ? 'Analyzing...' : 'Analyze Coverage'),
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }

  Widget _buildProgressCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.secondaryContainer.withOpacity(0.5),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            LinearProgressIndicator(
              value: _progress,
              backgroundColor: theme.colorScheme.outline.withOpacity(0.2),
              borderRadius: BorderRadius.circular(4),
            ),
            const SizedBox(height: 12),
            Text(
              _progressMessage,
              style: theme.textTheme.bodyMedium,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            Text(
              '${(_progress * 100).toStringAsFixed(0)}%',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildErrorCard(ThemeData theme) {
    return Card(
      elevation: 0,
      color: theme.colorScheme.errorContainer,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(Icons.error_outline, color: theme.colorScheme.onErrorContainer),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _error!,
                style: TextStyle(color: theme.colorScheme.onErrorContainer),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsSection(ThemeData theme) {
    final result = _result!;

    return AnimatedBuilder(
      animation: _resultsController,
      builder: (context, child) {
        final slideValue = Curves.easeOutQuart.transform(_resultsController.value);
        final fadeValue = Curves.easeOut.transform(_resultsController.value);

        return Transform.translate(
          offset: Offset(0, 20 * (1 - slideValue)),
          child: Opacity(
            opacity: fadeValue,
            child: child,
          ),
        );
      },
      child: Column(
        children: [
          // Summary card with pie chart
          _buildSummaryCard(theme, result),
          const SizedBox(height: 16),

          // Metrics grid
          _buildMetricsGrid(theme, result),
          const SizedBox(height: 16),

          // Leaking leaves (if any)
          if (result.leakingLeaves.isNotEmpty)
            _buildLeakingLeavesCard(theme, result),

          // Cache stats
          if (_service != null)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Text(
                _service!.cacheStats,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.5),
                ),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryCard(ThemeData theme, CoverageResult result) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Row(
              children: [
                // Pie chart
                SizedBox(
                  width: 140,
                  height: 140,
                  child: CustomPaint(
                    painter: _CoveragePieChartPainter(
                      coverage: result.coveragePercent,
                      leakage: result.leakagePercent,
                      unaccounted: result.unaccountedPercent,
                      coverageColor: const Color(0xFF4CAF50),
                      leakageColor: const Color(0xFFFFA726),
                      unaccountedColor: const Color(0xFFEF5350),
                    ),
                  ),
                ),
                const SizedBox(width: 24),
                // Legend
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLegendItem(
                        'Coverage',
                        '${result.coveragePercent.toStringAsFixed(1)}%',
                        const Color(0xFF4CAF50),
                        theme,
                      ),
                      const SizedBox(height: 8),
                      _buildLegendItem(
                        'Leakage',
                        '${result.leakagePercent.toStringAsFixed(1)}%',
                        const Color(0xFFFFA726),
                        theme,
                      ),
                      const SizedBox(height: 8),
                      _buildLegendItem(
                        'Unaccounted',
                        '${result.unaccountedPercent.toStringAsFixed(1)}%',
                        const Color(0xFFEF5350),
                        theme,
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Divider(color: theme.colorScheme.outline.withOpacity(0.2)),
            const SizedBox(height: 12),
            Text(
              'Root: ${_formatNumber(result.rootGameCount)} games • '
              'Target: ${result.targetPercent.toStringAsFixed(1)}% = ${_formatNumber(result.targetGameCount)} games',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.6),
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLegendItem(String label, String value, Color color, ThemeData theme) {
    return Row(
      children: [
        Container(
          width: 14,
          height: 14,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(4),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: theme.textTheme.bodyMedium,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.bold,
          ),
        ),
      ],
    );
  }

  Widget _buildMetricsGrid(ThemeData theme, CoverageResult result) {
    return Row(
      children: [
        Expanded(
          child: _buildMetricCard(
            theme,
            icon: Icons.check_circle_outline,
            iconColor: const Color(0xFF4CAF50),
            label: 'Sealed Leaves',
            value: result.sealedLeaves.length.toString(),
            subtitle: '${_formatNumber(result.totalSealedGames)} games',
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: _buildMetricCard(
            theme,
            icon: Icons.warning_amber_outlined,
            iconColor: const Color(0xFFFFA726),
            label: 'Leaking Leaves',
            value: result.leakingLeaves.length.toString(),
            subtitle: '${_formatNumber(result.totalLeakingGames)} games',
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard(
    ThemeData theme, {
    required IconData icon,
    required Color iconColor,
    required String label,
    required String value,
    required String subtitle,
  }) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: theme.colorScheme.outline.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            Icon(icon, color: iconColor, size: 28),
            const SizedBox(height: 8),
            Text(
              value,
              style: theme.textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              label,
              style: theme.textTheme.bodySmall,
            ),
            Text(
              subtitle,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurface.withOpacity(0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLeakingLeavesCard(ThemeData theme, CoverageResult result) {
    final sortedLeaves = [...result.leakingLeaves]
      ..sort((a, b) => b.gameCount.compareTo(a.gameCount));
    final displayLeaves = sortedLeaves.take(10).toList();

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: const Color(0xFFFFA726).withOpacity(0.3)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.warning_amber, color: Color(0xFFFFA726), size: 20),
                const SizedBox(width: 8),
                Text(
                  'Leaking Leaves (Need More Analysis)',
                  style: theme.textTheme.titleSmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ...displayLeaves.map((leaf) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFFA726).withOpacity(0.2),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      _formatNumber(leaf.gameCount),
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFE65100),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      leaf.moveString,
                      style: theme.textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            )),
            if (result.leakingLeaves.length > 10)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  '...and ${result.leakingLeaves.length - 10} more',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withOpacity(0.5),
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  String _formatNumber(int number) {
    if (number >= 1000000) {
      return '${(number / 1000000).toStringAsFixed(1)}M';
    } else if (number >= 1000) {
      return '${(number / 1000).toStringAsFixed(1)}K';
    }
    return number.toString();
  }
}

/// Custom painter for the coverage pie chart
class _CoveragePieChartPainter extends CustomPainter {
  final double coverage;
  final double leakage;
  final double unaccounted;
  final Color coverageColor;
  final Color leakageColor;
  final Color unaccountedColor;

  _CoveragePieChartPainter({
    required this.coverage,
    required this.leakage,
    required this.unaccounted,
    required this.coverageColor,
    required this.leakageColor,
    required this.unaccountedColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.min(size.width, size.height) / 2;
    final strokeWidth = radius * 0.35;
    final innerRadius = radius - strokeWidth;

    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;

    const startAngle = -math.pi / 2; // Start from top

    // Draw coverage
    final coverageSweep = 2 * math.pi * (coverage / 100);
    paint.color = coverageColor;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: innerRadius + strokeWidth / 2),
      startAngle,
      coverageSweep,
      false,
      paint,
    );

    // Draw leakage
    final leakageSweep = 2 * math.pi * (leakage / 100);
    paint.color = leakageColor;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: innerRadius + strokeWidth / 2),
      startAngle + coverageSweep,
      leakageSweep,
      false,
      paint,
    );

    // Draw unaccounted
    final unaccountedSweep = 2 * math.pi * (unaccounted / 100);
    paint.color = unaccountedColor;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: innerRadius + strokeWidth / 2),
      startAngle + coverageSweep + leakageSweep,
      unaccountedSweep,
      false,
      paint,
    );

    // Draw center text
    final textPainter = TextPainter(
      text: TextSpan(
        text: '${coverage.toStringAsFixed(0)}%',
        style: TextStyle(
          color: coverageColor,
          fontSize: radius * 0.35,
          fontWeight: FontWeight.bold,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      center - Offset(textPainter.width / 2, textPainter.height / 2),
    );
  }

  @override
  bool shouldRepaint(covariant _CoveragePieChartPainter oldDelegate) {
    return coverage != oldDelegate.coverage ||
           leakage != oldDelegate.leakage ||
           unaccounted != oldDelegate.unaccounted;
  }
}

