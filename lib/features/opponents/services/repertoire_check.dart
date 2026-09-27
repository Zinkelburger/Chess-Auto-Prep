/// "Check this opponent against my repertoire": walk their opening tree
/// (the games where they held the colour I am *not* holding) through the
/// book I have designated for my colour, and list where the book has no
/// answer.
///
/// Two kinds of finding, kept apart because they call for different work:
///
///  * **Unanswered** — my book continues here but has nothing against the
///    move they actually play. A gap to fill.
///  * **Past the end** — my book stops before this point, and they keep
///    going. Prep to extend, if the line is common enough to matter.
///
/// Moves are compared as SAN with check and annotation marks stripped, so a
/// `Nf3+` in a game file and `Nf3` in a repertoire agree. Transpositions are
/// not chased, the same deliberate limit the games page's deviation walk
/// keeps.
library;

import 'package:path/path.dart' as p;

import '../../../models/move_tree.dart';
import '../../../models/opening_tree.dart';
import '../../../chess_core/pgn/pgn_text.dart' show splitPgnIntoGames, stripBom;
import '../../../services/storage/storage_factory.dart';
import '../../../utils/movetext_builder.dart';
import '../../games/services/my_repertoire_settings.dart';

enum RepertoireGapKind { unanswered, pastTheEnd }

class RepertoireGap {
  const RepertoireGap({
    required this.kind,
    required this.sans,
    required this.fen,
    required this.games,
    required this.opponentScore,
  });

  final RepertoireGapKind kind;

  /// The line from the start, ending with the opponent's move.
  final List<String> sans;
  final String fen;

  /// How many of their games reach this move.
  final int games;

  /// Their score with it, 0–1, from their point of view.
  final double opponentScore;

  /// `1. e4 c5 2. Nf3 d6` — numbered from White's first move.
  String get line => buildNumberedMovetext(sans);
}

class RepertoireCheckReport {
  const RepertoireCheckReport({
    required this.bookNames,
    required this.bookChapters,
    required this.totalGames,
    required this.gaps,
  });

  /// Which designated repertoires the book was built from. Empty means none
  /// is designated for this colour, and [gaps] is meaningless.
  final List<String> bookNames;
  final int bookChapters;
  bool get hasBook => bookChapters > 0;

  /// Games in the opponent's tree for this colour.
  final int totalGames;

  /// Most-played first.
  final List<RepertoireGap> gaps;

  List<RepertoireGap> get unanswered =>
      gaps.where((g) => g.kind == RepertoireGapKind.unanswered).toList();
  List<RepertoireGap> get pastTheEnd =>
      gaps.where((g) => g.kind == RepertoireGapKind.pastTheEnd).toList();

  /// Games that reach some gap — each game is counted once, at its first.
  int get gapGames => gaps.fold(0, (n, g) => n + g.games);
}

final _sanSuffixMarks = RegExp(r'[+#!?]+$');

/// SAN without check, mate or annotation glyphs, castling normalised.
String normalizeSan(String san) => san
    .trim()
    .replaceAll(_sanSuffixMarks, '')
    .replaceAll('0-0-0', 'O-O-O')
    .replaceAll('0-0', 'O-O');

/// Every line of the book as a trie of normalised SANs.
class BookTrie {
  final Map<String, BookTrie> children = {};

  bool get isLeaf => children.isEmpty;

  void addTree(MoveTree tree) => _addNodes(tree.roots);

  void _addNodes(List<MoveNode> nodes) {
    for (final node in nodes) {
      children
          .putIfAbsent(normalizeSan(node.san), BookTrie.new)
          ._addNodes(node.children);
    }
  }

  /// Every game in [pgn] added as lines. Returns how many had moves.
  int addPgn(String pgn) {
    var added = 0;
    for (final game in splitPgnIntoGames(stripBom(pgn))) {
      final tree = MoveTree.fromPgn(game);
      if (tree.isEmpty) continue;
      addTree(tree);
      added++;
    }
    return added;
  }
}

class RepertoireCheck {
  RepertoireCheck({MyRepertoireSettings? settings})
    : _settings = settings ?? MyRepertoireSettings.instance;

  final MyRepertoireSettings _settings;

  /// The most-played gaps a report keeps.
  static const defaultMaxGaps = 60;

  /// The report for [tree], the opponent's games with [opponentIsWhite]
  /// colour, against my book for the other colour.
  Future<RepertoireCheckReport> run({
    required OpeningTree tree,
    required bool opponentIsWhite,
  }) async {
    await _settings.ensureLoaded();
    final folders = _settings.pathsFor(white: !opponentIsWhite);
    final book = BookTrie();
    var chapters = 0;
    for (final folder in folders) {
      chapters += await _addRepertoire(book, folder);
    }
    return compare(
      tree: tree,
      book: book,
      opponentIsWhite: opponentIsWhite,
      bookNames: [for (final folder in folders) p.basename(folder)],
      bookChapters: chapters,
    );
  }

  /// Adds every chapter under [folder] to [book]; returns how many had moves.
  Future<int> _addRepertoire(BookTrie book, String folder) async {
    final storage = StorageFactory.instance;
    var chapters = 0;
    try {
      for (final chapter in await storage.listChapters(folder)) {
        final text = await storage.readFile(chapter.filePath);
        if (text == null) continue;
        if (book.addPgn(text) > 0) chapters++;
      }
    } catch (_) {
      // A folder that has gone missing is simply not part of the book.
    }
    return chapters;
  }

  /// The pure half: classify [tree] against [book].
  static RepertoireCheckReport compare({
    required OpeningTree tree,
    required BookTrie book,
    required bool opponentIsWhite,
    List<String> bookNames = const [],
    int bookChapters = 1,
    int maxGaps = defaultMaxGaps,
  }) {
    final gaps = <RepertoireGap>[];
    if (!book.isLeaf) {
      _collectGaps(tree.root, book, 0, opponentIsWhite, gaps);
    }
    gaps.sort(_mostPlayedThenShortest);
    return RepertoireCheckReport(
      bookNames: bookNames,
      bookChapters: bookChapters,
      totalGames: tree.root.gamesPlayed,
      gaps: gaps.take(maxGaps).toList(),
    );
  }

  /// Walks [node]'s children alongside the book at [at]; [depth] is the ply
  /// count of [node]. A line ends at its first move off the book.
  static void _collectGaps(
    OpeningTreeNode node,
    BookTrie at,
    int depth,
    bool opponentIsWhite,
    List<RepertoireGap> gaps,
  ) {
    for (final child in node.children.values) {
      final ply = depth + 1;
      final whiteMoved = ply.isOdd;
      final opponentMoved = whiteMoved == opponentIsWhite;
      final next = at.children[normalizeSan(child.move)];
      if (next != null) {
        _collectGaps(child, next, ply, opponentIsWhite, gaps);
        continue;
      }
      // First move off the book on this line. Only the opponent's moves
      // are findings: when *their* opponent left my book, the game says
      // nothing about what they would do against it.
      if (!opponentMoved || child.gamesPlayed == 0) continue;
      gaps.add(
        RepertoireGap(
          kind: at.isLeaf
              ? RepertoireGapKind.pastTheEnd
              : RepertoireGapKind.unanswered,
          sans: child.getMovePath(),
          fen: child.fen,
          games: child.gamesPlayed,
          opponentScore: child.winRate,
        ),
      );
    }
  }

  static int _mostPlayedThenShortest(RepertoireGap a, RepertoireGap b) {
    final byGames = b.games.compareTo(a.games);
    return byGames != 0 ? byGames : a.sans.length.compareTo(b.sans.length);
  }
}
