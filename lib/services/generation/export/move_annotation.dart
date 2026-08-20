/// What the exporter knows about a single move of a generated line.
///
/// The build pipeline computes far more per node than a repertoire PGN
/// historically carried — ease, naturalness, practical scores, how recently a
/// move was seen in real games.  This is the carrier that gets it out of the
/// tree and into the file, so a strong player reading the export can see *why*
/// a move is recommended rather than just that it was.
///
/// Every field is optional: a Maia-only build has no game statistics, an
/// unevaluated coverage leaf has no eval, and the renderer simply omits what
/// is absent instead of inventing a neutral value.
library;

/// Where a move-likelihood number came from.
enum MoveLikelihoodSource {
  /// Maia's predicted human policy.
  maia,

  /// Observed frequency in the user's game database.
  gameDatabase,

  /// Injected from the engine's principal variation because no human source
  /// offered the move.
  engine;

  /// PGN token used for this source's likelihood value.
  String get pgnTag => switch (this) {
    MoveLikelihoodSource.maia => 'maiaProbability',
    MoveLikelihoodSource.gameDatabase => 'humanFrequency',
    MoveLikelihoodSource.engine => 'engineReply',
  };
}

/// How much per-move detail an export carries.
enum MoveAnnotationDetail {
  /// Bare movetext.
  none,

  /// Opponent move likelihood only — the historical default.
  likelihood,

  /// Everything available: eval, ease, practical score, recency.
  full;

  bool get emitsAnything => this != MoveAnnotationDetail.none;
  bool get emitsMetrics => this == MoveAnnotationDetail.full;

  static MoveAnnotationDetail parse(String? name) =>
      MoveAnnotationDetail.values.firstWhere(
        (d) => d.name == name,
        orElse: () => MoveAnnotationDetail.likelihood,
      );

  /// Restore the setting from the two booleans that preceded this enum, so
  /// presets and paused builds saved before the change still load.
  static MoveAnnotationDetail fromLegacyFlags({required bool annotate}) =>
      annotate ? MoveAnnotationDetail.likelihood : MoveAnnotationDetail.none;
}

class MoveAnnotation {
  /// Probability the side to move plays this move, in [0, 1].  Only
  /// meaningful for opponent moves — we choose ours.
  final double? likelihood;

  final MoveLikelihoodSource? likelihoodSource;

  /// Games behind [likelihood] when it came from a database.
  final int? gameCount;

  /// Score our side achieved from here in real games, in [0, 1].  Null when
  /// no game at this move had a recorded result.
  final double? practicalScore;

  /// Engine evaluation after the move, in centipawns from *our* perspective.
  final int? evalCp;

  /// How easily the side to move finds a good move here, in [0, 1].  Low is
  /// good for us: the opponent is likely to go wrong.
  final double? opponentEase;

  /// How natural our move is for a human to find, in [0, 1].
  final double? myEase;

  /// Our move is far enough ahead of every alternative to be effectively
  /// forced — the moves worth extra memorisation effort.
  final bool isOnlyMove;

  /// How far our move leads the best alternative, in centipawns, when
  /// [isOnlyMove].  Null when the lead is unknown (no evaluated sibling at
  /// all, so it is at least the build's eval-loss window).
  final int? onlyMoveLeadCp;

  /// Share of humans (Maia at the build's rating) who find our move here, in
  /// [0, 1].  Unlike [myEase] this is the raw policy, never rounded up for a
  /// forced move — a sole legal-looking move that 3% of players see is still
  /// hard to find.
  final double? humanFrequency;

  /// The move humans would reach for instead of ours, when it is a different
  /// move and noticeably more popular — with how much it gives away.
  final String? naturalAlternativeSan;
  final int? naturalAlternativeLossCp;

  /// For an opponent move: how much it gives away against their best option
  /// here, in centipawns from our perspective, when that is enough to call it
  /// a mistake.  [betterMoveSan] names the option they should have taken.
  final int? mistakeCp;
  final String? betterMoveSan;

  /// This is the last move of the line seen in master games — from here on
  /// the line is engine and Maia, not practice.
  final bool lastBookMove;

  /// Most recent year this move appears in the database.
  final int? lastPlayedYear;

  /// Free text emitted ahead of the `[%…]` tokens, for the rare move that
  /// needs a sentence rather than a number — currently the hand-off from
  /// prepared theory to a raw engine continuation. Survives at any detail
  /// level above [MoveAnnotationDetail.none], because a reader who has
  /// turned the metrics off still needs to know where preparation stopped.
  final String? note;

  const MoveAnnotation({
    this.likelihood,
    this.likelihoodSource,
    this.gameCount,
    this.practicalScore,
    this.evalCp,
    this.opponentEase,
    this.myEase,
    this.isOnlyMove = false,
    this.onlyMoveLeadCp,
    this.humanFrequency,
    this.naturalAlternativeSan,
    this.naturalAlternativeLossCp,
    this.mistakeCp,
    this.betterMoveSan,
    this.lastBookMove = false,
    this.lastPlayedYear,
    this.note,
  });

  static const none = MoveAnnotation();

  /// Opponent moves this far below their best option are written up as a
  /// mistake (`?!`), and from [kBlunderCp] as a blunder (`?`).
  static const int kMistakeCp = 80;
  static const int kBlunderCp = 150;

  /// A natural alternative losing less than this is "nearly as good" — worth
  /// saying, because it tells the reader the memorisation is optional.
  static const int kNegligibleLossCp = 15;

  /// Our moves found by fewer humans than this get a "hard to find" note.
  static const double kHardToFindFrequency = 0.20;

  /// The natural alternative is only named when it is at least this much
  /// more popular than our move — otherwise there is no one move that
  /// "everyone plays instead".
  static const double kNaturalAlternativeMargin = 0.15;

  /// Annotation glyph to write straight after the SAN — `!` for an
  /// only-move, `?!`/`?` for an opponent mistake/blunder — or null.
  String? get glyph {
    if (isOnlyMove) return '!';
    final loss = mistakeCp;
    if (loss == null) return null;
    if (loss >= kBlunderCp) return '?';
    if (loss >= kMistakeCp) return '?!';
    return null;
  }

  bool get isHardToFind =>
      humanFrequency != null && humanFrequency! < kHardToFindFrequency;

  /// The sentence a reader gets about this move — why it is forced, why it is
  /// hard to see, what the opponent just gave away, where theory stops.
  /// Empty when the move needs no explaining.
  String get explanation {
    final parts = <String>[];
    if (isOnlyMove) {
      final lead = onlyMoveLeadCp;
      parts.add(
        lead == null
            ? 'Only move.'
            : 'Only move: the next best gives up ${_pawns(lead)}.',
      );
    }
    if (isHardToFind) {
      final pct = (humanFrequency! * 100).round();
      final who = pct < 1 ? 'under 1% of players' : 'only $pct% of players';
      final alt = naturalAlternativeSan;
      final loss = naturalAlternativeLossCp;
      parts.add(
        alt == null
            ? 'Hard to find: $who see it.'
            : loss == null
            ? 'Hard to find: $who see it; most play $alt.'
            : loss >= kNegligibleLossCp
            ? 'Hard to find: $who see it; the natural $alt costs '
                  '${_pawns(loss)}.'
            : 'Hard to find: $who see it; the natural $alt is nearly as '
                  'good.',
      );
    }
    final loss = mistakeCp;
    if (loss != null && loss >= kMistakeCp) {
      final label = loss >= kBlunderCp ? 'Blunder' : 'Inaccuracy';
      final better = betterMoveSan;
      parts.add(
        better == null
            ? '$label: gives up ${_pawns(loss)}.'
            : '$label: gives up ${_pawns(loss)} against $better.',
      );
    }
    if (lastBookMove) {
      final n = gameCount ?? 0;
      final games = n == 1 ? '1 game' : '$n games';
      parts.add(
        n > 0
            ? 'Last move seen in master games ($games); from here the line '
                  'is engine and Maia.'
            : 'Last move seen in master games; from here the line is '
                  'engine and Maia.',
      );
    }
    return parts.join(' ');
  }

  /// This annotation with [note] set (a sentence such as "…improves on …
  /// in <game>"), everything else unchanged.
  MoveAnnotation withNote(String note) => MoveAnnotation(
    likelihood: likelihood,
    likelihoodSource: likelihoodSource,
    gameCount: gameCount,
    practicalScore: practicalScore,
    evalCp: evalCp,
    opponentEase: opponentEase,
    myEase: myEase,
    isOnlyMove: isOnlyMove,
    onlyMoveLeadCp: onlyMoveLeadCp,
    humanFrequency: humanFrequency,
    naturalAlternativeSan: naturalAlternativeSan,
    naturalAlternativeLossCp: naturalAlternativeLossCp,
    mistakeCp: mistakeCp,
    betterMoveSan: betterMoveSan,
    lastBookMove: lastBookMove,
    lastPlayedYear: lastPlayedYear,
    note: note,
  );

  /// This annotation flagged as the line's last move in master practice.
  MoveAnnotation withLastBookMove() => MoveAnnotation(
    likelihood: likelihood,
    likelihoodSource: likelihoodSource,
    gameCount: gameCount,
    practicalScore: practicalScore,
    evalCp: evalCp,
    opponentEase: opponentEase,
    myEase: myEase,
    isOnlyMove: isOnlyMove,
    onlyMoveLeadCp: onlyMoveLeadCp,
    humanFrequency: humanFrequency,
    naturalAlternativeSan: naturalAlternativeSan,
    naturalAlternativeLossCp: naturalAlternativeLossCp,
    mistakeCp: mistakeCp,
    betterMoveSan: betterMoveSan,
    lastBookMove: true,
    lastPlayedYear: lastPlayedYear,
    note: note,
  );

  bool get isEmpty =>
      note == null &&
      likelihood == null &&
      practicalScore == null &&
      evalCp == null &&
      opponentEase == null &&
      myEase == null &&
      lastPlayedYear == null &&
      humanFrequency == null &&
      mistakeCp == null &&
      !lastBookMove &&
      !isOnlyMove;

  /// Render as a PGN comment body (without the surrounding braces), or null
  /// when nothing at this detail level applies.
  ///
  /// Tokens follow the `[%name value]` convention the rest of the app already
  /// parses and strips, so an annotated export stays readable in any viewer.
  String? toPgnComment(MoveAnnotationDetail detail) {
    if (!detail.emitsAnything || isEmpty) return null;

    final tokens = <String>[];
    if (note != null && note!.isNotEmpty) tokens.add(note!);
    // Prose survives at every emitting level, like [note]: a reader who has
    // switched the metrics off still wants to know a move is forced.
    final why = explanation;
    if (why.isNotEmpty) tokens.add(why);
    if (likelihood != null && likelihoodSource != null) {
      tokens.add(
        '[%${likelihoodSource!.pgnTag} ${likelihood!.toStringAsFixed(3)}]',
      );
    }

    if (detail.emitsMetrics) {
      if (evalCp != null) tokens.add('[%eval ${_formatPawns(evalCp!)}]');
      if (isOnlyMove) tokens.add('[%onlyMove]');
      if (myEase != null) {
        tokens.add('[%myEase ${myEase!.toStringAsFixed(2)}]');
      }
      if (opponentEase != null) {
        tokens.add('[%ease ${opponentEase!.toStringAsFixed(2)}]');
      }
      if (practicalScore != null) {
        tokens.add('[%score ${(practicalScore! * 100).toStringAsFixed(1)}%]');
      }
      if (gameCount != null && gameCount! > 0) {
        tokens.add('[%games $gameCount]');
      }
      if (lastPlayedYear != null && lastPlayedYear! > 0) {
        tokens.add('[%lastPlayed $lastPlayedYear]');
      }
    }

    return tokens.isEmpty ? null : tokens.join(' ');
  }
}

/// `0.62` — an unsigned pawn amount for prose ("gives up 0.62").
String _pawns(int centipawns) => (centipawns.abs() / 100).toStringAsFixed(2);

/// `+0.31` / `-1.05` / `0.00` — pawns, always signed except at zero.
String _formatPawns(int centipawns) {
  final pawns = (centipawns / 100).toStringAsFixed(2);
  return centipawns > 0 ? '+$pawns' : pawns;
}
