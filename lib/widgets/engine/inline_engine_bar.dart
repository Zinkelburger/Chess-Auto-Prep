/// Compact inline engine bar for PGN views.
///
/// Shows a toggle switch, live Stockfish MultiPV lines, and a settings gear.
/// Designed to sit above a [PgnViewerWidget] in any screen that displays a
/// game PGN without its own engine integration.
///
/// Uses the shared [BoardEngine], keeping its configured threads asleep while
/// analysis is toggled off. Background jobs use their own on-demand pool.
library;

import 'package:chess_auto_prep/services/engine/board_engine.dart';

import '../../features/settings/models/engine_configuration.dart';

import 'package:provider/provider.dart';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:chess_auto_prep/core/board_preview_controller.dart';
import '../../features/settings/controllers/engine_settings.dart';
import '../../models/analysis/discovery_result.dart';
import '../../services/eval_cache.dart';
import '../../services/engine/engine_lifecycle.dart';
import '../../design_system/theme/app_typography.dart';
import '../../design_system/theme/workspace_theme.dart';
import '../../l10n/generated/app_localizations.dart';
import '../../utils/chess_utils.dart'
    show fenAfterMoves, formatEvalDisplay, formatNodes, uciPvToSanCached;
import '../../utils/fen_utils.dart';
import 'engine_pv_row.dart';
import 'inline_engine_settings.dart';
import '../../services/engine/threat_position.dart';
import '../../utils/app_shortcuts.dart';
import '../shortcut_tooltip.dart';
import 'engine_gate.dart';
import 'floating_board_preview.dart';

class InlineEngineBar extends StatefulWidget {
  final String fen;
  final bool isActive;

  /// Keep technical search status in a tooltip in the repertoire workspace.
  final bool compactChrome;

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
    this.compactChrome = false,
    this.onLineMoveTapped,
    this.previewFlipped = false,
    this.onThreatChanged,
  });

  /// Whether the engine is currently enabled (static, shared across instances).
  static bool isEngineEnabled(BuildContext context) =>
      context.read<EngineLifecycle>().state != EngineState.off;

  /// Toggle engine on/off from outside (e.g. keyboard shortcut).
  static void toggleEngine(BuildContext context) {
    final lifecycle = context.read<EngineLifecycle>();
    unawaited(
      (lifecycle.state == EngineState.off
              ? lifecycle.toggleOn()
              : lifecycle.toggleOff())
          .catchError(
            (Object error) =>
                debugPrint('[InlineEngine] Toggle failed: $error'),
          ),
    );
  }

  @override
  State<InlineEngineBar> createState() => _InlineEngineBarState();
}

class _InlineEngineBarState extends State<InlineEngineBar> {
  late final EngineSettings _settings = context.read<EngineSettings>();
  late final _lifecycle = context.read<EngineLifecycle>();

  bool get _engineEnabled => _lifecycle.state != EngineState.off;

  void _setEngineEnabled(bool value) {
    final lifecycle = _lifecycle;
    unawaited(
      (value ? lifecycle.toggleOn() : lifecycle.toggleOff()).catchError(
        (Object error) => debugPrint('[InlineEngine] Toggle failed: $error'),
      ),
    );
  }

  bool _threatMode = false;
  bool _failed = false;
  String get _searchFen =>
      _threatMode ? threatPositionFen(widget.fen) ?? widget.fen : widget.fen;

  void _publishThreat() {
    final generation = _generation;
    final fen = widget.fen;
    final uci =
        !EngineGate.isLocked(context) &&
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

  EngineConfiguration? _searchConfiguration;
  int get _displayLines => _searchConfiguration?.multiPv ?? _settings.multiPv;
  late final _session = context.read<BoardEngine>().createSession();
  late bool _wasEnabled = _engineEnabled;
  bool _modeActive = true;

  bool get _isActive => widget.isActive && _modeActive;

  late bool _gateLocked = EngineGate.isLocked(context);

  /// Drives the floating mini-board shown when hovering PV moves.
  final BoardPreviewController _boardPreview = BoardPreviewController();
  final GlobalKey _previewKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    _wasEnabled = _engineEnabled;
    _gateLocked = EngineGate.isLocked(context);
    // Committed settings apply to the next explicit search.
    _settings.addListener(_onSettingsChanged);
    _lifecycle.addListener(_onEngineGateChanged);
    if (_engineEnabled && _isActive) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _runDiscovery());
    }
  }

  /// Leave the shared board session while generation owns the CPU, then
  /// prepare and resume discovery when the build releases it.
  void _onEngineGateChanged() {
    if (!mounted) return;
    final locked = EngineGate.isLocked(context);
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
    _lifecycle.removeListener(_onEngineGateChanged);
    _settings.removeListener(_onSettingsChanged);
    _session.dispose();
    _boardPreview.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (!mounted) return;
    // The next explicit search/position reads committed settings.
    setState(() {});
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
    if (!_isActive || EngineGate.isLocked(context)) return;
    unawaited(
      _session.prepare().catchError((Object error) {
        if (kDebugMode) debugPrint('[InlineEngine] Preparation failed: $error');
      }),
    );
  }

  Future<void> _runDiscovery() async {
    if (!mounted ||
        !_isActive ||
        !_engineEnabled ||
        EngineGate.isLocked(context)) {
      return;
    }
    if (_searchFen == _lastAnalyzedFen && _discovery.lines.isNotEmpty) return;

    final myGen = ++_generation;
    final configuration = _searchConfiguration = _settings.committed;
    // Drop any pending throttled progress from the previous search so a stale
    // trailing flush can't paint over the new one.
    _progressThrottle?.cancel();
    _progressThrottle = null;
    _pendingProgress = null;
    final fen = _searchFen;
    _lastAnalyzedFen = fen;

    setState(() {
      _isSearching = true;
      _failed = false;
      _discovery = const DiscoveryResult();
    });
    _publishThreat();

    final whiteToMove = isWhiteToMove(fen);

    try {
      final result = await _session.discover(
        fen: fen,
        depth: configuration.depth,
        multiPv: configuration.multiPv,
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
        _failed = true;
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
    return Material(
      color: WorkspaceTheme.of(context).panel,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildToggleBar(context),
          if (_engineEnabled) ...[
            const Divider(height: 1),
            // Reserve every configured PV slot even while a new position has
            // no results (or fewer legal moves). Navigation must not move the
            // PGN below us as streamed lines disappear and arrive.
            ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: EnginePvRow.lineHeight(context) * _displayLines,
                maxHeight: (EnginePvRow.lineHeight(context) * _displayLines)
                    .clamp(240.0, double.infinity),
              ),
              child: SingleChildScrollView(
                child: EngineGate.isLocked(context)
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
      ),
    );
  }

  Widget _buildToggleBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    if (widget.compactChrome) return _buildCompactToggleBar(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      color: WorkspaceTheme.of(context).panel,
      child: Row(
        children: [
          SizedBox(
            height: 32,
            child: FittedBox(
              child: ShortcutTooltip(
                description: l10n.engineAppearanceToggle,
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
          const SizedBox(width: 6),
          Expanded(
            child: _engineEnabled
                ? Text(
                    EngineGate.isLocked(context)
                        ? l10n.engineAppearanceBusy
                        : _isSearching
                        ? l10n.engineAppearanceSearchStatus(
                            _threatMode ? 'threat' : 'normal',
                            _discovery.depth,
                            formatNodes(_discovery.nodes),
                          )
                        : l10n.engineAppearanceLinesStatus(
                            _threatMode ? 'threat' : 'normal',
                            _discovery.lines.length,
                            _discovery.depth,
                          ),
                    style: AppTypography.body(
                      context,
                    ).copyWith(fontWeight: FontWeight.w400),
                    overflow: TextOverflow.ellipsis,
                  )
                : Tooltip(
                    message: l10n.engineAppearanceToggle,
                    child: Text(
                      l10n.engineAppearanceEngine,
                      style: AppTypography.body(
                        context,
                      ).copyWith(fontWeight: FontWeight.w400),
                    ),
                  ),
          ),
          IconButton(
            icon: const Icon(Icons.gps_fixed, size: 20),
            style: IconButton.styleFrom(foregroundColor: colors.onSurface),
            selectedIcon: Icon(
              Icons.gps_fixed,
              size: 20,
              color: colors.primary,
            ),
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            tooltip: _threatMode
                ? l10n.engineAppearanceHideThreat
                : l10n.engineAppearanceShowThreat,
            isSelected: _threatMode,
            onPressed:
                _engineEnabled &&
                    !EngineGate.isLocked(context) &&
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

  Widget _buildCompactToggleBar(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          ShortcutTooltip(
            description: _engineEnabled
                ? l10n.engineAppearanceStopAnalysis
                : l10n.engineAppearanceStartAnalysis,
            shortcut: AppShortcut.toggleEngine,
            child: TextButton.icon(
              onPressed: () {
                if (!_engineEnabled && !EngineGate.ensureAvailable(context)) {
                  return;
                }
                _setEngineEnabled(!_engineEnabled);
              },
              icon: Icon(
                _engineEnabled ? Icons.stop : Icons.play_arrow,
                size: 18,
              ),
              label: Text(
                _engineEnabled
                    ? l10n.engineAppearanceStop
                    : l10n.engineAppearanceStartAnalysis,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: _engineEnabled
                  ? l10n.engineAppearanceDepthStatus(
                      _discovery.depth,
                      formatNodes(_discovery.nodes),
                    )
                  : l10n.engineAppearanceLocalEngine,
              child: Text(
                EngineGate.isLocked(context)
                    ? l10n.engineAppearanceBusy
                    : 'Stockfish',
                style: AppTypography.secondary(
                  context,
                ).copyWith(color: colors.onSurfaceVariant),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: l10n.engineAppearanceOptions,
            icon: Icon(
              Icons.more_horiz,
              size: 20,
              color: _threatMode ? colors.primary : colors.onSurfaceVariant,
            ),
            onSelected: (_) {
              if (!mounted) return;
              _toggleThreat();
            },
            itemBuilder: (_) => [
              CheckedPopupMenuItem<String>(
                value: 'threat',
                checked: _threatMode,
                enabled:
                    _engineEnabled &&
                    !EngineGate.isLocked(context) &&
                    threatPositionFen(widget.fen) != null,
                child: Text(l10n.engineAppearanceShowThreat),
              ),
            ],
          ),
          const InlineEngineSettings(),
        ],
      ),
    );
  }

  Widget _buildLines(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final lines = _discovery.lines;

    if (lines.isEmpty && !_isSearching) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Text(
          _failed
              ? l10n.engineAppearanceFailure
              : l10n.engineAppearanceNoLegalMoves,
          style: AppTypography.caption(context),
        ),
      );
    }
    if (lines.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
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
              l10n.engineAppearanceAnalyzing,
              style: AppTypography.secondary(context),
            ),
          ],
        ),
      );
    }

    final byRank = {for (final line in lines) line.pvNumber: line};
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(_displayLines, (index) {
        final line = byRank[index + 1];
        return line == null
            ? SizedBox(height: EnginePvRow.lineHeight(context))
            : _buildLineRow(context, line);
      }),
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

  Widget _buildLineRow(BuildContext context, DiscoveryLine line) {
    final sanMoves = _pvToSanList(_searchFen, line.pv);
    return EnginePvRow(
      key: ValueKey('$_searchFen:${line.pvNumber}'),
      evaluation: formatEvalDisplay(
        scoreCp: line.scoreCp,
        scoreMate: line.scoreMate,
      ),
      sanMoves: sanMoves,
      startPly: plyFromFen(_searchFen),
      onMoveTapped: !_threatMode && widget.onLineMoveTapped != null
          ? (idx) {
              if (!mounted) return;
              widget.onLineMoveTapped!(sanMoves, idx);
              _boardPreview.clearPreview();
            }
          : null,
      onMoveHovered: (idx, anchor) => _showPreview(line, sanMoves, idx, anchor),
      onHoverExit: _boardPreview.clearPreview,
    );
  }
}
