import 'package:chess_auto_prep/chess/pgn/chapter_heading.dart';
import 'package:chess_auto_prep/storage/chapter_files.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/workspace/generated_draft.dart';
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

  group('the draft beside a chapter', () {
    final source = ChapterRef.at('/Documents/repertoires/Main/Line.pgn');
    const marked = ChapterHeading(draft: true);
    ChapterRef inMain(String name, {ChapterHeading heading = marked}) =>
        ChapterRef.at(
          '/Documents/repertoires/Main/$name.pgn',
          heading: heading,
        );

    test('are the ones already there, marked drafts, in its folder', () {
      final chapters = [
        inMain('Line (draft)', heading: ChapterHeading.none),
        ChapterRef.at(
          '/Documents/repertoires/Other/Line (draft).pgn',
          heading: marked,
        ),
        inMain('Line (draft 3)'),
      ];
      expect(draftsBeside(source, chapters), [chapters.last]);
    });

    test('an existing one is used as it is', () async {
      final store = ScriptedDocumentStore();
      final draft = inMain('Line (draft 3)');
      final found = await publishDraft(
        ExistingDraft(draft),
        documents: store,
        textFor: (_) => fail('nothing is written'),
      );
      expect((found as DraftWritten).ref, draft);
      expect(store.documents, isEmpty);
    });

    test('a new one takes the first name no file in the folder has', () {
      final chapters = [
        inMain('Line (draft)', heading: ChapterHeading.none),
        inMain('line (draft 2)'),
        ChapterRef.at('/Documents/repertoires/Other/Line (draft 3).pgn'),
      ];
      expect(newDraftBeside(source, chapters)?.name, 'Line (draft 3)');
    });

    test(
      'a new one is written under the name asked about, or not at all',
      () async {
        final store = ScriptedDocumentStore();
        final target = newDraftBeside(source, const [])!;
        store.documents[first] = Opened('someone', scriptedRevision('someone'));
        final made = await publishDraft(
          target,
          documents: store,
          textFor: (name) => '// $name\n// Draft\n\n',
        );
        expect(made, isA<DraftNotWritten>());
        expect(store.documents.containsKey(second), isFalse);

        store.documents.remove(first);
        final retried = await publishDraft(
          target,
          documents: store,
          textFor: (name) => '// $name\n// Draft\n\n',
        );
        expect((retried as DraftWritten).ref, first);
        expect(
          (store.documents[first]! as Opened).text,
          '// Line (draft)\n// Draft\n\n',
        );
      },
    );
  });
}
