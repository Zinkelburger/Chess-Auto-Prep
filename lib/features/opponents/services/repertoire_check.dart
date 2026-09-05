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

import '../../../models/move_tree.dart';
import '../../../models/opening_tree.dart';
import '../../../services/pgn_parsing_service.dart'
    show splitPgnIntoGames, stripBom;
import '../../../services/storage/storage_factory.dart';
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
  String get line {
    final b = StringBuffer();
    for (var i = 0; i < sans.length; i++) {
      if (i.isEven) b.write('${i ~/ 2 + 1}. ');
      if (i == 0 && sans.isNotEmpty) {
        // First move is always White's here; nothing to add.
      }
      b.write(sans[i]);
      if (i < sans.length - 1) b.write(' ');
    }
    return b.toString();
  }
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

/// SAN without check, mate or annotation glyphs, castling normalised.
String normalizeSan(String san) {
  var s = san.trim().replaceAll(RegExp(r'[+#!?]+$'), '');
  s = s.replaceAll('0-0-0', 'O-O-O').replaceAll('0-0', 'O-O');
  return s;
}

/// Every line of the book as a trie of normalised SANs.
class BookTrie {
  final Map<String, BookTrie> children = {};

  bool get isLeaf => children.isEmpty;

  void addTree(MoveTree tree) {
    void walk(BookTrie at, List<MoveNode> nodes) {
      for (final node in nodes) {
        final next = at.children.putIfAbsent(
          normalizeSan(node.san),
          BookTrie.new,
        );
        walk(next, node.children);
      }
    }

    walk(this, tree.roots);
  }

  /// Every game in [pgn] added as lines.
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

  /// The report for [tree], the opponent's games with [opponentIsWhite]
  /// colour, against my book for the other colour.
  Future<RepertoireCheckReport> run({
    required OpeningTree tree,
    required bool opponentIsWhite,
  }) async {
    await _settings.ensureLoaded();
    final folders = _settings.pathsFor(white: !opponentIsWhite);
    final book = BookTrie();
    final names = <String>[];
    var chapters = 0;
    final storage = StorageFactory.instance;
    for (final folder in folders) {
      names.add(folder.split(RegExp(r'[/\\]')).last);
      try {
        for (final chapter in await storage.listChapters(folder)) {
          final text = await storage.readFile(chapter.filePath);
          if (text == null) continue;
          chapters += book.addPgn(text) > 0 ? 1 : 0;
        }
      } catch (_) {
        // A folder that has gone missing is simply not part of the book.
      }
    }
    return compare(
      tree: tree,
      book: book,
      opponentIsWhite: opponentIsWhite,
      bookNames: names,
      bookChapters: chapters,
    );
  }

  /// The pure half: classify [tree] against [book].
  static RepertoireCheckReport compare({
    required OpeningTree tree,
    required BookTrie book,
    required bool opponentIsWhite,
    List<String> bookNames = const [],
    int bookChapters = 1,
    int maxGaps = 60,
  }) {
    final gaps = <RepertoireGap>[];

    void walk(OpeningTreeNode node, BookTrie at, int depth) {
      for (final child in node.children.values) {
        final d = depth + 1;
        final whiteMoved = d.isOdd;
        final opponentMoved = whiteMoved == opponentIsWhite;
        final next = at.children[normalizeSan(child.move)];
        if (next != null) {
          walk(child, next, d);
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

    if (!book.isLeaf) walk(tree.root, book, 0);
    gaps.sort((a, b) {
      final byGames = b.games.compareTo(a.games);
      return byGames != 0 ? byGames : a.sans.length.compareTo(b.sans.length);
    });
    return RepertoireCheckReport(
      bookNames: bookNames,
      bookChapters: bookChapters,
      totalGames: tree.root.gamesPlayed,
      gaps: gaps.take(maxGaps).toList(),
    );
  }
}
