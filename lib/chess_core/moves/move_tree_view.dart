/// Read-only move access shared by mutable owners and immutable projections.
library;

import 'package:dartchess/dartchess.dart';
import '../../constants/chess_constants.dart';
import 'tree_path.dart';
import '../../models/move_tree_node_view.dart';
import 'package:chess_auto_prep/chess_core/pgn/move_text_writer.dart';
import '../../utils/chess_utils.dart' show tryParseFen;
import '../../utils/fen_utils.dart';

abstract interface class MoveNodeView implements MoveTreeNodeView {
  int get id;
  String get fen;
  String? get comment;
  String? get startingComment;
  List<int>? get nags;
  bool get isEphemeral;
  List<MoveNodeView> get children;
  Position get position;
  Position? get positionOrNull;
}

abstract class MoveTreeView {
  /// Stable editing-session identity, distinct from this revision's values.
  Object get identity => this;
  String get startingFen;
  String? get rootComment;
  List<MoveNodeView> get roots;
  int get version;
  Position? get startingPositionOrNull => tryParseFen(startingFen);
  Position get startingPosition => startingPositionOrNull ?? Chess.initial;

  /// Node at [path], or `null` if the path is empty or out of range.
  MoveNodeView? nodeAt(TreePath path) {
    if (path.isEmpty) return null;
    var siblings = roots;
    MoveNodeView? node;
    for (final index in path.indices) {
      if (index < 0 || index >= siblings.length) return null;
      node = siblings[index];
      siblings = node.children;
    }
    return node;
  }

  /// Ordered list of nodes from root to [path] (inclusive).
  List<MoveNodeView> nodeListAt(TreePath path) {
    final result = <MoveNodeView>[];
    var siblings = roots;
    for (final idx in path.indices) {
      if (idx < 0 || idx >= siblings.length) break;
      result.add(siblings[idx]);
      siblings = siblings[idx].children;
    }
    return result;
  }

  /// FEN at [path].  Empty path → [startingFen].
  String fenAt(TreePath path) {
    if (path.isEmpty) return startingFen;
    final node = nodeAt(path);
    return node?.fen ?? startingFen;
  }

  /// Position at [path].  Empty or invalid path → [startingPosition].
  /// O(depth) pointer walk; never parses a FEN the tree already parsed.
  Position positionAt(TreePath path) {
    if (path.isEmpty) return startingPosition;
    return nodeAt(path)?.position ?? startingPosition;
  }

  /// [positionAt] that refuses instead of substituting the start: null when
  /// [path] is unknown or the FEN there does not parse.  Callers that go on
  /// to *derive* a position from the result want this one.
  Position? positionOrNullAt(TreePath path) {
    if (path.isEmpty) return startingPositionOrNull;
    return nodeAt(path)?.positionOrNull;
  }

  /// SAN sequence from root to [path].
  List<String> sanSequenceAt(TreePath path) =>
      nodeListAt(path).map((n) => n.san).toList();

  /// Walk mainline (`children[0]`) to the leaf, starting from [path].
  TreePath mainlineEndFrom(TreePath path) {
    final indices = path.toList();
    var siblings = path.isEmpty ? roots : (nodeAt(path)?.children ?? []);
    while (siblings.isNotEmpty) {
      indices.add(0);
      siblings = siblings.first.children;
    }
    return TreePath.from(indices);
  }

  /// Whether the tree has any moves.
  bool get isEmpty => roots.isEmpty;
  bool get isNotEmpty => roots.isNotEmpty;

  /// Whether [path] points to a valid node.
  bool isValidPath(TreePath path) {
    if (path.isEmpty) return true;
    return nodeAt(path) != null;
  }

  String? commentAt(TreePath path) =>
      path.isEmpty ? rootComment : nodeAt(path)?.comment;

  /// Serialize this tree to PGN move text (no headers).
  String toPgnMoveText() {
    final (startMoveNumber, startIsWhite) = (
      fullMoveNumber(startingFen),
      isWhiteToMove(startingFen),
    );
    return writeMoveText(
      roots: roots,
      startMoveNumber: startMoveNumber,
      startIsWhite: startIsWhite,
      rootComment: rootComment,
    );
  }

  /// Serialize to full PGN including headers.
  String toPgn({String? event, String? white, String? black, String? result}) {
    final headers = <String>[];
    headers.add('[Event "${event ?? "?"}"]');
    headers.add(
      '[Date "${DateTime.now().toIso8601String().split('T').first}"]',
    );
    headers.add('[White "${white ?? "?"}"]');
    headers.add('[Black "${black ?? "?"}"]');
    headers.add('[Result "${result ?? "*"}"]');
    if (startingFen != kStandardStartFen) {
      headers.add('[FEN "$startingFen"]');
      headers.add('[SetUp "1"]');
    }

    final moveText = toPgnMoveText();
    return [...headers, '', moveText].join('\n');
  }
}
