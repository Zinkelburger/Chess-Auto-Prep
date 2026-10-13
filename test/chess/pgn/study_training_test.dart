import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/chess/pgn/study_training.dart';
import 'package:chess_auto_prep/chess/training/training_line.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';
import '../../support/study_fixture.dart';

void main() {
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
