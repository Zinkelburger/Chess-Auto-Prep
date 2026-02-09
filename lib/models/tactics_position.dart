/// TacticsPosition model - fully compatible with Python's TacticsPosition
class TacticsPosition {
  final String fen;
  final String userMove;           // The move the user actually played (mistake)
  final List<String> correctLine;  // The correct continuation moves
  final String mistakeType;        // "?" or "??" or "?!"
  final String mistakeAnalysis;    // Full analysis from Lichess
  final String positionContext;    // "Move X, Color to play"
  final String gameWhite;
  final String gameBlack;
  final String gameResult;
  final String gameDate;
  final String gameId;
  final String gameUrl;
  final DateTime? lastReviewed;
  final int reviewCount;           // Number of times reviewed
  final int successCount;          // Number of times solved correctly
  final double timeToSolve;        // Time taken to solve (seconds)
  final int hintsUsed;             // Number of hints used
  final String opponentBestResponse; // Opponent's best reply after user's bad move

  const TacticsPosition({
    required this.fen,
    required this.userMove,
    required this.correctLine,
    required this.mistakeType,
    required this.mistakeAnalysis,
    required this.positionContext,
    required this.gameWhite,
    required this.gameBlack,
    required this.gameResult,
    required this.gameDate,
    required this.gameId,
    this.gameUrl = '',
    this.lastReviewed,
    this.reviewCount = 0,
    this.successCount = 0,
    this.timeToSolve = 0.0,
    this.hintsUsed = 0,
    this.opponentBestResponse = '',
  });

  /// Create a copy with selected fields overridden.
  TacticsPosition copyWith({
    String? fen,
    String? userMove,
    List<String>? correctLine,
    String? mistakeType,
    String? mistakeAnalysis,
    String? positionContext,
    String? gameWhite,
    String? gameBlack,
    String? gameResult,
    String? gameDate,
    String? gameId,
    String? gameUrl,
    DateTime? lastReviewed,
    bool clearLastReviewed = false,
    int? reviewCount,
    int? successCount,
    double? timeToSolve,
    int? hintsUsed,
    String? opponentBestResponse,
  }) {
    return TacticsPosition(
      fen: fen ?? this.fen,
      userMove: userMove ?? this.userMove,
      correctLine: correctLine ?? this.correctLine,
      mistakeType: mistakeType ?? this.mistakeType,
      mistakeAnalysis: mistakeAnalysis ?? this.mistakeAnalysis,
      positionContext: positionContext ?? this.positionContext,
      gameWhite: gameWhite ?? this.gameWhite,
      gameBlack: gameBlack ?? this.gameBlack,
      gameResult: gameResult ?? this.gameResult,
      gameDate: gameDate ?? this.gameDate,
      gameId: gameId ?? this.gameId,
      gameUrl: gameUrl ?? this.gameUrl,
      lastReviewed: clearLastReviewed ? null : (lastReviewed ?? this.lastReviewed),
      reviewCount: reviewCount ?? this.reviewCount,
      successCount: successCount ?? this.successCount,
      timeToSolve: timeToSolve ?? this.timeToSolve,
      hintsUsed: hintsUsed ?? this.hintsUsed,
      opponentBestResponse: opponentBestResponse ?? this.opponentBestResponse,
    );
  }

  /// Calculate success rate for this position - matches Python property
  double get successRate => reviewCount > 0 ? successCount / reviewCount : 0.0;

  /// Get the best move (first move in correct line) - for backward compatibility
  String get bestMove => correctLine.isNotEmpty ? correctLine.first : 'unknown';

  // Legacy getters for backward compatibility
  String get description => mistakeType == '??'
      ? 'Fix the blunder - find the best move'
      : 'Improve on the mistake - find the best move';
  String get gameSource => '$gameWhite vs $gameBlack';
  int get moveNumber => _extractMoveNumber(positionContext);
  String get playerToMove => positionContext.contains('White') ? 'white' : 'black';

  int _extractMoveNumber(String context) {
    final match = RegExp(r'Move (\d+)').firstMatch(context);
    return match != null ? int.tryParse(match.group(1)!) ?? 1 : 1;
  }

  /// CSV column count.  Old files may have 17; current format has 18.
  static const int csvColumnCount = 18;

  /// Create from CSV row (18 columns; tolerates legacy 17-column rows).
  factory TacticsPosition.fromCsv(List<dynamic> row) {
    if (row.length < 17) {
      throw ArgumentError('Not enough CSV values for TacticsPosition (need ≥17, got ${row.length})');
    }

    return TacticsPosition(
      fen: row[0].toString(),
      gameWhite: row[1].toString(),
      gameBlack: row[2].toString(),
      gameResult: row[3].toString(),
      gameDate: row[4].toString(),
      gameId: row[5].toString(),
      gameUrl: row[6].toString(),
      positionContext: row[7].toString(),
      userMove: row[8].toString(),
      correctLine: row[9].toString().split('|').where((s) => s.isNotEmpty).toList(),
      mistakeType: row[10].toString(),
      mistakeAnalysis: row[11].toString(),
      reviewCount: int.tryParse(row[12].toString()) ?? 0,
      successCount: int.tryParse(row[13].toString()) ?? 0,
      lastReviewed: row[14].toString().isNotEmpty
          ? DateTime.tryParse(row[14].toString())
          : null,
      timeToSolve: double.tryParse(row[15].toString()) ?? 0.0,
      hintsUsed: int.tryParse(row[16].toString()) ?? 0,
      // Column 17 — added after initial 17-col format; tolerate old files.
      opponentBestResponse: row.length > 17 ? row[17].toString() : '',
    );
  }

  /// Create from JSON - for backward compatibility with Lichess import
  factory TacticsPosition.fromJson(Map<String, dynamic> json) {
    final correctLine = json['correct_line'] is String
        ? (json['correct_line'] as String).split('|').where((s) => s.isNotEmpty).toList()
        : (json['correct_line'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [];

    return TacticsPosition(
      fen: json['fen'] as String,
      userMove: json['user_move'] ?? '',
      correctLine: correctLine,
      mistakeType: json['mistake_type'] ?? '?',
      mistakeAnalysis: json['mistake_analysis'] ?? json['description'] ?? '',
      positionContext: json['position_context'] ?? 'Move 1, White to play',
      gameWhite: json['game_white'] ?? json['game_source']?.split(' vs ')?.first ?? '',
      gameBlack: json['game_black'] ?? json['game_source']?.split(' vs ')?.last ?? '',
      gameResult: json['game_result'] ?? '*',
      gameDate: json['game_date'] ?? '',
      gameId: json['game_id'] ?? '',
      gameUrl: json['game_url'] ?? '',
      lastReviewed: json['last_reviewed'] != null ? DateTime.tryParse(json['last_reviewed']) : null,
      reviewCount: json['review_count'] as int? ?? 0,
      successCount: json['success_count'] as int? ?? 0,
      timeToSolve: json['time_to_solve'] as double? ?? 0.0,
      hintsUsed: json['hints_used'] as int? ?? 0,
      opponentBestResponse: json['opponent_best_response'] as String? ?? '',
    );
  }

  /// Convert to JSON - includes all fields
  Map<String, dynamic> toJson() {
    return {
      'fen': fen,
      'user_move': userMove,
      'correct_line': correctLine,
      'mistake_type': mistakeType,
      'mistake_analysis': mistakeAnalysis,
      'position_context': positionContext,
      'game_white': gameWhite,
      'game_black': gameBlack,
      'game_result': gameResult,
      'game_date': gameDate,
      'game_id': gameId,
      'game_url': gameUrl,
      'last_reviewed': lastReviewed?.toIso8601String(),
      'review_count': reviewCount,
      'success_count': successCount,
      'time_to_solve': timeToSolve,
      'hints_used': hintsUsed,
      'opponent_best_response': opponentBestResponse,
    };
  }

  /// Convert to CSV row - matches Python's CSV format
  List<dynamic> toCsvRow() {
    return [
      fen,
      gameWhite,
      gameBlack,
      gameResult,
      gameDate,
      gameId,
      gameUrl,
      positionContext,
      userMove,
      correctLine.join('|'),
      mistakeType,
      mistakeAnalysis,
      reviewCount,
      successCount,
      lastReviewed?.toIso8601String() ?? '',
      timeToSolve,
      hintsUsed,
      opponentBestResponse,
    ];
  }
}
