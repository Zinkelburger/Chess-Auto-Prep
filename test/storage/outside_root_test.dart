// A file outside the Documents folder — one the viewer browsed to in
// Downloads — is read but never written: every write keeps the version it
// replaces under an id made from the path inside Documents, and such a
// file has none.
import 'dart:io';

import 'package:chess_auto_prep/chess/pgn/games_written.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/edit_scope.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/pgn_file_import.dart';
import 'package:chess_auto_prep/storage/pgn_file_store.dart';
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

  group('a symlinked Documents folder', () {
    late Link link;
    late PgnFileStore store;
    const original = '[Event "Original"]\n\n1. e4 *\n';
    const edited = '[Event "Edited"]\n\n1. e4 e5 *\n';

    setUp(() async {
      link = Link(p.join(fixture.root.path, 'linked-documents'));
      await link.create(fixture.documents.path);
      store = PgnFileStore(
        documents: Directory(link.path),
        support: fixture.support,
      );
    });

    Future<void> expectReadOnly(DocumentRef ref) async {
      final opened = await store.open(ref) as Opened;
      expect(opened.readOnly, 'it is outside your Documents folder');
      expect(
        await store.save(
          ref,
          '[Event "Annotation"]\n\n1. d4 *\n',
          expected: opened.revision,
          scope: const WholeDocument(),
        ),
        isA<IoFailure>(),
      );
      expect(await File(ref.path).readAsString(), opened.text);
    }

    test('a linked parent under the resolved root stays external', () async {
      final shared = await Directory(
        p.join(fixture.root.path, 'shared'),
      ).create();
      final folder = await Directory(p.join(shared.path, 'season')).create();
      final match = File(p.join(folder.path, 'match.pgn'));
      await match.writeAsString(original);
      final root = await fixture.documents.resolveSymbolicLinks();
      await Link(p.join(root, 'Club')).create(shared.path);
      final ref = DocumentRef(p.join(root, 'Club', 'season', 'match.pgn'));
      await expectReadOnly(ref);
      expect(
        await store.create(
          DocumentRef(p.join(root, 'Club', 'new', 'game.pgn')),
          edited,
        ),
        isA<IoFailure>(),
      );
      expect(await Directory(p.join(shared.path, 'new')).exists(), isFalse);

      final importer = NativePgnFileImport(
        documents: link.path,
        into: p.join(link.path, 'pgn_collections'),
        recovery: store.recovery,
      );
      final linkedFile = await Link(
        p.join(root, 'match.pgn'),
      ).create(match.path);
      for (final path in [ref.path, linkedFile.path]) {
        final copy = await importer.insideDocuments(path) as FileToOpen;
        expect(copy.copied, isTrue);
        expect(await File(copy.path).readAsString(), original);
      }
    });

    test('redirecting Documents admits neither resolved root', () async {
      final first = fixture.ref('match.pgn');
      await File(first.path).writeAsString(original);
      final prior = DocumentRef(await File(first.path).resolveSymbolicLinks());
      final opened = await store.open(prior) as Opened;
      expect(opened.readOnly, isNull);
      expect(
        await store.save(
          prior,
          edited,
          expected: opened.revision,
          scope: const WholeDocument(),
        ),
        isA<Saved>(),
      );
      expect(fixture.keptTexts(first), [original]);

      final other = await Directory(
        p.join(fixture.root.path, 'other'),
      ).create();
      final next = File(p.join(other.path, 'match.pgn'));
      await next.writeAsString('[Event "Other folder"]\n\n1. c4 *\n');
      await link.update(other.path);
      await expectReadOnly(DocumentRef(await next.resolveSymbolicLinks()));
      await expectReadOnly(prior);
      expect(fixture.keptTexts(first), [original]);
    });
  }, skip: Platform.isWindows ? 'symlink privileges not assumed' : false);
}
