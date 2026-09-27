import 'section_configuration.dart';

/// Where the file letters and rank numbers go. Same four choices as lila.
enum BoardCoordinates {
  /// Nothing on the board.
  none,

  /// Letters along the bottom rank and numbers up the right-hand file, in
  /// the corner of the edge squares. The lila default.
  inside,

  /// Letters and numbers in a margin around the squares.
  outside,

  /// Every square carries its own name. For learning the board.
  everySquare;

  static BoardCoordinates fromStorage(String? value) =>
      values.asNameMap()[value] ?? BoardCoordinates.inside;
}

/// How a piece is written in a move.
enum PieceNotation {
  /// `K Q R B N`, as in a PGN.
  letters,

  /// `♔ ♕ ♖ ♗ ♘`.
  figurines;

  static PieceNotation fromStorage(String? value) =>
      values.asNameMap()[value] ?? PieceNotation.letters;
}

class BoardDisplayConfiguration
    extends ImmutableSection<BoardDisplayConfiguration> {
  BoardDisplayConfiguration([Map<String, Object?> input = const {}])
    : super({
        'display.board_coordinates': BoardCoordinates.fromStorage(
          input['display.board_coordinates'] is String
              ? input['display.board_coordinates'] as String
              : null,
        ).name,
        'display.piece_notation': PieceNotation.fromStorage(
          input['display.piece_notation'] is String
              ? input['display.piece_notation'] as String
              : null,
        ).name,
        'display.legal_moves': input['display.legal_moves'] is bool
            ? input['display.legal_moves'] as bool
            : false,
      });
  @override
  BoardDisplayConfiguration withValues(Map<String, Object?> values) =>
      BoardDisplayConfiguration(values);
  BoardCoordinates get coordinates => BoardCoordinates.fromStorage(
    values['display.board_coordinates'] as String,
  );
  PieceNotation get pieceNotation =>
      PieceNotation.fromStorage(values['display.piece_notation'] as String);
  bool get showLegalMoves => values['display.legal_moves'] as bool;
}
