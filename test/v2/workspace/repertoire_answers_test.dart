import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_answers.dart';
import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

const _path = '/repertoires/Course/Course.pgn';

const _course = '''
// Color: White

[Event "Ruy"]
[ChapterName "Open games"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 *

[Event "Alapin"]
[ChapterName "Sicilian"]

1. e4 c5 2. c3 *
''';

void main() {
  test('the other chapters of a course file answer too', () async {
    final open = ChapterRef.at(_path, section: 'Open games');
    final sicilian = ChapterRef.at(_path, section: 'Sicilian');
    final store = ScriptedDocumentStore()
      ..documents[const DocumentRef(_path)] = Opened(
        _course,
        scriptedRevision(_course),
      );
    final answers = RepertoireAnswers(
      files: ScriptedFiles(
        listing: Repertoires([
          RepertoireFolder(
            name: 'Course',
            path: '/repertoires/Course',
            modified: DateTime(2026),
            chapters: [open, sicilian],
          ),
        ]),
      ),
      documents: store,
    );
    final around = await answers.around(open, Side.white);
    // After 1.e4 c5 the Sicilian chapter plays 2.c3; the open chapter's own
    // 1.e4 e5 positions are not the other chapter's answers.
    const afterC5 =
        'rnbqkbnr/pp1ppppp/8/2p5/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2';
    expect(around[const Fen(afterC5).position], 'Sicilian');
    expect(around.values.toSet(), {'Sicilian'});
  });
}
