/// Live Lichess Opening Explorer panel (user-view only).
///
/// Shows, for the current board position, the moves played in the Lichess or
/// Masters database with their game counts and win/draw/loss split — the
/// human-facing equivalent of the site's opening explorer, in this app's
/// style. It never feeds the generation pipeline; all lookups go through
/// [LiveExplorerService], which debounces and caches to respect the API's
/// one-request-at-a-time rate limit.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/coverage/services/coverage_service.dart'
    show LichessDatabase;
import '../../models/explorer_response.dart';
import '../../services/lichess_auth_service.dart';
import '../../services/live_explorer_service.dart';
import '../../theme/app_colors.dart';
import '../lichess_db_selector.dart';
import '../lichess_login_prompt.dart';
import 'explorer_move_row.dart';

class OpeningExplorerPanel extends StatefulWidget {
  const OpeningExplorerPanel({
    super.key,
    required this.service,
    required this.fen,
    this.movePath = const [],
    required this.onPlayMove,
    this.onAddMove,
    this.onHoverMove,
    this.repertoireMovesAtPosition = const {},
  });

  final LiveExplorerService service;

  /// FEN of the position to explore.
  final String fen;

  /// SAN path to [fen].  Lets the service scope its empty-run cutoff to this
  /// line instead of silencing every position deeper than the last dead one.
  final List<String> movePath;

  /// Play a move (by SAN) on the board — a row click.
  final ValueChanged<String> onPlayMove;

  /// Add a move to the repertoire (right-click menu). When null, the menu is
  /// not offered.
  final ValueChanged<ExplorerMove>? onAddMove;

  /// The move under the pointer, or null once it leaves the rows — so the
  /// host can echo it as an arrow on the board.
  final ValueChanged<ExplorerMove?>? onHoverMove;

  /// SANs already present in the repertoire at this position (for styling).
  final Set<String> repertoireMovesAtPosition;

  @override
  State<OpeningExplorerPanel> createState() => _OpeningExplorerPanelState();
}

class _OpeningExplorerPanelState extends State<OpeningExplorerPanel> {
  static const _kDb = 'live_explorer.db';
  static const _kSpeeds = 'live_explorer.speeds';
  static const _kRatings = 'live_explorer.ratings';

  LichessDatabase _database = LichessDatabase.lichess;
  Set<String> _speeds = {'blitz', 'rapid', 'classical'};
  Set<String> _ratings = {'2000', '2200', '2500'};
  bool _filtersExpanded = false;
  bool _prefsLoaded = false;

  @override
  void initState() {
    super.initState();
    // Logging in from anywhere in the app (this panel's own prompt, the DB
    // info popover, settings) should refill the panel, not leave it sitting
    // on a stale "login needed".
    LichessAuthService.instance.addListener(_onAuthChanged);
    unawaited(_loadPrefs());
  }

  @override
  void dispose() {
    LichessAuthService.instance.removeListener(_onAuthChanged);
    _clearHover();
    super.dispose();
  }

  void _onAuthChanged() {
    if (mounted) _requestCurrent();
  }

  @override
  void didUpdateWidget(covariant OpeningExplorerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fen != widget.fen) {
      // The hovered row belongs to the old position; its arrow would point
      // at the wrong squares on the new one.
      _clearHover();
      _requestCurrent();
    }
  }

  ExplorerMove? _hoveredMove;

  void _onRowHover(ExplorerMove move, bool hovered) {
    if (hovered) {
      _hoveredMove = move;
      widget.onHoverMove?.call(move);
    } else if (_hoveredMove?.uci == move.uci) {
      _clearHover();
    }
  }

  void _clearHover() {
    if (_hoveredMove == null) return;
    _hoveredMove = null;
    widget.onHoverMove?.call(null);
  }

  ExplorerQuery get _query =>
      ExplorerQuery(database: _database, speeds: _speeds, ratings: _ratings);

  void _requestCurrent() {
    if (!_prefsLoaded) return;
    widget.service.request(widget.fen, _query, movePath: widget.movePath);
  }

  Future<void> _loadPrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dbName = prefs.getString(_kDb);
      final speeds = prefs.getStringList(_kSpeeds);
      final ratings = prefs.getStringList(_kRatings);
      if (!mounted) return;
      setState(() {
        if (dbName != null) {
          _database = LichessDatabase.values.firstWhere(
            (d) => d.name == dbName,
            orElse: () => LichessDatabase.lichess,
          );
        }
        if (speeds != null && speeds.isNotEmpty) _speeds = speeds.toSet();
        if (ratings != null && ratings.isNotEmpty) _ratings = ratings.toSet();
        _prefsLoaded = true;
      });
    } catch (_) {
      if (mounted) setState(() => _prefsLoaded = true);
    }
    _requestCurrent();
  }

  Future<void> _savePrefs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kDb, _database.name);
      await prefs.setStringList(_kSpeeds, _speeds.toList());
      await prefs.setStringList(_kRatings, _ratings.toList());
    } catch (_) {
      // Best-effort persistence.
    }
  }

  void _onFiltersChanged() {
    setState(() {});
    unawaited(_savePrefs());
    _requestCurrent();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _buildFilterHeader(context),
        if (_filtersExpanded) ...[
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(8),
            child: LichessDbSelector(
              compact: true,
              database: _database,
              onDatabaseChanged: (db) {
                _database = db;
                _onFiltersChanged();
              },
              selectedSpeeds: _speeds,
              onSpeedsChanged: (s) {
                _speeds = s;
                _onFiltersChanged();
              },
              selectedRatings: _ratings,
              onRatingsChanged: (r) {
                _ratings = r;
                _onFiltersChanged();
              },
            ),
          ),
        ],
        const Divider(height: 1),
        Expanded(
          child: ValueListenableBuilder<ExplorerState>(
            valueListenable: widget.service.state,
            builder: (context, state, _) => _buildBody(context, state),
          ),
        ),
      ],
    );
  }

  /// One line naming the active filters, e.g. "Lichess · Blitz, Rapid,
  /// Classical · 2000+" — what the query actually is, not how many boxes
  /// are ticked.
  String get _filterSummary {
    if (_database == LichessDatabase.masters) return 'Masters';
    const order = [
      'ultraBullet',
      'bullet',
      'blitz',
      'rapid',
      'classical',
      'correspondence',
    ];
    final speeds = order
        .where(_speeds.contains)
        .map((s) => s[0].toUpperCase() + s.substring(1))
        .join(', ');
    final speedText = _speeds.length == order.length ? 'All speeds' : speeds;
    final ratings = _ratings.map(int.tryParse).nonNulls.toList()..sort();
    final ratingText = ratings.isEmpty
        ? ''
        : ratings.last >= 2500
        ? '${ratings.first}+'
        : ratings.length == 1
        ? '${ratings.first}'
        : '${ratings.first}–${ratings.last}';
    return [
      'Lichess',
      speedText,
      ratingText,
    ].where((s) => s.isNotEmpty).join(' · ');
  }

  Widget _buildFilterHeader(BuildContext context) {
    final summary = _filterSummary;
    return InkWell(
      onTap: () => setState(() => _filtersExpanded = !_filtersExpanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Row(
          children: [
            Icon(Icons.tune, size: 14, color: Colors.grey[400]),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                summary,
                style: TextStyle(fontSize: 12, color: Colors.grey[300]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              _filtersExpanded ? Icons.expand_less : Icons.expand_more,
              size: 16,
              color: Colors.grey[400],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, ExplorerState state) {
    switch (state.status) {
      case ExplorerStatus.idle:
      case ExplorerStatus.loading:
        // Hold the previous position's table rather than blanking to a
        // spinner — the new rows swap in where the old ones were, so the
        // panel never jumps. Only the very first lookup has nothing to keep,
        // and only that one shows a spinner.
        final previous = state.data;
        if (previous != null) return _buildData(context, previous, stale: true);
        return const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case ExplorerStatus.rateLimited:
        return _buildMessage(
          Icons.hourglass_empty,
          'Lichess is rate-limiting requests.\nPausing a moment before retrying…',
        );
      case ExplorerStatus.authRequired:
        return LichessLoginPrompt(
          compact: true,
          message:
              'Lichess requires an account to query the opening explorer. '
              'Log in once and this panel fills itself in.',
          onLoggedIn: _requestCurrent,
        );
      case ExplorerStatus.error:
        return _buildMessage(
          Icons.cloud_off,
          'Could not reach the Lichess explorer.',
        );
      case ExplorerStatus.data:
        return _buildData(context, state.data!);
    }
  }

  /// [stale] marks [data] as the previous position's — shown while the next
  /// one loads, dimmed and inert, because its moves are not legal here.
  Widget _buildData(
    BuildContext context,
    ExplorerResponse data, {
    bool stale = false,
  }) {
    final body = data.moves.isEmpty
        ? _buildMessage(Icons.search_off, 'No games found for this position.')
        : _buildTable(context, data);
    if (!stale) return body;
    return Stack(
      children: [
        Positioned.fill(child: body),
        // Absorbs clicks as well as dimming: a row here belongs to the
        // position we just left.
        Positioned.fill(
          child: AbsorbPointer(
            child: ColoredBox(
              color: Theme.of(
                context,
              ).colorScheme.surface.withValues(alpha: 0.55),
            ),
          ),
        ),
        const Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: LinearProgressIndicator(minHeight: 2),
        ),
      ],
    );
  }

  Widget _buildTable(BuildContext context, ExplorerResponse data) {
    return Column(
      children: [
        _buildOpeningHeader(data),
        const ExplorerTableHeader(),
        Expanded(
          child: Scrollbar(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemExtent: ExplorerColumns.rowHeight,
              itemCount: data.moves.length,
              itemBuilder: (context, i) {
                final move = data.moves[i];
                return ExplorerMoveRow(
                  key: ValueKey(move.uci),
                  move: move,
                  inRepertoire: widget.repertoireMovesAtPosition.contains(
                    move.san,
                  ),
                  onPlay: () => widget.onPlayMove(move.san),
                  onAdd: widget.onAddMove == null
                      ? null
                      : () => widget.onAddMove!(move),
                  onHover: widget.onHoverMove == null
                      ? null
                      : (hovered) => _onRowHover(move, hovered),
                );
              },
            ),
          ),
        ),
        ExplorerTotalsRow(response: data),
      ],
    );
  }

  Widget _buildOpeningHeader(ExplorerResponse data) {
    final name = data.openingName;
    final eco = data.openingEco;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          if (eco != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: Colors.grey[800],
                borderRadius: BorderRadius.circular(3),
              ),
              child: Text(
                eco,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              name ?? 'No opening name',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: name == null ? AppColors.onSurfaceMuted : null,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(IconData icon, String text) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 24, color: Colors.grey[600]),
            const SizedBox(height: 8),
            Text(
              text,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey[500]),
            ),
          ],
        ),
      ),
    );
  }
}
