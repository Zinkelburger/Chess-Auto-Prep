import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/generation_session_controller.dart';
import '../../../services/eval/chessdb_api_provider.dart';
import '../../../services/eval/db_move_list.dart';
import '../../../services/jobs/generation_job_display.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/chess_utils.dart';
import '../services/position_moves.dart';
import 'position_generation_settings.dart';

/// Board-side generation. Starting a run only adds analysis to the database.
class GeneratePositionPane extends StatefulWidget {
  const GeneratePositionPane({
    super.key,
    required this.fen,
    required this.databaseName,
    required this.generation,
    required this.onGenerate,
    required this.onPlayMove,
    required this.onPlanLines,
    this.onHoverMove,
    this.lookupChessDb,
    this.onCutLines,
    this.onBuildChessDb,
    this.sourceControl,
    this.chessDbSource,
    this.onShowGenerated,
  });
  final String fen;
  final String databaseName;
  final GenerationSessionController generation;
  final Future<String?> Function({
    String? moveSan,
    required int plies,
    required int cores,
    required int engineMoves,
    required double maiaCoverage,
  })
  onGenerate;
  final ValueChanged<String> onPlayMove;
  final ValueChanged<String?>? onHoverMove;
  final VoidCallback onPlanLines;
  final VoidCallback? onCutLines;
  final VoidCallback? onBuildChessDb;
  final Future<DbMoveList> Function(String fen)? lookupChessDb;

  /// The enclosing database pane can share this toolbar's source selector.
  final Widget? sourceControl;
  final bool? chessDbSource;
  final VoidCallback? onShowGenerated;

  @override
  State<GeneratePositionPane> createState() => _GeneratePositionPaneState();
}

class _GeneratePositionPaneState extends State<GeneratePositionPane>
    with AutomaticKeepAliveClientMixin {
  final _chessDb = ChessDbApiProvider();
  bool _showChessDb = false;
  bool _loading = false;
  bool _starting = false;
  int _lookupVersion = 0;
  DbMoveList _dbMoves = DbMoveList.empty;
  String? _error;
  final Map<String, DbMoveList> _cache = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _showChessDb = widget.chessDbSource ?? false;
    if (_showChessDb) unawaited(_lookup());
  }

  @override
  void didUpdateWidget(covariant GeneratePositionPane old) {
    super.didUpdateWidget(old);
    if (old.fen != widget.fen || old.chessDbSource != widget.chessDbSource) {
      _showChessDb = widget.chessDbSource ?? _showChessDb;
      _lookupVersion++;
      _dbMoves = DbMoveList.empty;
      _error = null;
      _loading = false;
      if (_showChessDb) unawaited(_lookup());
    }
  }

  Future<void> _lookup() async {
    if (!mounted) return;
    final version = ++_lookupVersion;
    final fen = widget.fen;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result =
          _cache[fen] ??
          await (widget.lookupChessDb ?? _chessDb.lookupMoves)(fen);
      if (!mounted || version != _lookupVersion) return;
      if (result.isNotEmpty) {
        if (_cache.length >= 128) _cache.clear();
        _cache[fen] = result;
      }
      setState(() {
        _dbMoves = result;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || version != _lookupVersion) return;
      setState(() {
        _loading = false;
        _error = 'ChessDB lookup failed. Try again.';
      });
    }
  }

  void _selectSource(bool chessDb) {
    if (!mounted) return;
    setState(() {
      _showChessDb = chessDb;
      _error = null;
      _loading = false;
      _lookupVersion++;
    });
    if (chessDb) unawaited(_lookup());
  }

  Future<void> _generate([String? san]) async {
    if (!mounted || _starting || widget.generation.isGenerating) return;
    final fen = widget.fen;
    setState(() {
      _starting = true;
      _showChessDb = false;
      _lookupVersion++;
      _loading = false;
      _error = null;
    });
    try {
      widget.onShowGenerated?.call();
      if (!mounted) return;
      final settings = await PositionGenerationSettings.load(widget.generation);
      if (!mounted || fen != widget.fen) return;
      final error = await widget.onGenerate(
        moveSan: san,
        plies: settings.plies,
        cores: settings.cores,
        engineMoves: settings.engineMoves,
        maiaCoverage: settings.maiaCoverage / 100,
      );
      if (mounted) setState(() => _error = error);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start generation: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  /// The one control for the run: it starts it, then parks and restarts it.
  /// A greyed-out Generate button while a run is in progress said nothing
  /// about the run and left Stop as the only live control.
  Widget _runControl(
    GenerationSessionController gen, {
    required bool canStart,
    required bool extending,
  }) {
    if (!gen.isGenerating) {
      // Not "Resume": a run does not continue where an earlier one stopped,
      // it scores this position and merges the result into what is saved.
      return Tooltip(
        message: extending
            ? 'Score this position and add it to the saved database'
            : 'Score this position and start a database beside the chapter',
        child: TextButton.icon(
          key: const ValueKey('generation-run-control'),
          onPressed: canStart ? () => _generate() : null,
          icon: const Icon(Icons.play_arrow, size: 16),
          label: Text(
            _starting
                ? 'Starting…'
                : extending
                ? 'Extend'
                : 'Generate',
          ),
        ),
      );
    }
    if (gen.isPaused) {
      return TextButton.icon(
        key: const ValueKey('generation-run-control'),
        onPressed: gen.isCancelling
            ? null
            : () {
                if (mounted) gen.resumeBuild();
              },
        icon: const Icon(Icons.play_arrow, size: 16),
        label: const Text('Resume'),
      );
    }
    // The remaining phases are short synchronous passes that would ignore a
    // pause request, so the control says so rather than doing nothing.
    final pausable = gen.canPause;
    return Tooltip(
      message: pausable
          ? 'Park the run and hand the engine back'
          : 'This step finishes too quickly to pause',
      child: TextButton.icon(
        key: const ValueKey('generation-run-control'),
        onPressed: pausable
            ? () {
                if (mounted) gen.pauseBuild();
              }
            : null,
        icon: const Icon(Icons.pause, size: 16),
        label: const Text('Pause'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: widget.generation,
      builder: (context, _) {
        final gen = widget.generation;
        final busy = gen.isGenerating || _starting;
        // What a previous run left beside the chapter. A run adds to it; it
        // never starts the database over.
        final savedPositions = gen.generatedTreeFenMap?.size ?? 0;
        final stmWhite = widget.fen.split(' ').elementAtOrNull(1) == 'w';
        final rows = positionMoves(
          widget.fen,
          database: gen.generatedTreeFenMap,
          liveNodeAt: gen.liveNodeAt,
          playAsWhite: gen.generatedTreeConfig?.playAsWhite ?? true,
          chessDb: _dbMoves,
          sortByChessDb: _showChessDb,
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child:
                        widget.sourceControl ??
                        PopupMenuButton<bool>(
                          key: const ValueKey('evaluation-source'),
                          tooltip: 'Evaluation source',
                          initialValue: _showChessDb,
                          onSelected: _selectSource,
                          itemBuilder: (_) => const [
                            PopupMenuItem(
                              value: false,
                              child: Text('Generated evals'),
                            ),
                            PopupMenuItem(value: true, child: Text('ChessDB')),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 10),
                            child: Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    _showChessDb
                                        ? 'ChessDB'
                                        : 'Generated evals',
                                    overflow: TextOverflow.ellipsis,
                                    style: AppTextStyles.muted,
                                  ),
                                ),
                                const Icon(Icons.arrow_drop_down, size: 18),
                              ],
                            ),
                          ),
                        ),
                  ),
                  _runControl(
                    gen,
                    canStart: !busy && rows.isNotEmpty,
                    extending: savedPositions > 0,
                  ),
                  IconButton(
                    key: const ValueKey('generation-settings'),
                    tooltip: 'Generation settings',
                    visualDensity: VisualDensity.compact,
                    onPressed: () {
                      if (!mounted) return;
                      unawaited(showPositionGenerationSettings(context, gen));
                    },
                    icon: const Icon(Icons.settings_outlined, size: 18),
                  ),
                  PopupMenuButton<String>(
                    key: const ValueKey('generation-actions'),
                    tooltip: 'More evaluation actions',
                    icon: const Icon(Icons.more_horiz, size: 18),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 220),
                    onSelected: (action) {
                      if (!mounted) return;
                      switch (action) {
                        case 'chessdb':
                          widget.onBuildChessDb?.call();
                        case 'plan':
                          widget.onPlanLines();
                        case 'cut':
                          widget.onCutLines?.call();
                        case 'refresh':
                          unawaited(_lookup());
                      }
                    },
                    itemBuilder: (_) => [
                      if (_showChessDb)
                        const PopupMenuItem(
                          value: 'refresh',
                          child: Text('Refresh ChessDB'),
                        ),
                      if (widget.onBuildChessDb != null)
                        PopupMenuItem(
                          key: const ValueKey('build-chessdb-repertoire'),
                          value: 'chessdb',
                          enabled: !busy,
                          child: const Text('Build ChessDB repertoire…'),
                        ),
                      const PopupMenuItem(
                        value: 'plan',
                        child: Text('Plan starting lines…'),
                      ),
                      if (widget.onCutLines != null)
                        PopupMenuItem(
                          value: 'cut',
                          enabled: !busy,
                          child: const Text('Cut lines…'),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            if (!gen.isGenerating && savedPositions > 0)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Text(
                  'Database on disk · $savedPositions position'
                  '${savedPositions == 1 ? '' : 's'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption,
                ),
              ),
            if (gen.isGenerating) ...[
              LinearProgressIndicator(
                minHeight: 2,
                // A bar still sweeping under a parked run would claim work
                // that is not happening.
                value: gen.isPaused ? gen.progress.jobProgress.fraction : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Tooltip(
                        message: gen.progress.status,
                        child: Text(
                          '${gen.isPaused ? 'Paused' : gen.progress.phase.label}'
                          ' · ${gen.progress.jobProgress.message}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: AppTextStyles.caption,
                        ),
                      ),
                    ),
                    TextButton(
                      onPressed: gen.isCancelling
                          ? null
                          : () {
                              if (mounted) gen.cancelBuild();
                            },
                      child: Text(gen.isCancelling ? 'Stopping…' : 'Stop'),
                    ),
                  ],
                ),
              ),
            ],
            if (_error != null || gen.lastError != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _error ?? gen.lastError!,
                  style: AppTextStyles.caption.copyWith(
                    color: AppColors.danger,
                  ),
                ),
              ),
            if (_showChessDb && _loading)
              const LinearProgressIndicator(minHeight: 2),
            if (_showChessDb && !_loading && _dbMoves.isEmpty)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: _lookup,
                  child: const Text('No ChessDB scores · Retry'),
                ),
              ),
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Move', style: AppTextStyles.caption),
                  ),
                  const SizedBox(
                    width: 84,
                    child: Tooltip(
                      message: 'Engine evaluation, from White’s perspective',
                      child: Text('Evaluation', style: AppTextStyles.caption),
                    ),
                  ),
                  SizedBox(
                    width: 84,
                    child: _showChessDb
                        ? const Text('Annotation', style: AppTextStyles.caption)
                        : const Tooltip(
                            message:
                                'Expectimax: the score expected once the '
                                'opponent’s likely replies are weighed in, '
                                'from White’s perspective',
                            child: Text(
                              'Expected',
                              style: AppTextStyles.caption,
                            ),
                          ),
                  ),
                  const SizedBox(width: 32),
                ],
              ),
            ),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('No legal moves.'))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, index) {
                        final row = rows[index];
                        final dbScore = row.chessDb?.stmCp;
                        final score = _showChessDb
                            ? dbScore == null
                                  ? null
                                  : dbScore * (stmWhite ? 1 : -1)
                            : row.evalCp;
                        // The engine continuation is no longer a column of
                        // its own; it stays reachable as the row's tooltip.
                        final detail = _showChessDb
                            ? RegExp(r'^[!?]+').stringMatch(
                                    (row.chessDb?.note ?? '').trim(),
                                  ) ??
                                  ''
                            : row.expectedCp == null
                            ? ''
                            : formatPackedEval(row.expectedCp!, decimals: 2);
                        final tooltip = _showChessDb
                            ? row.chessDb?.note ?? ''
                            : row.pvSan.isNotEmpty
                            ? row.pvSan.join(' ')
                            : row.expectedCp == null
                            ? 'Generate from this position to calculate an '
                                  'expected score.'
                            : '';
                        return MouseRegion(
                          onEnter: (_) {
                            if (mounted) widget.onHoverMove?.call(row.uci);
                          },
                          onExit: (_) {
                            if (mounted) widget.onHoverMove?.call(null);
                          },
                          child: InkWell(
                            onTap: () {
                              if (mounted) widget.onPlayMove(row.san);
                            },
                            child: Container(
                              color: index.isEven ? AppColors.rowStripe : null,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 3,
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      row.san,
                                      style: AppTextStyles.bodyStrong,
                                    ),
                                  ),
                                  SizedBox(
                                    width: 84,
                                    child: Text(
                                      score == null
                                          ? '—'
                                          : formatPackedEval(
                                              score,
                                              decimals: 2,
                                            ),
                                      style: AppTextStyles.mono,
                                    ),
                                  ),
                                  SizedBox(
                                    width: 84,
                                    child: _Detail(
                                      text: detail,
                                      tooltip: tooltip,
                                    ),
                                  ),
                                  SizedBox(
                                    width: 32,
                                    child: IconButton(
                                      tooltip:
                                          'Evaluate ${row.san} and save engine PV',
                                      onPressed: busy
                                          ? null
                                          : () => _generate(row.san),
                                      icon: const Icon(
                                        Icons.play_circle_outline,
                                        size: 18,
                                      ),
                                      constraints: const BoxConstraints(
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      padding: EdgeInsets.zero,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }
}

/// The third column's cell: the expected score, or a ChessDB annotation.
/// An empty tooltip would otherwise show as a blank popup on hover.
class _Detail extends StatelessWidget {
  const _Detail({required this.text, required this.tooltip});
  final String text;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final label = Text(
      text.isEmpty ? '—' : text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: AppTextStyles.mono,
    );
    if (tooltip.isEmpty) return label;
    return Tooltip(message: tooltip, child: label);
  }
}
