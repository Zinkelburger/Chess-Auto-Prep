import 'package:dartchess/dartchess.dart' show Position;

import '../fen.dart';
import 'game_tree.dart';
import 'pgn_issue.dart';
import 'pgn_token.dart';
import 'tree_edit.dart';

/// The moves of one game, the marker it ended with, and what could not be
/// read.
typedef MovetextRead = ({
  GameTree tree,
  String? terminator,
  List<PgnIssue> issues,
});

/// Builds the game tree from [tokens], the movetext of a game that starts
/// at [root]. [text] is the game's own text, for locating issues.
///
/// Move numbers are ignored: whose move it is comes from the board, never
/// from the number in front of it. Courses that number Black's ply `5.` are
/// the commonest shape in a real repertoire folder, and a reader that
/// believed the number would mis-read all of them.
///
/// Each position is carried down from the move that made it rather than
/// parsed again from its FEN. Reading a position back costs several times
/// what playing a move does, and a five megabyte file holds millions of
/// moves.
MovetextRead readMovetext(String text, List<PgnToken> tokens, Position root) {
  final moves = _Moves(text, root);
  for (final token in tokens) {
    moves.take(token);
  }
  return moves.finished();
}

/// A move being built. Mutable only in here; the tree handed out is values.
final class _Node {
  _Node(this.built, this.after);

  final MoveNode built;

  /// The position after [built], so the next move is played rather than
  /// read back out of a FEN.
  final Position after;
  String? starting;
  String? comment;
  final List<int> nags = [];
  final List<_Node> children = [];
}

/// One level of variation: where the next move goes, and where the last one
/// went, which is what a `(` opens an alternative to.
final class _Frame {
  _Frame(this.siblings, this.position);

  List<_Node> siblings;
  Position position;
  _Node? node;
  List<_Node>? nodeSiblings;
  Position? nodePosition;
  String? starting;

  void attach(_Node child) {
    child.starting = starting;
    starting = null;
    siblings.add(child);
    nodeSiblings = siblings;
    nodePosition = position;
    node = child;
    siblings = child.children;
    position = child.after;
  }
}

final class _Moves {
  _Moves(this.text, this.root) {
    _stack.add(_Frame(_top, root));
  }

  final String text;
  final Position root;

  /// The game's first moves. The root frame's own list moves down the tree
  /// as moves are attached to it, so it is not this one.
  final List<_Node> _top = [];
  final List<_Frame> _stack = [];
  final List<PgnIssue> _issues = [];
  String? _rootComment;
  String? _terminator;
  bool _saidMovesFollowed = false;

  void take(PgnToken token) {
    switch (token) {
      case SanToken(:final text, :final at):
        _move(_played(_stack.last.position, text, at), at);
      case NullMoveToken(:final text, :final at):
        _move(_nullPlayed(_stack.last.position, text, at), at);
      case CommentToken():
        _comment(token);
      case NagToken(:final value, :final at):
        _nag(value, at);
      case VariationOpen(:final at):
        _openVariation(at);
      case VariationClose(:final at):
        _closeVariation(at);
      case TerminationToken(:final text, :final at):
        _terminate(text, at);
      case EscapeLineToken(:final at):
        _say(at, (l, c) => EscapeInMovetext(line: l, column: c));
      case UnknownTextToken(:final text, :final at):
        _say(at, (l, c) => UnknownToken(text, line: l, column: c));
      case MoveNumberToken():
      case TagToken():
      case HeaderLineToken():
        break;
    }
  }

  MovetextRead finished() {
    while (_stack.length > 1) {
      _stack.removeLast();
      _say(text.length, (l, c) => UnterminatedVariation(line: l, column: c));
    }
    return (
      tree: GameTree(
        rootFen: Fen(root.fen),
        rootComment: _rootComment,
        children: _freeze(_top),
      ),
      terminator: _terminator,
      issues: List.unmodifiable(_issues),
    );
  }

  /// The node [spelling] makes from [position], or null with an issue
  /// recorded.
  _Node? _played(Position position, String spelling, int at) {
    final move = position.parseSan(parseableSan(spelling));
    if (move == null) {
      _say(at, (l, c) => IllegalMove(spelling, line: l, column: c));
      return null;
    }
    final (next, san) = position.makeSan(move);
    return _Node(
      MoveNode(
        san: san,
        spelling: san == spelling ? null : spelling,
        uci: move.uci,
        fen: Fen(next.fen),
      ),
      next,
    );
  }

  _Node? _nullPlayed(Position position, String spelling, int at) {
    final node = nullMoveNode(Fen(position.fen), spelling: spelling);
    final after = node == null ? null : positionOf(node.fen);
    if (node != null && after != null) return _Node(node, after);
    _say(at, (l, c) => IllegalMove(spelling, line: l, column: c));
    return null;
  }

  void _move(_Node? played, int at) {
    if (_terminator != null && !_saidMovesFollowed) {
      _saidMovesFollowed = true;
      _say(at, (l, c) => MovesAfterTermination(line: l, column: c));
    }
    if (played == null) return;
    _stack.last.attach(played);
  }

  void _comment(CommentToken token) {
    if (!token.closed) {
      _say(token.at, (l, c) => UnterminatedComment(line: l, column: c));
    }
    final frame = _stack.last;
    final node = frame.node;
    if (node != null) {
      node.comment = _joined(node.comment, token.text);
      return;
    }
    if (_stack.length == 1) {
      _rootComment = _joined(_rootComment, token.text);
      return;
    }
    frame.starting = _joined(frame.starting, token.text);
  }

  void _nag(int value, int at) {
    final node = _stack.last.node;
    if (node == null) {
      _say(at, (l, c) => StrayAnnotation(line: l, column: c));
      return;
    }
    node.nags.add(value);
  }

  void _openVariation(int at) {
    final frame = _stack.last;
    final siblings = frame.nodeSiblings;
    final position = frame.nodePosition;
    if (siblings == null || position == null) {
      _say(at, (l, c) => StrayVariationStart(line: l, column: c));
      _stack.add(_Frame([], frame.position));
      return;
    }
    _stack.add(_Frame(siblings, position));
  }

  void _closeVariation(int at) {
    if (_stack.length == 1) {
      _say(at, (l, c) => StrayVariationEnd(line: l, column: c));
      return;
    }
    if (_stack.removeLast().node != null) return;
    _say(at, (l, c) => EmptyVariation(line: l, column: c));
  }

  void _terminate(String marker, int at) {
    if (_stack.length > 1 || _terminator != null) {
      _say(at, (l, c) => ExtraTermination(marker, line: l, column: c));
      return;
    }
    _terminator = marker;
  }

  void _say(int at, PgnIssue Function(int line, int column) make) {
    final place = placeOf(text, at);
    _issues.add(make(place.line, place.column));
  }
}

/// Two comments in a row are one comment: `{a} {b}` and `{a b}` say the same
/// thing to every reader, and joining them is what lets a game with either
/// come back as itself.
String _joined(String? before, String text) =>
    before == null ? text : '$before $text';

/// [nodes] as immutable values.
///
/// Iterative on purpose: a game's main line is as deep as it has moves, and
/// a two-thousand-ply game must not depend on the stack. Every child appears
/// after its parent, so building in reverse has each node's children ready
/// before the node itself.
List<MoveNode> _freeze(List<_Node> nodes) {
  final order = <_Node>[];
  final pending = [...nodes];
  while (pending.isNotEmpty) {
    final node = pending.removeLast();
    order.add(node);
    pending.addAll(node.children);
  }
  final made = <_Node, MoveNode>{};
  for (final node in order.reversed) {
    made[node] = node.built.copyWith(
      startingComment: node.starting,
      comment: node.comment,
      nags: List.unmodifiable(node.nags),
      children: List.unmodifiable([
        for (final child in node.children) made[child]!,
      ]),
    );
  }
  return List.unmodifiable([for (final node in nodes) made[node]!]);
}

/// [san] in the one spelling dartchess parses: letter-O castling and an
/// explicit upper-case promotion piece. The move keeps how the file wrote it
/// in [MoveNode.spelling]; this is only how it is looked up.
String parseableSan(String san) {
  if (san.startsWith('0')) return san.replaceAll('0', 'O');
  final promotion = _promotion.firstMatch(san);
  if (promotion == null) return san;
  return '${promotion[1]}=${promotion[2]!.toUpperCase()}${promotion[3]}';
}

final _promotion = RegExp(r'^(.*[a-h][1-8])=?([nbrqkNBRQK])([+#]?)$');
