// The studies owner in the small: a new study made from games opens at its
// first chapter, chapters added to the open study are written to its file,
// a PGN whose only game cannot be read whole is refused, and the first
// chapter can be copied as PGN.
import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/game_text.dart';
import 'package:chess_auto_prep/chess/pgn/study.dart';
import 'package:chess_auto_prep/chess/pgn/tree_edit.dart';
import 'package:chess_auto_prep/features/study/studies_state.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/workspace/document/study_choice.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../../support/study_fixture.dart';
import '../../support/viewer_fixture.dart';

final _game = ChapterDraft(
  name: 'Carlsen – Nakamura',
  orientation: Side.black,
  moves: lineTree(Fen.initial, ['e4', 'c5']),
  tags: const [PgnTag('Event', 'Tata Steel'), PgnTag('Result', '0-1')],
  result: '0-1',
);

void main() {
  test('a new study made from games opens at its first chapter', () async {
    final study = await openStudy(twoChapterStudy);
    addTearDown(study.dispose);
    final made = await study.studies.addChapters(const NewStudy('Openings'), [
      _game,
    ]);
    expect((made as StudyDone).chapter, 0);
  });

  test('chapters added to the open study are written to its file, even '
      'while reading holds edits', () async {
    final study = await openStudy(twoChapterStudy);
    addTearDown(study.dispose);
    // Reading holds what is played; chapters added are written all the same.
    study.session.holdsEdits = true;
    final added = await study.studies.addChapters(IntoStudy(study.ref), [
      _game,
    ]);
    expect((added as StudyDone).chapter, 2);
    await study.saver.flush();
    expect(
      (study.store.documents[study.ref] as Opened).text,
      contains('Carlsen – Nakamura'),
    );
  });

  test('a PGN whose only game cannot be read whole is refused', () async {
    const path = '/Downloads/Broken.pgn';
    final importer = ScriptedImport()
      ..picked[path] = const PickedText(
        '[Event "Broken"]\n[Result "*"]\n\n1. e4 e5 2. Qxz9 Nc6 *\n',
      );
    final study = await openStudy(
      twoChapterStudy,
      picker: ScriptedPicker(path),
      importer: importer,
    );
    addTearDown(study.dispose);
    final imported = await study.studies.importPgn();
    expect(imported, isA<StudyProblem>());
    expect(
      (imported as StudyProblem).sentence,
      'That PGN contains no readable games.',
    );
  });

  test('the first chapter is copied as PGN', () async {
    final study = await openStudy(twoChapterStudy);
    addTearDown(study.dispose);
    final first = await study.studies.pgnOfChapter(0);
    expect(first, isNotNull);
    expect(first, contains('Rook endings'));
  });
}
