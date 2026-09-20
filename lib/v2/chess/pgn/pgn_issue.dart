/// Something in a game's text that this reader could not carry into the
/// model.
///
/// An issue is exactly where writing the game again would lose text, so a
/// game with any issue at all is never written again: the chapter keeps its
/// bytes and no edit can reach it. That is why the list is a closed set of
/// named cases rather than free prose — a caller can decide what to tell the
/// user, and a new way to lose text has to be added here to exist.
///
/// [line] and [column] are one-based and count within the game's own text.
sealed class PgnIssue {
  const PgnIssue({required this.line, required this.column});

  final int line;
  final int column;

  /// One plain English sentence fragment naming what was found.
  String get detail;

  @override
  String toString() => '$line:$column: $detail';
}

/// The `[FEN]` header is not a position a game can be played from, so the
/// game has no moves at all.
final class UnreadablePosition extends PgnIssue {
  const UnreadablePosition({required super.line, required super.column});

  @override
  String get detail => 'the FEN header is not a position';
}

/// A move that is not legal in the position it was written from. The branch
/// stops there; everything the file wrote after it is not in the model.
final class IllegalMove extends PgnIssue {
  const IllegalMove(this.san, {required super.line, required super.column});

  final String san;

  @override
  String get detail => '$san is not a legal move here';
}

/// A `{` that the game's text never closed.
final class UnterminatedComment extends PgnIssue {
  const UnterminatedComment({required super.line, required super.column});

  @override
  String get detail => 'a comment was never closed';
}

/// A `(` that the game's text never closed.
final class UnterminatedVariation extends PgnIssue {
  const UnterminatedVariation({required super.line, required super.column});

  @override
  String get detail => 'a variation was never closed';
}

/// A `(` with no move in front of it for the variation to replace.
final class StrayVariationStart extends PgnIssue {
  const StrayVariationStart({required super.line, required super.column});

  @override
  String get detail => 'a variation with no move to branch from';
}

/// A `)` with no variation open.
final class StrayVariationEnd extends PgnIssue {
  const StrayVariationEnd({required super.line, required super.column});

  @override
  String get detail => 'a variation ended that never started';
}

/// A `()` with no move in it. It may still hold a comment, which has no move
/// to belong to.
final class EmptyVariation extends PgnIssue {
  const EmptyVariation({required super.line, required super.column});

  @override
  String get detail => 'a variation with no move in it';
}

/// An annotation with no move in front of it, such as a game opening with
/// `$1`.
final class StrayAnnotation extends PgnIssue {
  const StrayAnnotation({required super.line, required super.column});

  @override
  String get detail => 'an annotation with no move to belong to';
}

/// A `%` escape line among the moves. The standard says to ignore the line,
/// and ignoring it is losing it.
final class EscapeInMovetext extends PgnIssue {
  const EscapeInMovetext({required super.line, required super.column});

  @override
  String get detail => 'a % escape line among the moves';
}

/// A second game-termination marker, or one inside a variation.
final class ExtraTermination extends PgnIssue {
  const ExtraTermination(
    this.marker, {
    required super.line,
    required super.column,
  });

  final String marker;

  @override
  String get detail => '$marker where the game had already ended';
}

/// A move written after the game-termination marker.
final class MovesAfterTermination extends PgnIssue {
  const MovesAfterTermination({required super.line, required super.column});

  @override
  String get detail => 'moves after the game ended';
}

/// Text among the moves that is not a move, a number, an annotation, a
/// comment, a bracket or a result.
final class UnknownToken extends PgnIssue {
  const UnknownToken(this.text, {required super.line, required super.column});

  final String text;

  @override
  String get detail => '"$text" is not anything a game can hold';
}

/// Where in [text] the character at [offset] is, counting from one.
({int line, int column}) placeOf(String text, int offset) {
  var line = 1;
  var lineStart = 0;
  final end = offset < text.length ? offset : text.length;
  for (var i = 0; i < end; i++) {
    if (text.codeUnitAt(i) != 0x0A) continue;
    line++;
    lineStart = i + 1;
  }
  return (line: line, column: end - lineStart + 1);
}
