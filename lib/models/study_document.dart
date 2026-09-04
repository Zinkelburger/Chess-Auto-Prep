/// A local study: one PGN file holding multiple annotated games
/// ("chapters"), each an editable [MoveTree] — think Lichess studies,
/// stored on disk.
///
/// Round-trip contract: unknown PGN headers are preserved per chapter, the
/// chapter name lives in `[Event]`, chapters starting from a custom position
/// carry `[FEN]`/`[SetUp "1"]`, and the chapter's own opening note — the prose
/// a study puts before move 1 — is kept in [StudyChapter.intro].
///
/// The contract is not cosmetic. Editing anywhere in a study (playing a move
/// counts) rewrites the *whole file* from this model, so whatever the model
/// cannot hold is deleted from the reader's study on the next autosave.
library;

import 'package:dartchess/dartchess.dart' show PgnGame;

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

  /// The chapter's own note, written before its first move — where a Lichess
  /// study chapter's introduction lives. Empty when there is none.
  String intro;

  StudyChapter({
    required this.name,
    Map<String, String>? headers,
    MoveTree? tree,
    String? startingFen,
    this.intro = '',
  }) : headers = headers ?? {},
       tree = tree ?? MoveTree(startingFen: startingFen);

  /// One chapter, parsed from the text of one game — the single place that
  /// decides what a chapter keeps, so a caller cannot build one that quietly
  /// keeps less.
  factory StudyChapter.fromGameText(String gameText, {String? name}) {
    final headers = extractHeaders(gameText);
    final headerName = headers['Event']?.trim();
    return StudyChapter(
      name: name ?? (headerName?.isNotEmpty == true ? headerName! : 'Chapter'),
      headers: headers,
      tree: MoveTree.fromPgn(gameText),
      intro: _introOf(gameText),
    );
  }

  /// The `{ … }` blocks a game opens with, before any move.
  static String _introOf(String gameText) {
    try {
      final comments = PgnGame.parsePgn(gameText).comments;
      return comments.map((c) => c.trim()).where((c) => c.isNotEmpty).join(' ');
    } catch (_) {
      return '';
    }
  }

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
    final opening = intro.trim().isEmpty
        ? ''
        : '{${intro.trim().replaceAll('{', '').replaceAll('}', '')}} ';
    final body = moveText.isEmpty
        ? '$opening$result'
        : '$opening$moveText $result';
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
      chapters.add(StudyChapter.fromGameText(gameText, name: chapterName));
    }
    if (chapters.isEmpty) {
      chapters.add(StudyChapter(name: 'Chapter 1'));
    }
    return StudyDocument(name: name, filePath: filePath, chapters: chapters);
  }

  String toPgn() => chapters.map((c) => c.toPgn()).join('\n');
}
