import 'package:dartchess/dartchess.dart';

import '../fen.dart';
import 'game_text.dart';
import 'game_tree.dart';
import 'movetext_reader.dart';
import 'pgn_issue.dart';
import 'pgn_lexer.dart';
import 'pgn_token.dart';
import 'tree_edit.dart';

/// One game read from its text.
///
/// Everything the game holds is here: its header lines in file order, its
/// moves, the marker the file ended it with and the whitespace between the
/// two. Writing those four back gives the game again, which is what
/// `rewrite_gate.dart` checks before any rewrite happens.
final class GameRead {
  const GameRead({
    required this.tags,
    required this.tree,
    required this.terminator,
    required this.separator,
    required this.issues,
  });

  /// Every line of the header block, in file order.
  final List<PgnHeader> tags;

  /// The game's moves, or null when its `[FEN]` header is not a position a
  /// game can be played from.
  final GameTree? tree;

  /// The game-termination marker the file wrote — `1-0`, `0-1`, `1/2-1/2`,
  /// `*` — or null when it wrote none.
  ///
  /// It is not the `[Result]` tag and is never taken from it: a game whose
  /// tag and marker disagree keeps both, because guessing which one the user
  /// meant would change a result.
  final String? terminator;

  /// The whitespace between the header block and the first move, kept so a
  /// game written again has the blank line it had.
  final String separator;

  /// What the text held that this reader could not carry into the model.
  final List<PgnIssue> issues;

  /// Whether the game can be written again without losing anything.
  ///
  /// Any issue at all says no. A game that says no keeps its own bytes and
  /// no edit may touch it, which is the whole point of listing issues by
  /// name rather than counting them.
  bool get rewritable => issues.isEmpty;
}

/// Reads one game's PGN text.
///
/// The whole of [text] is that one game; a file is cut into games by
/// [splitChapterText], which knows where a `{}` comment is.
///
/// Nothing is thrown and nothing is guessed. Every move is checked for
/// legality here, so nothing downstream replays them: a node carries the
/// position after its own move.
GameRead readGame(String text) {
  final tokens = lexGame(text);
  final headers = tokens.takeWhile(_isHeader).toList();
  final moves = tokens.skip(headers.length).toList();
  final tags = [for (final token in headers) _header(token)];
  final root = _rootPosition(tags);
  final separator = _separator(text, headers, moves);
  if (root == null) {
    return GameRead(
      tags: tags,
      tree: null,
      terminator: null,
      separator: separator,
      issues: [_unreadablePosition(text, tags, headers)],
    );
  }
  final read = readMovetext(text, moves, Fen(root.fen));
  return GameRead(
    tags: tags,
    tree: read.tree,
    terminator: read.terminator,
    separator: separator,
    issues: read.issues,
  );
}

bool _isHeader(PgnToken token) => token is TagToken || token is HeaderLineToken;

PgnHeader _header(PgnToken token) => switch (token) {
  TagToken(:final key, :final value, :final newline) => PgnTag(
    key,
    value,
    newline: newline,
  ),
  HeaderLineToken(:final text, :final newline) => UnparsedHeader(
    text,
    newline: newline,
  ),
  _ => throw StateError('not a header token'),
};

/// The position the game starts from, or null when the `[FEN]` header names
/// none. A game with no `[FEN]` starts from the initial position.
Position? _rootPosition(List<PgnHeader> tags) {
  final fen = tagValue(tags, 'FEN');
  return fen == null ? Chess.initial : positionOf(Fen(fen));
}

PgnIssue _unreadablePosition(
  String text,
  List<PgnHeader> tags,
  List<PgnToken> headers,
) {
  final index = tags.indexWhere((tag) => tag is PgnTag && tag.key == 'FEN');
  final at = index < 0 ? 0 : headers[index].at;
  final place = placeOf(text, at);
  return UnreadablePosition(line: place.line, column: place.column);
}

String _separator(String text, List<PgnToken> headers, List<PgnToken> moves) {
  final start = switch (headers.lastOrNull) {
    TagToken(:final end) => end,
    HeaderLineToken(:final end) => end,
    _ => 0,
  };
  final end = moves.isEmpty ? start : moves.first.at;
  return end > start ? text.substring(start, end) : '';
}
