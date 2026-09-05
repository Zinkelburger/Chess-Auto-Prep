/// A study chapter on disk is a Lichess study export: `[Event "Study:
/// Chapter"]`, `[StudyName]`, `[ChapterName]`, `[Orientation]`, and a
/// Lichess file read back gives clean chapter names and the right board
/// orientation.
library;

import 'package:chess_auto_prep/models/study_document.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

const _lichessExport = '''
[Event "Italian Game: Giuoco Piano intro"]
[Site "https://lichess.org/study/abcdefgh/ijklmnop"]
[Result "*"]
[Variant "Standard"]
[ECO "C53"]
[Opening "Italian Game: Giuoco Piano"]
[Annotator "https://lichess.org/@/someone"]
[StudyName "Italian Game"]
[ChapterName "Giuoco Piano intro"]
[UTCDate "2024.01.01"]
[UTCTime "12:00:00"]
[ChapterURL "https://lichess.org/study/abcdefgh/ijklmnop"]
[Orientation "black"]

{ Welcome to the Italian. [%cal Ge2e4] }
1. e4 e5 2. Nf3 Nc6 3. Bc4 { The Italian bishop eyes f7. } *

[Event "Italian Game: Endgame"]
[Result "*"]
[StudyName "Italian Game"]
[ChapterName "Endgame"]
[FEN "8/8/4k3/8/8/4K3/4P3/8 b - - 0 1"]
[SetUp "1"]

1... Kd6 *
''';

void main() {
  group('reading a Lichess export', () {
    final doc = StudyDocument.fromPgn(_lichessExport, name: 'Italian Game');

    test('chapter names come from ChapterName, not the prefixed Event', () {
      expect(doc.chapters.map((c) => c.name), [
        'Giuoco Piano intro',
        'Endgame',
      ]);
    });

    test('orientation follows the Orientation tag', () {
      expect(doc.chapters[0].orientation, Side.black);
    });

    test('without a tag, a set-up position faces the side to move', () {
      expect(doc.chapters[1].orientation, Side.black);
      expect(StudyChapter(name: 'x').orientation, Side.white);
      expect(
        StudyChapter(
          name: 'x',
          startingFen: '8/8/4k3/8/8/4K3/4P3/8 w - - 0 1',
        ).orientation,
        Side.white,
      );
    });

    test('the introduction before the first move is kept', () {
      expect(
        doc.chapters[0].tree.rootComment,
        'Welcome to the Italian. [%cal Ge2e4]',
      );
    });

    test('owned tags are not kept as loose headers; the rest are', () {
      final headers = doc.chapters[0].headers;
      expect(headers.keys, isNot(contains('Event')));
      expect(headers.keys, isNot(contains('ChapterName')));
      expect(headers.keys, isNot(contains('Orientation')));
      expect(
        headers['ChapterURL'],
        'https://lichess.org/study/abcdefgh/ijklmnop',
      );
      expect(headers['ECO'], 'C53');
    });
  });

  group('writing', () {
    test('a chapter carries the Lichess tag set', () {
      final doc = StudyDocument.fresh('Endgames');
      doc.chapters.single
        ..name = 'Lucena'
        ..orientation = Side.black;
      final out = doc.toPgn();
      expect(out, contains('[Event "Endgames: Lucena"]'));
      expect(out, contains('[StudyName "Endgames"]'));
      expect(out, contains('[ChapterName "Lucena"]'));
      expect(out, contains('[Orientation "black"]'));
    });

    test('a Lichess export round-trips through save and reopen', () {
      final once = StudyDocument.fromPgn(
        _lichessExport,
        name: 'Italian Game',
      ).toPgn();
      final again = StudyDocument.fromPgn(once, name: 'Italian Game');
      expect(again.chapters.map((c) => c.name), [
        'Giuoco Piano intro',
        'Endgame',
      ]);
      expect(again.chapters[0].orientation, Side.black);
      expect(again.chapters[0].tree.rootComment, contains('Welcome'));
      expect(again.chapters[0].headers['ECO'], 'C53');
      expect(again.toPgn(), once);
    });

    test('a chapter name is free text — a colon is not a file problem', () {
      final doc = StudyDocument.fresh('Games');
      doc.chapters.single.name = 'Fischer - Spassky: Game 6?';
      final again = StudyDocument.fromPgn(doc.toPgn(), name: 'Games');
      expect(again.chapters.single.name, 'Fischer - Spassky: Game 6?');
    });
  });

  group('nameFromHeaders', () {
    test('strips the study prefix from an older Event-only file', () {
      expect(
        StudyChapter.nameFromHeaders(
          {'Event': 'Italian Game: Evans Gambit'},
          fallback: 'Chapter 1',
          studyName: 'Italian Game',
        ),
        'Evans Gambit',
      );
    });

    test('keeps an Event that merely contains a colon', () {
      expect(
        StudyChapter.nameFromHeaders(
          {'Event': 'Round 3: Carlsen - Caruana'},
          fallback: 'Chapter 1',
          studyName: 'My games',
        ),
        'Round 3: Carlsen - Caruana',
      );
    });

    test('falls back to the players, then the fallback', () {
      expect(
        StudyChapter.nameFromHeaders({
          'White': 'Fischer',
          'Black': 'Spassky',
        }, fallback: 'Chapter 7'),
        'Fischer - Spassky',
      );
      expect(
        StudyChapter.nameFromHeaders({'Event': '?'}, fallback: 'Chapter 7'),
        'Chapter 7',
      );
    });
  });
}
