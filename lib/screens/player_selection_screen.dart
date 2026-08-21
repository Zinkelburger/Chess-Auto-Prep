/// Player selection screen for analysis.
library;

///
/// Pushed as a full-screen route from [AnalysisScreen]. Lists every cached
/// player game-set — downloaded by username or imported from PGN files —
/// and lets the user select one, re-download, or delete.
/// Pops with the chosen [AnalysisPlayerInfo].

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../models/analysis_player_info.dart';
import '../services/analysis_games_service.dart';
import '../theme/app_colors.dart';
import '../theme/app_text_styles.dart';
import '../utils/app_messages.dart';
import '../widgets/analysis_download_dialog.dart';
import '../widgets/analysis_import_dialog.dart';
import '../widgets/common/list_search_field.dart';
import '../widgets/opponent_list_import_dialog.dart';

class PlayerSelectionScreen extends StatefulWidget {
  const PlayerSelectionScreen({super.key});

  @override
  State<PlayerSelectionScreen> createState() => _PlayerSelectionScreenState();
}

class _PlayerSelectionScreenState extends State<PlayerSelectionScreen> {
  final AnalysisGamesService _gamesService = AnalysisGamesService();
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
        automaticallyImplyLeading: false,
        title: const Text('Select Player to Analyze'),
        actions: [
          IconButton(
            tooltip: 'Back',
            onPressed: () => Navigator.of(context).maybePop(),
            icon: const Icon(Icons.arrow_back),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
      floatingActionButton: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'import_opponents',
            onPressed: _showOpponentImportDialog,
            icon: const Icon(Icons.groups),
            label: const Text('Import Opponents'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'import_pgn',
            onPressed: _showImportDialog,
            icon: const Icon(Icons.file_open),
            label: const Text('Load from disk'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'download_new',
            onPressed: _showDownloadDialog,
            icon: const Icon(Icons.add),
            label: const Text('Download New'),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_loadError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.error_outline,
                size: 64,
                color: AppColors.danger,
              ),
              const SizedBox(height: 16),
              Text(_loadError!, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: _loadCachedPlayers,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
      );
    }

    if (_cachedPlayers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(
              Icons.person_search,
              size: 64,
              color: AppColors.onSurfaceDim,
            ),
            const SizedBox(height: 24),
            Text(
              'No Players Downloaded',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Download games for a player, or import PGN files,'
              ' to get started',
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: AppColors.onSurfaceMuted),
            ),
            const SizedBox(height: 32),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: _showDownloadDialog,
                  icon: const Icon(Icons.download),
                  label: const Text('Download Games'),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _showImportDialog,
                  icon: const Icon(Icons.file_open),
                  label: const Text('Load from disk'),
                ),
              ],
            ),
          ],
        ),
      );
    }

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
                  // Room at the bottom for the two floating action buttons,
                  // which otherwise sit on top of the last card.
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 140),
                  itemCount: visible.length,
                  itemBuilder: (_, index) => _buildPlayerCard(visible[index]),
                ),
        ),
      ],
    );
  }

  // ── Player card ──────────────────────────────────────────────────

  Widget _buildPlayerCard(AnalysisPlayerInfo player) {
    final isOpponent = player.accounts.isNotEmpty;
    final platformIcon = isOpponent
        ? Icons.person_search
        : player.isImported
        ? Icons.file_open
        : player.platform == 'chesscom'
        ? Icons.language
        : Icons.bolt;
    final platformColor = isOpponent
        ? AppColors.platformImported
        : player.isImported
        ? AppColors.platformImported
        : player.platform == 'chesscom'
        ? AppColors.platformChessCom
        : AppColors.platformLichess;

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _selectPlayer(player),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Platform badge
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: platformColor.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(platformIcon, color: platformColor, size: 32),
              ),
              const SizedBox(width: 16),

              // Player info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      player.displayName,
                      style: AppTextStyles.body.copyWith(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    if (player.accounts.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        [
                          for (final a in player.accounts)
                            '${a.username} (${_shortPlatform(a.platform)})',
                          if (player.group != null) player.group!,
                        ].join(' · '),
                        style: AppTextStyles.caption,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                    const SizedBox(height: 4),
                    Text(
                      '${player.gameCount} games · ${player.platformDisplayName}'
                      ' · ${player.rangeDescription}',
                      style: AppTextStyles.body.copyWith(
                        color: AppColors.onSurfaceMuted,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${player.isImported ? 'Imported' : 'Downloaded'} '
                      '${player.downloadTimeAgo}',
                      style: AppTextStyles.caption,
                    ),
                  ],
                ),
              ),

              // Overflow menu
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  switch (value) {
                    case 'delete':
                      unawaited(_deletePlayer(player));
                    case 'redownload':
                      unawaited(_redownloadPlayer(player));
                    case 'redownload_custom':
                      unawaited(_redownloadPlayerCustom(player));
                  }
                },
                itemBuilder: (_) => [
                  // PGN-file imports have no source to re-download from.
                  if (player.canRedownload) ...const [
                    PopupMenuItem(
                      value: 'redownload',
                      child: Row(
                        children: [
                          Icon(Icons.refresh, size: 20),
                          SizedBox(width: 12),
                          Text('Re-download (last 6 months)'),
                        ],
                      ),
                    ),
                    PopupMenuItem(
                      value: 'redownload_custom',
                      child: Row(
                        children: [
                          Icon(Icons.settings, size: 20),
                          SizedBox(width: 12),
                          Text('Re-download (custom)'),
                        ],
                      ),
                    ),
                  ],
                  const PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, size: 20, color: AppColors.danger),
                        SizedBox(width: 12),
                        Text(
                          'Delete',
                          style: TextStyle(color: AppColors.danger),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Actions ──────────────────────────────────────────────────────

  void _selectPlayer(AnalysisPlayerInfo player) {
    Navigator.of(context).pop(player);
  }

  Future<void> _deletePlayer(AnalysisPlayerInfo player) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Games'),
        content: Text('Delete all games for ${player.displayName}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _gamesService.deletePlayerData(player.platform, player.username);
      await _loadCachedPlayers();
    }
  }

  /// Re-download using the last 6 months as the default range.
  Future<void> _redownloadPlayer(AnalysisPlayerInfo player) async {
    await _downloadGames(
      player.copyWith(monthsBack: 6, clearMonthsBack: false),
    );
  }

  /// Re-download but let the user tweak the settings first.
  Future<void> _redownloadPlayerCustom(AnalysisPlayerInfo player) async {
    if (player.accounts.isNotEmpty) {
      // A multi-account opponent has no single platform/username to edit;
      // the range is what the user can change, so ask for that alone.
      final months = await _askMonths(player);
      if (months == null || !mounted) return;
      await _downloadGames(player.copyWith(monthsBack: months));
      return;
    }
    final appState = context.read<AppState>();

    final result = await showDialog<AnalysisPlayerInfo>(
      context: context,
      builder: (_) => AnalysisDownloadDialog(
        chesscomUsername: player.platform == 'chesscom'
            ? player.username
            : appState.chesscomUsername,
        lichessUsername: player.platform == 'lichess'
            ? player.username
            : appState.lichessUsername,
        initialPlatform: player.platform,
      ),
    );

    if (result != null && mounted) {
      _rememberFirstUsername(appState, result);
      await _downloadGames(result);
    }
  }

  Future<void> _showImportDialog() async {
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
    if (existing != null) {
      final replace = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Replace Imported Games?'),
          content: Text(
            '"${existing.username}" already has ${existing.gameCount} '
            'imported game${existing.gameCount == 1 ? '' : 's'}. Importing '
            'will replace them and clear their cached analysis.',
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
      if (replace != true || !mounted) return;
    }

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

  Future<void> _showDownloadDialog() async {
    final appState = context.read<AppState>();

    final result = await showDialog<AnalysisPlayerInfo>(
      context: context,
      builder: (_) => AnalysisDownloadDialog(
        chesscomUsername: appState.chesscomUsername,
        lichessUsername: appState.lichessUsername,
      ),
    );

    if (result != null && mounted) {
      _rememberFirstUsername(appState, result);
      await _downloadGames(result);
    }
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

  // ── Download with live progress ──────────────────────────────────

  Future<void> _downloadGames(AnalysisPlayerInfo config) async {
    final progress = ValueNotifier<String>('Downloading games…');

    // Show a non-dismissible progress dialog.
    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => PopScope(
          canPop: false,
          child: AlertDialog(
            content: ValueListenableBuilder<String>(
              valueListenable: progress,
              builder: (_, message, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    try {
      final pgns = await _gamesService.downloadGamesFor(
        config,
        monthsBack: config.monthsBack,
        onProgress: (msg) => progress.value = msg,
      );

      if (pgns.isEmpty) {
        if (mounted) {
          Navigator.of(context).pop(); // close progress dialog
          showAppSnackBar(
            context,
            AppMessages.noGamesFound(config.displayName),
          );
        }
        return;
      }

      progress.value = 'Saving…';

      // Saves games and automatically clears stale cached analysis.
      await _gamesService.saveAnalysisGames(
        pgns,
        platform: config.platform,
        username: config.username,
        maxGames: config.maxGames,
        monthsBack: config.monthsBack,
        accounts: config.accounts,
        group: config.group,
      );

      await _loadCachedPlayers();

      if (mounted) {
        Navigator.of(context).pop(); // close progress dialog
      }
    } catch (e) {
      debugPrint('Download failed: $e');
      if (mounted) {
        Navigator.of(context).pop(); // close progress dialog
        showAppSnackBar(context, AppMessages.genericError, isError: true);
      }
    } finally {
      progress.dispose();
    }
  }

  // ── Opponent list import ─────────────────────────────────────────

  Future<void> _showOpponentImportDialog() async {
    final request = await showDialog<OpponentImportRequest>(
      context: context,
      builder: (_) => const OpponentListImportDialog(),
    );
    if (request == null || !mounted) return;
    await _importOpponents(request);
  }

  /// Download every opponent in turn behind one progress dialog. A failure on
  /// one person is recorded and the loop moves on — a field of twenty must
  /// not be abandoned because one account was renamed.
  Future<void> _importOpponents(OpponentImportRequest request) async {
    final opponents = request.list.downloadable;
    final progress = ValueNotifier<String>('Starting…');
    var cancelled = false;

    unawaited(
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            title: Text(request.list.event ?? 'Importing opponents'),
            content: ValueListenableBuilder<String>(
              valueListenable: progress,
              builder: (_, message, _) => Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text(message, textAlign: TextAlign.center),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () {
                  cancelled = true;
                  progress.value = 'Stopping after the current opponent…';
                },
                child: const Text('Stop'),
              ),
            ],
          ),
        ),
      ),
    );

    var imported = 0;
    var skipped = 0;
    final failed = <String>[];

    try {
      for (var i = 0; i < opponents.length; i++) {
        if (cancelled) break;
        final opponent = opponents[i];
        final info = opponent.toPlayerInfo(
          group: request.list.event,
          maxGames: 100,
          monthsBack: request.monthsBack,
        );
        final label = '${opponent.name} (${i + 1}/${opponents.length})';

        if (!request.redownloadExisting) {
          final existing = await _gamesService.findExistingPlayer(
            info.platform,
            info.username,
          );
          if (existing != null) {
            skipped++;
            continue;
          }
        }

        try {
          progress.value = '$label\nDownloading…';
          final pgns = await _gamesService.downloadGamesFor(
            info,
            monthsBack: request.monthsBack,
            onProgress: (m) => progress.value = '$label\n$m',
          );
          if (pgns.trim().isEmpty) {
            failed.add('${opponent.name}: no games found');
            continue;
          }
          await _gamesService.saveAnalysisGames(
            pgns,
            platform: info.platform,
            username: info.username,
            maxGames: info.maxGames,
            monthsBack: info.monthsBack,
            accounts: info.accounts,
            group: info.group,
          );
          imported++;
        } catch (e) {
          debugPrint('Opponent import failed for ${opponent.name}: $e');
          failed.add('${opponent.name}: $e');
        }
      }
    } finally {
      progress.dispose();
      if (mounted) Navigator.of(context).pop(); // close progress dialog
    }

    await _loadCachedPlayers();
    if (!mounted) return;

    final parts = <String>[
      'Imported $imported opponent${imported == 1 ? '' : 's'}',
      if (skipped > 0) '$skipped already saved',
      if (failed.isNotEmpty) '${failed.length} failed',
      if (cancelled) 'stopped early',
    ];
    showAppSnackBar(context, parts.join(' · '), isError: failed.isNotEmpty);
    if (failed.isNotEmpty) {
      unawaited(
        showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Some opponents could not be imported'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Text(failed.map((f) => '• $f').join('\n')),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        ),
      );
    }
  }

  /// Ask for a month range for a multi-account opponent. Returns null on
  /// cancel.
  Future<int?> _askMonths(AnalysisPlayerInfo player) async {
    final controller = TextEditingController(text: '${player.monthsBack ?? 6}');
    try {
      return await showDialog<int>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text('Re-download ${player.displayName}'),
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

  static String _shortPlatform(String platform) => switch (platform) {
    'chesscom' => 'chess.com',
    'lichess' => 'lichess',
    _ => platform,
  };
}
