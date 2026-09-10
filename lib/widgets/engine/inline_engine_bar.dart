/// Compact inline engine bar for PGN views.
///
/// Shows a toggle switch, live Stockfish MultiPV lines, and a settings gear.
/// Designed to sit above a [PgnViewerWidget] in any screen that displays a
/// game PGN without its own engine integration.
///
/// Uses the shared [BoardEngine], keeping its configured threads asleep while
/// analysis is toggled off. Background jobs use their own on-demand pool.
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../models/engine_settings.dart';
import '../../services/analysis_service.dart';
import '../../services/eval_cache.dart';
import '../../services/engine/engine_lifecycle.dart';
import '../../services/engine/board_engine.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_text_styles.dart';
import '../../utils/chess_utils.dart'
    show fenAfterMoves, formatEvalDisplay, formatNodes, uciPvToSanCached;
import '../../utils/fen_utils.dart';
import '../clickable_move_line.dart';
import 'inline_engine_settings.dart';
import '../../services/engine/threat_position.dart';
import '../../utils/app_shortcuts.dart';
import '../shortcut_tooltip.dart';
import 'engine_gate.dart';
import 'floating_board_preview.dart';

class InlineEngineBar extends StatefulWidget {
  final String fen;
  final bool isActive;

  /// Called when the user clicks a move in an engine line.
  /// Provides the full PV as SAN moves and the 0-based index of the clicked move.
  final void Function(List<String> sanMoves, int clickedIndex)?
  onLineMoveTapped;

  /// Orientation of the floating hover-preview board.
  final bool previewFlipped;
  final void Function(String fen, String? uci)? onThreatChanged;

  const InlineEngineBar({
    super.key,
    required this.fen,
    this.isActive = true,
    this.onLineMoveTapped,
    this.previewFlipped = false,
    this.onThreatChanged,
  });

  /// Whether the engine is currently enabled (static, shared across instances).
  static bool get isEngineEnabled => _InlineEngineBarState._engineEnabled;

  /// Toggle engine on/off from outside (e.g. keyboard shortcut).
  static void toggleEngine() => _InlineEngineBarState.toggleEngineExternal();

  @override
  State<InlineEngineBar> createState() => _InlineEngineBarState();
}

class _InlineEngineBarState extends State<InlineEngineBar> {
  final EngineSettings _settings = EngineSettings.instance;

  static bool get _engineEnabled =>
      EngineLifecycle.instance.state != EngineState.off;

  static void toggleEngineExternal() {
    _setEngineEnabled(!_engineEnabled);
  }

  static void _setEngineEnabled(bool value) {
    final lifecycle = EngineLifecycle.instance;
    unawaited(
      (value ? lifecycle.toggleOn() : lifecycle.toggleOff()).catchError(
        (Object error) => debugPrint('[InlineEngine] Toggle failed: $error'),
      ),
    );
  }

  bool _threatMode = false;
  String? _error;
  String get _searchFen =>
      _threatMode ? threatPositionFen(widget.fen) ?? widget.fen : widget.fen;

  void _publishThreat() {
    final generation = _generation;
    final fen = widget.fen;
    final uci =
        !EngineGate.isLocked &&
            _threatMode &&
            _engineEnabled &&
            _isActive &&
            _discovery.lines.isNotEmpty &&
            _discovery.lines.first.pv.isNotEmpty
        ? _discovery.lines.first.pv.first
        : null;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.fen != fen || _generation != generation) return;
      widget.onThreatChanged?.call(fen, uci);
    });
  }

  void _toggleThreat() {
    if (!mounted) return;
    setState(() {
      _threatMode = !_threatMode;
      _discovery = const DiscoveryResult();
      _lastAnalyzedFen = null;
    });
    _boardPreview.clearPreview();
    _publishThreat();
    unawaited(_runDiscovery());
  }

  int _generation = 0;
  DiscoveryResult _discovery = const DiscoveryResult();
  bool _isSearching = false;
  String? _lastAnalyzedFen;

  // Per-info-line progress used to fire a full setState (re-deriving every
  // line's SAN) many times per second; throttle to a leading+trailing cadence.
  Timer? _progressThrottle;
  DiscoveryResult? _pendingProgress;

  // Settings fields that actually affect the inline search — a re-search runs
  // only when one of these changes, not on every unrelated EngineSettings
  // notify (column mutes, Maia toggles, explorer DB, …).
  int _lastDepth = 0;
  int _lastMultiPv = 0;
  int _lastInlineThreads = 0;
  int _lastHashMb = 0;

  final _session = BoardEngine.instance.createSession();
  bool _wasEnabled = _engineEnabled;
  bool _modeActive = true;

  bool get _isActive => widget.isActive && _modeActive;

  bool _gateLocked = EngineGate.isLocked;

  /// Drives the floating mini-board shown when hovering PV moves.
  final BoardPreviewController _boardPreview = BoardPreviewController();
  final GlobalKey _previewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // Reconfigure the idle worker and restart when search settings change.
    _settings.addListener(_onSettingsChanged);
    _lastDepth = _settings.depth;
    _lastMultiPv = _settings.multiPv;
    _lastInlineThreads = _settings.cores;
    _lastHashMb = _settings.hashMb;
    EngineLifecycle.instance.addListener(_onEngineGateChanged);
    if (_engineEnabled && _isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runDiscovery());
    }
  }

  /// Leave the shared board session while generation owns the CPU, then
  /// prepare and resume discovery when the build releases it.
  void _onEngineGateChanged() {
    if (!mounted) return;
    final locked = EngineGate.isLocked;
    final enabled = _engineEnabled;
    final changed = locked != _gateLocked || enabled != _wasEnabled;
    _gateLocked = locked;
    _wasEnabled = enabled;
    if (!changed) return;
    if (locked || !enabled) {
      _generation++;
      _progressThrottle?.cancel();
      _progressThrottle = null;
      _pendingProgress = null;
      _session.pause();
      if (locked) _session.detach();
      _lastAnalyzedFen = null;
      _threatMode = false;
      setState(() {
        _isSearching = false;
        _discovery = const DiscoveryResult();
      });
      _publishThreat();
    } else {
      _prepareEngine();
      if (_isActive) unawaited(_runDiscovery());
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (_modeActive == active) {
      _prepareEngine();
      return;
    }
    _modeActive = active;
    if (!_isActive) {
      _stopDiscovery();
    } else {
      _prepareEngine();
      if (_engineEnabled) unawaited(_runDiscovery());
    }
  }

  @override
  void didUpdateWidget(InlineEngineBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.fen != oldWidget.fen) {
      _threatMode = false;
      _discovery = const DiscoveryResult();
      _boardPreview.clearPreview();
      _publishThreat();
    }
    if (!_isActive) {
      _stopDiscovery();
      return;
    }
    _prepareEngine();
    if (_engineEnabled &&
        (widget.fen != oldWidget.fen || !oldWidget.isActive)) {
      unawaited(_runDiscovery());
    }
  }

  void _stopDiscovery() {
    _generation++;
    _progressThrottle?.cancel();
    _progressThrottle = null;
    _pendingProgress = null;
    _session.detach();
    _lastAnalyzedFen = null;
    _discovery = const DiscoveryResult();
    _isSearching = false;
    _publishThreat();
  }

  @override
  void dispose() {
    _generation++;
    _progressThrottle?.cancel();
    EngineLifecycle.instance.removeListener(_onEngineGateChanged);
    _settings.removeListener(_onSettingsChanged);
    _session.dispose();
    _boardPreview.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    // Only depth / MultiPV / cores / memory changes affect the inline search;
    // EngineSettings fires for ~30 unrelated fields and each one used to abort
    // and restart the in-progress search.
    final relevant =
        _settings.depth != _lastDepth ||
        _settings.multiPv != _lastMultiPv ||
        _settings.cores != _lastInlineThreads ||
        _settings.hashMb != _lastHashMb;
    if (!relevant) return;
    _lastDepth = _settings.depth;
    _lastMultiPv = _settings.multiPv;
    _lastInlineThreads = _settings.cores;
    _lastHashMb = _settings.hashMb;

    _lastAnalyzedFen = null;
    _prepareEngine();
    if (_engineEnabled && _isActive) {
      unawaited(_runDiscovery());
    }
  }

  /// Leading + trailing throttle for streamed search progress: paint the first
  /// update immediately, then coalesce the flood of UCI info lines to ~12fps
  /// so each one doesn't fire a full bar rebuild + per-line SAN derivation.
  /// The definitive result is still applied unthrottled in [_runDiscovery].
  void _onDiscoveryProgress(DiscoveryResult intermediate, int myGen) {
    if (!mounted || _generation != myGen) return;
    _pendingProgress = intermediate;
    if (_progressThrottle != null) return; // trailing edge will flush it
    setState(() => _discovery = _pendingProgress!);
    _publishThreat();
    _pendingProgress = null;
    _progressThrottle = Timer(const Duration(milliseconds: 80), () {
      _progressThrottle = null;
      if (!mounted || _generation != myGen) return;
      final pending = _pendingProgress;
      _pendingProgress = null;
      if (pending != null) {
        setState(() => _discovery = pending);
        _publishThreat();
      }
    });
  }

  void _prepareEngine() {
    if (!_isActive || EngineGate.isLocked) return;
    unawaited(
      _session.prepare().catchError((Object error) {
        if (kDebugMode) debugPrint('[InlineEngine] Preparation failed: $error');
      }),
    );
  }

  Future<void> _runDiscovery() async {
    if (!mounted || !_isActive || !_engineEnabled || EngineGate.isLocked) {
      return;
    }
    if (_searchFen == _lastAnalyzedFen && _discovery.lines.isNotEmpty) return;

    final myGen = ++_generation;
    // Drop any pending throttled progress from the previous search so a stale
    // trailing flush can't paint over the new one.
    _progressThrottle?.cancel();
    _progressThrottle = null;
    _pendingProgress = null;
    final fen = _searchFen;
    _lastAnalyzedFen = fen;

    setState(() {
      _isSearching = true;
      _error = null;
      _discovery = const DiscoveryResult();
    });
    _publishThreat();

    final whiteToMove = isWhiteToMove(fen);

    try {
      final result = await _session.discover(
        fen: fen,
        depth: _settings.depth,
        multiPv: _settings.multiPv,
        whiteToMove: whiteToMove,
        onProgress: (intermediate) => _onDiscoveryProgress(intermediate, myGen),
      );

      if (!mounted || _generation != myGen) {
        return;
      }
      if (result == null) {
        setState(() => _isSearching = false);
        _lastAnalyzedFen = null;
        return;
      }
      setState(() {
        _discovery = result;
        _isSearching = false;
      });
      _publishThreat();
      if (!_threatMode) _persistBestEvalToCache(fen, result);
    } catch (e) {
      if (!mounted || _generation != myGen) return;
      if (kDebugMode) debugPrint('[InlineEngine] Discovery failed: $e');
      setState(() {
        _isSearching = false;
        _lastAnalyzedFen = null;
        _error = 'Engine failed. Toggle it to retry.';
      });
    }
  }

  void _persistBestEvalToCache(String fen, DiscoveryResult result) {
    if (result.lines.isEmpty) return;
    final best = result.lines.first;
    final cp = best.scoreCp;
    if (cp == null) return;
    EvalCache.instance.putEvalCpWhiteSoon(fen, cp, best.depth);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildToggleBar(context),
        if (_engineEnabled) ...[
          const Divider(height: 1),
          // Reserve every configured PV slot even while a new position has
          // no results (or fewer legal moves). Navigation must not move the
          // PGN below us as streamed lines disappear and arrive.
          SizedBox(
            height: (_lineHeight(context) * _settings.multiPv).clamp(
              40.0,
              double.infinity,
            ),
            child: SingleChildScrollView(
              child: EngineGate.isLocked
                  ? const EngineBusyNotice(dense: true)
                  : _buildLines(context),
            ),
          ),
        ],
        // Renders nothing inline; drives the hover mini-board via Overlay.
        FloatingBoardPreview(
          stackKey: _previewKey,
          controller: _boardPreview,
          flipped: widget.previewFlipped,
          ownerTag: _previewKey,
        ),
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
              child: ShortcutTooltip(
                description: 'Toggle engine',
                shortcut: AppShortcut.toggleEngine,
                child: Switch(
                  value: _engineEnabled,
                  onChanged: (value) {
                    if (value && !EngineGate.ensureAvailable(context)) return;
                    _setEngineEnabled(value);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: _engineEnabled
                ? Text(
                    EngineGate.isLocked
                        ? 'Engine busy'
                        : _isSearching
                        ? '${_threatMode ? 'Threat · ' : ''}Depth ${_discovery.depth} • '
                              '${formatNodes(_discovery.nodes)} nodes'
                        : '${_threatMode ? 'Threat · ' : ''}${_discovery.lines.length} lines • '
                              'depth ${_discovery.depth}',
                    style: AppTextStyles.caption,
                    overflow: TextOverflow.ellipsis,
                  )
                : const Tooltip(
                    message: 'Toggle engine',
                    child: Text('Engine', style: AppTextStyles.caption),
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.gps_fixed, size: 18),
            tooltip: _threatMode ? 'Hide threat' : 'Show threat',
            isSelected: _threatMode,
            onPressed:
                _engineEnabled &&
                    !EngineGate.isLocked &&
                    threatPositionFen(widget.fen) != null
                ? _toggleThreat
                : null,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const InlineEngineSettings(),
        ],
      ),
    );
  }

  Widget _buildLines(BuildContext context) {
    final lines = _discovery.lines;

    if (lines.isEmpty && !_isSearching) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Text(_error ?? 'No legal moves.', style: AppTextStyles.caption),
      );
    }
    if (lines.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 1.5),
            ),
            SizedBox(width: 8),
            Text(
              'Analyzing...',
              style: TextStyle(color: AppColors.onSurfaceMuted, fontSize: 13),
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
      uciPvToSanCached(fen, pv);

  /// Show the floating board after [sanMoves] up to and including [idx].
  void _showPreview(
    DiscoveryLine line,
    List<String> sanMoves,
    int idx,
    Offset anchor,
  ) {
    if (sanMoves.isEmpty) return;
    _boardPreview.setPreview(
      fenAfterMoves(_searchFen, sanMoves, idx),
      moves: sanMoves.sublist(0, idx + 1),
      target: BoardPreviewTarget.floating,
      lastMoveUci: idx < line.pv.length ? line.pv[idx] : null,
      anchorGlobal: anchor,
      ownerTag: _previewKey,
    );
  }

  double _lineHeight(BuildContext context) =>
      MediaQuery.textScalerOf(context).scale(14) * 1.5 + 8;

  Widget _buildLineRow(BuildContext context, DiscoveryLine line) {
    final sanMoves = _pvToSanList(_searchFen, line.pv);
    final san = sanMoves.isNotEmpty ? sanMoves.first : '?';

    final evalStr = formatEvalDisplay(
      scoreCp: line.scoreCp,
      scoreMate: line.scoreMate,
    );

    return Container(
      height: _lineHeight(context),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              evalStr,
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                fontFamily: AppTextStyles.monoFamily,
              ),
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 48,
            child: Builder(
              builder: (anchorContext) => MouseRegion(
                cursor: !_threatMode && widget.onLineMoveTapped != null
                    ? SystemMouseCursors.click
                    : MouseCursor.defer,
                onEnter: (_) {
                  final box = anchorContext.findRenderObject() as RenderBox?;
                  if (box == null) return;
                  final anchor = box.localToGlobal(
                    Offset(box.size.width / 2, box.size.height),
                  );
                  _showPreview(line, sanMoves, 0, anchor);
                },
                onExit: (_) => _boardPreview.clearPreview(),
                child: GestureDetector(
                  onTap: !_threatMode && widget.onLineMoveTapped != null
                      ? () {
                          widget.onLineMoveTapped!(sanMoves, 0);
                          _boardPreview.clearPreview();
                        }
                      : null,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Text(
                      san,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontFamily: AppTextStyles.monoFamily,
                        fontSize: 14,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Expanded(child: _buildClickableContinuation(line, sanMoves)),
        ],
      ),
    );
  }

  Widget _buildClickableContinuation(
    DiscoveryLine line,
    List<String> sanMoves,
  ) {
    if (sanMoves.length <= 1) return const SizedBox.shrink();

    // Ply of the first move in the PV (index 0)
    final firstMovePly = plyFromFen(_searchFen);

    return ClickableMoveLineWidget(
      sanMoves: sanMoves,
      startPly: firstMovePly,
      startIndex: 1,
      maxMoves: 7,
      fontSize: 12,
      onMoveTapped: !_threatMode && widget.onLineMoveTapped != null
          ? (idx) {
              widget.onLineMoveTapped!(sanMoves, idx);
              _boardPreview.clearPreview();
            }
          : null,
      onMoveHovered: (idx, anchor) => _showPreview(line, sanMoves, idx, anchor),
      onHoverExit: _boardPreview.clearPreview,
    );
  }
}
