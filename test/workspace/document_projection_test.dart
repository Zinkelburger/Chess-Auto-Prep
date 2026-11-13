import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_sections.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/document/document_projection.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';

String _game(String moves, {String? section}) =>
    '[Event "Line"]\n'
    '${section == null ? '' : '[ChapterName "$section"]\n'}'
    '\n$moves *\n\n';

final _course =
    _game('1. e4', section: 'A') +
    _game('1. d4', section: 'A') +
    _game('1. c4', section: 'B');

void main() {
  group('reading a document', () {
    const path = '/Documents/repertoires/Course/Main.pgn';
    late ScriptedDocumentStore store;
    setUp(() {
      store = ScriptedDocumentStore();
      store.documents[ChapterRef.at(path)] = Opened(
        _course,
        scriptedRevision(_course),
      );
    });

    test('a chapter one past the last game is not there', () async {
      final read = await readDocument(store, ChapterRef.at(path), game: 3);
      expect((read as DocumentUnread).reason, contains('has no chapter 4'));
    });

    test('a chapter of a course file opens with where it sits', () async {
      final read =
          await readDocument(store, ChapterRef.at(path, section: 'B'))
              as DocumentShown;
      expect(read.view?.places, [2]);
    });

    test('a chapter no game is called by any more is not there', () async {
      final read = await readDocument(
        store,
        ChapterRef.at(path, section: 'Gone'),
      );
      expect(
        (read as DocumentUnread).reason,
        contains('no longer in its file'),
      );
    });
  });

  group('after an undo', () {
    final file = parseChapter(name: 'Main', text: _course, game: 2);

    test('a game the file still holds is shown as it is', () {
      expect(gameAfterUndo(file, null), same(file));
    });

    test('a game past the file\'s end becomes its last', () {
      final longer = parseChapter(
        name: 'Main',
        text: _course + _game('1. Nf3', section: 'B'),
        game: 3,
      );
      final shorter = withLines(longer, file.lines);
      expect(gameAfterUndo(shorter, null).game, 2);
    });

    test('a chapter still named is kept as it is', () {
      final view = sectionView(file, 'B');
      expect(chapterAfterUndo(file, view, const []).view, same(view));
    });

    test('a chapter no longer named becomes the one its first surviving '
        'game is called now', () {
      final gone = sectionView(file, 'Old');
      expect(chapterAfterUndo(file, gone, const [1, 2]).view?.section, 'A');
      expect(chapterAfterUndo(file, gone, const [2]).view?.section, 'B');
      expect(chapterAfterUndo(file, gone, const [3]).view?.section, 'A');
    });
  });
}
