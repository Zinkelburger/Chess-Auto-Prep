import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
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

  test(
    'unknown creation retains exact bytes and name across retries',
    () async {
      final store = ScriptedDocumentStore()
        ..creates.add(const IoFailure('lost ack'));
      var text = 'accepted timestamp';
      var builds = 0;
      final draft = command(
        store,
        text: (_) {
          builds++;
          return text;
        },
      );
      expect(await draft.write(), isA<DraftNotWritten>());
      text = 'later timestamp';
      expect((await draft.write() as DraftWritten).ref, first);
      expect((await store.open(first) as Opened).text, 'accepted timestamp');
      expect(builds, 1);
      expect(await store.open(second), isA<Absent>());
    },
  );

  test(
    'uncertain destination occupied by different bytes is preserved',
    () async {
      final store = ScriptedDocumentStore()
        ..creates.add(const IoFailure('lost ack'));
      final draft = command(store);
      await draft.write();
      store.documents[first] = Opened(
        'someone else',
        scriptedRevision('someone else'),
      );
      expect(await draft.write(), isA<DraftNotWritten>());
      expect((await store.open(first) as Opened).text, 'someone else');
      expect(await store.open(second), isA<Absent>());
    },
  );

  test('matching published bytes acknowledge without another create', () async {
    final store = ScriptedDocumentStore()
      ..creates.add(const IoFailure('lost ack'));
    final draft = command(store, text: (_) => 'accepted');
    await draft.write();
    store.documents[first] = Opened('accepted', scriptedRevision('accepted'));
    expect((await draft.write() as DraftWritten).ref, first);
    expect(await store.open(second), isA<Absent>());
  });

  test(
    'collision after absent retry read never silently reallocates',
    () async {
      final store = _AppearedDuringRetry();
      final draft = command(store, text: (_) => 'accepted');
      expect(await draft.write(), isA<DraftNotWritten>());
      expect(await draft.write(), isA<DraftNotWritten>());
      expect(store.requested, [first, first]);
      expect(await draft.write(), isA<DraftNotWritten>());
      expect(store.requested, [first, first]);
    },
  );
}

final class _AppearedDuringRetry implements PgnDocumentStore {
  final requested = <DocumentRef>[];
  int reads = 0;
  @override
  Future<CreateResult> create(DocumentRef ref, String text) async {
    requested.add(ref);
    return requested.length == 1
        ? const IoFailure('lost ack')
        : const Collision();
  }

  @override
  Future<DocumentRead> open(DocumentRef ref) async => reads++ == 0
      ? const Absent()
      : Opened('other bytes', scriptedRevision('other bytes'));
  @override
  Never noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName}');
}
