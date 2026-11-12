import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/chess/pgn/study_training.dart';
import 'package:chess_auto_prep/chess/training/training_line.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import '../../support/study_fixture.dart';

void main() {
  test('changing a side replaces that tag and keeps every other header', () {
    final study = parseChapter(
      name: 'S',
      text:
          '[Event "S: A"]\n[ChapterName "A"]\n[TrainingSide "white"]\n\n'
          '1. e4 *\n',
    );
    final changed =
        setStudyTrainingSides(study, {0: Side.black}) as ChapterEdited;
    final tags = changed.chapter.lines.single.tags;
    expect(tagValue(tags, 'Event'), 'S: A');
    expect(tagValue(tags, 'ChapterName'), 'A');
    expect(tagValue(tags, 'TrainingSide'), 'black');
    expect(
      'TrainingSide'.allMatches(changed.chapter.lines.single.text),
      hasLength(1),
    );
  });

  test(
    'side changes preserve orientation and every untouched chapter byte',
    () {
      final before = parseChapter(
        name: 'Study',
        text: twoChapterStudy,
        game: 0,
      );
      final edited =
          setStudyTrainingSides(before, {0: Side.black}) as ChapterEdited;
      expect(studyTrainingSide(edited.chapter.lines.first), Side.black);
      expect(studyOrientation(edited.chapter.lines.first), Side.white);
      expect(edited.chapter.lines[1].text, before.lines[1].text);
      expect(
        trainingLines(edited.chapter, source: 'study').map((l) => l.side),
        [Side.black, Side.black],
      );
    },
  );

  test('ready chapters train even with missing or invalid sides elsewhere', () {
    final before = parseChapter(
      name: 'Study',
      text: threeChapterStudy,
      game: 1,
    );
    expect(trainingLines(before, source: 'study'), isEmpty);
    final edited =
        setStudyTrainingSides(before, {1: Side.white}) as ChapterEdited;
    expect(trainingLines(edited.chapter, source: 'study').single.game, 1);
    expect(
      setStudyTrainingSides(before, {3: Side.white}),
      isA<ChapterEditRefused>(),
    );
    expect(
      setStudyTrainingSides(edited.chapter, {1: Side.white}),
      isA<ChapterUnchanged>(),
    );
  });
}
