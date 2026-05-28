/// Engine-like panel displaying expectimax lines from the precomputed tree.
///
/// Visual parity with [UnifiedEnginePane]: rank, eval, clickable/hoverable
/// SAN continuation. Backed by precomputed tree data instead of live Stockfish.
library;

import 'package:flutter/material.dart';

import '../../models/build_tree_node.dart';
import '../../models/engine_settings.dart';
import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../services/coherence_service.dart';
import '../../services/expectimax_line_service.dart';
import '../../services/on_the_fly_expectimax_service.dart';
import '../../services/generation/eca_calculator.dart';
import '../../utils/eval_constants.dart';
import '../../services/generation/fen_map.dart';
import '../../services/generation/generation_config.dart';
import '../../theme/app_colors.dart';
import '../../utils/chess_utils.dart' show fenAfterMoves;
import '../clickable_move_line.dart';
import 'floating_board_preview.dart';

class ExpectimaxLinesPane extends StatefulWidget {
  final String fen;
  final BuildTree? tree;
  final TreeBuildConfig? config;
  final FenMap? fenMap;
  final bool isWhiteRepertoire;
  final BoardPreviewController boardPreview;
  final void Function(String san)? onMoveSelected;
  final void Function(List<String> sanMoves, int index)? onLineMoveClicked;
  final CoherenceResult? coherenceResult;
  final OnTheFlyProgressiveLines? progressiveSnapshot;
  final bool onTheFlyMode;
  final VoidCallback? onOpenSettings;

  /// Embedded beside engine pane — no bottom PV depth controls.
  final bool compact;

  const ExpectimaxLinesPane({
    super.key,
    required this.fen,
    this.tree,
    this.config,
    this.fenMap,
    required this.isWhiteRepertoire,
    required this.boardPreview,
    this.onMoveSelected,
    this.onLineMoveClicked,
    this.coherenceResult,
    this.progressiveSnapshot,
    this.onTheFlyMode = false,
    this.onOpenSettings,
    this.compact = false,
  });

  @override
  State<ExpectimaxLinesPane> createState() => _ExpectimaxLinesPaneState();
}

class _ExpectimaxLinesPaneState extends State<ExpectimaxLinesPane> {
  final EngineSettings _settings = EngineSettings();
  List<ExpectimaxLine> _lines = [];
  int _maxPlies = 12;
  final GlobalKey _previewStackKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Manual listener: _recompute rebuilds expectimax lines when settings change.
    _settings.addListener(_recompute);
    _recompute();
  }

  @override
  void dispose() {
    _settings.removeListener(_recompute);
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ExpectimaxLinesPane old) {
    super.didUpdateWidget(old);
    if (old.fen != widget.fen ||
        old.tree != widget.tree ||
        old.config != widget.config ||
        old.progressiveSnapshot != widget.progressiveSnapshot) {
      _recompute();
    }
  }

  bool get _useProgressive =>
      (widget.onTheFlyMode && widget.progressiveSnapshot != null) ||
      (widget.progressiveSnapshot != null &&
          (widget.progressiveSnapshot!.lines.isNotEmpty ||
              widget.progressiveSnapshot!.isComputing));

  List<ExpectimaxLine> get _displayLines =>
      _useProgressive ? widget.progressiveSnapshot!.lines : _lines;

  void _recompute() {
    if (_useProgressive) {
      setState(() {});
      return;
    }

    if (widget.tree == null || widget.config == null) {
      setState(() => _lines = []);
      return;
    }

    final node = findNodeByFen(widget.tree!, widget.fen);
    if (node == null) {
      setState(() => _lines = []);
      return;
    }

    final eca =
        ExpectimaxCalculator(config: widget.config!, fenMap: widget.fenMap);

    final lines = generateExpectimaxLines(
      node,
      widget.config!,
      eca,
      topLines: _settings.expectimaxOurMultipv,
      maxPlies: _maxPlies,
      fenMap: widget.fenMap,
    );

    setState(() => _lines = lines);
  }

  int get _startPly {
    final fen = widget.fen;
    final parts = fen.split(' ');
    if (parts.length < 6) return 0;
    final fullMoveNumber = int.tryParse(parts[5]) ?? 1;
    final isBlack = parts[1] == 'b';
    return (fullMoveNumber - 1) * 2 + (isBlack ? 1 : 0);
  }

  @override
  Widget build(BuildContext context) {
    final prog = widget.progressiveSnapshot;
    final isComputing = prog?.isComputing ?? false;

    // On-the-fly mode with no snapshot yet — show computing state.
    if (widget.onTheFlyMode && prog == null) {
      return _buildComputingState(
        const OnTheFlyProgressiveLines(
          lines: [],
          targetMaxDepth: 5,
          isComputing: true,
        ),
      );
    }

    if (!_useProgressive && widget.tree == null) {
      return _buildNoTreeState(isComputing: isComputing);
    }

    if (_displayLines.isEmpty) {
      if (prog?.errorMessage != null && !isComputing) {
        return _buildErrorState(prog!.errorMessage!);
      }
      if (isComputing || widget.onTheFlyMode) {
        return _buildComputingState(
          prog ??
              const OnTheFlyProgressiveLines(
                lines: [],
                targetMaxDepth: 5,
                isComputing: true,
              ),
        );
      }
      return _buildNoDataState();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(prog),
        const Divider(height: 1),
        Expanded(
          child: Stack(
            key: _previewStackKey,
            clipBehavior: Clip.none,
            children: [
              ListView.builder(
                itemCount: _displayLines.length,
                itemBuilder: (ctx, i) => _buildLineRow(_displayLines[i]),
              ),
              FloatingBoardPreview(
                stackKey: _previewStackKey,
                controller: widget.boardPreview,
                flipped: !widget.isWhiteRepertoire,
                ownerTag: _previewStackKey,
              ),
            ],
          ),
        ),
        if (!_useProgressive && !widget.compact) _buildControls(),
      ],
    );
  }

  Widget _buildErrorState(String message) {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.error_outline, size: 18, color: AppColors.danger),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Expectimax failed',
                  style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 2),
                Text(
                  message,
                  style: TextStyle(color: Colors.grey[500], fontSize: 11),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildComputingState(OnTheFlyProgressiveLines prog) {
    final done = prog.bestCompletedDepth;
    final target = prog.targetMaxDepth;
    final fraction = target > 0 ? done / target : 0.0;

    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          SizedBox(
            width: 20,
            height: 20,
            child: Stack(
              alignment: Alignment.center,
              children: [
                CircularProgressIndicator(
                  value: fraction > 0 ? fraction : null,
                  strokeWidth: 2,
                  color: AppColors.expectimax,
                ),
                if (done > 0)
                  Text('$done', style: TextStyle(fontSize: 8, color: Colors.grey[400])),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'Computing $done/$target',
              style: TextStyle(color: Colors.grey[400], fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNoTreeState({bool isComputing = false}) {
    if (isComputing || widget.onTheFlyMode) {
      return _buildComputingState(
        widget.progressiveSnapshot ??
            const OnTheFlyProgressiveLines(
              lines: [],
              targetMaxDepth: 5,
              isComputing: true,
            ),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.analytics_outlined, size: 36, color: Colors.grey[600]),
            const SizedBox(height: 12),
            Text(
              'No tree loaded',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
            const SizedBox(height: 4),
            Text(
              'Generate a repertoire tree to see expectimax lines',
              style: TextStyle(color: Colors.grey[600], fontSize: 11),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNoDataState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 36, color: Colors.grey[600]),
            const SizedBox(height: 12),
            Text(
              'Position not in tree',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(OnTheFlyProgressiveLines? prog) {
    final isComputing = prog?.isComputing ?? false;
    final depthDone = prog?.bestCompletedDepth ?? 0;
    final depthTarget = prog?.targetMaxDepth ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const Tooltip(
            message:
                'Best practical continuations considering how humans actually play.\n'
                'Uses Maia probabilities and Stockfish evals to find the most\n'
                'likely game continuations via expectimax search.',
            child: Text('Expectimax PV',
                style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
          ),
          if (isComputing) ...[
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: AppColors.expectimax,
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: Text(
                '$depthDone/$depthTarget',
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey[500],
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ],
          const Spacer(),
          if (widget.onOpenSettings != null)
            IconButton(
              icon: const Icon(Icons.settings, size: 16),
              tooltip: 'Analysis settings',
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
              onPressed: widget.onOpenSettings,
            ),
        ],
      ),
    );
  }

  Widget _buildLineRow(ExpectimaxLine line) {
    final expectedEval = _formatEval(line.expectedEvalCp);
    final rawEval = line.evalCp != null ? _formatEval(line.evalCp!) : null;
    final tooltipParts = <String>[
      'Expected eval accounting for opponent mistake probabilities',
    ];
    if (rawEval != null) {
      tooltipParts.add('Raw engine eval: $rawEval');
    }

    final annotations = <MoveAnnotation>[];
    for (final info in line.moveInfo) {
      if (!info.isOurMove && info.moveProbability > 0) {
        final pct = (info.moveProbability * 100).round();
        annotations.add(MoveAnnotation(
          suffix: ' $pct%',
          suffixColor: pct >= 50
              ? AppColors.warning
              : Colors.grey[500],
          suffixFontWeight: FontWeight.w600,
        ));
      } else if (info.isOurMove && info.isRepertoireMove) {
        annotations.add(const MoveAnnotation(
          prefixIcon: Icons.star,
          prefixIconColor: AppColors.expectimax,
          iconSize: 9,
        ));
      } else {
        annotations.add(const MoveAnnotation());
      }
    }

    double? coherence;
    if (widget.coherenceResult != null) {
      coherence = _averageCoherenceForFirstMove(
          line.movesSan.isNotEmpty ? line.movesSan.first : null);
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        children: [
          SizedBox(
              width: 20,
              child: Text('${line.rank}',
                  style: const TextStyle(
                      fontWeight: FontWeight.bold, fontSize: 13))),
          Tooltip(
            message: tooltipParts.join('\n'),
            child: SizedBox(
                width: 56,
                child: Text(expectedEval,
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                      fontFamily: 'monospace',
                      color: _evalColor(line.expectedEvalCp),
                    ))),
          ),
          if (coherence != null)
            Tooltip(
              message: 'Coherence: lines through this move share '
                  '${(coherence * 100).round()}% structural patterns',
              child: Container(
                width: 40,
                padding:
                    const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                child: Text(
                  'C:${(coherence * 100).round()}',
                  style: TextStyle(
                    fontSize: 10,
                    color: _coherenceColor(coherence),
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ),
          const SizedBox(width: 6),
          Expanded(
            child: ClickableMoveLineWidget(
              sanMoves: line.movesSan,
              startPly: _startPly,
              maxMoves: 10,
              annotations: annotations,
              onMoveTapped: (idx) => _onLineMoveTapped(line, idx),
              onMoveHovered: (idx, pos) => _onMoveHovered(line, idx, pos),
              onHoverExit: () => widget.boardPreview.clearPreview(),
            ),
          ),
        ],
      ),
    );
  }

  double? _averageCoherenceForFirstMove(String? firstMoveSan) {
    if (firstMoveSan == null || widget.coherenceResult == null) return null;
    final scores = widget.coherenceResult!.lineCoherenceById;
    if (scores.isEmpty) return null;
    final values = scores.values.toList();
    return values.reduce((a, b) => a + b) / values.length;
  }

  static Color _coherenceColor(double c) {
    return AppColors.coherence(c);
  }

  Widget _buildControls() {
    return Padding(
      padding: const EdgeInsets.all(8),
      child: Row(
        children: [
          const Spacer(),
          DropdownButton<int>(
            value: _settings.expectimaxOurMultipv,
            items: [1, 2, 3, 4, 5]
                .map((v) =>
                    DropdownMenuItem(value: v, child: Text('Top $v')))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                _settings.expectimaxOurMultipv = v;
                _recompute();
              }
            },
            isDense: true,
            underline: const SizedBox.shrink(),
          ),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: _maxPlies,
            items: [4, 8, 12, 16, 20]
                .map((v) =>
                    DropdownMenuItem(value: v, child: Text('+$v')))
                .toList(),
            onChanged: (v) {
              if (v != null) {
                setState(() {
                  _maxPlies = v;
                  _recompute();
                });
              }
            },
            isDense: true,
            underline: const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }

  void _onLineMoveTapped(ExpectimaxLine line, int index) {
    widget.onLineMoveClicked?.call(line.movesSan, index);
  }

  void _onMoveHovered(ExpectimaxLine line, int index, Offset anchorGlobal) {
    final fen = fenAfterMoves(widget.fen, line.movesSan, index);
    final uci =
        index < line.movesUci.length ? line.movesUci[index] : null;
    widget.boardPreview.setPreview(
      fen,
      moves: line.movesSan.sublist(0, index + 1),
      target: BoardPreviewTarget.floating,
      lastMoveUci: uci,
      anchorGlobal: anchorGlobal,
      ownerTag: _previewStackKey,
    );
  }

  static String _formatEval(int cp) {
    if (isMateEval(cp)) return cp > 0 ? '#' : '-#';
    final sign = cp >= 0 ? '+' : '';
    return '$sign${(cp / 100).toStringAsFixed(2)}';
  }

  static Color _evalColor(int cp) {
    return AppColors.cpEval(cp);
  }
}
