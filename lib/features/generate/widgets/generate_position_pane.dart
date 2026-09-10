import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../core/generation_session_controller.dart';
import '../../../services/eval/chessdb_api_provider.dart';
import '../../../services/eval/db_move_list.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/app_text_styles.dart';
import '../../../utils/chess_utils.dart';
import '../../../utils/system_info.dart';
import '../services/position_moves.dart';
import '../../../widgets/common/number_stepper.dart';

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

  @override
  State<GeneratePositionPane> createState() => _GeneratePositionPaneState();
}

class _GeneratePositionPaneState extends State<GeneratePositionPane>
    with AutomaticKeepAliveClientMixin {
  late final _depth = TextEditingController(
    text: '${widget.generation.lastConfig?.maxPly ?? 6}',
  );
  late final _cores = TextEditingController(
    text: '${widget.generation.lastConfig?.resolvedEngineThreads ?? 1}',
  );
  int _engineMoves = 4;
  int _maiaCoverage = 60;
  final _form = GlobalKey<FormState>();
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
  void didUpdateWidget(covariant GeneratePositionPane old) {
    super.didUpdateWidget(old);
    if (old.fen != widget.fen) {
      _lookupVersion++;
      _dbMoves = DbMoveList.empty;
      _error = null;
      _loading = false;
      if (_showChessDb) unawaited(_lookup());
    }
  }

  @override
  void dispose() {
    _depth.dispose();
    _cores.dispose();
    super.dispose();
  }

  Future<void> _lookup() async {
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
    } catch (e) {
      if (!mounted || version != _lookupVersion) return;
      setState(() {
        _loading = false;
        _error = 'ChessDB lookup failed. Try again.';
      });
    }
  }

  Future<void> _generate([String? san]) async {
    if (_starting ||
        widget.generation.isGenerating ||
        !_form.currentState!.validate()) {
      return;
    }
    setState(() {
      _starting = true;
      _showChessDb = false;
      _error = null;
    });
    try {
      final error = await widget.onGenerate(
        moveSan: san,
        plies: int.parse(_depth.text),
        cores: int.parse(_cores.text),
        engineMoves: _engineMoves,
        maiaCoverage: _maiaCoverage / 100,
      );
      if (mounted) setState(() => _error = error);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not start generation: $e');
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  Widget _number(
    String label,
    TextEditingController controller,
    int max,
    String tooltip,
    bool busy,
  ) => SizedBox(
    width: 76,
    child: Tooltip(
      message: tooltip,
      child: TextFormField(
        controller: controller,
        enabled: !busy,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly],
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        validator: (text) {
          final value = int.tryParse(text ?? '');
          return value == null || value < 1 || value > max ? '1–$max' : null;
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListenableBuilder(
      listenable: widget.generation,
      builder: (context, _) {
        final gen = widget.generation;
        final busy = gen.isGenerating || _starting;
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
              padding: const EdgeInsets.all(12),
              child: Form(
                key: _form,
                child: Wrap(
                  spacing: 8,
                  runSpacing: 10,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _number(
                      'Depth',
                      _depth,
                      60,
                      'Half-moves to explore from the board position.',
                      busy,
                    ),
                    _number(
                      'Cores',
                      _cores,
                      getLogicalCores(),
                      'CPU cores used for generation.',
                      busy,
                    ),
                    FilledButton(
                      onPressed: busy || rows.isEmpty
                          ? null
                          : () => _generate(),
                      child: const Text('Generate'),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Engine moves', style: AppTextStyles.caption),
                      NumberStepper(
                        key: const ValueKey('generate-engine-moves'),
                        value: _engineMoves,
                        min: 1,
                        max: 20,
                        fieldWidth: 32,
                        enabled: !busy,
                        onChanged: (v) {
                          if (mounted) setState(() => _engineMoves = v);
                        },
                      ),
                    ],
                  ),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Maia coverage', style: AppTextStyles.caption),
                      NumberStepper(
                        key: const ValueKey('generate-maia-coverage'),
                        value: _maiaCoverage,
                        min: 1,
                        max: 100,
                        step: 5,
                        suffix: '%',
                        fieldWidth: 32,
                        enabled: !busy,
                        onChanged: (v) {
                          if (mounted) setState(() => _maiaCoverage = v);
                        },
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (gen.isGenerating) ...[
              const LinearProgressIndicator(),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${gen.progress.depthExplored.fold<int>(0, (a, b) => a + b)} positions completed · depth ${gen.progress.depth}/${gen.progress.maxPlyConfig}\n${gen.progress.status}',
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: AppTextStyles.caption,
                      ),
                    ),
                    TextButton(
                      onPressed: gen.isCancelling ? null : gen.cancelBuild,
                      child: Text(gen.isCancelling ? 'Stopping…' : 'Stop'),
                    ),
                  ],
                ),
              ),
            ] else if (gen.lastRunSummary.isNotEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(
                  gen.lastRunSummary,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.caption,
                ),
              ),
            if (_error != null || gen.lastError != null)
              Padding(
                padding: const EdgeInsets.all(8),
                child: Text(
                  _error ?? gen.lastError!,
                  style: const TextStyle(color: AppColors.danger),
                ),
              ),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
              child: Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  ChoiceChip(
                    label: const Text('Local analysis'),
                    selected: !_showChessDb,
                    onSelected: (_) => setState(() => _showChessDb = false),
                  ),
                  ChoiceChip(
                    label: const Text('ChessDB'),
                    selected: _showChessDb,
                    onSelected: (_) {
                      setState(() => _showChessDb = true);
                      unawaited(_lookup());
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              child: Text(
                _showChessDb
                    ? 'Source: chessdb.cn · scores for White'
                    : 'Top $_engineMoves engine + $_maiaCoverage% Maia moves · scores for White',
                style: AppTextStyles.caption,
              ),
            ),
            if (_showChessDb && _loading) const LinearProgressIndicator(),
            if (_showChessDb && !_loading && _dbMoves.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextButton(
                  onPressed: _lookup,
                  child: const Text('No ChessDB scores returned · Retry'),
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
                  SizedBox(
                    width: 65,
                    child: Text(
                      _showChessDb ? 'Rank' : 'Engine',
                      style: AppTextStyles.caption,
                    ),
                  ),
                  SizedBox(
                    width: 65,
                    child: Text(
                      _showChessDb ? 'Score' : 'Expected',
                      style: AppTextStyles.caption,
                    ),
                  ),
                  const SizedBox(width: 36),
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
                        final stmWhite = widget.fen.split(' ')[1] == 'w';
                        final dbScore = row.chessDb?.stmCp;
                        final score = _showChessDb
                            ? dbScore == null
                                  ? null
                                  : dbScore * (stmWhite ? 1 : -1)
                            : row.expectedCp;
                        return MouseRegion(
                          onEnter: (_) => widget.onHoverMove?.call(row.uci),
                          onExit: (_) => widget.onHoverMove?.call(null),
                          child: InkWell(
                            onTap: () => widget.onPlayMove(row.san),
                            child: Container(
                              color: index.isEven
                                  ? AppColors.onSurfaceMuted.withValues(
                                      alpha: 0.04,
                                    )
                                  : null,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 2,
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
                                    width: 65,
                                    child: Tooltip(
                                      message: row.pvSan.isEmpty
                                          ? 'Engine evaluation'
                                          : row.pvSan.join(' '),
                                      child: Text(
                                        _showChessDb
                                            ? '${row.chessDb?.rank ?? '—'}'
                                            : row.evalCp == null
                                            ? '—'
                                            : formatPackedEval(
                                                row.evalCp!,
                                                decimals: 2,
                                              ),
                                        style: AppTextStyles.caption,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 65,
                                    child: Tooltip(
                                      message: _showChessDb
                                          ? row.chessDb?.note ?? 'ChessDB score'
                                          : score == null
                                          ? 'Generate from this position to calculate an expected score.'
                                          : 'Expected score from opponent move probabilities',
                                      child: Text(
                                        score == null
                                            ? '—'
                                            : formatPackedEval(
                                                score,
                                                decimals: 2,
                                              ),
                                        style: AppTextStyles.caption,
                                      ),
                                    ),
                                  ),
                                  SizedBox(
                                    width: 36,
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
            const Divider(height: 1),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Wrap(
                spacing: 8,
                children: [
                  if (widget.onBuildChessDb != null)
                    TextButton.icon(
                      key: const ValueKey('build-chessdb-repertoire'),
                      onPressed: busy ? null : widget.onBuildChessDb,
                      icon: const Icon(Icons.menu_book_outlined, size: 16),
                      label: const Text('Build ChessDB repertoire…'),
                    ),
                  TextButton(
                    onPressed: widget.onPlanLines,
                    child: const Text('Plan starting lines…'),
                  ),
                  if (widget.onCutLines != null)
                    TextButton(
                      onPressed: busy ? null : widget.onCutLines,
                      child: const Text('Cut lines…'),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
