/// Typed model for analysis player download metadata.
library;

/// Replaces the loose [Map<String, dynamic>] previously passed between screens.
///
/// Two download modes:
///   • **Game-count mode** ([monthsBack] is `null`): download up to [maxGames].
///   • **Months mode** ([monthsBack] is set): download all games from the
///     last N months.
class AnalysisPlayerInfo {
  final String platform;
  final String username;
  final int maxGames;

  /// When non-null the download fetches all games from the last [monthsBack]
  /// months instead of limiting by [maxGames].
  final int? monthsBack;

  final DateTime? downloadedAt;
  final int gameCount;

  const AnalysisPlayerInfo({
    required this.platform,
    required this.username,
    this.maxGames = 100,
    this.monthsBack,
    this.downloadedAt,
    this.gameCount = 0,
  });

  /// Whether the download is/was limited by calendar months.
  bool get isMonthsMode => monthsBack != null;

  /// Human-readable platform name.
  String get platformDisplayName =>
      platform == 'chesscom' ? 'Chess.com' : 'Lichess';

  /// Unique key used for file-system storage.
  String get playerKey => '${platform}_${username.toLowerCase()}';

  /// Human-readable description of the download range.
  String get rangeDescription {
    if (isMonthsMode) {
      return 'last $monthsBack month${monthsBack == 1 ? '' : 's'}';
    }
    return 'last $maxGames game${maxGames == 1 ? '' : 's'}';
  }

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
        'monthsBack': monthsBack,
        'downloadedAt': downloadedAt?.toIso8601String(),
        'gameCount': gameCount,
      };

  factory AnalysisPlayerInfo.fromJson(Map<String, dynamic> json) {
    return AnalysisPlayerInfo(
      platform: json['platform'] as String? ?? 'unknown',
      username: json['username'] as String? ?? 'unknown',
      maxGames: json['maxGames'] as int? ?? 100,
      monthsBack: json['monthsBack'] as int?,
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
    int? monthsBack,
    bool clearMonthsBack = false,
    DateTime? downloadedAt,
    int? gameCount,
  }) {
    return AnalysisPlayerInfo(
      platform: platform ?? this.platform,
      username: username ?? this.username,
      maxGames: maxGames ?? this.maxGames,
      monthsBack: clearMonthsBack ? null : (monthsBack ?? this.monthsBack),
      downloadedAt: downloadedAt ?? this.downloadedAt,
      gameCount: gameCount ?? this.gameCount,
    );
  }
}
