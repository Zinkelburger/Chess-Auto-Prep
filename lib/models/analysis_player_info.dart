/// Typed model for analysis player download metadata.
library;
/// Replaces the loose [Map<String, dynamic>] previously passed between screens.

class AnalysisPlayerInfo {
  final String platform;
  final String username;
  final int maxGames;
  final DateTime? downloadedAt;
  final int gameCount;

  const AnalysisPlayerInfo({
    required this.platform,
    required this.username,
    this.maxGames = 100,
    this.downloadedAt,
    this.gameCount = 0,
  });

  /// Human-readable platform name.
  String get platformDisplayName =>
      platform == 'chesscom' ? 'Chess.com' : 'Lichess';

  /// Unique key used for file-system storage.
  String get playerKey => '${platform}_${username.toLowerCase()}';

  /// Human-readable time since the games were downloaded.
  String get downloadTimeAgo {
    if (downloadedAt == null) return 'Unknown';
    final diff = DateTime.now().difference(downloadedAt!);
    if (diff.inDays > 0) return '${diff.inDays}d ago';
    if (diff.inHours > 0) return '${diff.inHours}h ago';
    return '${diff.inMinutes}m ago';
  }

  // ── Serialisation ──────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
        'platform': platform,
        'username': username,
        'maxGames': maxGames,
        'downloadedAt': downloadedAt?.toIso8601String(),
        'gameCount': gameCount,
      };

  factory AnalysisPlayerInfo.fromJson(Map<String, dynamic> json) {
    return AnalysisPlayerInfo(
      platform: json['platform'] as String? ?? 'unknown',
      username: json['username'] as String? ?? 'unknown',
      maxGames: json['maxGames'] as int? ?? 100,
      downloadedAt: json['downloadedAt'] != null
          ? DateTime.tryParse(json['downloadedAt'] as String)
          : null,
      gameCount: json['gameCount'] as int? ?? 0,
    );
  }

  AnalysisPlayerInfo copyWith({
    String? platform,
    String? username,
    int? maxGames,
    DateTime? downloadedAt,
    int? gameCount,
  }) {
    return AnalysisPlayerInfo(
      platform: platform ?? this.platform,
      username: username ?? this.username,
      maxGames: maxGames ?? this.maxGames,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      gameCount: gameCount ?? this.gameCount,
    );
  }
}
