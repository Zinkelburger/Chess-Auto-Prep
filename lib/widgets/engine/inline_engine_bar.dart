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
import '../../services/engine/eval_worker.dart';
import '../../services/engine/stockfish_connection_factory.dart';
import '../../services/engine/stockfish_pool.dart' show kPoolHashPerWorkerMb;
import '../../utils/chess_utils.dart';
import 'engine_settings_dialog.dart';

class InlineEngineBar extends StatefulWidget {
  final String fen;
  final bool isActive;

  const InlineEngineBar({
    super.key,
    required this.fen,
    this.isActive = true,
  });

  @override
  State<InlineEngineBar> createState() => _InlineEngineBarState();
}

class _InlineEngineBarState extends State<InlineEngineBar> {
  final EngineSettings _settings = EngineSettings();

  static bool _engineEnabled = false;

  int _generation = 0;
  DiscoveryResult _discovery = const DiscoveryResult();
  bool _isSearching = false;
  String? _lastAnalyzedFen;

  EvalWorker? _worker;
  int _workerThreads = 0;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    if (_engineEnabled && widget.isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runDiscovery());
    }
  }

  @override
  void didUpdateWidget(InlineEngineBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_engineEnabled || !widget.isActive) return;

    if (widget.fen != oldWidget.fen || (!oldWidget.isActive && widget.isActive)) {
      _runDiscovery();
    }
  }

  @override
  void dispose() {
    _generation++;
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
    _lastAnalyzedFen = widget.fen;

    setState(() => _isSearching = true);

    final fenParts = widget.fen.split(' ');
    final isWhiteToMove = fenParts.length >= 2 && fenParts[1] == 'w';

    try {
      final worker = await _ensureWorker();
      if (!mounted || _generation != myGen) return;
      if (worker == null) {
        setState(() => _isSearching = false);
        return;
      }

      final result = await worker.runDiscovery(
        widget.fen,
        _settings.depth,
        _settings.multiPv,
        isWhiteToMove,
        onProgress: (intermediate) {
          if (!mounted || _generation != myGen) return;
          setState(() => _discovery = intermediate);
        },
      );

      if (!mounted || _generation != myGen) return;
      setState(() {
        _discovery = result;
        _isSearching = false;
      });
    } catch (e) {
      if (!mounted || _generation != myGen) return;
      if (kDebugMode) debugPrint('[InlineEngine] Discovery failed: $e');
      setState(() => _isSearching = false);
    }
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
                : Text(
                    'Engine',
                    style: TextStyle(fontSize: 12, color: Colors.grey[500]),
                  ),
          ),
          if (_engineEnabled)
            IconButton(
              icon: const Icon(Icons.settings, size: 18),
              tooltip: 'Engine Settings',
              onPressed: () => showEngineSettingsDialog(
                context: context,
                settings: _settings,
                compact: true,
                currentProbabilityStartMoves: _settings.probabilityStartMoves,
                onProbabilityStartMovesChanged: (_) {},
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

  Widget _buildLineRow(BuildContext context, DiscoveryLine line) {
    final san = line.pv.isNotEmpty ? uciToSan(widget.fen, line.pv.first) : '?';
    final continuation = formatContinuation(widget.fen, line.pv);

    final String evalStr;
    if (line.scoreMate != null) {
      evalStr = 'M${line.scoreMate}';
    } else if (line.scoreCp != null) {
      final e = line.scoreCp! / 100.0;
      evalStr = e >= 0 ? '+${e.toStringAsFixed(1)}' : e.toStringAsFixed(1);
    } else {
      evalStr = '--';
    }

    final evalColor = line.scoreMate != null || (line.scoreCp ?? 0) > 50
        ? Colors.green
        : (line.scoreCp ?? 0) < -50
            ? Colors.red
            : Colors.grey;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 48,
            child: Text(
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
            child: Text(
              continuation,
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey[500],
                fontFamily: 'monospace',
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}
