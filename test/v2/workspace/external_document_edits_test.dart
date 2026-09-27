import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/chess/pgn/line_moves.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/storage/pgn_file_store.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart' as store;
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../storage/store_fixture.dart';
import '../support/fixtures.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture f;
  late store.DocumentEdit secondary;
  var disposed = false;
  setUp(() async {
    disposed = false;
    f = await openSession(blackChapter);
    final ref = chapterRef('KID', 'Other');
    f.store.documents[ref] = store.Opened(
      whiteChapter,
      scriptedRevision(whiteChapter),
    );
    secondary = store.DocumentEdit(
      ref: ref,
      text: '$whiteChapter\n',
      expected: scriptedRevision(whiteChapter),
      scope: const WholeDocument(),
    );
  });
  tearDown(() {
    if (!disposed) f.dispose();
  });

  Future<PreparedDocumentEdit> prepare() async =>
      await f.session.externalEdits.prepare(
            (chapter) => linesTakenOut(chapter, games: {1}),
          )
          as PreparedDocumentEdit;
  Future<store.SaveResult> publish(store.DocumentEdit primary) =>
      f.store.savePair(primary, secondary, operationId: 'external-pair');

  test(
    'preparation leaves shown words unchanged; success adopts one compound undo',
    () async {
      final before = f.session.chapter;
      final command = await prepare();
      expect(f.session.chapter, same(before));
      expect(f.onDisk, blackChapter);
      expect(
        await f.session.externalEdits.commit(command, publish),
        isA<store.Saved>(),
      );
      expect(f.session.chapter, same(command.landing.chapter));
      expect(f.onDisk, command.primary.text);
      expect(
        await f.session.externalEdits.commit(command, publish),
        isA<store.Saved>(),
      );
      expect(f.store.requestedSaves, hasLength(2));
      expect(await f.session.undo(), isA<Restored>());
      expect(f.onDisk, blackChapter);
      expect(
        (f.store.documents[secondary.ref] as store.Opened).text,
        whiteChapter,
      );
      expect(f.saver.canUndo, isFalse);
    },
  );

  test(
    'unknown publication blocks new edits and exact retry adopts receipt',
    () async {
      final command = await prepare();
      final before = f.session.chapter;
      Future<store.SaveResult> lost(store.DocumentEdit primary) async {
        await publish(primary);
        throw StateError('lost acknowledgement');
      }

      expect(
        await f.session.externalEdits.commit(command, lost),
        isA<store.IoFailure>(),
      );
      expect(f.saver.referencesPending, isTrue);
      f.session.setComment(NodePath.of([0]), 'must not enter');
      expect(f.session.chapter, same(before));
      expect(
        await f.session.externalEdits.commit(command, publish),
        isA<store.Saved>(),
      );
      expect(f.saver.referencesPending, isFalse);
      expect(f.session.chapter, same(command.landing.chapter));
    },
  );

  test(
    'navigation during publication does not adopt old landing into new editor',
    () async {
      final command = await prepare();
      final started = Completer<void>();
      final release = Completer<void>();
      final committing = f.session.externalEdits.commit(command, (
        primary,
      ) async {
        started.complete();
        await release.future;
        return publish(primary);
      });
      await started.future;
      final opening = f.session.open(chapterRef('KID', 'Other'));
      release.complete();
      expect(await committing, isA<store.Saved>());
      await opening;
      expect(f.session.source, secondary.ref);
      expect(f.session.chapter, isNot(same(command.landing.chapter)));
      expect(f.saver.canUndo, isFalse);
      expect(f.saver.referencesPending, isFalse);
    },
  );

  test('inspection drafts are refused without saving them', () async {
    f.session.holdsEdits = true;
    f.session.setComment(NodePath.of([0]), 'inspection');
    expect(
      await f.session.externalEdits.prepare(
        (chapter) => linesTakenOut(chapter, games: {1}),
      ),
      isA<ExternalEditRefused>(),
    );
    expect(f.onDisk, blackChapter);
    expect(f.session.hasHeldEdits, isTrue);
  });

  test('stale unsubmitted token never calls its publisher', () async {
    final command = await prepare();
    f.session.setComment(NodePath.of([0]), 'new draft');
    var calls = 0;
    expect(
      await f.session.externalEdits.commit(command, (primary) async {
        calls++;
        return publish(primary);
      }),
      isA<store.SaveRefused>(),
    );
    expect(calls, 0);
  });

  test(
    'same bytes from a replaced native source cannot admit old token',
    () async {
      f.saver.opened(
        f.ref,
        Revision(
          scriptedRevision(blackChapter).contentHash,
          nativeIdentity: 'first-object',
        ),
      );
      final command = await prepare();
      f.saver.opened(
        f.ref,
        Revision(
          scriptedRevision(blackChapter).contentHash,
          nativeIdentity: 'replacement-object',
        ),
      );
      expect(
        await f.session.externalEdits.commit(command, publish),
        isA<store.SaveRefused>(),
      );
      expect(f.store.requestedSaves, isEmpty);
    },
  );

  test(
    'receipt with a different known native before proof cannot be adopted',
    () async {
      f.saver.opened(
        f.ref,
        Revision(
          scriptedRevision(blackChapter).contentHash,
          nativeIdentity: 'accepted-object',
        ),
      );
      final command = await prepare();
      final before = f.session.chapter;
      final result = await f.session.externalEdits.commit(command, (
        primary,
      ) async {
        final result = await publish(primary) as store.Saved;
        return store.Saved(
          store.Receipt(
            committed: result.receipt.committed,
            before: result.receipt.before,
            beforeRevision: Revision(
              primary.expected.contentHash,
              nativeIdentity: 'other-object',
            ),
            compound: result.receipt.compound,
          ),
        );
      });
      expect(result, isA<store.IoFailure>());
      expect(f.session.chapter, same(before));
      expect(f.saver.referencesPending, isTrue);
      // A historical acknowledgement has no native proof; it can settle the
      // command, but cannot fabricate a new training source lineage.
      expect(
        await f.session.externalEdits.commit(command, publish),
        isA<store.Saved>(),
      );
      expect(f.saver.trainingSourceRevision!.nativeIdentity, 'accepted-object');
    },
  );

  test('concurrent retry runs the retained publisher only once', () async {
    final command = await prepare();
    final entered = Completer<void>();
    final release = Completer<void>();
    var calls = 0;
    Future<store.SaveResult> held(store.DocumentEdit primary) async {
      calls++;
      entered.complete();
      await release.future;
      return publish(primary);
    }

    final first = f.session.externalEdits.commit(command, held);
    final retry = f.session.externalEdits.commit(command, held);
    expect(retry, same(first));
    await entered.future;
    expect(f.saver.referencesPending, isTrue);
    f.session.setComment(NodePath.of([0]), "blocked while publishing");
    expect(f.session.chapter, isNot(same(command.landing.chapter)));
    release.complete();
    expect(await first, isA<store.Saved>());
    expect(calls, 1);
  });

  for (final dispose in [false, true]) {
    test(
      'old accepted retry after ${dispose ? 'disposal' : 'navigation'} does not adopt',
      () async {
        final owner = f.session.externalEdits;
        final command = await prepare();
        expect(
          await owner.commit(
            command,
            (_) async => const store.IoFailure('not acknowledged'),
          ),
          isA<store.IoFailure>(),
        );
        if (dispose) {
          f.dispose();
          disposed = true;
        } else {
          await f.session.open(chapterRef('KID', 'Other'));
        }
        final shown = f.session.chapter;
        final revision = f.saver.revision;
        expect(await owner.commit(command, publish), isA<store.Saved>());
        expect(f.session.chapter, same(shown));
        expect(f.saver.revision, same(revision));
        expect(f.saver.canUndo, isFalse);
        if (!dispose) expect(f.saver.referencesPending, isFalse);
      },
    );
  }

  test(
    'saved listeners observe matching shown words and undo together',
    () async {
      final command = await prepare();
      var observations = 0;
      void inspect() {
        if (f.saver.lastReceipt == null) return;
        observations++;
        expect(f.session.chapter, same(command.landing.chapter));
        expect(f.saver.canUndo, isTrue);
        expect(f.saver.referencesPending, isFalse);
      }

      f.saver.addListener(inspect);
      f.session.addListener(inspect);
      expect(
        await f.session.externalEdits.commit(command, publish),
        isA<store.Saved>(),
      );
      expect(observations, greaterThanOrEqualTo(2));
    },
  );

  test(
    'native prepared pair adopts native receipt and undo restores both PGNs',
    () async {
      final disk = await StoreFixture.create();
      final source = ChapterRef(
        repertoire: 'Source',
        name: 'Main',
        path: disk.ref('repertoires/Source/Main.pgn').path,
      );
      final target = disk.ref('repertoires/Target/Main.pgn');
      await disk.put(source, blackChapter);
      await disk.put(target, whiteChapter);
      final saver = DocumentSaver(disk.store);
      final session = DocumentSession(disk.store, saver);
      try {
        await session.open(source);
        final command =
            await session.externalEdits.prepare(
                  (chapter) => linesTakenOut(chapter, games: {1}),
                )
                as PreparedDocumentEdit;
        expect(command.primary.expected.nativeIdentity, isNotNull);
        final second = store.DocumentEdit(
          ref: target,
          text: '$whiteChapter\n',
          expected: await disk.revisionOf(target),
          scope: const WholeDocument(),
        );
        expect(
          await session.externalEdits.commit(
            command,
            (primary) => disk.store.savePair(
              primary,
              second,
              operationId: 'workspace-pair',
            ),
          ),
          isA<store.Saved>(),
        );
        expect(session.chapter, same(command.landing.chapter));
        expect(saver.revision!.nativeIdentity, isNotNull);
        expect(
          saver.trainingSourceRevision!.nativeIdentity,
          saver.revision!.nativeIdentity,
        );
        expect(await session.undo(), isA<Restored>());
        expect(await File(source.path).readAsString(), blackChapter);
        expect(await File(target.path).readAsString(), whiteChapter);
        expect(saver.canUndo, isFalse);
      } finally {
        session.dispose();
        saver.dispose();
        await disk.dispose();
      }
    },
  );

  for (final change in ['changed', 'deleted', 'replaced', 'historical']) {
    test(
      'native completed retry after source $change acknowledges without false adoption',
      () async {
        final disk = await StoreFixture.create();
        final source = ChapterRef(
          repertoire: 'Source',
          name: 'Main',
          path: disk.ref('repertoires/Source/Main.pgn').path,
        );
        final target = disk.ref('repertoires/Target/Main.pgn');
        await disk.put(source, blackChapter);
        await disk.put(target, whiteChapter);
        final saver = DocumentSaver(disk.store);
        final session = DocumentSession(disk.store, saver);
        try {
          await session.open(source);
          final shown = session.chapter;
          final baseline = saver.trainingSourceRevision;
          final command =
              await session.externalEdits.prepare(
                    (chapter) => linesTakenOut(chapter, games: {1}),
                  )
                  as PreparedDocumentEdit;
          final second = store.DocumentEdit(
            ref: target,
            text: '$whiteChapter\n',
            expected: await disk.revisionOf(target),
            scope: const WholeDocument(),
          );
          Future<store.SaveResult> publish(store.DocumentEdit primary) =>
              disk.store.savePair(primary, second, operationId: 'lost-pair');
          expect(
            await session.externalEdits.commit(command, (primary) async {
              expect(await publish(primary), isA<store.Saved>());
              return const store.IoFailure('acknowledgement lost');
            }),
            isA<store.IoFailure>(),
          );
          final sourceFile = File(source.path);
          if (change == 'changed') await sourceFile.writeAsString(whiteChapter);
          if (change == 'deleted') await sourceFile.delete();
          if (change == 'replaced') {
            await sourceFile.rename('${source.path}.old');
            await sourceFile.writeAsString(command.primary.text);
          }
          final retryStore = change == 'historical'
              ? PgnFileStore(documents: disk.documents, support: disk.support)
              : disk.store;
          expect(
            await session.externalEdits.commit(
              command,
              (primary) => retryStore.savePair(
                primary,
                second,
                operationId: 'lost-pair',
              ),
            ),
            isA<store.Saved>(),
          );
          expect(session.chapter, same(shown));
          expect(saver.state, isA<SaveConflict>());
          expect(saver.settled, isFalse);
          expect(saver.canUndo, isFalse);
          expect(saver.trainingSourceRevision, same(baseline));
          if (change == 'deleted') {
            expect(await sourceFile.exists(), isFalse);
          } else {
            expect(
              await sourceFile.readAsString(),
              change == 'changed' ? whiteChapter : command.primary.text,
            );
          }
        } finally {
          session.dispose();
          saver.dispose();
          await disk.dispose();
        }
      },
    );
  }
}
