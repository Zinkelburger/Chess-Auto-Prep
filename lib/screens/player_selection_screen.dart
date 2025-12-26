/// Player selection screen for analysis
/// Shows all cached player game sets and allows selecting or downloading new ones

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../core/app_state.dart';
import '../services/analysis_games_service.dart';
import '../widgets/analysis_download_dialog.dart';

class PlayerSelectionScreen extends StatefulWidget {
  const PlayerSelectionScreen({super.key});

  @override
  State<PlayerSelectionScreen> createState() => _PlayerSelectionScreenState();
}

class _PlayerSelectionScreenState extends State<PlayerSelectionScreen> {
  final AnalysisGamesService _gamesService = AnalysisGamesService();
  List<Map<String, dynamic>> _cachedPlayers = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadCachedPlayers();
  }

  Future<void> _loadCachedPlayers() async {
    setState(() => _isLoading = true);
    final players = await _gamesService.getAllCachedPlayers();
    setState(() {
      _cachedPlayers = players;
      _isLoading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Select Player to Analyze'),
      ),
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
            Icon(
              Icons.person_search,
              size: 64,
              color: Colors.grey[400],
            ),
            const SizedBox(height: 24),
            Text(
              'No Players Downloaded',
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 8),
            Text(
              'Download games for a player to get started',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.grey[600],
                  ),
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
      itemBuilder: (context, index) {
        final player = _cachedPlayers[index];
        return _buildPlayerCard(player);
      },
    );
  }

  Widget _buildPlayerCard(Map<String, dynamic> player) {
    final platform = player['platform'] as String? ?? 'Unknown';
    final username = player['username'] as String? ?? 'Unknown';
    final gameCount = player['gameCount'] as int? ?? 0;
    final downloadedAt = player['downloadedAt'] as String?;

    final platformName = platform == 'chesscom' ? 'Chess.com' : 'Lichess';
    final platformIcon = platform == 'chesscom' ? Icons.language : Icons.bolt;
    final platformColor = platform == 'chesscom' ? Colors.green : Colors.blue;

    String timeAgo = 'Unknown';
    if (downloadedAt != null) {
      try {
        final downloaded = DateTime.parse(downloadedAt);
        final difference = DateTime.now().difference(downloaded);

        if (difference.inDays > 0) {
          timeAgo = '${difference.inDays}d ago';
        } else if (difference.inHours > 0) {
          timeAgo = '${difference.inHours}h ago';
        } else {
          timeAgo = '${difference.inMinutes}m ago';
        }
      } catch (e) {
        // Keep default
      }
    }

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _selectPlayer(player),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Platform icon
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: platformColor.withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(
                  platformIcon,
                  color: platformColor,
                  size: 32,
                ),
              ),
              const SizedBox(width: 16),

              // Player info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      username,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '$gameCount games • $platformName',
                      style: TextStyle(
                        fontSize: 14,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Downloaded $timeAgo',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.grey[500],
                      ),
                    ),
                  ],
                ),
              ),

              // Actions
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert),
                onSelected: (value) {
                  if (value == 'delete') {
                    _deletePlayer(player);
                  } else if (value == 'redownload') {
                    _redownloadPlayer(player);
                  } else if (value == 'redownload_custom') {
                    _redownloadPlayerCustom(player);
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'redownload',
                    child: Row(
                      children: [
                        Icon(Icons.refresh, size: 20),
                        SizedBox(width: 12),
                        Text('Re-download'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
                    value: 'redownload_custom',
                    child: Row(
                      children: [
                        Icon(Icons.settings, size: 20),
                        SizedBox(width: 12),
                        Text('Re-download (custom)'),
                      ],
                    ),
                  ),
                  const PopupMenuItem(
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

  void _selectPlayer(Map<String, dynamic> player) {
    // Return the selected player to the previous screen
    Navigator.of(context).pop(player);
  }

  Future<void> _deletePlayer(Map<String, dynamic> player) async {
    final platform = player['platform'] as String;
    final username = player['username'] as String;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Games'),
        content: Text('Delete all games for $username?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await _gamesService.deleteAnalysisGames(platform, username);
      await _loadCachedPlayers();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Deleted games for $username')),
        );
      }
    }
  }

  Future<void> _redownloadPlayer(Map<String, dynamic> player) async {
    final platform = player['platform'] as String;
    final username = player['username'] as String;
    final maxGames = player['maxGames'] as int? ?? player['gameCount'] as int? ?? 100;

    // Re-download with same settings (no confirmation needed)
    await _downloadGames(platform, username, maxGames);
  }

  Future<void> _redownloadPlayerCustom(Map<String, dynamic> player) async {
    final platform = player['platform'] as String;
    final username = player['username'] as String;

    // Show download dialog with pre-filled username
    final appState = context.read<AppState>();

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AnalysisDownloadDialog(
        chesscomUsername: platform == 'chesscom' ? username : appState.chesscomUsername,
        lichessUsername: platform == 'lichess' ? username : appState.lichessUsername,
      ),
    );

    if (result != null && mounted) {
      final newPlatform = result['platform'] as String;
      final newUsername = result['username'] as String;
      final newMaxGames = result['maxGames'] as int;

      // Download with new settings
      await _downloadGames(newPlatform, newUsername, newMaxGames);
    }
  }

  Future<void> _showDownloadDialog() async {
    final appState = context.read<AppState>();

    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AnalysisDownloadDialog(
        chesscomUsername: appState.chesscomUsername,
        lichessUsername: appState.lichessUsername,
      ),
    );

    if (result != null && mounted) {
      final platform = result['platform'] as String;
      final username = result['username'] as String;
      final maxGames = result['maxGames'] as int;

      // Download the games
      await _downloadGames(platform, username, maxGames);
    }
  }

  Future<void> _downloadGames(String platform, String username, int maxGames) async {
    // Show loading dialog
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => const AlertDialog(
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(),
            SizedBox(height: 16),
            Text('Downloading games...'),
          ],
        ),
      ),
    );

    try {
      String pgns;

      if (platform == 'chesscom') {
        pgns = await _gamesService.downloadChesscomGames(
          username,
          maxGames: maxGames,
        );
      } else {
        pgns = await _gamesService.downloadLichessGames(
          username,
          maxGames: maxGames,
        );
      }

      if (pgns.isEmpty) {
        if (mounted) {
          Navigator.of(context).pop(); // Close loading dialog
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('No games found for $username')),
          );
        }
        return;
      }

      // Save games to disk
      await _gamesService.saveAnalysisGames(pgns, platform, username, maxGames);

      // Reload player list
      await _loadCachedPlayers();

      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Downloaded games for $username')),
        );
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // Close loading dialog
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    }
  }
}
