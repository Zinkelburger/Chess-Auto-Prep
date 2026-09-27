import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/workspace/generated_draft.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';

void main() {
  final first = ChapterRef.at('/Documents/repertoires/Main/Line (draft).pgn');
  final second = ChapterRef.at(
    '/Documents/repertoires/Main/Line (draft 2).pgn',
  );

  GeneratedDraft command(
    PgnDocumentStore store, {
    String Function(String)? text,
  }) => GeneratedDraft(
    documents: store,
    folder: '/Documents/repertoires/Main',
    chapter: 'Line',
    textFor: text ?? (name) => '[Event "$name"]\n\n1. e4 *',
  );

  test('only a proven initial collision selects another name', () async {
    final store = ScriptedDocumentStore();
    store.documents[first] = Opened('existing', scriptedRevision('existing'));
    final result = await command(store).write();
    expect((result as DraftWritten).ref, second);
    expect((await store.open(first) as Opened).text, 'existing');
  });

  test('a failed write says why and a second try writes the draft', () async {
    final store = ScriptedDocumentStore()
      ..creates.add(const IoFailure('disk full'));
    final draft = command(store, text: (_) => 'lines');
    final failed = await draft.write();
    expect((failed as DraftNotWritten).reason, contains('disk full'));
    expect((await draft.write() as DraftWritten).ref, first);
    expect((await store.open(first) as Opened).text, 'lines');
  });

  test(
    'a lost acknowledgement verifies the original path and frozen bytes',
    () async {
      final store = ScriptedDocumentStore()
        ..creates.add(const IoFailure('lost ack'));
      var textCalls = 0;
      final draft = command(store, text: (_) => 'lines ${++textCalls}');
      expect(await draft.write(), isA<DraftNotWritten>());
      store.documents[first] = Opened('lines 1', scriptedRevision('lines 1'));
      expect((await draft.write() as DraftWritten).ref, first);
      expect(store.documents.containsKey(second), isFalse);
      expect(textCalls, 1);
    },
  );

  test(
    'uncertain destination changed by someone else cannot create a duplicate',
    () async {
      final store = ScriptedDocumentStore()
        ..creates.add(const IoFailure('lost ack'));
      final draft = command(store, text: (_) => 'lines');
      await draft.write();
      store.documents[first] = Opened('external', scriptedRevision('external'));
      expect(await draft.write(), isA<DraftNotWritten>());
      expect(store.documents.containsKey(second), isFalse);
    },
  );
}
