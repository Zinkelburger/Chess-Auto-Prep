/// When a game is stopped before the pieces settle it.
///
/// Two engines of similar strength will shuffle a dead-drawn rook ending for
/// two hundred moves and a lost position to bare kings, so every tournament
/// manager adjudicates. The knobs here are cutechess-cli's (`-draw` /
/// `-resign`), with its semantics: a *move* means both sides have moved, and
/// captures and pawn pushes reset the draw counter because the position is
/// no longer the one that looked dead.
library;

class AdjudicationRules {
  const AdjudicationRules({
    this.drawEnabled = true,
    this.drawMoveNumber = 40,
    this.drawMoveCount = 8,
    this.drawScoreCp = 10,
    this.resignEnabled = true,
    this.resignMoveCount = 4,
    this.resignScoreCp = 900,
    this.twoSidedResign = true,
    this.maxMoves = 300,
    this.fiftyMoveRule = true,
    this.threefoldRepetition = true,
  });

  /// Call a draw once both engines agree the position is level.
  final bool drawEnabled;

  /// Earliest full move at which a draw may be called at all.
  final int drawMoveNumber;

  /// Consecutive full moves both scores must stay inside [drawScoreCp].
  final int drawMoveCount;
  final int drawScoreCp;

  /// Stop a game an engine has already resigned itself to.
  final bool resignEnabled;

  /// Consecutive moves by the losing side below `-[resignScoreCp]`.
  final int resignMoveCount;
  final int resignScoreCp;

  /// Also require the *winner* to be that far ahead, so a single engine's
  /// pessimism cannot hand away a game its opponent does not think it wins.
  final bool twoSidedResign;

  /// Hard ceiling in full moves; the game is filed as an unfinished draw.
  final int maxMoves;

  final bool fiftyMoveRule;
  final bool threefoldRepetition;

  static const AdjudicationRules none = AdjudicationRules(
    drawEnabled: false,
    resignEnabled: false,
    maxMoves: 500,
  );

  AdjudicationRules copyWith({
    bool? drawEnabled,
    int? drawMoveNumber,
    int? drawMoveCount,
    int? drawScoreCp,
    bool? resignEnabled,
    int? resignMoveCount,
    int? resignScoreCp,
    bool? twoSidedResign,
    int? maxMoves,
    bool? fiftyMoveRule,
    bool? threefoldRepetition,
  }) => AdjudicationRules(
    drawEnabled: drawEnabled ?? this.drawEnabled,
    drawMoveNumber: drawMoveNumber ?? this.drawMoveNumber,
    drawMoveCount: drawMoveCount ?? this.drawMoveCount,
    drawScoreCp: drawScoreCp ?? this.drawScoreCp,
    resignEnabled: resignEnabled ?? this.resignEnabled,
    resignMoveCount: resignMoveCount ?? this.resignMoveCount,
    resignScoreCp: resignScoreCp ?? this.resignScoreCp,
    twoSidedResign: twoSidedResign ?? this.twoSidedResign,
    maxMoves: maxMoves ?? this.maxMoves,
    fiftyMoveRule: fiftyMoveRule ?? this.fiftyMoveRule,
    threefoldRepetition: threefoldRepetition ?? this.threefoldRepetition,
  );

  Map<String, dynamic> toJson() => {
    'drawEnabled': drawEnabled,
    'drawMoveNumber': drawMoveNumber,
    'drawMoveCount': drawMoveCount,
    'drawScoreCp': drawScoreCp,
    'resignEnabled': resignEnabled,
    'resignMoveCount': resignMoveCount,
    'resignScoreCp': resignScoreCp,
    'twoSidedResign': twoSidedResign,
    'maxMoves': maxMoves,
    'fiftyMoveRule': fiftyMoveRule,
    'threefoldRepetition': threefoldRepetition,
  };

  factory AdjudicationRules.fromJson(Map<String, dynamic> json) =>
      AdjudicationRules(
        drawEnabled: json['drawEnabled'] as bool? ?? true,
        drawMoveNumber: (json['drawMoveNumber'] as num?)?.toInt() ?? 40,
        drawMoveCount: (json['drawMoveCount'] as num?)?.toInt() ?? 8,
        drawScoreCp: (json['drawScoreCp'] as num?)?.toInt() ?? 10,
        resignEnabled: json['resignEnabled'] as bool? ?? true,
        resignMoveCount: (json['resignMoveCount'] as num?)?.toInt() ?? 4,
        resignScoreCp: (json['resignScoreCp'] as num?)?.toInt() ?? 900,
        twoSidedResign: json['twoSidedResign'] as bool? ?? true,
        maxMoves: (json['maxMoves'] as num?)?.toInt() ?? 300,
        fiftyMoveRule: json['fiftyMoveRule'] as bool? ?? true,
        threefoldRepetition: json['threefoldRepetition'] as bool? ?? true,
      );
}
