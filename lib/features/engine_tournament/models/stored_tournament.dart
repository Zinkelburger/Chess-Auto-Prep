/// A tournament as it lives on disk: the config it was started with, the
/// games played so far, and where the PGN is.
library;

import 'tournament_config.dart';
import 'tournament_game.dart';

enum TournamentStatus { pending, running, completed, cancelled, failed }

extension TournamentStatusLabel on TournamentStatus {
  String get label => switch (this) {
    TournamentStatus.pending => 'Not started',
    TournamentStatus.running => 'Running',
    TournamentStatus.completed => 'Completed',
    TournamentStatus.cancelled => 'Stopped',
    TournamentStatus.failed => 'Failed',
  };

  bool get isTerminal => switch (this) {
    TournamentStatus.completed ||
    TournamentStatus.cancelled ||
    TournamentStatus.failed => true,
    _ => false,
  };
}

class StoredTournament {
  const StoredTournament({
    required this.id,
    required this.directoryPath,
    required this.pgnPath,
    required this.config,
    required this.createdAt,
    required this.status,
    this.games = const [],
    this.finishedAt,
    this.error,
  });

  /// Directory name under the tournaments root; also the identity used by the
  /// controller and by breadcrumb re-delivery.
  final String id;

  final String directoryPath;

  /// The collection the PGN Viewer opens. One game per schedule slot, in
  /// schedule order, so a row's game number is its position in the viewer.
  final String pgnPath;

  final TournamentConfig config;
  final DateTime createdAt;
  final DateTime? finishedAt;
  final TournamentStatus status;
  final List<TournamentGameRecord> games;

  /// Set when [status] is [TournamentStatus.failed].
  final String? error;

  int get gamesPlayed => games.length;
  int get gamesTotal => config.totalGames;

  double get progress =>
      gamesTotal == 0 ? 0 : (gamesPlayed / gamesTotal).clamp(0, 1);

  StoredTournament copyWith({
    TournamentStatus? status,
    List<TournamentGameRecord>? games,
    DateTime? finishedAt,
    Object? error = _unset,
    TournamentConfig? config,
  }) => StoredTournament(
    id: id,
    directoryPath: directoryPath,
    pgnPath: pgnPath,
    config: config ?? this.config,
    createdAt: createdAt,
    status: status ?? this.status,
    games: games ?? this.games,
    finishedAt: finishedAt ?? this.finishedAt,
    error: error == _unset ? this.error : error as String?,
  );

  static const Object _unset = Object();

  Map<String, dynamic> toJson() => {
    'version': 1,
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    if (finishedAt != null) 'finishedAt': finishedAt!.toIso8601String(),
    'status': status.name,
    if (error != null) 'error': error,
    'config': config.toJson(),
    'games': games.map((g) => g.toJson()).toList(),
  };

  factory StoredTournament.fromJson(
    Map<String, dynamic> json, {
    required String directoryPath,
    required String pgnPath,
  }) => StoredTournament(
    id: json['id'] as String? ?? '',
    directoryPath: directoryPath,
    pgnPath: pgnPath,
    config: TournamentConfig.fromJson(
      Map<String, dynamic>.from(json['config'] as Map? ?? const {}),
    ),
    createdAt:
        DateTime.tryParse(json['createdAt'] as String? ?? '') ??
        DateTime.fromMillisecondsSinceEpoch(0),
    finishedAt: DateTime.tryParse(json['finishedAt'] as String? ?? ''),
    status: TournamentStatus.values.firstWhere(
      (s) => s.name == json['status'],
      // A run interrupted by a crash or a quit is stale, not still running.
      orElse: () => TournamentStatus.cancelled,
    ),
    error: json['error'] as String?,
    games:
        (json['games'] as List?)
            ?.map(
              (g) => TournamentGameRecord.fromJson(
                Map<String, dynamic>.from(g as Map),
              ),
            )
            .toList() ??
        const [],
  );
}
