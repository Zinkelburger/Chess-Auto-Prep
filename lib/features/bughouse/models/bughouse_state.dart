import 'dart:math' as math;

import 'package:dartchess/dartchess.dart';

/// Which board of the pair. Board A is the one the engine's team plays as
/// [BughouseState.team]; board B is where its partner sits, playing the
/// opposite colour.
enum BughouseBoard { a, b }

extension BughouseBoardX on BughouseBoard {
  /// The engine prefixes every move with this digit: `1e2e4`, `2d7d5`.
  String get uciPrefix => this == BughouseBoard.a ? '1' : '2';

  /// Numbered, not lettered, because the four *players* are A, B, C and D —
  /// see [BughouseState.seatLetter]. One alphabet per thing being named.
  String get label => this == BughouseBoard.a ? 'Board 1' : 'Board 2';

  /// Just the digit, for a tag with no room for a word.
  String get number => this == BughouseBoard.a ? '1' : '2';
  String get shortLabel => this == BughouseBoard.a ? 'A' : 'B';
  BughouseBoard get other =>
      this == BughouseBoard.a ? BughouseBoard.b : BughouseBoard.a;
}

/// One half of a joint action. Bughouse lets a team move on either board, or
/// deliberately do nothing — `pass` is a real, often best, move.
class BughouseHalfMove {
  const BughouseHalfMove.move(this.uci) : isPass = false;
  const BughouseHalfMove.pass() : uci = null, isPass = true;

  final String? uci;
  final bool isPass;

  factory BughouseHalfMove.parse(String token) {
    final t = token.trim();
    if (t.isEmpty || t == 'pass' || t == '(none)' || t == 'none') {
      return const BughouseHalfMove.pass();
    }
    return BughouseHalfMove.move(t);
  }

  @override
  String toString() => isPass ? 'pass' : uci!;
}

/// What the engine returns: one action per board, played together. A chess
/// engine returns one move; this is a decision about two boards at once.
class BughouseJointMove {
  const BughouseJointMove(this.a, this.b);

  final BughouseHalfMove a;
  final BughouseHalfMove b;

  bool get isEmpty => a.isPass && b.isPass;

  BughouseHalfMove half(BughouseBoard board) =>
      board == BughouseBoard.a ? a : b;

  /// Parses `(d2d4,pass)` as emitted after `bestmove` / `ponder`.
  static BughouseJointMove? tryParse(String raw) {
    final text = raw.trim();
    if (!text.startsWith('(') || !text.endsWith(')')) return null;
    final inner = text.substring(1, text.length - 1);
    final parts = inner.split(',');
    if (parts.length != 2) return null;
    return BughouseJointMove(
      BughouseHalfMove.parse(parts[0]),
      BughouseHalfMove.parse(parts[1]),
    );
  }

  @override
  String toString() => '($a,$b)';
}

/// One `info` line from a search.
///
/// The score deserves a warning, because it is not a chess engine's score.
/// Hivemind reports `180·tan(1.56·Q)` of an MCTS value, and that value carries
/// a large constant offset: a dead-level position reads about **-2.3**, not
/// 0.00, at every node count we have measured (500 to 15 000). What is
/// meaningful is the *ordering* of the moves in one search and the *gaps*
/// between them — see [levelBaseline] and [BughouseSearchResult.lines].
class BughouseInfo {
  const BughouseInfo({
    required this.depth,
    required this.scoreCp,
    required this.nodes,
    required this.nps,
    required this.timeMs,
    required this.pv,
    this.multipv = 1,
    this.mateIn,
  });

  final int depth;
  final int scoreCp;
  final int nodes;
  final int nps;
  final int timeMs;

  /// Which ranked line this is, 1-based. Only meaningful when the search ran
  /// with MultiPV > 1; a single-line search always reports 1.
  final int multipv;

  /// Moves to mate when the search proved one, our team's sign: positive we
  /// mate, negative we are mated. Null for an ordinary score.
  final int? mateIn;

  /// Principal variation as joint moves — each entry is one ply for the team,
  /// spanning both boards.
  final List<BughouseJointMove> pv;

  /// Evaluation on Hivemind's scale, from the searching team's point of view.
  /// Read it against [levelBaseline], not against zero.
  double get scorePawns => scoreCp / 100.0;

  /// Where a balanced position sits on that scale. Measured, not chosen:
  /// the opening position reads -2.29 to -2.40 from either seat.
  static const double levelBaseline = -2.3;

  /// How much better or worse than level this looks. Still not pawns, but at
  /// least it is signed the way a reader expects.
  double get relativeToLevel => scorePawns - levelBaseline;

  /// The engine's own number, printed — `#3`, `#-2`, or a signed score.
  String get scoreLabel {
    final mate = mateIn;
    if (mate != null) return mate >= 0 ? '#$mate' : '#-${-mate}';
    final sign = scorePawns > 0 ? '+' : '';
    return '$sign${scorePawns.toStringAsFixed(2)}';
  }

  /// The number to show a person: zero is level, positive is good for the team
  /// that was searched.
  ///
  /// [scoreLabel] prints what the engine said, which for a dead-level position
  /// is `-2.30` — a number that reads as "losing" to every chess eye that sees
  /// it. Subtracting the measured baseline is not cosmetic: it is the
  /// difference between a score a reader can act on and one that misleads.
  String get evalLabel {
    final mate = mateIn;
    if (mate != null) return mate >= 0 ? '#$mate' : '#-${-mate}';
    final hundredths = (relativeToLevel * 100).round();
    if (hundredths == 0) return '0.00';
    final sign = hundredths > 0 ? '+' : '-';
    return '$sign${(hundredths.abs() / 100).toStringAsFixed(2)}';
  }

  /// Where to fill an eval bar for the team that was searched, 0 to 1.
  ///
  /// The engine's scale is a tangent of an MCTS value, so it has no natural
  /// units to divide by; the squash below just has to be monotonic and to put
  /// a level position in the middle. A mate fills the bar.
  double get barFraction {
    final mate = mateIn;
    if (mate != null) return mate >= 0 ? 1.0 : 0.0;
    final squashed = 2 / (1 + math.exp(-relativeToLevel / 1.6)) - 1;
    return (0.5 + squashed / 2).clamp(0.0, 1.0);
  }
}

/// Where a team stands on the clock, which in bughouse is a rule input rather
/// than a statistic: only a team that is ahead can afford to sit.
///
/// The engine's own model is binary — `TimeAdvantage true|false` — so [level]
/// and [behind] produce the *same* search. They are still separate here
/// because they are different questions to ask, and because pairing either
/// with [RequireMoveOn] gives the genuinely third case: a team that cannot
/// even pass on one board.
enum BughouseTimeStance {
  /// Up on the diagonal: may sit on both boards.
  ahead,

  /// Neither side clearly up. No double-sit.
  level,

  /// Down on the diagonal: no double-sit, and every tempo costs.
  behind,
}

extension BughouseTimeStanceX on BughouseTimeStance {
  /// What the engine is told. Only [ahead] unlocks sitting on both boards.
  bool get givesTimeAdvantage => this == BughouseTimeStance.ahead;

  String get label => switch (this) {
    BughouseTimeStance.ahead => 'We are ahead',
    BughouseTimeStance.level => 'Level',
    BughouseTimeStance.behind => 'They are ahead',
  };

  String get shortLabel => switch (this) {
    BughouseTimeStance.ahead => 'Ahead',
    BughouseTimeStance.level => 'Level',
    BughouseTimeStance.behind => 'Behind',
  };

  /// A tooltip, not a lesson. [level] and [behind] read the same because they
  /// search the same — the engine's clock model is one bit — and two identical
  /// hints say that more quietly than a paragraph explaining it would.
  String get hint => switch (this) {
    BughouseTimeStance.ahead => 'The team may sit on both boards',
    BughouseTimeStance.level ||
    BughouseTimeStance.behind => 'No sitting on both boards',
  };
}

/// Forces the team to move on a board rather than passing there.
///
/// This is the constraint that actually expresses "we do not get to sit" —
/// stronger than [BughouseTimeStance.behind], which still permits a pass on
/// one board while the other moves.
enum RequireMoveOn {
  none,
  boardA,
  boardB;

  /// The value the engine's `RequireMoveOn` option takes.
  String get uciValue => switch (this) {
    RequireMoveOn.none => 'none',
    RequireMoveOn.boardA => 'A',
    RequireMoveOn.boardB => 'B',
  };

  String get label => switch (this) {
    RequireMoveOn.none => 'Either board',
    RequireMoveOn.boardA => 'Must move on board 1',
    RequireMoveOn.boardB => 'Must move on board 2',
  };
}

/// The four clocks on a bughouse table.
///
/// Bughouse clocks matter more than chess clocks and differently: what decides
/// whether sitting is safe is the *diagonal* relationship — your time against
/// the player your partner is facing — not the two clocks on your own board.
class BughouseClocks {
  const BughouseClocks({
    this.whiteA = const Duration(minutes: 3),
    this.blackA = const Duration(minutes: 3),
    this.whiteB = const Duration(minutes: 3),
    this.blackB = const Duration(minutes: 3),
  });

  final Duration whiteA;
  final Duration blackA;
  final Duration whiteB;
  final Duration blackB;

  Duration of(BughouseBoard board, Side side) => switch ((board, side)) {
    (BughouseBoard.a, Side.white) => whiteA,
    (BughouseBoard.a, Side.black) => blackA,
    (BughouseBoard.b, Side.white) => whiteB,
    (BughouseBoard.b, Side.black) => blackB,
  };

  BughouseClocks withClock(BughouseBoard board, Side side, Duration value) {
    final v = value.isNegative ? Duration.zero : value;
    return switch ((board, side)) {
      (BughouseBoard.a, Side.white) => copyWith(whiteA: v),
      (BughouseBoard.a, Side.black) => copyWith(blackA: v),
      (BughouseBoard.b, Side.white) => copyWith(whiteB: v),
      (BughouseBoard.b, Side.black) => copyWith(blackB: v),
    };
  }

  BughouseClocks copyWith({
    Duration? whiteA,
    Duration? blackA,
    Duration? whiteB,
    Duration? blackB,
  }) => BughouseClocks(
    whiteA: whiteA ?? this.whiteA,
    blackA: blackA ?? this.blackA,
    whiteB: whiteB ?? this.whiteB,
    blackB: blackB ?? this.blackB,
  );

  /// Where the team playing [team] on board A stands on the diagonal.
  ///
  /// A team is two seats: [team] on board A and its partner on board B. Each
  /// seat's diagonal opponent is the player on the *other* board with the
  /// *same* colour — the one who can be starved of pieces by sitting. This
  /// compares the two pairs, which is the ordinary way players judge it.
  ///
  /// Differences inside [tolerance] read as level, because a second or two
  /// either way does not decide whether sitting is safe.
  BughouseTimeStance stanceFor(
    Side team, {
    Duration tolerance = const Duration(seconds: 5),
  }) {
    final ours = of(BughouseBoard.a, team) + of(BughouseBoard.b, team.opposite);
    final theirs =
        of(BughouseBoard.a, team.opposite) + of(BughouseBoard.b, team);
    final delta = ours - theirs;
    if (delta.abs() <= tolerance) return BughouseTimeStance.level;
    return delta > Duration.zero
        ? BughouseTimeStance.ahead
        : BughouseTimeStance.behind;
  }

  /// Convenience for the engine's one-bit view.
  bool teamIsAhead(Side team) => stanceFor(team) == BughouseTimeStance.ahead;
}

/// The full two-board position the engine reasons about.
class BughouseState {
  const BughouseState({
    required this.boardA,
    required this.boardB,
    this.team = Side.white,
    this.timeStance = BughouseTimeStance.level,
    this.clocks = const BughouseClocks(),
  });

  /// Standard opening on both boards, the engine's team playing white on A.
  factory BughouseState.initial() => const BughouseState(
    boardA: Crazyhouse.initial,
    boardB: Crazyhouse.initial,
  );

  /// Bare boards, for building a position up from nothing in the editor.
  factory BughouseState.empty() {
    final blank = bareKingsPosition();
    return BughouseState(boardA: blank, boardB: blank);
  }

  /// Crazyhouse rather than Chess because bughouse boards carry pockets: the
  /// pieces your *partner* captures are droppable here.
  final Crazyhouse boardA;
  final Crazyhouse boardB;

  /// The side the engine plays on board A. It plays the opposite colour on
  /// board B, because partners always sit on opposite colours.
  final Side team;

  /// Where this team stands on the diagonal clock. It decides whether sitting
  /// is legal, so the engine has to be told explicitly.
  final BughouseTimeStance timeStance;

  /// The one bit the engine actually takes.
  bool get teamHasTimeAdvantage => timeStance.givesTimeAdvantage;

  final BughouseClocks clocks;

  Crazyhouse board(BughouseBoard which) =>
      which == BughouseBoard.a ? boardA : boardB;

  /// The colour this team plays on the given board.
  Side sideOn(BughouseBoard which) =>
      which == BughouseBoard.a ? team : team.opposite;

  /// Whether it is this team's turn there — the precondition for having any
  /// move on that board at all.
  bool isOurTurn(BughouseBoard which) => board(which).turn == sideOn(which);

  /// Whether [which] team has anything to move at all.
  ///
  /// Each board has its own turn, so a team may hold both moves, one, or
  /// none — and a team with none is not a search that returns slowly, it is a
  /// search with no question in it.
  bool hasMoveFor(Side which) =>
      boardA.turn == which || boardB.turn == which.opposite;

  /// The letter that names the person playing [mover] on [which].
  ///
  /// Four people play a bughouse game and neither "board 1" nor a colour names
  /// one of them, so each seat gets a letter: **A** and **B** face each other
  /// on board 1, **C** and **D** on board 2, and our team is A and C. The
  /// engine's joint action reads as advice only once each half is attached to
  /// whoever has to carry it out, and a letter does that without a phrase like
  /// "your partner's opponent" in every row.
  String seatLetter(BughouseBoard which, Side mover) => which == BughouseBoard.a
      ? (mover == team ? 'A' : 'B')
      : (mover == team.opposite ? 'C' : 'D');

  /// The same seat spelled out, for a tooltip: `A — you, white on board 1`.
  String seatDescription(BughouseBoard which, Side mover) {
    final letter = seatLetter(which, mover);
    final who = switch (letter) {
      'A' => 'you',
      'B' => 'your opponent',
      'C' => 'your partner',
      _ => 'your partner\'s opponent',
    };
    return '$letter — $who, ${mover.name} on ${which.label.toLowerCase()}';
  }

  /// Both seats of a team, in board order: ours is `A + C`, theirs `B + D`.
  String teamLetters(Side which) => which == team ? 'A + C' : 'B + D';

  /// Whether [team] may sit on both boards.
  ///
  /// The clock is a diagonal relationship, so it answers for both teams at
  /// once: if we are behind, they are the ones who may sit. "Level" lets
  /// nobody sit, which is what the engine's single bit already says.
  bool timeAdvantageFor(Side which) => which == team
      ? teamHasTimeAdvantage
      : timeStance == BughouseTimeStance.behind;

  BughouseState copyWith({
    Crazyhouse? boardA,
    Crazyhouse? boardB,
    Side? team,
    BughouseTimeStance? timeStance,
    BughouseClocks? clocks,
  }) => BughouseState(
    boardA: boardA ?? this.boardA,
    boardB: boardB ?? this.boardB,
    team: team ?? this.team,
    timeStance: timeStance ?? this.timeStance,
    clocks: clocks ?? this.clocks,
  );

  BughouseState withBoard(BughouseBoard which, Crazyhouse position) =>
      which == BughouseBoard.a
      ? copyWith(boardA: position)
      : copyWith(boardB: position);

  /// The engine's dual-FEN form: two crazyhouse FENs joined by `|`.
  String get dualFen => '${boardA.fen}|${boardB.fen}';

  // ------------------------------------------------------------------ moves

  /// Plays [move] on one board and routes any captured piece to the *other*
  /// board's pocket.
  ///
  /// This is the rule that makes bughouse bughouse, and it is the opposite of
  /// the crazyhouse rule dartchess implements for us:
  ///
  ///   * crazyhouse — you capture a black knight, it becomes a *white* knight
  ///     in your own reserve, on the same board.
  ///   * bughouse — you hand it to your partner, who sits on the other board
  ///     playing the opposite colour to you, and drops it as a *black* knight.
  ///
  /// So the colour is preserved and the board changes. We let dartchess play
  /// the move, then undo the pocket increment it made and apply ours.
  ///
  /// Returns null when the move is not legal on that board.
  BughouseState? playMove(BughouseBoard which, Move move) {
    final before = board(which);
    if (!before.isLegal(move)) return null;

    final captured = _capturedPiece(before, move);
    final after = before.playUnchecked(move) as Crazyhouse;

    if (captured == null) return withBoard(which, after);

    // Promoted pieces revert to pawns when captured — dartchess already
    // applies that when filling its own pocket, so mirror it here.
    final role = captured.promoted ? Role.pawn : captured.role;

    // Undo the crazyhouse increment on this board...
    final localPockets = (after.pockets ?? Pockets.empty).decrement(
      captured.color.opposite,
      role,
    );
    // ...and hand the piece to the partner, colour intact.
    final partner = board(which.other);
    final partnerPockets = (partner.pockets ?? Pockets.empty).increment(
      captured.color,
      role,
    );

    return withBoard(
      which,
      after.copyWith(pockets: localPockets) as Crazyhouse,
    ).withBoard(
      which.other,
      partner.copyWith(pockets: partnerPockets) as Crazyhouse,
    );
  }

  /// What [move] captures on [position], including en passant. Drops capture
  /// nothing.
  static Piece? _capturedPiece(Crazyhouse position, Move move) {
    if (move is DropMove) return null;
    final normal = move as NormalMove;
    final target = position.board.pieceAt(normal.to);
    if (target != null) return target;
    // En passant: the pawn taken is not on the destination square.
    final moving = position.board.pieceAt(normal.from);
    if (moving?.role == Role.pawn && normal.to == position.epSquare) {
      final capturedSquare = Square(normal.to.file | (normal.from.rank << 3));
      return position.board.pieceAt(capturedSquare);
    }
    return null;
  }

  // ------------------------------------------------------------------ setup

  /// The emptiest position that is still a position: two kings, nothing else.
  ///
  /// A board with no pieces at all cannot be represented — dartchess rejects
  /// it outright — and a bughouse position without kings is not one anyway, so
  /// "clear" leaves the kings standing rather than failing.
  static Crazyhouse bareKingsPosition() => Crazyhouse.fromSetup(
    Setup.parseFen('4k3/8/8/8/8/8/8/4K3[] w - - 0 1'),
    ignoreImpossibleCheck: true,
  );

  /// Rebuilds a board from a modified [Setup], tolerating the half-finished
  /// positions an editor produces (no king yet, a king in an impossible
  /// check). Returns null when even that fails.
  static Crazyhouse? tryBuild(Setup setup) {
    try {
      return Crazyhouse.fromSetup(setup, ignoreImpossibleCheck: true);
    } catch (_) {
      return null;
    }
  }

  Setup setupOf(BughouseBoard which) {
    final position = board(which);
    return Setup(
      board: position.board,
      pockets: position.pockets ?? Pockets.empty,
      turn: position.turn,
      castlingRights: position.castles.castlingRights,
      epSquare: position.epSquare,
      halfmoves: position.halfmoves,
      fullmoves: position.fullmoves,
    );
  }

  /// Places or clears a square. Passing a null [piece] erases.
  BughouseState? withPieceAt(BughouseBoard which, Square square, Piece? piece) {
    final setup = setupOf(which);
    final newBoard = piece == null
        ? setup.board.removePieceAt(square)
        : setup.board.setPieceAt(square, piece);
    final built = tryBuild(
      Setup(
        board: newBoard,
        pockets: setup.pockets,
        turn: setup.turn,
        // Rights referring to a rook that is no longer there are dropped by
        // Castles.fromSetup, so no bookkeeping is needed here.
        castlingRights: setup.castlingRights,
        epSquare: null,
        halfmoves: setup.halfmoves,
        fullmoves: setup.fullmoves,
      ),
    );
    return built == null ? null : withBoard(which, built);
  }

  /// Adds or removes a piece from one board's reserve. [delta] is usually ±1.
  BughouseState withPocket(
    BughouseBoard which,
    Side side,
    Role role,
    int delta,
  ) {
    final position = board(which);
    var pockets = position.pockets ?? Pockets.empty;
    if (delta > 0) {
      for (var i = 0; i < delta; i++) {
        pockets = pockets.increment(side, role);
      }
    } else {
      for (var i = 0; i < -delta; i++) {
        if (pockets.of(side, role) == 0) break;
        pockets = pockets.decrement(side, role);
      }
    }
    return withBoard(which, position.copyWith(pockets: pockets) as Crazyhouse);
  }

  BughouseState withTurn(BughouseBoard which, Side turn) {
    final position = board(which);
    if (position.turn == turn) return this;
    return withBoard(
      which,
      position.copyWith(turn: turn, epSquare: null) as Crazyhouse,
    );
  }

  /// Toggles one castling right. Rebuilt through a FEN round-trip because
  /// castling rights are derived state on [Castles].
  BughouseState? withCastlingRight(
    BughouseBoard which,
    Side side,
    CastlingSide castlingSide,
    bool enabled,
  ) {
    final position = board(which);
    final rook = position.castles.rookOf(side, castlingSide);
    if (enabled && rook == null) {
      // No rook on the expected square: the right cannot be granted.
      return null;
    }
    var rights = position.castles.castlingRights;
    if (enabled) {
      rights = rights.withSquare(_castlingRookSquare(side, castlingSide));
    } else if (rook != null) {
      rights = rights.withoutSquare(rook);
    }
    final built = tryBuild(
      Setup(
        board: position.board,
        pockets: position.pockets ?? Pockets.empty,
        turn: position.turn,
        castlingRights: rights,
        epSquare: position.epSquare,
        halfmoves: position.halfmoves,
        fullmoves: position.fullmoves,
      ),
    );
    return built == null ? null : withBoard(which, built);
  }

  static Square _castlingRookSquare(Side side, CastlingSide castlingSide) {
    final rank = side == Side.white ? 0 : 7;
    final file = castlingSide == CastlingSide.king ? 7 : 0;
    return Square(file | (rank << 3));
  }

  BughouseState clearBoard(BughouseBoard which) =>
      withBoard(which, bareKingsPosition());

  BughouseState resetBoard(BughouseBoard which) =>
      withBoard(which, Crazyhouse.initial);

  // -------------------------------------------------------------------- FEN

  /// Parses `<fenA>|<fenB>`, the form the engine speaks. A single FEN is
  /// accepted too and applied to both boards, which is what pasting a
  /// crazyhouse position from elsewhere should do.
  static BughouseState? tryParseDualFen(
    String raw, {
    Side team = Side.white,
    BughouseTimeStance timeStance = BughouseTimeStance.level,
  }) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    final parts = text.split('|');
    if (parts.length > 2) return null;
    try {
      final a = Crazyhouse.fromSetup(
        Setup.parseFen(parts[0].trim()),
        ignoreImpossibleCheck: true,
      );
      final b = parts.length == 2
          ? Crazyhouse.fromSetup(
              Setup.parseFen(parts[1].trim()),
              ignoreImpossibleCheck: true,
            )
          : a;
      return BughouseState(
        boardA: a,
        boardB: b,
        team: team,
        timeStance: timeStance,
      );
    } catch (_) {
      return null;
    }
  }
}
