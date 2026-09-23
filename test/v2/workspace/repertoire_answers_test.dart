import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/gap_hunt.dart';
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

/// The position after 1.e4 c5 2.c3 d5, and after 1.e4 c5 2.c3 e6.
const _afterD5 =
    'rnbqkbnr/pp2pppp/8/2pp4/4P3/2P5/PP1P1PPP/RNBQKBNR w KQkq - 0 3';
const _afterE6 =
    'rnbqkbnr/pp1p1ppp/4p3/2p5/4P3/2P5/PP1P1PPP/RNBQKBNR w KQkq - 0 3';

/// The position after 1.e4 e6 2.d4 d5, and after 1.e4 e6 2.d3 d5.
const _afterD4D5 =
    'rnbqkbnr/ppp2ppp/4p3/3p4/3PP3/8/PPP2PPP/RNBQKBNR w KQkq - 0 3';
const _afterD3D5 =
    'rnbqkbnr/ppp2ppp/4p3/3p4/4P3/3P4/PPP2PPP/RNBQKBNR w KQkq - 0 3';

String _chapter(String moves) =>
    '// Color: White\n\n[Event "Line"]\n[Result "*"]\n\n$moves *\n';

void main() {
  test('forgetting one file reads it again and keeps what the others '
      'answered', () async {
    final main = ref('KID', 'Main');
    final sicilian = ref('KID', 'Sicilian');
    final french = ref('KID', 'French');
    final store = ScriptedDocumentStore();
    void write(DocumentRef chapter, String moves) {
      final text = _chapter(moves);
      store.documents[chapter] = Opened(text, scriptedRevision(text));
    }

    write(sicilian, '1. e4 c5 2. c3 d5 3. exd5');
    write(french, '1. e4 e6 2. d4 d5 3. Nc3');
    final answers = RepertoireAnswers(
      files: ScriptedFiles(
        listing: Repertoires([
          folder('KID', ['Main', 'Sicilian', 'French']),
        ]),
      ),
      documents: store,
    );
    await answers.around(main, Side.white);
    write(sicilian, '1. e4 c5 2. c3 e6 3. d4');
    write(french, '1. e4 e6 2. d3 d5 3. Nd2');
    answers.forgetFile(sicilian.path);
    final around = await answers.around(main, Side.white);
    expect(around[const Fen(_afterE6).position], 'Sicilian');
    expect(around.containsKey(const Fen(_afterD5).position), isFalse);
    // The French file was not forgotten: it answers what it did.
    expect(around[const Fen(_afterD4D5).position], 'French');
    expect(around.containsKey(const Fen(_afterD3D5).position), isFalse);
  });

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
