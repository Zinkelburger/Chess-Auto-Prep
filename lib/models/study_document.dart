/// A local study: one PGN file holding multiple annotated games
/// ("chapters"), each an editable [MoveTree] — think Lichess studies,
/// stored on disk.
///
/// Round-trip contract: unknown PGN headers are preserved per chapter, the
/// chapter name lives in `[Event]`, and chapters starting from a custom
/// position carry `[FEN]`/`[SetUp "1"]`.
library;

import '../constants/chess_constants.dart';
import '../services/pgn_parsing_service.dart'
    show splitPgnIntoGames, extractHeaders, stripBom;
import 'move_tree.dart';

class StudyChapter {
  String name;

  /// Original PGN headers (minus the ones this model owns — Event/FEN/SetUp
  /// are regenerated on save).  Preserved so tags like ECO or Annotator
  /// survive a round-trip.
  final Map<String, String> headers;

  final MoveTree tree;

  StudyChapter({
    required this.name,
    Map<String, String>? headers,
    MoveTree? tree,
    String? startingFen,
  }) : headers = headers ?? {},
       tree = tree ?? MoveTree(startingFen: startingFen);

  /// Result header token used to terminate the movetext ("*" when absent).
  String get result => headers['Result'] ?? '*';

  String toPgn() {
    final lines = <String>[];
    lines.add('[Event "${_escape(name)}"]');
    for (final entry in headers.entries) {
      if (entry.key == 'Event' || entry.key == 'FEN' || entry.key == 'SetUp') {
        continue;
      }
      lines.add('[${entry.key} "${_escape(entry.value)}"]');
    }
    if (tree.startingFen != kStandardStartFen) {
      lines.add('[FEN "${tree.startingFen}"]');
      lines.add('[SetUp "1"]');
    }

    final moveText = tree.toPgnMoveText();
    final body = moveText.isEmpty ? result : '$moveText $result';
    return '${lines.join('\n')}\n\n$body\n';
  }

  static String _escape(String value) =>
      value.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
}

class StudyDocument {
  /// Absolute path of the backing `.pgn` file (`null` until first save).
  String? filePath;

  /// Display name (the file's basename).
  String name;

  final List<StudyChapter> chapters;

  StudyDocument({
    this.filePath,
    required this.name,
    List<StudyChapter>? chapters,
  }) : chapters = chapters ?? [];

  /// A new study with one empty chapter.
  factory StudyDocument.fresh(String name) => StudyDocument(
    name: name,
    chapters: [StudyChapter(name: 'Chapter 1')],
  );

  factory StudyDocument.fromPgn(
    String content, {
    required String name,
    String? filePath,
  }) {
    final chapters = <StudyChapter>[];
    final games = splitPgnIntoGames(stripBom(content));
    for (int i = 0; i < games.length; i++) {
      final gameText = games[i];
      final headers = extractHeaders(gameText);
      final chapterName = headers['Event']?.trim().isNotEmpty == true
          ? headers['Event']!
          : 'Chapter ${i + 1}';
      // MoveTree.fromPgn reads the [FEN] header itself.
      chapters.add(
        StudyChapter(
          name: chapterName,
          headers: headers,
          tree: MoveTree.fromPgn(gameText),
        ),
      );
    }
    if (chapters.isEmpty) {
      chapters.add(StudyChapter(name: 'Chapter 1'));
    }
    return StudyDocument(name: name, filePath: filePath, chapters: chapters);
  }

  String toPgn() => chapters.map((c) => c.toPgn()).join('\n');
}
