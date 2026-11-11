import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_line.dart';
import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/chess/pgn/study_edits.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart' show lineTree;
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';

void main() {
  test(
    'reading a study: lists one chapter per game, named and facing as its tags say',
    () {
      final study = parseChapter(name: 'Endgames', text: twoChapterStudy);
      final chapters = studyChapters(study.lines);
      expect(chapters.map((c) => c.name), ['Rook endings', 'Pawn endings']);
      expect(chapters.map((c) => c.ordinal), [1, 2]);
      expect(chapters.last.orientation, Side.black);
    },
  );

  test('reading a study: takes the study name from the tags', () {
    final study = parseChapter(name: 'file name', text: twoChapterStudy);
    expect(studyNameIn(study.lines), 'Endgames');
  });

  test(
    'reading a study: peels the study name off an Event with no ChapterName',
    () {
      const pgn = '[Event "Openings: The Benko"]\n\n1. d4 *\n';
      final study = parseChapter(name: 'Openings', text: pgn);
      expect(studyChapters(study.lines).single.name, 'The Benko');
    },
  );

  group('reading a study, at the edges', () {
    List<ChapterLine> lines(String pgn) =>
        parseChapter(name: 'x', text: pgn).lines;

    test('a StudyName tag wins over the Event, and an Event that starts with '
        'its colon names no study', () {
      expect(
        studyNameIn(lines('[Event "Other: Ch"]\n[StudyName "Mine"]\n\n*\n')),
        'Mine',
      );
      expect(studyNameIn(lines('[Event ": Ch"]\n\n*\n')), isNull);
    });

    test(
      'every chapter facing a side makes sides per chapter only in a study',
      () {
        expect(
          sidesPerChapter(
            lines('[Event "S: A"]\n[Orientation "black"]\n\n1. e4 *\n'),
          ),
          isTrue,
        );
        expect(
          sidesPerChapter(
            lines('[Event "A game"]\n[Orientation "black"]\n\n1. e4 *\n'),
          ),
          isFalse,
          reason: 'no study name',
        );
      },
    );

    test('a chapter named from one player only is numbered instead', () {
      final line = lines('[Event "?"]\n[White "Tal"]\n\n1. e4 *\n').single;
      expect(studyChapterName(line, index: 0), 'Chapter 1');
    });

    test('the study name is peeled off a one-letter chapter name', () {
      final line = lines('[Event "S: X"]\n\n1. e4 *\n').single;
      expect(studyChapterName(line, index: 0, study: 'S'), 'X');
    });
  });

  test('reading a study: falls back to the players, then to a number', () {
    const pgn =
        '[Event "?"]\n[White "Tal"]\n[Black "Botvinnik"]\n\n1. e4 *\n\n'
        '[Event "?"]\n\n1. d4 *\n';
    final study = parseChapter(name: 'Games', text: pgn);
    expect(studyChapters(study.lines).map((c) => c.name), [
      'Tal - Botvinnik',
      'Chapter 2',
    ]);
  });

  test(
    'reading a study: faces the side to move when a set-up chapter has no tag',
    () {
      const fen = '4k3/8/8/8/8/8/4P3/4K3 b - - 0 1';
      const pgn = '[Event "Mate"]\n[FEN "$fen"]\n[SetUp "1"]\n\n*\n';
      final study = parseChapter(name: 'Mates', text: pgn);
      expect(studyChapters(study.lines).single.orientation, Side.black);
    },
  );

  test(
    'one game as the chapter: shows that game alone, facing its own way',
    () {
      final second = parseChapter(
        name: 'Endgames',
        text: twoChapterStudy,
        game: 1,
      );
      expect(second.tree.children.single.san, 'd4');
      expect(second.side, Side.black);
      expect(second.gameCount, 1);
      // The other chapter is in the file but is not this chapter's business.
      expect(second.lines, hasLength(2));
      expect(second.skippedGames, 0);
    },
  );

  test('one game as the chapter: merges every game when no game is named', () {
    final whole = parseChapter(name: 'Endgames', text: twoChapterStudy);
    expect(whole.tree.children.map((node) => node.san), ['e4', 'd4']);
  });

  test(
    'one game as the chapter: a game index nobody has reads as an empty chapter',
    () {
      final missing = parseChapter(
        name: 'Endgames',
        text: twoChapterStudy,
        game: 7,
      );
      expect(missing.tree.isEmpty, isTrue);
      expect(missing.tree.rootFen, Fen.initial);
    },
  );

  test('one game as the chapter: another game shown shares the games', () {
    final first = parseChapter(
      name: 'Endgames',
      text: twoChapterStudy,
      game: 0,
    );
    for (final game in [1, 0, 7]) {
      final shown = withGame(first, game);
      final built = withLines(first, first.lines, game: game);
      expect(identical(shown.lines, first.lines), isTrue, reason: '$game');
      expect(shown.name, built.name);
      expect(shown.side, built.side, reason: '$game');
      expect(shown.sideStated, built.sideStated);
      expect(shown.preamble, built.preamble);
      expect(sameLines(shown.lines, built.lines), isTrue);
      expect(identical(shown.tree, built.tree), isTrue, reason: '$game');
      expect(shown.game, built.game);
      expect(shown.lineIds, built.lineIds);
    }
    expect(withGame(first, 1).side, Side.black);
  });

  test('writing a chapter: writes the six tags the study owns', () {
    final text = newStudyChapterText(
      study: 'Endgames',
      chapter: 'Rook endings',
      orientation: Side.black,
    );
    expect(text, contains('[Event "Endgames: Rook endings"]'));
    expect(text, contains('[StudyName "Endgames"]'));
    expect(text, contains('[ChapterName "Rook endings"]'));
    expect(text, contains('[Orientation "black"]'));
    expect(text, isNot(contains('SetUp')));
  });

  test('writing a chapter: a chapter from a FEN carries FEN and SetUp', () {
    const fen = '4k3/8/8/8/8/8/4P3/4K3 b - - 0 1';
    final text = newStudyChapterText(
      study: 'Mates',
      chapter: 'One',
      orientation: Side.black,
      root: const Fen(fen),
    );
    expect(text, contains('[FEN "$fen"]'));
    expect(text, contains('[SetUp "1"]'));
  });

  test(
    'writing a chapter: keeps every tag the study does not own, where it was',
    () {
      final study = parseChapter(name: 'Endgames', text: twoChapterStudy);
      final tags = withStudyTags(
        study.lines.first.tags,
        study: 'Endgames',
        chapter: 'Renamed',
        orientation: Side.white,
        root: Fen.initial,
      );
      expect(tags.map((tag) => tag.text), contains('[Result "*"]'));
      expect(tags.map((tag) => tag.text), contains('[ChapterName "Renamed"]'));
      expect(
        tags.where((tag) => tag.text.startsWith('[ChapterName')),
        hasLength(1),
      );
    },
  );

  test(
    'writing a chapter: names an unnamed chapter after the ones already there',
    () {
      final study = parseChapter(name: 'Endgames', text: twoChapterStudy);
      expect(nextChapterName(studyChapters(study.lines)), 'Chapter 3');
    },
  );

  group('adding many chapters at once', () {
    ChapterDraft draft(String name, List<String> moves) => ChapterDraft(
      name: name,
      orientation: Side.white,
      moves: lineTree(Fen.initial, moves),
    );

    test('writes what adding them one at a time writes, CRLF kept', () {
      final before = parseChapter(
        name: 'Endgames',
        text: twoChapterStudy.replaceAll('\n', '\r\n'),
      );
      final drafts = [
        draft('One', ['e4']),
        draft('', ['d4', 'd5']),
        draft('Three', ['c4']),
      ];
      final edit =
          addChapters(before, study: 'Endgames', drafts: drafts)
              as ChapterEdited;
      var oneByOne = before;
      for (final one in drafts) {
        final added =
            addChapters(oneByOne, study: 'Endgames', drafts: [one])
                as ChapterEdited;
        oneByOne = parseChapter(
          name: 'Endgames',
          text: writeChapter(added.chapter),
        );
      }
      expect(writeChapter(edit.chapter), writeChapter(oneByOne));
      expect(writeChapter(edit.chapter), isNot(contains(RegExp('[^\r]\n'))));
      expect(edit.chapter.game, 2);
    });

    test('a thousand drafts become a thousand chapters', () {
      final before = parseChapter(name: 'Endgames', text: twoChapterStudy);
      final edit =
          addChapters(
                before,
                study: 'Endgames',
                drafts: [
                  for (var i = 0; i < 1000; i++) draft('', ['e4']),
                ],
              )
              as ChapterEdited;
      expect(edit.chapter.lines, hasLength(1002));
      expect(studyChapters(edit.chapter.lines).last.name, 'Chapter 1002');
    });
  });
}
