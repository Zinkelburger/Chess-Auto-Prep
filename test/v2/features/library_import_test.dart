import 'package:chess_auto_prep/v2/features/library/library.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/library_fixture.dart';
import '../support/scripted_files.dart';
import '../support/scripted_store.dart';

/// Importing a PGN as a repertoire: the chapters land in a folder named
/// after the file, nothing half-written is ever listed, and every way it
/// can fail is a typed answer.
void main() {
  final kid = folder('KID', ['Main']);
  late LibraryFixture fixture;

  const study = '''
[Event "Najdorf: 6.Bg5 e6"]
[ChapterName "6.Bg5 e6"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Bg5 e6 (6... Nbd7) *

[Event "Najdorf: 6.Be3"]
[ChapterName "6.Be3"]
[Result "*"]

1. e4 c5 2. Nf3 d6 3. d4 cxd4 4. Nxd4 Nf6 5. Nc3 a6 6. Be3 e5 *
''';

  const oneLine = '[Event "x"]\n[Result "*"]\n\n1. e4 e5 *\n';

  Iterable<String> paths() => fixture.store.documents.keys.map((r) => r.path);

  setUp(() async {
    fixture = await openLibrary([kid]);
  });

  tearDown(() => fixture.dispose());

  test(
    'a pasted study becomes one folder with a chapter per study chapter',
    () async {
      final result = await fixture.library.importText(study, name: 'Najdorf');
      expect(result, isA<LibraryAdded>());
      final added = result as LibraryAdded;
      expect(added.first.path, '/repertoires/Najdorf/6.Bg5 e6.pgn');
      expect(added.chapters, 2);
      expect(added.lines, 3);
      expect(
        paths().where((path) => p.isWithin('/repertoires/Najdorf', path)),
        unorderedEquals([
          '/repertoires/Najdorf/6.Bg5 e6.pgn',
          '/repertoires/Najdorf/6.Be3.pgn',
        ]),
      );
      expect(
        fixture.textAt('/repertoires/Najdorf/6.Bg5 e6.pgn'),
        startsWith('// 6.Bg5 e6\n'),
      );
      expect(
        paths().where((path) => p.basename(p.dirname(path)).startsWith('.')),
        isEmpty,
        reason: 'the staging folder was renamed into place',
      );
      expect(fixture.files.stagingRemoved, isEmpty);
    },
  );

  test('a name the list already has is suffixed rather than refused', () async {
    final result = await fixture.library.importText(oneLine, name: 'kid');
    expect(
      (result as LibraryAdded).first.path,
      '/repertoires/kid (2)/Main.pgn',
    );
  });

  test('the file name is made safe to be a folder name', () async {
    fixture.picker.answer = '/downloads/My: Sicilian?.pgn';
    final result = await fixture.library.importFile();
    expect(
      result,
      isA<LibraryFileUnreadable>(),
      reason: 'nothing at that path',
    );
    fixture.store.documents[const DocumentRef('/downloads/My: Sicilian?.pgn')] =
        Opened(oneLine, scriptedRevision(oneLine), readOnly: 'outside');
    final again = await fixture.library.importFile() as LibraryAdded;
    expect(again.first.path, '/repertoires/My_ Sicilian_/Main.pgn');
  });

  test('closing the file dialog imports nothing', () async {
    fixture.picker.answer = null;
    expect(await fixture.library.importFile(), isNull);
    expect(fixture.library.busy, isFalse);
  });

  test('text with no moves is refused before anything is written', () async {
    final result = await fixture.library.importText(
      '[Event "x"]\n\n*\n',
      name: 'Empty',
    );
    expect(result, isA<LibraryNothingToImport>());
    expect(paths().where((path) => path.contains('Empty')), isEmpty);
  });

  test('a write that fails takes the staging folder with it', () async {
    fixture.store.creates.addAll([
      const Created(Revision('first')),
      const IoFailure('disk full'),
    ]);
    final result = await fixture.library.importText(study, name: 'Najdorf');
    expect(result, isA<LibraryFailure>());
    expect((result as LibraryFailure).detail, 'disk full');
    expect(fixture.files.stagingRemoved, hasLength(1));
    expect(
      p.basename(fixture.files.stagingRemoved.single),
      startsWith(stagingPrefix),
    );
    expect(paths().where((path) => path.contains('Najdorf')), isEmpty);
  });

  test(
    'a folder that appeared meanwhile is a taken name, and staging goes',
    () async {
      fixture.store.folderMoves.add(const FolderNameTaken());
      final result = await fixture.library.importText(oneLine, name: 'Fresh');
      expect(result, isA<LibraryNameTaken>());
      expect(fixture.files.stagingRemoved, hasLength(1));
    },
  );

  test('two imports do not run at once', () async {
    fixture.store.hold = true;
    final first = fixture.library.importText(oneLine, name: 'One');
    expect(
      await fixture.library.importText(oneLine, name: 'Two'),
      isA<LibraryBusy>(),
    );
    fixture.store
      ..hold = false
      ..releaseAll();
    expect(await first, isA<LibraryAdded>());
  });
}
