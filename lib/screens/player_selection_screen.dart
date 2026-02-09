/// Player selection screen for analysis.
library;
///
/// Pushed as a full-screen route from [AnalysisScreen]. Lists every cached
/// player game-set and lets the user select one, re-download, or delete.
/// Pops with the chosen [AnalysisPlayerInfo].

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../models/analysis_player_info.dart';
import '../services/analysis_games_service.dart';
import '../widgets/analysis_download_dialog.dart';

class PlayerSelectionScreen extends StatefulWidget {
  const PlayerSelectionScreen({super.key});

  @override
  State<PlayerSelectionScreen> createState() => _PlayerSelectionScreenState();
}

class _PlayerSelectionScreenState extends State<PlayerSelectionScreen> {
  final AnalysisGamesService _gamesService = AnalysisGamesService();
  List<AnalysisPlayerInfo> _cachedPlayers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCachedPlayers();
  }

  Future<void> _loadCachedPlayers() async {
    setState(() => _isLoading = true);
    final players = await _gamesService.getAllCachedPlayers();
    if (mounted) {
      setState(() {
        _cachedPlayers = players;
        _isLoading = false;
      });
    }
  }

  // ── Build ────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Select Player to Analyze')),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showDownloadDialog,
        icon: const Icon(Icons.add),
        label: const Text('Download New'),
      ),
    );
  }

  Widget _buildBody() {
    if (_cachedPlayers.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.person_search, size: 64, color: Colors.grey[400]),
            const SizedBox(height: 24),
            Text(
              'No Players Downloaded',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Download games for a player to get started',
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Colors.grey[600]),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _showDownloadDialog,
              icon: const Icon(Icons.download),
              label: const Text('Download Games'),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _cachedPlayers.length,
      itemBuilder: (_, index) => _buildPlayerCard(_cachedPlayers[index]),
    );
  }

  // ── Player card ──────────────────────────────────────────────────

  Widget _buildPlayerCard(AnalysisPlayerInfo player) {
    final platformIcon =
        player.platform == 'chesscom' ? Icons.language : Icons.bolt;
    final platformColor =
        player.platform == 'chesscom' ? Colors.green : Colors.blue;

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
                      player.username,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${player.gameCount} games · ${player.platformDisplayName}'
                      ' · ${player.rangeDescription}',
                      style: TextStyle(fontSize: 14, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Downloaded ${player.downloadTimeAgo}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[500]),
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
                      _deletePlayer(player);
                    case 'redownload':
                      _redownloadPlayer(player);
                    case 'redownload_custom':
                      _redownloadPlayerCustom(player);
                  }
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(
                    value: 'redownload',
                    child: Row(
                      children: [
                        Icon(Icons.refresh, size: 20),
                        SizedBox(width: 12),
                        Text('Re-download'),
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
                  PopupMenuItem(
                    value: 'delete',
                    child: Row(
                      children: [
                        Icon(Icons.delete, size: 20, color: Colors.red),
                        SizedBox(width: 12),
                        Text('Delete', style: TextStyle(color: Colors.red)),
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
        content: Text('Delete all games for ${player.username}?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _gamesService.deletePlayerData(
        player.platform,
        player.username,
      );
      await _loadCachedPlayers();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted games for ${player.username}')),
        );
      }
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
      ),
    );

    if (result != null && mounted) {
      await _downloadGames(result);
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
      await _downloadGames(result);
    }
  }

  // ── Download with live progress ──────────────────────────────────

  Future<void> _downloadGames(AnalysisPlayerInfo config) async {
    final progress = ValueNotifier<String>('Downloading games…');

    // Show a non-dismissible progress dialog.
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: ValueListenableBuilder<String>(
            valueListenable: progress,
            builder: (_, message, __) => Column(
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
    );

    try {
      final String pgns;

      if (config.platform == 'chesscom') {
        pgns = await _gamesService.downloadChesscomGames(
          config.username,
          maxGames: config.maxGames,
          monthsBack: config.monthsBack,
          onProgress: (msg) => progress.value = msg,
        );
      } else {
        pgns = await _gamesService.downloadLichessGames(
          config.username,
          maxGames: config.maxGames,
          monthsBack: config.monthsBack,
          onProgress: (msg) => progress.value = msg,
        );
      }

      if (pgns.isEmpty) {
        if (mounted) {
          Navigator.of(context).pop(); // close progress dialog
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('No games found for ${config.username}'),
            ),
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
      );

      await _loadCachedPlayers();

      if (mounted) {
        Navigator.of(context).pop(); // close progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Downloaded games for ${config.username}'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // close progress dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}
