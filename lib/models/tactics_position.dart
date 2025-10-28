class TacticsPosition {
  final String fen;
  final String userMove;           // The move the user actually played (mistake)
  final List<String> correctLine;  // The correct continuation moves
  final String bestMove;           // The single best move in SAN format (e.g., "Qc7")
  final String mistakeType;        // "?" or "??"
  final String mistakeAnalysis;    // Full analysis from Lichess
  final String positionContext;    // "Move X, Color to play"
  final String gameWhite;
  final String gameBlack;
  final String gameResult;
  final String gameDate;
  final String gameId;
  final int difficulty;
  final DateTime? lastReviewed;
  final int reviewCount;
  final double successRate;

  const TacticsPosition({
    required this.fen,
    required this.userMove,
    required this.correctLine,
    required this.bestMove,
    required this.mistakeType,
    required this.mistakeAnalysis,
    required this.positionContext,
    required this.gameWhite,
    required this.gameBlack,
    required this.gameResult,
    required this.gameDate,
    required this.gameId,
    this.difficulty = 0,
    this.lastReviewed,
    this.reviewCount = 0,
    this.successRate = 0.0,
  });

  // Legacy getters for backward compatibility
  String get description => mistakeType == '??'
      ? 'Fix the blunder - find the best move ($bestMove)'
      : 'Improve on the mistake - find the best move ($bestMove)';
  String get gameSource => '$gameWhite vs $gameBlack';
  int get moveNumber => _extractMoveNumber(positionContext);
  String get playerToMove => positionContext.contains('White') ? 'white' : 'black';

  int _extractMoveNumber(String context) {
    final match = RegExp(r'Move (\d+)').firstMatch(context);
    return match != null ? int.tryParse(match.group(1)!) ?? 1 : 1;
  }

  factory TacticsPosition.fromCsv(List<String> values) {
    if (values.length < 16) {
      throw ArgumentError('Not enough CSV values for TacticsPosition');
    }

    return TacticsPosition(
      fen: values[0],
      userMove: values[1],
      correctLine: values[2].split('|').where((s) => s.isNotEmpty).toList(),
      bestMove: values[3],
      mistakeType: values[4],
      mistakeAnalysis: values[5],
      positionContext: values[6],
      gameWhite: values[7],
      gameBlack: values[8],
      gameResult: values[9],
      gameDate: values[10],
      gameId: values[11],
      difficulty: int.tryParse(values[12]) ?? 0,
      lastReviewed: values[13].isNotEmpty ? DateTime.tryParse(values[13]) : null,
      reviewCount: int.tryParse(values[14]) ?? 0,
      successRate: double.tryParse(values[15]) ?? 0.0,
    );
  }

  // Legacy fromJson for backward compatibility
  factory TacticsPosition.fromJson(Map<String, dynamic> json) {
    final correctLine = json['correct_line'] is String
        ? (json['correct_line'] as String).split('|').where((s) => s.isNotEmpty).toList()
        : (json['correct_line'] as List<dynamic>?)?.map((e) => e as String).toList() ?? [];

    return TacticsPosition(
      fen: json['fen'] as String,
      userMove: json['user_move'] ?? json['best_move'] as String,
      correctLine: correctLine,
      bestMove: json['best_move'] ?? (correctLine.isNotEmpty ? correctLine.first : 'unknown'),
      mistakeType: json['mistake_type'] ?? '?',
      mistakeAnalysis: json['mistake_analysis'] ?? json['description'] ?? '',
      positionContext: json['position_context'] ?? 'Move 1, White to play',
      gameWhite: json['game_white'] ?? json['game_source']?.split(' vs ')?.first ?? '',
      gameBlack: json['game_black'] ?? json['game_source']?.split(' vs ')?.last ?? '',
      gameResult: json['game_result'] ?? '*',
      gameDate: json['game_date'] ?? '',
      gameId: json['game_id'] ?? '',
      difficulty: json['difficulty'] as int? ?? 0,
      lastReviewed: json['last_reviewed'] != null ? DateTime.tryParse(json['last_reviewed']) : null,
      reviewCount: json['review_count'] as int? ?? 0,
      successRate: json['success_rate'] as double? ?? 0.0,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'fen': fen,
      'user_move': userMove,
      'correct_line': correctLine,
      'best_move': bestMove,
      'mistake_type': mistakeType,
      'mistake_analysis': mistakeAnalysis,
      'position_context': positionContext,
      'game_white': gameWhite,
      'game_black': gameBlack,
      'game_result': gameResult,
      'game_date': gameDate,
      'game_id': gameId,
      'difficulty': difficulty,
      'last_reviewed': lastReviewed?.toIso8601String(),
      'review_count': reviewCount,
      'success_rate': successRate,
    };
  }
}