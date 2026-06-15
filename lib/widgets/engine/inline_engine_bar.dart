/// Compact inline engine bar for PGN views.
///
/// Shows a toggle switch, live Stockfish MultiPV lines, and a settings gear.
/// Designed to sit above a [PgnViewerWidget] in any screen that displays a
/// game PGN without its own engine integration.
///
/// Spawns its own dedicated [EvalWorker] with configurable threads (via
/// [EngineSettings.inlineThreads]) so it doesn't compete with the pool
/// workers used by the repertoire pane.
library;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../models/engine_settings.dart';
import '../../models/analysis/discovery_result.dart';
import '../../services/analysis_service.dart';
import '../../services/eval_cache.dart';
import '../../services/engine/eval_worker.dart';
import '../../services/engine/stockfish_connection_factory.dart';
import '../../services/engine/stockfish_pool.dart' show kPoolHashPerWorkerMb;
import '../../theme/app_colors.dart';
import '../../utils/chess_utils.dart'
    show formatEvalDisplay, formatNodes, uciPvToSan;
import '../../utils/fen_utils.dart';
import '../clickable_move_line.dart';
import '../analysis/analysis_settings_sheet.dart';

class InlineEngineBar extends StatefulWidget {
  final String fen;
  final bool isActive;

  /// Called when the user clicks a move in an engine line.
  /// Provides the full PV as SAN moves and the 0-based index of the clicked move.
  final void Function(List<String> sanMoves, int clickedIndex)?
      onLineMoveTapped;

  /// Which move index (0-based) in the engine line is currently active/highlighted.
  final int? activeLineMoveIndex;

  const InlineEngineBar({
    super.key,
    required this.fen,
    this.isActive = true,
    this.onLineMoveTapped,
    this.activeLineMoveIndex,
  });

  /// Whether the engine is currently enabled (static, shared across instances).
  static bool get isEngineEnabled => _InlineEngineBarState._engineEnabled;

  /// Toggle engine on/off from outside (e.g. keyboard shortcut).
  static void toggleEngine() => _InlineEngineBarState.toggleEngineExternal();

  @override
  State<InlineEngineBar> createState() => _InlineEngineBarState();
}

class _InlineEngineBarState extends State<InlineEngineBar> {
  final EngineSettings _settings = EngineSettings();

  static bool _engineEnabled = false;

  static final _externalToggleNotifier = <VoidCallback>[];

  /// Toggle engine on/off from outside (e.g. keyboard shortcut).
  /// Any mounted InlineEngineBar will pick up the change on next build.
  static void toggleEngineExternal() {
    _engineEnabled = !_engineEnabled;
    for (final cb in _externalToggleNotifier) {
      cb();
    }
  }

  int _generation = 0;
  DiscoveryResult _discovery = const DiscoveryResult();
  bool _isSearching = false;
  String? _lastAnalyzedFen;

  EvalWorker? _worker;
  int _workerThreads = 0;

  @override
  void initState() {
    super.initState();
    // Manual listener: thread-count changes dispose worker and re-run discovery.
    _settings.addListener(_onSettingsChanged);
    _externalToggleNotifier.add(_onExternalToggle);
    if (_engineEnabled && widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runDiscovery());
    }
  }

  void _onExternalToggle() {
    if (!mounted) return;
    _toggleEngine(_engineEnabled);
  }

  @override
  void didUpdateWidget(InlineEngineBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_engineEnabled || !widget.isActive) return;

    if (widget.fen != oldWidget.fen ||
        (!oldWidget.isActive && widget.isActive)) {
      _runDiscovery();
    }
  }

  @override
  void dispose() {
    _generation++;
    _externalToggleNotifier.remove(_onExternalToggle);
    _settings.removeListener(_onSettingsChanged);
    _disposeWorker();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (_settings.inlineThreads != _workerThreads) {
      _disposeWorker();
    }
    _lastAnalyzedFen = null;
    if (_engineEnabled && widget.isActive) {
      _runDiscovery();
    }
  }

  void _toggleEngine(bool value) {
    setState(() {
      _engineEnabled = value;
      if (!value) {
        _generation++;
        _discovery = const DiscoveryResult();
        _isSearching = false;
        _lastAnalyzedFen = null;
        _disposeWorker();
      }
    });
    if (_engineEnabled && widget.isActive) {
      _runDiscovery();
    }
  }

  Future<EvalWorker?> _ensureWorker() async {
    final wantThreads = _settings.inlineThreads;
    if (_worker != null && _workerThreads == wantThreads) return _worker;

    _disposeWorker();
    if (!StockfishConnectionFactory.isAvailable) return null;

    try {
      final engine = await StockfishConnectionFactory.create();
      if (engine == null) return null;
      final w = EvalWorker(engine);
      await w.init(hashMb: kPoolHashPerWorkerMb, threads: wantThreads);
      _worker = w;
      _workerThreads = wantThreads;
      return w;
    } catch (e) {
      if (kDebugMode) debugPrint('[InlineEngine] Worker spawn failed: $e');
      return null;
    }
  }

  void _disposeWorker() {
    _worker?.dispose();
    _worker = null;
    _workerThreads = 0;
  }

  Future<void> _runDiscovery() async {
    if (!mounted || !_engineEnabled) return;
    if (widget.fen == _lastAnalyzedFen && _discovery.lines.isNotEmpty) return;

    final myGen = ++_generation;
    final fen = widget.fen;
    _lastAnalyzedFen = fen;

    setState(() => _isSearching = true);
    AnalysisService().beginEnginePaneAnalysis(fen);

    final whiteToMove = isWhiteToMove(fen);

    try {
      final worker = await _ensureWorker();
      if (!mounted || _generation != myGen) {
        AnalysisService().endEnginePaneAnalysis(fen);
        return;
      }
      if (worker == null) {
        AnalysisService().endEnginePaneAnalysis(fen);
        setState(() => _isSearching = false);
        return;
      }

      final result = await worker.runDiscovery(
        fen,
        _settings.depth,
        _settings.multiPv,
        whiteToMove,
        onProgress: (intermediate) {
          if (!mounted || _generation != myGen) return;
          setState(() => _discovery = intermediate);
        },
      );

      if (!mounted || _generation != myGen) {
        AnalysisService().endEnginePaneAnalysis(fen);
        return;
      }
      AnalysisService().endEnginePaneAnalysis(fen);
      setState(() {
        _discovery = result;
        _isSearching = false;
      });
      _persistBestEvalToCache(fen, result);
    } catch (e) {
      AnalysisService().endEnginePaneAnalysis(fen);
      if (!mounted || _generation != myGen) return;
      if (kDebugMode) debugPrint('[InlineEngine] Discovery failed: $e');
      setState(() => _isSearching = false);
    }
  }

  void _persistBestEvalToCache(String fen, DiscoveryResult result) {
    if (result.lines.isEmpty) return;
    final best = result.lines.first;
    final cp = best.scoreCp;
    if (cp == null) return;
    EvalCache.instance.putEvalCpWhite(fen, cp, best.depth);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildToggleBar(context),
        if (_engineEnabled) ...[
          const Divider(height: 1),
          _buildLines(context),
        ],
      ],
    );
  }

  Widget _buildToggleBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          SizedBox(
            height: 24,
            child: FittedBox(
              child: Switch(
                value: _engineEnabled,
                onChanged: _toggleEngine,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _engineEnabled
                ? Text(
                    _isSearching
                        ? 'Depth ${_discovery.depth} • '
                            '${formatNodes(_discovery.nodes)} nodes'
                        : '${_discovery.lines.length} lines • '
                            'depth ${_discovery.depth}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[400]),
                    overflow: TextOverflow.ellipsis,
                  )
                : Tooltip(
                    message: 'Toggle engine (E)',
                    child: Text(
                      'Engine',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                    ),
                  ),
          ),
          if (_engineEnabled)
            IconButton(
              icon: const Icon(Icons.settings, size: 18),
              tooltip: 'Engine Settings',
              onPressed: () => showAnalysisSettingsSheet(
                context,
                mode: AnalysisSettingsContext.engineOnly,
              ),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            ),
        ],
      ),
    );
  }

  Widget _buildLines(BuildContext context) {
    final lines = _discovery.lines;

    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            const SizedBox(width: 8),
            Text(
              'Analyzing...',
              style: TextStyle(color: Colors.grey[500], fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: lines.map((line) => _buildLineRow(context, line)).toList(),
    );
  }

  List<String> _pvToSanList(String fen, List<String> pv) =>
      uciPvToSan(fen, pv, maxMoves: pv.length);

  Widget _buildLineRow(BuildContext context, DiscoveryLine line) {
    final sanMoves = _pvToSanList(widget.fen, line.pv);
    final san = sanMoves.isNotEmpty ? sanMoves.first : '?';
    final isFirstActive = widget.activeLineMoveIndex == 0 && line.pvNumber == 1;

    final evalStr =
        formatEvalDisplay(scoreCp: line.scoreCp, scoreMate: line.scoreMate);

    final evalColor = AppColors.cpEval(line.effectiveCp);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: widget.onLineMoveTapped != null
                ? MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: () => widget.onLineMoveTapped!(sanMoves, 0),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: isFirstActive
                            ? BoxDecoration(
                                color: AppColors.pgnMainLine,
                                borderRadius: BorderRadius.circular(3),
                              )
                            : null,
                        child: Text(
                          san,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontFamily: 'monospace',
                            fontSize: 14,
                            color: isFirstActive ? Colors.white : null,
                          ),
                        ),
                      ),
                    ),
                  )
                : Text(
                    san,
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                      fontSize: 14,
                    ),
                  ),
          ),
          Container(
            width: 52,
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: evalColor.withAlpha(25),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              evalStr,
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: evalColor,
                fontFamily: 'monospace',
              ),
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _buildClickableContinuation(sanMoves, line.pvNumber == 1),
          ),
        ],
      ),
    );
  }

  Widget _buildClickableContinuation(List<String> sanMoves, bool isPv1) {
    if (sanMoves.length <= 1) return const SizedBox.shrink();

    final fenParts = widget.fen.split(' ');
    final whiteToMove = isWhiteToMove(widget.fen);
    final fullMoveNum =
        fenParts.length >= 6 ? (int.tryParse(fenParts[5]) ?? 1) : 1;
    // Ply of the first move in the PV (index 0)
    final firstMovePly = (fullMoveNum - 1) * 2 + (whiteToMove ? 0 : 1);

    return ClickableMoveLineWidget(
      sanMoves: sanMoves,
      startPly: firstMovePly,
      startIndex: 1,
      maxMoves: 7,
      fontSize: 12,
      activeMoveIndex: isPv1 ? widget.activeLineMoveIndex : null,
      onMoveTapped: widget.onLineMoveTapped != null
          ? (idx) => widget.onLineMoveTapped!(sanMoves, idx)
          : null,
    );
  }
}
