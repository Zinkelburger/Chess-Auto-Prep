/// One lexical item of a game's PGN text.
///
/// [at] is the offset of the token's first character in the game's text, so
/// an issue built from a token can say where in the file it was found.
sealed class PgnToken {
  const PgnToken(this.at);

  final int at;
}

/// One `[Key "value"]` pair. [value] is prose: `\"` and `\\` are already a
/// quote and a backslash.
final class TagToken extends PgnToken {
  const TagToken(
    super.at,
    this.end,
    this.key,
    this.value,
    this.raw,
    this.trailer,
  );

  /// The offset just past this tag and the whitespace after it.
  final int end;

  final String key;
  final String value;

  /// The tag exactly as the file wrote it, `[` to `]`.
  final String raw;

  /// The whitespace between this tag and whatever came next.
  final String trailer;
}

/// A line in the header block that is not a tag pair, kept exactly as it was
/// written so it can go back unchanged.
final class HeaderLineToken extends PgnToken {
  const HeaderLineToken(super.at, this.end, this.text, this.trailer);

  /// The offset just past this line and its ending.
  final int end;

  final String text;

  /// The line's ending, or the empty string at the end of the text.
  final String trailer;
}

/// The text of a `{}` or `;` comment, exactly as the file wrote it between
/// the braces or after the semicolon.
final class CommentToken extends PgnToken {
  const CommentToken(super.at, this.text, {required this.closed});

  final String text;

  /// False when a `{` ran to the end of the game with no `}`.
  final bool closed;
}

/// A `%` escape line among the moves. The standard says to ignore the line;
/// this reader says so out loud instead.
final class EscapeLineToken extends PgnToken {
  const EscapeLineToken(super.at);
}

final class VariationOpen extends PgnToken {
  const VariationOpen(super.at);
}

final class VariationClose extends PgnToken {
  const VariationClose(super.at);
}

/// `$5`, or the symbolic `!?` that means the same thing.
final class NagToken extends PgnToken {
  const NagToken(super.at, this.value);

  final int value;
}

/// `12.`, `12...` or a bare run of dots. Nothing in the model needs it: the
/// side to move comes from the board, never from the number, which is what
/// lets a course that numbers Black's ply `5.` read correctly.
final class MoveNumberToken extends PgnToken {
  const MoveNumberToken(super.at);
}

/// `1-0`, `0-1`, `1/2-1/2` or `*`.
final class TerminationToken extends PgnToken {
  const TerminationToken(super.at, this.text);

  final String text;
}

/// A move, spelled as the file spelled it.
final class SanToken extends PgnToken {
  const SanToken(super.at, this.text);

  final String text;
}

/// `--`, `Z0`, `0000` or `@@@@`: a ply where nobody moved. Chessable's
/// introduction chapters are one of these and nothing else.
final class NullMoveToken extends PgnToken {
  const NullMoveToken(super.at, this.text);

  final String text;
}

/// Text among the moves that is none of the above.
final class UnknownTextToken extends PgnToken {
  const UnknownTextToken(super.at, this.text);

  final String text;
}
