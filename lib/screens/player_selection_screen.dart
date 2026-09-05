/// The player picker for Player Analysis.
library;

///
/// Pushed as a full-screen route from [AnalysisScreen]. One job: choose whose
/// games to analyse. It lists every saved game-set — downloaded from an
/// account, opened from PGN files, or pulled in as a tournament field — and
/// pops with the chosen [AnalysisPlayerInfo].
///
/// Adding a player goes through exactly one control: **Add player** in the
/// app bar, whose menu names the three sources (see [AddPlayerSource]). On
/// first run, with nothing to pick, those three are spelled out in the body
/// instead of hidden behind the menu. The screen used to carry five
/// overlapping buttons — three stacked FABs over the list plus two more in
/// the empty state — whose labels ("Download New", "Download Games", "Import
/// Opponents", "Load from disk") did not distinguish a download from a file.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../models/analysis_player_info.dart';
import '../services/analysis_games_service.dart';
import '../theme/app_colors.dart';
import '../utils/app_messages.dart';
import '../widgets/analysis/add_player_sources.dart';
import '../widgets/analysis/player_downloads.dart';
import '../widgets/analysis_download_dialog.dart';
import '../widgets/analysis_import_dialog.dart';
import '../widgets/common/list_search_field.dart';
import '../widgets/opponent_list_import_dialog.dart';

class PlayerSelectionScreen extends StatefulWidget {
  const PlayerSelectionScreen({super.key, this.gamesService});

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
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a player'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: AddPlayerButton(onSelected: _addPlayerFrom),
          ),
        ],
      ),
      body: _buildBody(),
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
            onChanged: (v) => setState(() => _search = v),
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
                    onSelect: () => Navigator.of(context).pop(visible[i]),
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
  /// of, and "no players" without a next step is a dead end.
  Widget _buildFirstRun() {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'No players yet',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
              const SizedBox(height: 8),
              const Text(
                'Add someone’s games — your own or an opponent’s — and the '
                'app maps their openings, mistakes and the traps they walk '
                'into.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppColors.onSurfaceMuted),
              ),
              const SizedBox(height: 24),
              AddPlayerSourceList(onSelected: _addPlayerFrom),
            ],
          ),
        ),
      ),
    );
  }

  // ── Adding a player ──────────────────────────────────────────────

  void _addPlayerFrom(AddPlayerSource source) {
    switch (source) {
      case AddPlayerSource.download:
        unawaited(_downloadNewPlayer());
      case AddPlayerSource.pgnFiles:
        unawaited(_openPgnFiles());
      case AddPlayerSource.opponentList:
        unawaited(_addTournamentField());
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

  Future<void> _addTournamentField() async {
    final request = await showDialog<OpponentImportRequest>(
      context: context,
      builder: (_) => const OpponentListImportDialog(),
    );
    if (request == null || !mounted) return;
    await _downloads.downloadList(context, request);
    if (mounted) await _loadCachedPlayers();
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

  /// Download again with a different range. A multi-account opponent has no
  /// single platform/username to edit, so it is asked only for the range.
  Future<void> _changeRange(AnalysisPlayerInfo player) async {
    if (player.accounts.isNotEmpty) {
      final months = await _askMonths(player);
      if (months == null || !mounted) return;
      await _download(player.copyWith(monthsBack: months));
      return;
    }

    final appState = context.read<AppState>();
    final config = await showDialog<AnalysisPlayerInfo>(
      context: context,
      builder: (_) => AnalysisDownloadDialog(
        chesscomUsername: player.platform == 'chesscom'
            ? player.username
            : appState.chesscomUsername,
        lichessUsername: player.platform == 'lichess'
            ? player.username
            : appState.lichessUsername,
        initialPlatform: player.platform,
        initialSpeeds: player.speeds,
      ),
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

  /// Ask for a month range for a multi-account opponent. Null on cancel.
  Future<int?> _askMonths(AnalysisPlayerInfo player) async {
    final controller = TextEditingController(text: '${player.monthsBack ?? 6}');
    try {
      return await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Download ${player.displayName} again'),
          content: TextField(
            controller: controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Months of games, per account',
              helperText: player.accounts.map((a) => a.username).join(', '),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final n = int.tryParse(controller.text.trim());
                if (n != null && n > 0) Navigator.of(ctx).pop(n);
              },
              child: const Text('Download'),
            ),
          ],
        ),
      );
    } finally {
      controller.dispose();
    }
  }
}

/// What the row's overflow menu offers.
enum _PlayerAction { update, changeRange, delete }

/// One saved game-set, as a plain [ListTile]: who, how many games, where from
/// and how old — then get out of the way. Tapping the row picks the player,
/// which is the only reason the screen exists.
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

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        onTap: onSelect,
        leading: Icon(_icon, color: _color),
        title: Text(player.displayName),
        isThreeLine: true,
        subtitle: Text(
          '$facts\n$origin',
          style: const TextStyle(color: AppColors.onSurfaceMuted),
        ),
        trailing: PopupMenuButton<_PlayerAction>(
          tooltip: 'More actions',
          onSelected: onAction,
          itemBuilder: (_) => [
            // PGN-file imports have no source to fetch fresh games from.
            if (player.canRedownload) ...const [
              PopupMenuItem(
                value: _PlayerAction.update,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.refresh, size: 20),
                  title: Text('Download the latest games'),
                ),
              ),
              PopupMenuItem(
                value: _PlayerAction.changeRange,
                child: ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(Icons.tune, size: 20),
                  title: Text('Download a different range…'),
                ),
              ),
            ],
            const PopupMenuItem(
              value: _PlayerAction.delete,
              child: ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(Icons.delete_outline, size: 20),
                title: Text('Remove from this list'),
              ),
            ),
          ],
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
