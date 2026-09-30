import 'package:dartchess/dartchess.dart';

import 'fen.dart';

/// Setting a position up by hand: dartchess's [Setup] — a position that
/// need not be legal — edited one square or one right at a time.
///
/// Nothing here refuses a step, because a position is built through
/// illegal ones (an empty board has no kings). What would make the result
/// unplayable is [illegal], asked when the position is to be used. Each
/// edit keeps the castling rights and the en-passant square to what the
/// board still allows, so the FEN never carries a right with no rook.
extension SetupEdits on Setup {
  /// [fen] as a setup, or null when it cannot be read at all. Missing
  /// fields are filled in (`w - - 0 1`), as dartchess reads them.
  static Setup? read(String fen) => switch (readSetup(fen.trim())) {
    final setup? => _tidy(setup),
    null => null,
  };

  Fen get asFen => Fen(fen);

  /// [piece] put on [square] in place of what was there; null empties it.
  Setup withPiece(Square square, Piece? piece) => _with(
    board: piece == null
        ? board.removePieceAt(square)
        : board.setPieceAt(square, piece),
  );

  /// [board] in place of the pieces, the side to move kept.
  Setup withBoard(Board board) => _with(board: board);

  /// The piece on [from] moved to [to], taking whatever stood there.
  Setup withMove(Square from, Square to) {
    final piece = board.pieceAt(from);
    if (piece == null || from == to) return this;
    return _with(board: board.removePieceAt(from).setPieceAt(to, piece));
  }

  Setup withTurn(Side side) => _with(turn: side);

  /// Castling with the rook on [rook] — a1, h1, a8 or h8 — allowed or not.
  Setup withCastling(Square rook, {required bool on}) => _with(
    castlingRights: on
        ? castlingRights.withSquare(rook)
        : castlingRights.withoutSquare(rook),
  );

  Setup withEnPassant(Square? square) => _with(epSquare: square);

  /// Whether castling with the rook on [rook] can be allowed: its king and
  /// that rook are on their first squares.
  bool canCastle(Square rook) {
    final side = rook.rank == Rank.first ? Side.white : Side.black;
    final king = side == Side.white ? Square.e1 : Square.e8;
    return board.pieceAt(king) == Piece(color: side, role: Role.king) &&
        board.pieceAt(rook) == Piece(color: side, role: Role.rook);
  }

  /// The squares a pawn could be taken on en passant by the side to move:
  /// behind an enemy pawn on its fourth rank, with the square it came
  /// from and the one it passed empty, and a pawn beside it to take it.
  ///
  /// Once the position can be played from, the capture must be legal too,
  /// as a FEN reached by moves has it: after 1.e4 no black pawn can take
  /// on e3, so that FEN says `-`, and a position set up by hand keyed any
  /// other way would miss every book and explorer row for it.
  List<Square> get enPassantSquares {
    final white = turn == Side.white;
    final target = white ? Rank.sixth : Rank.third;
    final pawnRank = white ? Rank.fifth : Rank.fourth;
    final origin = white ? Rank.seventh : Rank.second;
    final pawn = Piece(color: turn.opposite, role: Role.pawn);
    final taker = Piece(color: turn, role: Role.pawn);
    bool takerOn(int file) =>
        file >= 0 &&
        file < 8 &&
        board.pieceAt(Square.fromCoords(File(file), pawnRank)) == taker;
    return [
      for (final file in File.values)
        if (board.pieceAt(Square.fromCoords(file, pawnRank)) == pawn &&
            board.pieceAt(Square.fromCoords(file, target)) == null &&
            board.pieceAt(Square.fromCoords(file, origin)) == null &&
            (takerOn(file - 1) || takerOn(file + 1)) &&
            _legalCapture(Square.fromCoords(file, target)))
          Square.fromCoords(file, target),
    ];
  }

  /// Whether taking en passant on [square] is legal, or cannot be told yet
  /// because the position is not one a game could be played from.
  bool _legalCapture(Square square) {
    final Position position;
    try {
      position = Chess.fromSetup(_withEp(square));
    } on Object {
      return true;
    }
    return position.fen.split(' ')[3] == square.name;
  }

  Setup _withEp(Square square) => Setup(
    board: board,
    turn: turn,
    castlingRights: castlingRights,
    epSquare: square,
    halfmoves: halfmoves,
    fullmoves: fullmoves,
  );

  /// Why this cannot be played from, or null when it can.
  IllegalSetupCause? get illegal {
    try {
      Chess.fromSetup(this);
      return null;
    } on PositionSetupException catch (error) {
      return error.cause;
    }
  }

  Setup _with({
    Board? board,
    Side? turn,
    SquareSet? castlingRights,
    Object? epSquare = _same,
  }) => _tidy(
    Setup(
      board: board ?? this.board,
      turn: turn ?? this.turn,
      castlingRights: castlingRights ?? this.castlingRights,
      epSquare: epSquare == _same ? this.epSquare : epSquare as Square?,
      halfmoves: halfmoves,
      fullmoves: fullmoves,
    ),
  );
}

/// [text] as dartchess reads a FEN, or null when it cannot be read.
///
/// Every throw is caught, not only `FenException`: the board parser also
/// throws a bare `ArgumentError` — `.NBQKBNR` gives "Invalid argument(s):
/// -2". Which one came back is no use to anybody, and a mistyped FEN must
/// not take down the dialog it was typed into, or the document it was read
/// from.
Setup? readSetup(String text) {
  try {
    return Setup.parseFen(text);
  } on Object {
    return null;
  }
}

/// [text] as a FEN a game can start from — readable and legal, with only
/// the rights its board allows — or null.
Fen? playableFen(String text) {
  final setup = SetupEdits.read(text);
  return setup == null || setup.illegal != null ? null : setup.asFen;
}

const _same = Object();

const _rookCorners = [Square.a1, Square.h1, Square.a8, Square.h8];

/// [setup] with only the rights its board allows: a castling right with its
/// king and rook at home, an en-passant square a pawn could be taken on.
Setup _tidy(Setup setup) {
  var rights = SquareSet.empty;
  for (final rook in _rookCorners) {
    if (setup.castlingRights.has(rook) && setup.canCastle(rook)) {
      rights = rights.withSquare(rook);
    }
  }
  final ep = setup.epSquare;
  return Setup(
    board: setup.board,
    turn: setup.turn,
    castlingRights: rights,
    epSquare: ep != null && setup.enPassantSquares.contains(ep) ? ep : null,
    halfmoves: setup.halfmoves,
    fullmoves: setup.fullmoves,
  );
}
