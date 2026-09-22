/// One repertoire chapter as the deviation walker reads it: the set of
/// positions its lines reach, keyed by move and by position.
///
/// Built once per chapter file and cached by `GameDeviationService`. Every
/// root-to-leaf path of every line — mainlines and variations alike — is
/// played out from the initial position; a position reached by two move
/// orders is one node, which is what lets a transposing game count as in
/// book. Two things are read as commentary rather than book (see
/// [BookNode.alternatives]): at a position where it is our move, every child
/// after the first, and the move at the ply where an already-expanded line
/// took such a bracket.
library;

import 'package:dartchess/dartchess.dart'
    show Chess, PgnNode, PgnNodeData, Position, Side;

import '../../../models/repertoire_line.dart';
import '../../../chess_core/pgn/pgn_text.dart' as pgn;
import '../../../services/repertoire_service.dart';
import '../../../utils/chess_utils.dart' show moveToStandardUci;
import 'book_move_keys.dart';

/// Chapter files larger than this are parsed on a worker isolate. Below it
/// the parse is a few milliseconds, and the tests that drive it pump fake
/// time, under which an isolate's answer never arrives.
const int kOffThreadChapterBytes = 512 * 1024;

/// Chapter titles that are not lines of the repertoire even though they hold
/// moves: a course's introduction, its quick-start digest, its model games.
/// Used only to prefer a better *name* for a position; their moves are read
/// like anyone else's, since they never say anything the chapters do not.
final RegExp _nonRepertoireTitle = RegExp(
  r'introduction|quick\s*start|model\s*game',
  caseSensitive: false,
);

/// Whether [title] names a course's introduction, digest or model game
/// rather than a repertoire line.
bool isNonRepertoireTitle(String title) => _nonRepertoireTitle.hasMatch(title);

/// One position of a book, keyed by move (see [moveKey]). Shared by every
/// path that reaches the position, whatever their move order.
class BookNode {
  BookNode(this.path);

  /// The first move order the book used to reach this position.
  final List<String> path;

  /// Move key → the position it leads to.
  final Map<String, BookNode> children = {};

  /// Move key → the book's own SAN for it, for displaying expected moves.
  final Map<String, String> display = {};

  /// Our-side moves the book mentions here without recommending them.
  final Map<String, String> alternatives = {};

  /// A line through this position, by title.
  String? lineName;

  /// Whether the book has any recommended move from this position.
  bool get hasMoves => children.isNotEmpty;
}

/// The positions one chapter reaches, from the initial position.
class BookTree {
  BookTree._() : root = BookNode(const []) {
    _byPosition[positionKey(Chess.initial)] = root;
  }

  /// The book one chapter file describes, read for the side [ourSideWhite].
  /// [chapterName] names positions of untitled lines (see [_lineNameFor]).
  factory BookTree.fromChapter(
    String chapterContent, {
    required bool ourSideWhite,
    required String chapterName,
  }) {
    final service = RepertoireService();
    final text = pgn.stripBom(chapterContent);
    final parsed = service.parseGames(pgn.splitPgnIntoGames(text));
    // The same lines the trainer and the builder see, so the model-game and
    // custom-start rules are applied exactly once, in one place.
    final lines = service.linesFromParsedGames(
      parsed,
      declaredColor: pgn.extractRepertoireColor(text),
      courseChapter: pgn.extractCourseChapter(text),
    );
    final treeByIndex = {for (final p in parsed) p.index: p.game.moves};
    return BookTree.fromLines(
      lines,
      treeByIndex,
      ourSideWhite: ourSideWhite,
      chapterName: chapterName,
    );
  }

  /// The book [lines] describe, each read as its full PGN tree
  /// ([treeByIndex], keyed by [RepertoireLine.gameIndex]).
  factory BookTree.fromLines(
    List<RepertoireLine> lines,
    Map<int, PgnNode<PgnNodeData>> treeByIndex, {
    required bool ourSideWhite,
    required String chapterName,
  }) {
    final tree = BookTree._();
    for (final line in lines) {
      // Someone else's game illustrating the repertoire is not the
      // repertoire: its moves would extend the book far past where your own
      // preparation actually ends, and hide the deviation.
      if (line.isModelGame) continue;
      // Lines from a custom root can't be matched by a from-move-1 walk.
      if (line.startPosition.fen != Chess.initial.fen) continue;
      final pgnTree = treeByIndex[line.gameIndex];
      if (pgnTree == null) continue;
      tree._addTree(
        tree.root,
        pgnTree,
        Chess.initial,
        ply: 0,
        ourSideWhite: ourSideWhite,
        commentaryFrom: line.firstBranchOnSide(white: ourSideWhite),
        lineName: _lineNameFor(line, chapterName),
      );
    }
    return tree;
  }

  final BookNode root;

  /// Position key (see [positionKey]) → node.
  final Map<String, BookNode> _byPosition = {};

  /// Whether the chapter contributed no moves at all.
  bool get isEmpty => root.children.isEmpty;

  /// The node for the position keyed [key], or null when no line of the
  /// chapter reaches it.
  BookNode? nodeAt(String key) => _byPosition[key];

  /// What to call a line: its course chapter and title when the file still
  /// groups by title, else the chapter *file* and the title — an imported
  /// course is split into one file per chapter, and "Main Line #3" on its
  /// own does not say which opening. A hand-built "Main" chapter adds
  /// nothing and is left off.
  static String _lineNameFor(RepertoireLine line, String chapterName) {
    if (line.chapter != null) return line.qualifiedName;
    if (chapterName == 'Main' ||
        line.name.toLowerCase().startsWith(chapterName.toLowerCase())) {
      return line.name;
    }
    return '$chapterName › ${line.name}';
  }

  /// Every path of [pgnNode] into the book under [node]. A move that is
  /// illegal where it stands ends its branch: nothing after it can be
  /// compared with a real game anyway.
  ///
  /// Commentary — every child after the first at our own move, and the move
  /// at [commentaryFrom] — is recorded in [BookNode.alternatives] and not
  /// followed.
  void _addTree(
    BookNode node,
    PgnNode<PgnNodeData> pgnNode,
    Position pos, {
    required int ply,
    required bool ourSideWhite,
    required int? commentaryFrom,
    required String lineName,
  }) {
    _nameNode(node, lineName);
    final ourMove = (pos.turn == Side.white) == ourSideWhite;
    for (var i = 0; i < pgnNode.children.length; i++) {
      final child = pgnNode.children[i];
      final san = child.data.san;
      final move = pos.parseSan(san);
      if (move == null) continue;
      final key = moveToStandardUci(pos, move);
      if ((ourMove && i > 0) || ply == commentaryFrom) {
        node.alternatives.putIfAbsent(key, () => san);
        continue;
      }
      node.display.putIfAbsent(key, () => san);
      final nextPos = pos.play(move);
      final next = node.children.putIfAbsent(
        key,
        () => _byPosition.putIfAbsent(
          positionKey(nextPos),
          () => BookNode([...node.path, san]),
        ),
      );
      _addTree(
        next,
        child,
        nextPos,
        ply: ply + 1,
        ourSideWhite: ourSideWhite,
        commentaryFrom: commentaryFrom,
        lineName: lineName,
      );
    }
  }

  /// The first line through a position names it, unless that line is a
  /// course's introduction or digest and a real chapter comes along later.
  static void _nameNode(BookNode node, String lineName) {
    final current = node.lineName;
    if (current == null ||
        (isNonRepertoireTitle(current) && !isNonRepertoireTitle(lineName))) {
      node.lineName = lineName;
    }
  }
}
