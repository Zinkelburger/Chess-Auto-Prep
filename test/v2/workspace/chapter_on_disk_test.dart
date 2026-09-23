// The whole write path on real files: a chapter in a throwaway Documents
// folder, opened, edited and saved through PgnFileStore. Nothing here looks
// at the profile the app really uses.
import 'dart:io';

import 'package:chess_auto_prep/v2/workspace/copy_aside.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/save_state.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../storage/store_fixture.dart';
import '../support/fixtures.dart';

void main() {
  late StoreFixture files;
  late DocumentSaver saver;
  late DocumentSession session;
  late ChapterRef chapter;

  setUp(() async {
    files = await StoreFixture.create();
    chapter = ChapterRef(
      repertoire: 'KID',
      name: 'Main',
      path: files.ref('repertoires/KID/Main.pgn').path,
    );
    await files.put(chapter, whiteChapter);
    saver = DocumentSaver(files.store, delay: Duration.zero);
    session = DocumentSession(files.store, saver);
    await session.open(chapter);
  });

  tearDown(() async {
    session.dispose();
    saver.dispose();
    await files.dispose();
  });

  String onDisk() => File(chapter.path).readAsStringSync();

  /// Waits for the save the edit asked for to reach the disk. Real file
  /// work takes as many turns of the event loop as it takes.
  Future<void> settled() async {
    for (var i = 0; i < 400; i++) {
      if (saver.state is! Saving && saver.state is! Unsaved) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }

  /// The games of the file as written, so an untouched one can be compared
  /// byte for byte.
  List<String> gamesOf(String text) =>
      text.split('[Event ').map((game) => game.trimRight()).toList();

  test(
    'a move played in the workspace is in the file the old app reads',
    () async {
      session.toEnd(); // 1. d4 d5 2. c4 e6 3. cxd5 exd5 4. Nc3
      expect(session.currentMove?.san, 'Nc3');
      session.playMove('g8f6'); // 4... Nf6
      final played = session.cursor;
      session.setComment(played, 'Their main answer');
      await settled();
      expect(saver.state, isA<Saved>());

      final written = parseChapter(name: 'Main', text: onDisk());
      expect(written.tree.nodeAt(played)?.san, 'Nf6');
      expect(written.tree.nodeAt(played)?.comment, 'Their main answer');
      expect(written.gameCount, 3, reason: 'the line was extended, not added');
      expect(
        gamesOf(onDisk()).last,
        gamesOf(whiteChapter).last,
        reason: 'a game nobody edited keeps its bytes',
      );
    },
  );

  test('the version it replaced is kept, and undo puts it back', () async {
    session.setComment(const NodePath.root(), 'Read this first');
    await settled();
    expect(onDisk(), contains('{Read this first}'));
    expect(files.keptTexts(chapter), [whiteChapter]);
    await session.undo();
    expect(onDisk(), whiteChapter);
    expect(saver.canUndo, isFalse);
  });

  test(
    'a file changed underneath is a conflict, and the draft stays',
    () async {
      File(chapter.path).writeAsStringSync('$whiteChapter\n[Event "Theirs"]\n');
      session.setComment(const NodePath.root(), 'Mine');
      await settled();
      expect(saver.state, isA<SaveConflict>());
      expect(onDisk(), contains('Theirs'));
      expect(session.commentAt(const NodePath.root()), contains('Mine'));
      expect(await saveCopy(session, saver, 'Main draft'), isA<CopySaved>());
      expect(
        File(
          p.join(p.dirname(chapter.path), 'Main draft.pgn'),
        ).readAsStringSync(),
        contains('Mine'),
      );
    },
  );
}
