import 'package:chess_auto_prep/constants/chess_constants.dart';
import 'package:chess_auto_prep/services/generation/course/chapter_planner.dart';
import 'package:chess_auto_prep/services/generation/course/chapter_titles.dart';
import 'package:chess_auto_prep/services/generation/course/opening_namer.dart';
import 'package:chess_auto_prep/services/generation/line_extractor.dart';
import 'package:chess_auto_prep/services/opening_book_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// A hand-built book covering the openings these tests name, so the suite
/// never depends on the bundled TSV assets.
OpeningBook _book() => OpeningBook(
  buildOpeningBookFromTsv([
    [
      'eco\tname\tpgn',
      'B00\tKing\'s Pawn Game\t1. e4',
      'B20\tSicilian Defense\t1. e4 c5',
      'B27\tSicilian Defense: Accelerated Dragon\t1. e4 c5 2. Nf3 g6',
      'B36\tSicilian Defense: Accelerated Dragon, Maroczy Bind\t'
          '1. e4 c5 2. Nf3 g6 3. d4 cxd4 4. Nxd4 Nc6 5. c4',
      'C20\tKing\'s Pawn Game: Open\t1. e4 e5',
      'C40\tKing\'s Knight Opening\t1. e4 e5 2. Nf3',
    ].join('\n'),
  ]),
);

ExtractedLine _line(String moves) {
  final san = moves.split(' ').where((m) => m.isNotEmpty).toList();
  return ExtractedLine(movesSan: san, movesUci: san, probability: 0.01);
}

CourseNamer _namer({
  OpeningBook? book,
  List<String> prefix = const [],
  bool playAsWhite = true,
}) => CourseNamer(
  namer: book == null
      ? OpeningNamer.unavailable(startFen: kStandardStartFen)
      : OpeningNamer(book: book, startFen: kStandardStartFen),
  rootWhiteToMove: true,
  startMoveNumber: 1,
  repertoirePrefix: prefix,
  playAsWhite: playAsWhite,
);

ChapterGroup _group(String prefix, List<String> lineMoves, {int? splitPly}) =>
    ChapterGroup(
      prefixSan: prefix.split(' ').where((m) => m.isNotEmpty).toList(),
      lines: lineMoves.map(_line).toList(),
      splitPly: splitPly,
    );

void main() {
  group('OpeningNamer', () {
    test('names a line by the deepest book position it passes through', () {
      final namer = OpeningNamer(book: _book(), startFen: kStandardStartFen);

      expect(namer.label(['e4', 'e5'])?.name, "King's Pawn Game: Open");
      expect(namer.label(['e4', 'e5', 'Nf3'])?.name, "King's Knight Opening");
      expect(namer.label(['e4', 'e5', 'Nf3'])?.eco, 'C40');
    });

    test('keeps the last name earned after the line leaves book', () {
      final namer = OpeningNamer(book: _book(), startFen: kStandardStartFen);

      expect(
        namer.label(['e4', 'e5', 'Nf3', 'Nc6', 'Bc4'])?.name,
        "King's Knight Opening",
      );
    });

    test('returns null when the line never touches the book', () {
      final namer = OpeningNamer(book: _book(), startFen: kStandardStartFen);

      expect(namer.label(['a3', 'a6']), isNull);
    });

    test('stops cleanly at an illegal move instead of throwing', () {
      final namer = OpeningNamer(book: _book(), startFen: kStandardStartFen);

      expect(namer.label(['e4', 'e5', 'Qxh8'])?.name, "King's Pawn Game: Open");
    });

    test('an unavailable book names nothing rather than failing', () {
      expect(
        OpeningNamer.unavailable(startFen: kStandardStartFen).label(['e4']),
        isNull,
      );
    });
  });

  group('formatMoveReference', () {
    test('numbers White and Black moves the way a reader writes them', () {
      expect(formatMoveReference('e4', 0, rootWhiteToMove: true), '1.e4');
      expect(formatMoveReference('c5', 1, rootWhiteToMove: true), '1...c5');
      expect(formatMoveReference('Nf3', 2, rootWhiteToMove: true), '2.Nf3');
    });

    test('respects a Black-to-move root and a mid-game move number', () {
      expect(
        formatMoveReference(
          'Bg7',
          0,
          rootWhiteToMove: false,
          startMoveNumber: 5,
        ),
        '5...Bg7',
      );
      expect(
        formatMoveReference(
          'd4',
          1,
          rootWhiteToMove: false,
          startMoveNumber: 5,
        ),
        '6.d4',
      );
    });
  });

  group('CourseNamer', () {
    test('titles the course from the opening it starts in', () {
      final namer = _namer(book: _book(), prefix: ['e4', 'c5', 'Nf3', 'g6']);

      expect(
        namer.courseTitle(),
        'Sicilian Defense: Accelerated Dragon: Repertoire for White',
      );
    });

    test('falls back to the repertoire name with no book match', () {
      expect(
        _namer().courseTitle(fallback: 'My anti-London'),
        'My anti-London: Repertoire for White',
      );
    });

    test('says which colour the repertoire is for', () {
      expect(
        _namer(playAsWhite: false).courseTitle(fallback: 'Dragon'),
        endsWith('Repertoire for Black'),
      );
    });

    test('strips the family name every chapter shares', () {
      final titles = _namer(book: _book()).nameChapters([
        _group('e4 c5 Nf3 g6 d4 cxd4 Nxd4 Nc6 c4', [
          'e4 c5 Nf3 g6 d4 cxd4 '
              'Nxd4 Nc6 c4 Bg7',
        ], splitPly: 8),
        _group('e4 c5 Nf3 g6', ['e4 c5 Nf3 g6 d4'], splitPly: 3),
      ]);

      // Both are "Sicilian Defense: Accelerated Dragon…"; the course title
      // already says so, so only the distinguishing tail survives.
      expect(titles[0].name, '1. Maroczy Bind');
      expect(titles[1].name, '2. Accelerated Dragon');
    });

    test('numbers chapters from one', () {
      final titles = _namer(book: _book()).nameChapters([
        _group('e4 e5', ['e4 e5 Nf3']),
        _group('e4 c5', ['e4 c5 Nf3']),
      ]);

      expect(titles.map((t) => t.index), [1, 2]);
      expect(titles.first.name, startsWith('1. '));
    });

    test('carries the ECO code of the chapter position', () {
      final titles = _namer(book: _book()).nameChapters([
        _group('e4 e5 Nf3', ['e4 e5 Nf3 Nc6']),
      ]);

      expect(titles.single.eco, 'C40');
    });

    test('disambiguates same-named chapters with their defining move', () {
      // Both chapters resolve to the same book name; only the split move
      // distinguishes them.
      final titles = _namer(book: _book()).nameChapters([
        _group('e4 e5 Nf3 Nc6', ['e4 e5 Nf3 Nc6 Bb5'], splitPly: 3),
        _group('e4 e5 Nf3 Nf6', ['e4 e5 Nf3 Nf6 Nxe5'], splitPly: 3),
      ]);

      expect(titles[0].name, '1. King\'s Knight Opening (2...Nc6)');
      expect(titles[1].name, '2. King\'s Knight Opening (2...Nf6)');
    });

    test('names the misc bucket for what it is', () {
      final titles = _namer(book: _book()).nameChapters([
        ChapterGroup(
          prefixSan: const ['e4'],
          lines: [_line('e4 a6 d4')],
          isMisc: true,
        ),
      ]);

      expect(titles.single.name, '1. Rare sidelines after 1.e4');
    });

    test('falls back to the defining move with no book', () {
      final titles = _namer().nameChapters([
        _group('e4 e5', ['e4 e5 Nf3'], splitPly: 1),
        _group('e4 c5', ['e4 c5 Nf3'], splitPly: 1),
      ]);

      expect(titles[0].name, '1. After 1...e5');
      expect(titles[1].name, '2. After 1...c5');
    });

    test('variation names use a more specific opening than the chapter', () {
      final group = _group('e4 e5', ['e4 e5 Nf3']);

      expect(
        _namer(
          book: _book(),
        ).variationNames(group, chapterBaseName: "King's Pawn Game: Open"),
        ["King's Knight Opening"],
      );
    });

    test('variation names are unique within a chapter', () {
      // Both lines share their first three post-prefix moves, so the naive
      // three-move label would collide.
      final group = _group('e4 e5', ['e4 e5 a3 a6 h3 h6', 'e4 e5 a3 a6 h3 b6']);

      final names = _namer().variationNames(group, chapterBaseName: 'x');

      expect(names.toSet(), hasLength(2));
      // Both grow together — one name must never be a prefix of another, or
      // the shorter reads as a line that simply stops there.
      expect(names[0], '2.a3 a6 3.h3 h6');
      expect(names[1], '2.a3 a6 3.h3 b6');
    });

    test('identical lines still get distinct names', () {
      final group = _group('e4 e5', ['e4 e5 Nf3', 'e4 e5 Nf3']);

      final names = _namer().variationNames(group, chapterBaseName: 'x');

      expect(names.toSet(), hasLength(2));
    });

    test('variation names fall back to the moves after the chapter prefix', () {
      final group = _group('e4 e5', ['e4 e5 a3 a6 h3']);

      expect(_namer().variationNames(group, chapterBaseName: 'anything'), [
        '2.a3 a6 3.h3',
      ]);
    });
  });
}
