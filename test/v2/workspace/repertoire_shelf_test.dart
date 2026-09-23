import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/repertoire_shelf.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

const _path = '/repertoires/Open games/Course.pgn';

/// One course file of two chapters by tag: the Italian, two lines after
/// 3.Bc4, and the Ruy, three lines after 3.Bb5.
const course = '''
// Color: White

[Event "Italian"]
[ChapterName "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Bc5 4. c3 *

[Event "Italian"]
[ChapterName "Italian"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bc4 Nf6 4. d3 *

[Event "Ruy"]
[ChapterName "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 *

[Event "Ruy"]
[ChapterName "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 Nf6 4. O-O *

[Event "Ruy"]
[ChapterName "Ruy"]
[Result "*"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 f5 4. Nc3 *
''';

/// After 1.e4 e5 2.Nf3 Nc6.
const afterNc6 =
    'r1bqkbnr/pppp1ppp/2n5/4p3/4P3/5N2/PPPP1PPP/RNBQKB1R w KQkq - 2 3';

void main() {
  final italian = ChapterRef.at(_path, section: 'Italian');
  final ruy = ChapterRef.at(_path, section: 'Ruy');
  late ScriptedDocumentStore store;
  late ScriptedFiles files;
  late RepertoireShelf shelf;

  void write(String text) => store.documents[const DocumentRef(_path)] = Opened(
    text,
    scriptedRevision(text),
  );

  setUp(() {
    store = ScriptedDocumentStore();
    write(course);
    files = ScriptedFiles(
      listing: Repertoires([
        RepertoireFolder(
          name: 'Open games',
          path: '/repertoires/Open games',
          modified: DateTime(2026),
          chapters: [italian, ruy],
        ),
      ]),
    );
    shelf = RepertoireShelf(files: files, documents: store);
  });

  /// What [chapter] plays after 1.e4 e5 2.Nf3 Nc6, and how many lines.
  Map<String, int> linesAt(ChapterRef chapter) {
    final index = shelf.indexOf(chapter)!;
    final moves = index.movesAt(const Fen(afterNc6).position)!;
    return {
      for (final MapEntry(:key, :value) in moves.entries) key: value.lines,
    };
  }

  test('each chapter of a course file is indexed from its own games', () async {
    await shelf.read(gone: () => false);
    expect(shelf.refs, [italian, ruy]);
    expect(linesAt(italian), {'f1c4': 2});
    expect(linesAt(ruy), {'f1b5': 3});
  });

  test('a file whose bytes are the same keeps its index; a changed one is '
      'indexed again', () async {
    await shelf.read(gone: () => false);
    final before = shelf.indexOf(ruy);
    shelf.forget();
    await shelf.read(gone: () => false);
    expect(shelf.indexOf(ruy), same(before));
    write(course.replaceFirst('3. Bb5 f5 4. Nc3', '3. Bb5 f5 4. d3'));
    shelf.forget();
    await shelf.read(gone: () => false);
    expect(shelf.indexOf(ruy), isNot(same(before)));
    expect(linesAt(ruy), {'f1b5': 3});
  });

  test('a read its caller gave up leaves the files to be read again by the '
      'next reader', () async {
    files.hold = true;
    var overtaken = false;
    final first = shelf.read(gone: () => overtaken);
    await pumpEventQueue();
    final second = shelf.read(gone: () => false);
    overtaken = true;
    files
      ..hold = false
      ..releaseAll();
    await first;
    expect(shelf.stale, isTrue);
    await second;
    expect(shelf.stale, isFalse);
    expect(shelf.refs, [italian, ruy]);
    expect(linesAt(ruy), {'f1b5': 3});
  });
}
