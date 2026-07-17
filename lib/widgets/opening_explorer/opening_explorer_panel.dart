/// Live Lichess Opening Explorer panel (user-view only).
///
/// Shows, for the current board position, the moves played in the Lichess or
/// Masters database with their game counts and win/draw/loss split — the
/// human-facing equivalent of the site's opening explorer, in this app's
/// style. It never feeds the generation pipeline; all lookups go through
/// [LiveExplorerService], which debounces and caches to respect the API's
/// one-request-at-a-time rate limit.
library;

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../features/coverage/services/coverage_service.dart'
    show LichessDatabase;
import '../../models/explorer_response.dart';
import '../../services/live_explorer_service.dart';
import '../lichess_db_selector.dart';
import 'explorer_move_row.dart';

class OpeningExplorerPanel extends StatefulWidget {
  const OpeningExplorerPanel({
    super.key,
    required this.service,
    required this.fen,
    required this.onPlayMove,
    this.onAddMove,
    this.repertoireMovesAtPosition = const {},
  });

  final LiveExplorerService service;

  /// FEN of the position to explore.
  final String fen;

  /// Play a move (by SAN) on the board.
  final ValueChanged<String> onPlayMove;

  /// Add a move to the repertoire. When null, the "+" affordance is hidden.
  final ValueChanged<ExplorerMove>? onAddMove;

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
    _loadPrefs();
  }

  @override
  void didUpdateWidget(covariant OpeningExplorerPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fen != widget.fen) _requestCurrent();
  }

  ExplorerQuery get _query =>
      ExplorerQuery(database: _database, speeds: _speeds, ratings: _ratings);

  void _requestCurrent() {
    if (!_prefsLoaded) return;
    widget.service.request(widget.fen, _query);
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
    _savePrefs();
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

  Widget _buildFilterHeader(BuildContext context) {
    final dbLabel = _database == LichessDatabase.masters
        ? 'Masters'
        : 'Lichess';
    final summary = _database == LichessDatabase.masters
        ? dbLabel
        : '$dbLabel · ${_speeds.length} speeds · ${_ratings.length} ratings';
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
      case ExplorerStatus.error:
        return _buildMessage(
          Icons.cloud_off,
          'Could not reach the Lichess explorer.',
        );
      case ExplorerStatus.data:
        return _buildData(context, state.data!);
    }
  }

  Widget _buildData(BuildContext context, ExplorerResponse data) {
    if (data.moves.isEmpty) {
      return _buildMessage(
        Icons.search_off,
        'No games found for this position.',
      );
    }
    return Column(
      children: [
        _buildOpeningHeader(data),
        Expanded(
          child: Scrollbar(
            child: ListView.builder(
              padding: EdgeInsets.zero,
              itemCount: data.moves.length,
              itemBuilder: (context, i) {
                final move = data.moves[i];
                return ExplorerMoveRow(
                  move: move,
                  inRepertoire: widget.repertoireMovesAtPosition.contains(
                    move.san,
                  ),
                  onPlay: () => widget.onPlayMove(move.san),
                  onAdd: widget.onAddMove == null
                      ? null
                      : () => widget.onAddMove!(move),
                );
              },
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildOpeningHeader(ExplorerResponse data) {
    final name = data.openingName;
    final eco = data.openingEco;
    final games = _formatGames(data.totalGames);
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
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Expanded(
            child: Text(
              name ?? 'Opening explorer',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '$games games',
            style: TextStyle(fontSize: 10, color: Colors.grey[400]),
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

  static String _formatGames(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}k';
    return '$n';
  }
}
