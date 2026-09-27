// A file outside the Documents folder — one the viewer browsed to in
// Downloads — is read but never written: every write keeps the version it
// replaces under an id made from the path inside Documents, and such a
// file has none.
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;

  setUp(() async => fixture = await StoreFixture.create());
  tearDown(() => fixture.dispose());

  test(
    'a file outside Documents opens to read, and a save is refused',
    () async {
      final path = p.join(fixture.root.path, 'Downloads', 'twic.pgn');
      await File(path).create(recursive: true);
      await File(path).writeAsString('[Event "?"]\n\n1. e4 *\n');
      final ref = DocumentRef(path);
      final opened = await fixture.store.open(ref) as Opened;
      expect(opened.text, '[Event "?"]\n\n1. e4 *\n');
      expect(opened.readOnly, 'it is outside your Documents folder');
      final saved = await fixture.store.save(
        ref,
        '[Event "?"]\n\n1. e4 e5 *\n',
        expected: opened.revision,
        scope: GamesEdited(GamesWritten(rewritten: const {0})),
      );
      expect(saved, isA<IoFailure>());
      expect(await File(path).readAsString(), '[Event "?"]\n\n1. e4 *\n');
    },
  );

  test('a file inside Documents opens to write', () async {
    final ref = fixture.ref('pgn_collections/games.pgn');
    await fixture.put(ref, '[Event "?"]\n\n1. e4 *\n');
    final opened = await fixture.store.open(ref) as Opened;
    expect(opened.readOnly, isNull);
  });
}
