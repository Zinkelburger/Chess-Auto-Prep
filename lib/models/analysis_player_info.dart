/// Typed model for analysis player download metadata.
library;

import '../utils/time_format.dart';

/// Replaces the loose [Map<String, dynamic>] previously passed between screens.
///
/// Two download modes:
///   • **Game-count mode** ([monthsBack] is `null`): download up to [maxGames].
///   • **Months mode** ([monthsBack] is set): download all games from the
///     last N months.
///
/// A third source is local PGN files ([platform] == 'import'), where the
/// games were imported rather than downloaded and no range applies.
///
/// A fourth is an *opponent* built from an opponent list: also stored under
/// `'import'` (one merged game-set, so the analysis sees one person), but with
/// [accounts] recording the online accounts the games came from so the set
/// can be re-downloaded, and [group] naming the event it belongs to.
class AnalysisPlayerInfo {
  final String platform;
  final String username;
  final int maxGames;

  /// Online accounts this game-set was downloaded from, when it merges more
  /// than one (or one, under a real name). Empty for a plain download or a
  /// PGN-file import.
  final List<PlayerAccount> accounts;

  /// The event or list this player was imported as part of, if any — shown
  /// and searchable in the picker so a whole tournament field is easy to
  /// find and remove together.
  final String? group;

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
    this.accounts = const [],
    this.group,
  });

  /// Whether the download is/was limited by calendar months.
  bool get isMonthsMode => monthsBack != null;

  /// True when the games came from local PGN files instead of a download.
  bool get isImported => platform == 'import';

  /// Whether there is a source to fetch fresh games from: a live platform
  /// account, or the [accounts] an opponent was built from. A PGN-file import
  /// has none.
  bool get canRedownload => !isImported || accounts.isNotEmpty;

  /// The name to show for this player. An opponent's [username] carries every
  /// name the analysis should match (`"Jane Doe; janed; jd_li"`); the first
  /// segment is the person, the rest are their handles.
  String get displayName {
    final first = username.split(';').first.trim();
    return first.isEmpty ? username : first;
  }

  /// Human-readable platform name.
  String get platformDisplayName {
    if (accounts.isNotEmpty) {
      final names = <String>{
        for (final a in accounts) _platformLabel(a.platform),
      };
      return names.join(' + ');
    }
    if (isImported) return 'PGN file';
    return _platformLabel(platform);
  }

  static String _platformLabel(String platform) => switch (platform) {
    'chesscom' => 'Chess.com',
    'lichess' => 'Lichess',
    _ => platform,
  };

  /// Unique key used for file-system storage.
  ///
  /// Free-text names (the 'import' platform) may contain characters that are
  /// invalid or hazardous in filenames (`/` would silently nest the files in
  /// a subdirectory the player list never scans), so everything outside
  /// [a-z0-9_-] is folded to `_`. Chess.com/Lichess usernames are already
  /// limited to that alphabet, so their keys — and existing on-disk data —
  /// are unchanged.
  String get playerKey {
    final safe = username.toLowerCase().replaceAll(RegExp(r'[^a-z0-9_-]'), '_');
    return '${platform}_$safe';
  }

  /// Human-readable description of the download range.
  String get rangeDescription {
    if (isImported && accounts.isEmpty) return 'imported PGN';
    if (isMonthsMode) {
      return 'last $monthsBack month${monthsBack == 1 ? '' : 's'}';
    }
    return 'last $maxGames game${maxGames == 1 ? '' : 's'}';
  }

  /// Human-readable time since the games were downloaded.
  String get downloadTimeAgo =>
      downloadedAt == null ? 'Unknown' : formatTimeAgo(downloadedAt!);

  // ── Serialisation ──────────────────────────────────────────────────

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'username': username,
    'maxGames': maxGames,
    'monthsBack': monthsBack,
    'downloadedAt': downloadedAt?.toIso8601String(),
    'gameCount': gameCount,
    if (accounts.isNotEmpty) 'accounts': [for (final a in accounts) a.toJson()],
    if (group != null && group!.isNotEmpty) 'group': group,
  };

  factory AnalysisPlayerInfo.fromJson(Map<String, dynamic> json) {
    return AnalysisPlayerInfo(
      platform: json['platform'] as String? ?? 'unknown',
      username: json['username'] as String? ?? 'unknown',
      maxGames: (json['maxGames'] as num?)?.toInt() ?? 100,
      monthsBack: (json['monthsBack'] as num?)?.toInt(),
      downloadedAt: json['downloadedAt'] != null
          ? DateTime.tryParse(json['downloadedAt'] as String)
          : null,
      gameCount: (json['gameCount'] as num?)?.toInt() ?? 0,
      accounts: [
        for (final a in (json['accounts'] as List?) ?? const [])
          if (a is Map) PlayerAccount.fromJson(a.cast<String, dynamic>()),
      ],
      group: json['group'] as String?,
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
    List<PlayerAccount>? accounts,
    String? group,
  }) {
    return AnalysisPlayerInfo(
      platform: platform ?? this.platform,
      username: username ?? this.username,
      maxGames: maxGames ?? this.maxGames,
      monthsBack: clearMonthsBack ? null : (monthsBack ?? this.monthsBack),
      downloadedAt: downloadedAt ?? this.downloadedAt,
      gameCount: gameCount ?? this.gameCount,
      accounts: accounts ?? this.accounts,
      group: group ?? this.group,
    );
  }
}

/// One online account: `'chesscom'` or `'lichess'` plus the username.
class PlayerAccount {
  final String platform;
  final String username;

  const PlayerAccount(this.platform, this.username);

  Map<String, dynamic> toJson() => {'platform': platform, 'username': username};

  factory PlayerAccount.fromJson(Map<String, dynamic> json) => PlayerAccount(
    json['platform'] as String? ?? 'chesscom',
    json['username'] as String? ?? '',
  );

  @override
  bool operator ==(Object other) =>
      other is PlayerAccount &&
      other.platform == platform &&
      other.username == username;

  @override
  int get hashCode => Object.hash(platform, username);

  @override
  String toString() => '$platform:$username';
}
