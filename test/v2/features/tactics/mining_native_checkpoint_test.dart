import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle_edits.dart';
import 'package:chess_auto_prep/v2/chess/tactics/puzzle.dart';
import 'package:chess_auto_prep/v2/features/tactics/set_additions.dart';
import 'package:chess_auto_prep/v2/features/tactics/tactics_set.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/settings_store.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart'
    show DocumentSaver;
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/my_games_fixture.dart';
import '../../support/tactics_fixture.dart';

void main() {
  for (final (existing, open) in [
    (false, false),
    (true, false),
    (true, true),
  ]) {
    test(
      'lost native ${existing ? 'save' : 'create'} ack ${open ? 'keeps editor conflict' : 'retains count'} and reopens exactly once',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'mining-checkpoint-',
        );
        addTearDown(() => root.delete(recursive: true));
        final documents = await Directory(
          p.join(root.path, 'Documents'),
        ).create();
        final support = await Directory(p.join(root.path, 'Support')).create();
        final ref = ChapterRef.at(
          p.join(documents.path, 'tactics_sets', 'Default.pgn'),
        );
        if (existing) {
          await File(ref.path).parent.create(recursive: true);
          await File(ref.path).writeAsString(tacticsSet);
        }
        final store = _LostAcknowledgement(
          PgnFileStore(documents: documents, support: support),
        );
        final saver = DocumentSaver(store, delay: Duration.zero);
        final session = DocumentSession(store, saver);
        final settings = SettingsStore();
        final set = TacticsSet(
          documents: store,
          session: session,
          settings: settings,
          ref: ref,
        );
        addTearDown(() {
          set.dispose();
          session.dispose();
          saver.dispose();
          settings.dispose();
        });
        final additions = SetAdditions(
          documents: store,
          session: session,
          saver: saver,
          set: set,
          older: () async => {},
        );
        if (open) await session.open(ref, game: 0);
        const id = 'lichess_AbCd1234';
        expect(await additions.add(id, [minedScholarsMate()]), isA<NotAdded>());
        final published = await File(ref.path).readAsString();
        if (open) {
          session.apply(
            (chapter) => recordAttempt(
              chapter,
              index: 0,
              solved: true,
              seconds: 4,
              now: tacticsToday,
            ),
          );
          expect(
            await additions.add(id, [minedScholarsMate()]),
            isA<NotAdded>(),
          );
          expect(saver.settled, isFalse);
          expect(
            puzzlesOf(session.chapter!.lines).first.stats.reviews,
            1,
            reason: 'unrelated draft is retained',
          );
          expect(await File(ref.path).readAsString(), published);
          // An explicit reload resolves the editor conflict; the checkpoint's
          // retained receipt still accounts for its already published puzzle.
          await session.reloadFromDisk();
        }
        final retry = await additions.add(id, [minedScholarsMate()]);
        expect(retry, isA<Added>());
        expect(
          (retry as Added).added,
          1,
          reason: 'the original checkpoint receipt keeps its count',
        );
        expect(await File(ref.path).readAsString(), published);
        final reopened =
            await PgnFileStore(documents: documents, support: support).open(ref)
                as Opened;
        expect(analyzedIn(reopened.text), contains(id));
        expect(
          parseChapter(name: 'Default', text: reopened.text).lines,
          hasLength(existing ? 6 : 1),
        );
        expect(
          store.publications,
          1,
          reason: 'lost acknowledgement does not append twice',
        );
      },
    );
  }
}

final class _LostAcknowledgement implements PgnDocumentStore {
  _LostAcknowledgement(this.store);
  final PgnDocumentStore store;
  bool lose = true;
  int publications = 0;
  @override
  Future<DocumentRead> open(DocumentRef ref) => store.open(ref);
  @override
  Future<CreateResult> create(DocumentRef ref, String text) async {
    final result = await store.create(ref, text);
    if (result is Created) publications++;
    if (lose && result is Created) {
      lose = false;
      return const IoFailure('acknowledgement lost');
    }
    return result;
  }

  @override
  Future<SaveResult> save(
    DocumentRef ref,
    String text, {
    required Revision expected,
    required EditScope scope,
  }) async {
    final result = await store.save(
      ref,
      text,
      expected: expected,
      scope: scope,
    );
    if (result is Saved) publications++;
    if (lose && result is Saved) {
      lose = false;
      return const IoFailure('acknowledgement lost');
    }
    return result;
  }

  @override
  Never noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
