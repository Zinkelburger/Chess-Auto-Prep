import '../../../utils/fen_utils.dart';
import 'tactics_note.dart';

/// TacticsPosition model - fully compatible with Python's TacticsPosition
class TacticsPosition {
  final String fen;
  final String userMove; // The move the user actually played (mistake)
  final List<String> correctLine; // Trainable line (tactical plies only)
  final List<String> solutionPv; // Longer engine PV for display (Show Solution)
  final String mistakeType; // "?" or "??" or "?!"
  final String mistakeAnalysis; // Full analysis from Lichess

  /// Which study variation this card was cut from ("Variation 3"), for
  /// puzzles decoded out of a study PGN. Empty for mined and custom puzzles.
  /// It is the only part of [positionContext] the FEN cannot supply.
  final String variationLabel;
  final String gameWhite;
  final String gameBlack;
  final String gameResult;
  final String gameDate;
  final String gameId;
  final String gameUrl;

  /// Full source-game mainline as numbered movetext (e.g. "1. e4 e5 2. Nf3 …"),
  /// captured at mine time so the analysis tab can show the whole game even
  /// after the source game is pruned from storage. Empty for legacy tactics
  /// mined before this was captured, and for custom / variation puzzles.
  final String sourceMovetext;
  final DateTime? lastReviewed;
  final int reviewCount; // Number of times reviewed
  final int successCount; // Number of times solved correctly
  final double timeToSolve; // Time taken to solve (seconds)
  final int hintsUsed; // Number of hints used
  final String
  opponentBestResponse; // Opponent's best reply after user's bad move
  final int rating; // 0 = unrated, 1–5 star quality rating

  /// Flaw attribution tags computed at mine time (see FlawTagger): at most
  /// one each of impact (reversed/squandered), opportunity (miss/lucky),
  /// phase (opening/middlegame/endgame) and tempo (low-clock/hasty/
  /// unrushed).  Tempo is absent — not `unrushed` — when the source game
  /// carried no clock data.  Empty for legacy and custom puzzles.
  final List<String> flawTags;

  const TacticsPosition({
    required this.fen,
    required this.userMove,
    required this.correctLine,
    this.solutionPv = const [],
    required this.mistakeType,
    required this.mistakeAnalysis,
    this.variationLabel = '',
    required this.gameWhite,
    required this.gameBlack,
    required this.gameResult,
    required this.gameDate,
    required this.gameId,
    this.gameUrl = '',
    this.sourceMovetext = '',
    this.lastReviewed,
    this.reviewCount = 0,
    this.successCount = 0,
    this.timeToSolve = 0.0,
    this.hintsUsed = 0,
    this.opponentBestResponse = '',
    this.rating = 0,
    this.flawTags = const [],
  });

  /// Create a copy with selected fields overridden.
  TacticsPosition copyWith({
    String? fen,
    String? userMove,
    List<String>? correctLine,
    List<String>? solutionPv,
    String? mistakeType,
    String? mistakeAnalysis,
    String? variationLabel,
    String? gameWhite,
    String? gameBlack,
    String? gameResult,
    String? gameDate,
    String? gameId,
    String? gameUrl,
    String? sourceMovetext,
    DateTime? lastReviewed,
    bool clearLastReviewed = false,
    int? reviewCount,
    int? successCount,
    double? timeToSolve,
    int? hintsUsed,
    String? opponentBestResponse,
    int? rating,
    List<String>? flawTags,
  }) {
    return TacticsPosition(
      fen: fen ?? this.fen,
      userMove: userMove ?? this.userMove,
      correctLine: correctLine ?? this.correctLine,
      solutionPv: solutionPv ?? this.solutionPv,
      mistakeType: mistakeType ?? this.mistakeType,
      mistakeAnalysis: mistakeAnalysis ?? this.mistakeAnalysis,
      variationLabel: variationLabel ?? this.variationLabel,
      gameWhite: gameWhite ?? this.gameWhite,
      gameBlack: gameBlack ?? this.gameBlack,
      gameResult: gameResult ?? this.gameResult,
      gameDate: gameDate ?? this.gameDate,
      gameId: gameId ?? this.gameId,
      gameUrl: gameUrl ?? this.gameUrl,
      sourceMovetext: sourceMovetext ?? this.sourceMovetext,
      lastReviewed: clearLastReviewed
          ? null
          : (lastReviewed ?? this.lastReviewed),
      reviewCount: reviewCount ?? this.reviewCount,
      successCount: successCount ?? this.successCount,
      timeToSolve: timeToSolve ?? this.timeToSolve,
      hintsUsed: hintsUsed ?? this.hintsUsed,
      opponentBestResponse: opponentBestResponse ?? this.opponentBestResponse,
      rating: rating ?? this.rating,
      flawTags: flawTags ?? this.flawTags,
    );
  }

  /// Calculate success rate for this position - matches Python property
  double get successRate => reviewCount > 0 ? successCount / reviewCount : 0.0;

  /// [gameDate] (PGN `YYYY.MM.DD`) parsed as a date, or `null` when absent
  /// or a placeholder like `????.??.??`.
  DateTime? get gameDateTime {
    final match = RegExp(
      r'^(\d{4})\.(\d{2})\.(\d{2})$',
    ).firstMatch(gameDate.trim());
    if (match == null) return null;
    final year = int.parse(match.group(1)!);
    final month = int.parse(match.group(2)!);
    final day = int.parse(match.group(3)!);
    if (month < 1 || month > 12 || day < 1 || day > 31) return null;
    return DateTime(year, month, day);
  }

  /// Get the best move (first move in correct line) - for backward compatibility
  String get bestMove => correctLine.isNotEmpty ? correctLine.first : 'unknown';

  // Legacy getters for backward compatibility
  String get description => switch (mistakeType) {
    '??' => 'Fix the blunder - find the best move',
    '?!' => 'Correct the inaccuracy - find the best move',
    'custom' => 'Find the best move',
    _ => 'Improve on the mistake - find the best move',
  };
  String get gameSource => '$gameWhite vs $gameBlack';

  /// The severity of a mined mistake in words. `??` / `?` / `?!` are notation
  /// a reader has to decode; the word is the same information without the
  /// decode step. Empty for custom puzzles, which record no severity.
  String get mistakeLabel => switch (mistakeType) {
    '??' => 'blunder',
    '?' => 'mistake',
    '?!' => 'inaccuracy',
    _ => '',
  };

  /// Where on the board this puzzle sits. All three read the FEN, which is
  /// the position — they used to re-parse an English sentence built from it
  /// ("Move 12, White to play"), so a puzzle could describe itself wrongly.
  int get moveNumber => fullMoveNumber(fen);
  bool get whiteToPlay => isWhiteToMove(fen);
  String get playerToMove => whiteToPlay ? 'white' : 'black';

  /// Human-readable location, e.g. "Move 12, White to play" — prefixed with
  /// [variationLabel] for study cards.
  String get positionContext {
    final where =
        'Move $moveNumber, ${whiteToPlay ? 'White' : 'Black'} to play';
    return variationLabel.isEmpty ? where : '$variationLabel — $where';
  }

  /// Where this card came from, as one caption line: "Move 12 · Alice vs Bob"
  /// (or "Variation 3 · Move 12" for a study card, which has no players).
  ///
  /// Deliberately *not* [positionContext]: the side to move is the task, shown
  /// as the card's heading, and repeating it here would say it twice.
  String get provenanceLine {
    final parts = <String>[
      if (variationLabel.isNotEmpty) variationLabel,
      'Move $moveNumber',
      if (gameWhite.isNotEmpty || gameBlack.isNotEmpty)
        '$gameWhite vs $gameBlack',
    ];
    return parts.join(' · ');
  }

  /// CSV column count.  Old files may have 17–21; current format has 22.
  static const int csvColumnCount = 22;

  /// Create from CSV row (18 columns; tolerates legacy 17-column rows).
  factory TacticsPosition.fromCsv(List<dynamic> row) {
    if (row.length < 17) {
      throw ArgumentError(
        'Not enough CSV values for TacticsPosition (need ≥17, got ${row.length})',
      );
    }

    return TacticsPosition(
      fen: row[0].toString(),
      gameWhite: row[1].toString(),
      gameBlack: row[2].toString(),
      gameResult: row[3].toString(),
      gameDate: row[4].toString(),
      gameId: row[5].toString(),
      gameUrl: row[6].toString(),
      // Column 7 held the "Move X, Colour to play" sentence, which is read
      // off the FEN in column 0 now — skipped rather than trusted.
      userMove: row[8].toString(),
      correctLine: row[9]
          .toString()
          .split('|')
          .where((s) => s.isNotEmpty)
          .toList(),
      mistakeType: row[10].toString(),
      mistakeAnalysis: TacticsNote.canonicalize(row[11].toString()),
      reviewCount: int.tryParse(row[12].toString()) ?? 0,
      successCount: int.tryParse(row[13].toString()) ?? 0,
      lastReviewed: row[14].toString().isNotEmpty
          ? DateTime.tryParse(row[14].toString())
          : null,
      timeToSolve: double.tryParse(row[15].toString()) ?? 0.0,
      hintsUsed: int.tryParse(row[16].toString()) ?? 0,
      // Column 17 — added after initial 17-col format; tolerate old files.
      opponentBestResponse: row.length > 17 ? row[17].toString() : '',
      // Column 18 — star rating; tolerate pre-rating files.
      rating: row.length > 18 ? (int.tryParse(row[18].toString()) ?? 0) : 0,
      // Column 19 — full PV for display; tolerate pre-PV files.
      solutionPv: row.length > 19
          ? row[19].toString().split('|').where((s) => s.isNotEmpty).toList()
          : const [],
      // Column 20 — source-game movetext; tolerate pre-source-game files.
      sourceMovetext: row.length > 20 ? row[20].toString() : '',
      // Column 21 — flaw attribution tags; tolerate pre-tag files.
      flawTags: row.length > 21
          ? row[21].toString().split('|').where((s) => s.isNotEmpty).toList()
          : const [],
    );
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
      rating,
      solutionPv.join('|'),
      sourceMovetext,
      flawTags.join('|'),
    ];
  }
}
