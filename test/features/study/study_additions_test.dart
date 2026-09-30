import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/pgn/chapter_edit.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/chess/pgn/study_edits.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart' show lineTree;
import 'package:chess_auto_prep/features/study/studies.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/study_choice.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/scripted_store.dart';
import '../../support/study_fixture.dart';

/// A game from a collection, with the tags it came with.
final _game = ChapterDraft(
  name: 'Carlsen – Nakamura',
  orientation: Side.black,
  moves: lineTree(Fen.initial, ['e4', 'c5']),
  tags: const [
    PgnTag('Event', 'Tata Steel'),
    PgnTag('White', 'Carlsen'),
    PgnTag('Black', 'Nakamura'),
    PgnTag('Result', '0-1'),
  ],
  result: '0-1',
);

void main() {
  group('the chapters as the file writes them', () {
    test('each draft is a chapter at the end, with its own tags kept and '
        'the study\'s written; the games before are untouched', () async {
      final study = await readChapter(name: 'Ideas', text: twoChapterStudy);
      final edit = addChapters(
        study,
        study: 'Endgames',
        drafts: [_game, _game.named('')],
      );
      final edited = (edit as ChapterEdited).chapter;
      expect(edited.lines, hasLength(4));
      expect(edited.game, 2, reason: 'the first new chapter is shown');
      for (var i = 0; i < 2; i++) {
        expect(edited.lines[i].text, study.lines[i].text);
      }
      final added = edited.lines[2];
      expect(tagValue(added.tags, 'ChapterName'), 'Carlsen – Nakamura');
      expect(tagValue(added.tags, 'Event'), 'Endgames: Carlsen – Nakamura');
      expect(tagValue(added.tags, 'White'), 'Carlsen');
      expect(tagValue(added.tags, 'Orientation'), 'black');
      expect(added.text, endsWith('1. e4 c5 0-1'));
      expect(tagValue(edited.lines[3].tags, 'ChapterName'), 'Chapter 4');
      expect(edit.games.order.take(2), [0, 1]);
    });
  });

  group('adding from another mode', () {
    late StudyFixture study;
    tearDown(() => study.dispose());

    test(
      'into a study on disk: written through the store, appending only',
      () async {
        study = await openStudy(twoChapterStudy);
        final other = studyRef('Openings');
        final text = newStudyText(study: 'Openings', chapter: 'Intro');
        study.store.documents[other] = Opened(text, scriptedRevision(text));
        final result = await study.studies.addChapters(IntoStudy(other), [
          _game,
        ]);
        expect((result as StudyDone).opened, other);
        expect(result.chapter, 1);
        final save = study.store.requestedSaves.single;
        expect(save.scope, isA<GamesRearranged>());
        expect(save.text, startsWith(text.trimRight()));
        expect(save.text, contains('[StudyName "Openings"]'));
        expect(
          study.onDisk,
          twoChapterStudy,
          reason: 'the open study is not it',
        );
      },
    );

    test('into the study that is open: through its editor', () async {
      study = await openStudy(twoChapterStudy);
      final result = await study.studies.addChapters(IntoStudy(study.ref), [
        _game,
      ]);
      expect((result as StudyDone).chapter, 2);
      expect(study.session.chapter!.lines, hasLength(3));
      await pumpEventQueue();
      expect(study.onDisk, contains('Carlsen – Nakamura'));
    });

    test('into a new study: the study is made with them in it', () async {
      study = await openStudy(twoChapterStudy);
      final result = await study.studies.addChapters(const NewStudy('Prep'), [
        _game,
      ]);
      expect((result as StudyDone).opened, studyRef('Prep'));
      final made = study.store.documents[studyRef('Prep')]! as Opened;
      expect(made.text, startsWith('[Event "Prep: Carlsen – Nakamura"]'));
      expect(await readChapter(name: 'Prep', text: made.text), isNotNull);
    });

    test(
      'a study that changed while it was read is refused, and kept',
      () async {
        study = await openStudy(twoChapterStudy);
        final other = studyRef('Openings');
        final text = newStudyText(study: 'Openings', chapter: 'Intro');
        study.store.documents[other] = Opened(text, scriptedRevision(text));
        study.store.saves.add(Conflict(scriptedRevision('elsewhere')));
        final result = await study.studies.addChapters(IntoStudy(other), [
          _game,
        ]);
        expect(result, isA<StudyProblem>());
        expect((study.store.documents[other]! as Opened).text, text);
      },
    );
  });
}
