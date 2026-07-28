import 'package:chess_auto_prep/services/study_import/import_source.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseImportSource — Lichess', () {
    test('recognises a study URL', () {
      final source = parseImportSource('https://lichess.org/study/WcJ8Iyaz');
      expect(source, isA<LichessStudySource>());
      expect((source as LichessStudySource).studyId, 'WcJ8Iyaz');
      expect(source.chapterId, isNull);
    });

    test('recognises a chapter URL', () {
      final source =
          parseImportSource('https://lichess.org/study/WcJ8Iyaz/mVfBcMlS')
              as LichessStudySource;
      expect(source.studyId, 'WcJ8Iyaz');
      expect(source.chapterId, 'mVfBcMlS');
    });

    test('accepts a scheme-less URL and www', () {
      expect(
        parseImportSource('www.lichess.org/study/WcJ8Iyaz'),
        const LichessStudySource(studyId: 'WcJ8Iyaz'),
      );
    });

    test('ignores query strings and fragments', () {
      expect(
        parseImportSource('https://lichess.org/study/WcJ8Iyaz?page=2#12'),
        const LichessStudySource(studyId: 'WcJ8Iyaz'),
      );
    });

    test('recognises the all-studies-by-user URL', () {
      expect(
        parseImportSource('https://lichess.org/study/by/DrNykterstein'),
        const LichessUserStudiesSource('DrNykterstein'),
      );
    });

    test('rejects an id that is not 8 URL-safe characters', () {
      expect(parseImportSource('https://lichess.org/study/short'), isNull);
      expect(
        parseImportSource('https://lichess.org/study/waytoolongid'),
        isNull,
      );
    });

    test('rejects non-study Lichess URLs', () {
      expect(parseImportSource('https://lichess.org/@/thibault'), isNull);
      expect(parseImportSource('https://lichess.org/broadcast'), isNull);
    });

    test('a trailing slug is not mistaken for a chapter id', () {
      final source =
          parseImportSource('https://lichess.org/study/WcJ8Iyaz/embed')
              as LichessStudySource;
      expect(source.chapterId, isNull);
    });
  });

  group('parseImportSource — chessgames.com', () {
    test('recognises a collection URL', () {
      expect(
        parseImportSource(
          'https://www.chessgames.com/perl/chesscollection?cid=1012548',
        ),
        const ChessgamesCollectionSource('1012548'),
      );
    });

    test('accepts extra query params in any order', () {
      expect(
        parseImportSource(
          'chessgames.com/perl/chesscollection?order=oldest&cid=1012548',
        ),
        const ChessgamesCollectionSource('1012548'),
      );
    });

    test('rejects a non-numeric cid', () {
      expect(
        parseImportSource('https://www.chessgames.com/perl/x?cid=abc'),
        isNull,
      );
    });

    test('rejects a chessgames URL with no cid', () {
      expect(
        parseImportSource(
          'https://www.chessgames.com/perl/chessgame?gid=1008366',
        ),
        isNull,
      );
    });
  });

  group('parseImportSource — rejections', () {
    test('empty and whitespace', () {
      expect(parseImportSource(''), isNull);
      expect(parseImportSource('   '), isNull);
    });

    test('an unrelated host', () {
      expect(parseImportSource('https://chess.com/study/WcJ8Iyaz'), isNull);
    });

    test('a host that merely ends in lichess.org', () {
      expect(
        parseImportSource('https://evil-lichess.org/study/WcJ8Iyaz'),
        isNull,
      );
    });

    test('surrounding whitespace is tolerated', () {
      expect(
        parseImportSource('  https://lichess.org/study/WcJ8Iyaz  '),
        const LichessStudySource(studyId: 'WcJ8Iyaz'),
      );
    });
  });
}
