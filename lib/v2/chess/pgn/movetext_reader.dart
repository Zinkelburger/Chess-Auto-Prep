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
/// from [rootFen]. [text] is the game's own text, for locating issues.
///
/// Move numbers are ignored: whose move it is comes from the board, never
/// from the number in front of it. Courses that number Black's ply `5.` are
/// the commonest shape in a real repertoire folder, and a reader that
/// believed the number would mis-read all of them.
MovetextRead readMovetext(String text, List<PgnToken> tokens, Fen rootFen) {
  final moves = _Moves(text, rootFen);
  for (final token in tokens) {
    moves.take(token);
  }
  return moves.finished();
}

/// A move being built. Mutable only in here; the tree handed out is values.
final class _Node {
  _Node(this.built);

  final MoveNode built;
  String? starting;
  String? comment;
  final List<int> nags = [];
  final List<_Node> children = [];
}

/// One level of variation: where the next move goes, and where the last one
/// went, which is what a `(` opens an alternative to.
final class _Frame {
  _Frame(this.siblings, this.fen);

  List<_Node> siblings;
  Fen fen;
  _Node? node;
  List<_Node>? nodeSiblings;
  Fen? nodeFen;
  String? starting;

  void attach(_Node child) {
    child.starting = starting;
    starting = null;
    siblings.add(child);
    nodeSiblings = siblings;
    nodeFen = fen;
    node = child;
    siblings = child.children;
    fen = child.built.fen;
  }
}

final class _Moves {
  _Moves(this.text, this.rootFen) {
    _stack.add(_Frame(_top, rootFen));
  }

  final String text;
  final Fen rootFen;

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
        _move(_played(_stack.last.fen, text, at), at);
      case NullMoveToken(:final text, :final at):
        _move(_nullPlayed(_stack.last.fen, text, at), at);
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
        rootFen: rootFen,
        rootComment: _rootComment,
        children: _freeze(_top),
      ),
      terminator: _terminator,
      issues: List.unmodifiable(_issues),
    );
  }

  /// The node [spelling] makes from [fen], or null with an issue recorded.
  MoveNode? _played(Fen fen, String spelling, int at) {
    final position = positionOf(fen);
    final move = position?.parseSan(parseableSan(spelling));
    if (position == null || move == null) {
      _say(at, (l, c) => IllegalMove(spelling, line: l, column: c));
      return null;
    }
    final (next, san) = position.makeSan(move);
    return MoveNode(
      san: san,
      spelling: san == spelling ? null : spelling,
      uci: move.uci,
      fen: Fen(next.fen),
    );
  }

  MoveNode? _nullPlayed(Fen fen, String spelling, int at) {
    final node = nullMoveNode(fen, spelling: spelling);
    if (node != null) return node;
    _say(at, (l, c) => IllegalMove(spelling, line: l, column: c));
    return null;
  }

  void _move(MoveNode? built, int at) {
    if (_terminator != null && !_saidMovesFollowed) {
      _saidMovesFollowed = true;
      _say(at, (l, c) => MovesAfterTermination(line: l, column: c));
    }
    if (built == null) return;
    _stack.last.attach(_Node(built));
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
    final fen = frame.nodeFen;
    if (siblings == null || fen == null) {
      _say(at, (l, c) => StrayVariationStart(line: l, column: c));
      _stack.add(_Frame([], frame.fen));
      return;
    }
    _stack.add(_Frame(siblings, fen));
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
