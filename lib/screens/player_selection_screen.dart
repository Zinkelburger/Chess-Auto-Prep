/// The player picker for Player Analysis.
library;

/// Embedded below the Player Analysis toolbar so app actions, navigation and
/// settings remain available while choosing games. The list uses a readable
/// width and exposes each saved player's maintenance actions directly.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../models/analysis_player_info.dart';
import '../services/analysis_games_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../widgets/analysis/add_player_sources.dart';
import '../widgets/analysis/player_downloads.dart';
import '../widgets/analysis_download_dialog.dart';
import '../widgets/analysis_import_dialog.dart';
import '../widgets/common/list_search_field.dart';
import '../features/opponents/widgets/tournaments_screen.dart';

class PlayerSelectionScreen extends StatefulWidget {
  const PlayerSelectionScreen({
    super.key,
    this.gamesService,
    required this.onSelected,
    this.onCancel,
  });

  final ValueChanged<AnalysisPlayerInfo> onSelected;
  final VoidCallback? onCancel;

  /// Injectable so a widget test can list players without real disk I/O —
  /// `testWidgets` runs in a fake-async zone where a `dart:io` read never
  /// completes, which would leave the screen spinning forever.
  final AnalysisGamesService? gamesService;

  @override
  State<PlayerSelectionScreen> createState() => _PlayerSelectionScreenState();
}

class _PlayerSelectionScreenState extends State<PlayerSelectionScreen> {
  late final AnalysisGamesService _gamesService =
      widget.gamesService ?? AnalysisGamesService();
  late final PlayerDownloadRunner _downloads = PlayerDownloadRunner(
    _gamesService,
  );

  List<AnalysisPlayerInfo> _cachedPlayers = [];
  bool _isLoading = true;
  String? _loadError;
  String _search = '';

  /// Matched against the username, the platform name and the group, so
  /// "lichess" narrows to one site and "Spring Open" to one event's field as
  /// readily as a name prefix does to one player.
  List<AnalysisPlayerInfo> get _visiblePlayers => _cachedPlayers
      .where(
        (p) => matchesSearch(
          _search,
          '${p.username} ${p.platformDisplayName} ${p.group ?? ''}',
        ),
      )
      .toList();

  @override
  void initState() {
    super.initState();
    unawaited(_loadCachedPlayers());
  }

  Future<void> _loadCachedPlayers() async {
    if (!mounted) return;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });

    try {
      final players = await _gamesService.getAllCachedPlayers();
      if (mounted) {
        setState(() {
          _cachedPlayers = players;
          _isLoading = false;
          _loadError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _cachedPlayers = [];
          _isLoading = false;
          _loadError = 'Could not load saved players.\n$e';
        });
      }
    }
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topCenter,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1040),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
              child: Row(
                children: [
                  const Expanded(
                    child: Text('Which player?', style: AppTextStyles.title),
                  ),
                  if (widget.onCancel != null)
                    TextButton(
                      onPressed: widget.onCancel,
                      child: const Text('Back to analysis'),
                    ),
                  TextButton(
                    onPressed: _openTournaments,
                    child: const Text('Players & groups'),
                  ),
                  const SizedBox(width: 8),
                  AddPlayerButton(onSelected: _addPlayerFrom),
                ],
              ),
            ),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) return const Center(child: CircularProgressIndicator());
    if (_loadError != null) return _buildError(_loadError!);
    if (_cachedPlayers.isEmpty) return _buildFirstRun();

    final visible = _visiblePlayers;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: ListSearchField(
            hintText: 'Search players',
            autofocus: true,
            onChanged: (v) {
              if (mounted) setState(() => _search = v);
            },
          ),
        ),
        Expanded(
          child: visible.isEmpty
              ? Center(
                  child: Text(
                    'No players match "$_search"',
                    style: const TextStyle(color: AppColors.onSurfaceMuted),
                  ),
                )
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: visible.length,
                  itemBuilder: (_, i) => _PlayerTile(
                    player: visible[i],
                    onSelect: () => _pick(visible[i]),
                    onAction: (action) => _runTileAction(visible[i], action),
                  ),
                ),
        ),
      ],
    );
  }

  Widget _buildError(String message) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 48, color: AppColors.danger),
            const SizedBox(height: 16),
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _loadCachedPlayers,
              icon: const Icon(Icons.refresh),
              label: const Text('Try again'),
            ),
          ],
        ),
      ),
    );
  }

  /// Nothing saved yet. The three ways in are on the screen, not in a menu —
  /// a first-run user has no reason to open a menu they cannot see the point
  /// of. The heading already asks the question; the body is just the answer.
  Widget _buildFirstRun() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: AddPlayerSourceList(onSelected: _addPlayerFrom),
        ),
      ),
    );
  }

  void _pick(AnalysisPlayerInfo player) {
    if (!mounted) return;
    widget.onSelected(player);
  }

  // ── Adding a player ──────────────────────────────────────────────

  void _addPlayerFrom(AddPlayerSource source) {
    switch (source) {
      case AddPlayerSource.download:
        unawaited(_downloadNewPlayer());
      case AddPlayerSource.pgnFiles:
        unawaited(_openPgnFiles());
      case AddPlayerSource.opponentList:
        unawaited(_openTournaments());
    }
  }

  Future<void> _downloadNewPlayer() async {
    final appState = context.read<AppState>();
    final config = await showDialog<AnalysisPlayerInfo>(
      context: context,
      builder: (_) => AnalysisDownloadDialog(
        chesscomUsername: appState.chesscomUsername,
        lichessUsername: appState.lichessUsername,
      ),
    );
    if (config == null || !mounted) return;
    _rememberFirstUsername(appState, config);
    await _download(config);
  }

  Future<void> _openPgnFiles() async {
    final result = await showDialog<AnalysisImportResult>(
      context: context,
      builder: (_) => const AnalysisImportDialog(),
    );
    if (result == null || !mounted) return;

    // Names that sanitize to the same storage key (e.g. "AC/DC" vs "AC DC")
    // land in the same files, so check the disk rather than the raw name.
    final existing = await _gamesService.findExistingPlayer(
      'import',
      result.playerName,
    );
    if (!mounted) return;
    if (existing != null && !await _confirmReplace(existing)) return;

    try {
      await _gamesService.saveAnalysisGames(
        result.pgns,
        platform: 'import',
        username: result.playerName,
        maxGames: result.gameCount,
      );
      await _loadCachedPlayers();
    } catch (e) {
      debugPrint('Import failed: $e');
      if (mounted) {
        showAppSnackBar(context, AppMessages.genericError, isError: true);
      }
    }
  }

  Future<bool> _confirmReplace(AnalysisPlayerInfo existing) async {
    final replace = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Replace these games?'),
        content: Text(
          '"${existing.username}" already has ${existing.gameCount} '
          'game${existing.gameCount == 1 ? '' : 's'} here. Opening these '
          'files replaces them and clears their cached analysis.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return replace == true && mounted;
  }

  /// The tournaments screen hands back a player when the user picks
  /// "Analyse" on an opponent there; otherwise the list is just refreshed,
  /// since games may have been downloaded meanwhile.
  Future<void> _openTournaments() async {
    final picked = await Navigator.of(context).push<AnalysisPlayerInfo>(
      MaterialPageRoute(builder: (_) => const TournamentsScreen()),
    );
    if (!mounted) return;
    if (picked != null) {
      _pick(picked);
      return;
    }
    await _loadCachedPlayers();
  }

  /// Seed the app-wide default username, but only when none is saved yet:
  /// Player Analysis downloads opponents' games too, and an opponent's name
  /// must not overwrite the user's own saved default (editable in Settings).
  void _rememberFirstUsername(AppState appState, AnalysisPlayerInfo config) {
    if (config.platform == 'lichess') {
      if (appState.lichessUsername?.isNotEmpty != true) {
        appState.setLichessUsername(config.username);
      }
    } else if (config.platform == 'chesscom') {
      if (appState.chesscomUsername?.isNotEmpty != true) {
        appState.setChesscomUsername(config.username);
      }
    }
  }

  Future<void> _download(AnalysisPlayerInfo config) async {
    await _downloads.downloadOne(context, config);
    if (mounted) await _loadCachedPlayers();
  }

  // ── Per-player actions ───────────────────────────────────────────

  Future<void> _runTileAction(
    AnalysisPlayerInfo player,
    _PlayerAction action,
  ) async {
    switch (action) {
      case _PlayerAction.update:
        // Re-uses the range this game-set was saved with, so "update" cannot
        // quietly shrink a two-year set to six months.
        await _download(player);
      case _PlayerAction.changeRange:
        await _changeRange(player);
      case _PlayerAction.delete:
        await _deletePlayer(player);
    }
  }

  /// Download again with a different range or time controls. Site and
  /// username are fixed: a multi-account opponent has no single one to edit.
  Future<void> _changeRange(AnalysisPlayerInfo player) async {
    final config = await showDialog<AnalysisPlayerInfo>(
      context: context,
      builder: (_) => AnalysisDownloadDialog(player: player),
    );
    if (config == null || !mounted) return;
    await _download(config);
  }

  Future<void> _deletePlayer(AnalysisPlayerInfo player) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove ${player.displayName}?'),
        content: const Text(
          'Deletes the saved games and their analysis. Nothing on '
          'Chess.com or Lichess is touched.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _gamesService.deletePlayerData(player.platform, player.username);
    await _loadCachedPlayers();
  }
}

/// Maintenance actions exposed on each saved player.
enum _PlayerAction { update, changeRange, delete }

/// Select a player by name; maintenance buttons stay beside the metadata on
/// wide windows and wrap below it when there is less room.
class _PlayerTile extends StatelessWidget {
  const _PlayerTile({
    required this.player,
    required this.onSelect,
    required this.onAction,
  });

  final AnalysisPlayerInfo player;
  final VoidCallback onSelect;
  final ValueChanged<_PlayerAction> onAction;

  @override
  Widget build(BuildContext context) {
    final games = player.gameCount;
    final facts = [
      '$games game${games == 1 ? '' : 's'}',
      player.platformDisplayName,
      player.rangeDescription,
      // Only when it is not the usual "everything but bullet".
      if (player.speedsDescription != null) player.speedsDescription!,
    ].join(' · ');
    final origin = [
      '${player.isImported && player.accounts.isEmpty ? 'Opened' : 'Downloaded'}'
          ' ${player.downloadTimeAgo}',
      if (player.group != null && player.group!.isNotEmpty) player.group!,
      for (final a in player.accounts)
        '${a.username} (${_shortPlatform(a.platform)})',
    ].join(' · ');

    final details = ListTile(
      onTap: onSelect,
      leading: Icon(_icon, color: _color),
      title: Text(player.displayName, style: AppTextStyles.body),
      subtitle: Text(
        '$facts\n$origin',
        style: AppTextStyles.muted.copyWith(color: AppColors.onSurfaceMuted),
      ),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    );
    final actions = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Wrap(
        spacing: 4,
        runSpacing: 4,
        children: [
          if (player.canRedownload) ...[
            TextButton.icon(
              onPressed: () => onAction(_PlayerAction.update),
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Update games'),
            ),
            TextButton.icon(
              onPressed: () => onAction(_PlayerAction.changeRange),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Change range…'),
            ),
          ],
          TextButton.icon(
            onPressed: () => onAction(_PlayerAction.delete),
            icon: const Icon(Icons.delete_outline, size: 18),
            label: const Text('Remove'),
          ),
        ],
      ),
    );
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      clipBehavior: Clip.antiAlias,
      child: LayoutBuilder(
        builder: (context, constraints) => constraints.maxWidth >= 900
            ? Row(
                children: [
                  Expanded(child: details),
                  actions,
                ],
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [details, actions],
              ),
      ),
    );
  }

  bool get _isOpponent => player.accounts.isNotEmpty;

  IconData get _icon {
    if (_isOpponent) return Icons.groups_outlined;
    if (player.isImported) return Icons.description_outlined;
    return player.platform == 'chesscom' ? Icons.language : Icons.bolt;
  }

  Color get _color {
    if (_isOpponent || player.isImported) return AppColors.platformImported;
    return player.platform == 'chesscom'
        ? AppColors.platformChessCom
        : AppColors.platformLichess;
  }

  static String _shortPlatform(String platform) => switch (platform) {
    'chesscom' => 'chess.com',
    'lichess' => 'lichess',
    _ => platform,
  };
}
