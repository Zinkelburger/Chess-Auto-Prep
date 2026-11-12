import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/document_repository.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';

void main() {
  group('a change touches', () {
    test('its own path and what is under it', () {
      const saved = DocumentChange(
        '/r/KID/Main.pgn',
        kind: DocumentChangeKind.saved,
      );
      expect(saved.folder, isFalse);
      expect(saved.touches('/r/KID/Main.pgn'), isTrue);
      expect(saved.touches('/r/KID'), isTrue);
      expect(saved.touches('/r/Benko'), isFalse);
    });

    test('what is inside it only when it is a folder', () {
      const file = DocumentChange('/r/KID', kind: DocumentChangeKind.saved);
      expect(file.touches('/r/KID/Main.pgn'), isFalse);
      const folder = DocumentChange(
        '/r/KID',
        kind: DocumentChangeKind.moved,
        movedTo: '/r/Kings Indian',
        folder: true,
      );
      expect(folder.touches('/r/KID/Main.pgn'), isTrue);
      expect(folder.touches('/r/Kings Indian/Main.pgn'), isTrue);
    });

    test('the path it moved to', () {
      const moved = DocumentChange(
        '/r/a.pgn',
        kind: DocumentChangeKind.moved,
        movedTo: '/r/b.pgn',
      );
      expect(moved.touches('/r/b.pgn'), isTrue);
      expect(moved.touches('/r/c.pgn'), isFalse);
    });
  });

  test('a folder move is published as a folder', () async {
    final repository = DocumentRepository(ScriptedDocumentStore());
    addTearDown(repository.dispose);
    await repository.moveFolder('/r/KID', '/r/Kings Indian');
    final change = repository.lastChange!;
    expect(
      (change.kind, change.path, change.movedTo, change.folder),
      (DocumentChangeKind.moved, '/r/KID', '/r/Kings Indian', true),
    );
  });

  test(
    'a write that lands after the repository is closed tells nobody',
    () async {
      final store = ScriptedDocumentStore()
        ..hold = true
        ..deletes.add(const Deleted('/r/.recovered/a.pgn'));
      final repository = DocumentRepository(store);
      final deleting = repository.delete(
        const DocumentRef('/r/a.pgn'),
        expected: const Revision('ab12'),
      );
      await pumpEventQueue();
      repository.dispose();
      store.releaseAll();
      expect(await deleting, isA<Deleted>());
      expect(repository.lastChange, isNull);
    },
  );
}
