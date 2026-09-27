import 'package:chess_auto_prep/v2/chess/pgn/game_tree.dart';
import 'package:chess_auto_prep/v2/storage/compound_commit.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart' as store;
import 'package:chess_auto_prep/v2/storage/reference_change.dart';
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:chess_auto_prep/v2/workspace/edit_strip.dart';
import 'package:chess_auto_prep/v2/workspace/session_results.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/fixtures.dart';
import '../support/scripted_store.dart';
import '../support/session_fixture.dart';

void main() {
  late SessionFixture fixture;
  late String edited;
  var saverDisposed = false;
  final move = NodePath.of([0]);

  setUp(() async {
    saverDisposed = false;
    fixture = await openSession(blackChapter);
    fixture.session.setComment(move, 'Changed');
    await fixture.saver.flush();
    edited = fixture.onDisk;
    // An acknowledged compound edit has the same normal undo history, with
    // its two participants retained in the store receipt.
    fixture.saver.opened(fixture.ref, scriptedRevision(blackChapter));
    fixture.store.saves.add(
      store.Saved(
        store.Receipt(
          committed: scriptedRevision(edited),
          before: blackChapter,
          beforeRevision: scriptedRevision(blackChapter),
          compound: CompoundCommit(
            id: 'section-rename',
            documentPath: fixture.ref.path,
            documentBefore: blackChapter,
            documentAfter: edited,
            booksBefore: '{}',
            booksAfter: '{"renamed":true}',
          ),
        ),
      ),
    );
    fixture.saver.save(edited, const WholeDocument());
    await fixture.saver.flush();
  });

  tearDown(() {
    if (saverDisposed) {
      fixture.session.dispose();
    } else {
      fixture.dispose();
    }
  });

  Future<void> failAfterPublication() async {
    fixture.store.saves.add(const store.IoFailure('acknowledgement lost'));
    expect(await fixture.session.undo(), isA<UndoRefused>());
    // The publication happened; only its acknowledgement was lost. The
    // store recognizes the exact inverse on retry despite the old revision.
    fixture.store.documents[fixture.ref] = store.Opened(
      blackChapter,
      scriptedRevision(blackChapter),
    );
  }

  void acknowledgeRetry() {
    fixture.store.saves.add(
      store.Saved(
        store.Receipt(
          committed: scriptedRevision(blackChapter),
          before: edited,
          beforeRevision: scriptedRevision(edited),
        ),
      ),
    );
  }

  test(
    'compound undo refuses newer edits while its answer is pending',
    () async {
      fixture.store.hold = true;
      final undoing = fixture.session.undo();
      await pumpEventQueue();
      expect(fixture.saver.takesWords, isFalse);
      fixture.session.setComment(move, 'Newer');
      expect(fixture.session.refusedEdit, isA<EditNotWritten>());
      expect(fixture.session.commentAt(move), 'Changed [%eval 0.30]');
      fixture.store.hold = false;
      fixture.store.releaseAll();
      expect(await undoing, isA<Restored>());
      expect(fixture.onDisk, blackChapter);
    },
  );

  test(
    'unknown undo stays frozen through flush and retries exact scope',
    () async {
      await failAfterPublication();
      expect(fixture.saver.takesWords, isFalse);
      fixture.session.setComment(move, 'Newer');
      expect(fixture.session.commentAt(move), 'Changed [%eval 0.30]');
      final first = fixture.store.requestedSaves.last;
      final attempts = fixture.store.requestedSaves.length;
      await fixture.saver.flush();
      expect(fixture.store.requestedSaves, hasLength(attempts));
      expect(fixture.saver.settled, isFalse);
      expect(fixture.saver.state, isA<SaveFailed>());
      acknowledgeRetry();
      expect(await fixture.session.undo(), isA<Restored>());
      final retried = fixture.store.requestedSaves.last;
      expect(retried.scope, same(first.scope));
      expect(retried.text, first.text);
      expect(retried.expected, first.expected);
      expect(fixture.session.commentAt(move), 'The Sicilian [%eval 0.30]');
      expect(fixture.saver.settled, isTrue);
      expect(fixture.saver.canUndo, isFalse);
      fixture.session.setComment(move, 'After retry');
      await fixture.saver.flush();
      expect(fixture.onDisk, contains('After retry'));
    },
  );

  testWidgets('failed compound undo Retry updates the displayed document', (
    tester,
  ) async {
    await tester.runAsync(failAfterPublication);
    final editing = ValueNotifier(false);
    addTearDown(editing.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: EditStrip(
            session: fixture.session,
            saver: fixture.saver,
            editing: editing,
          ),
        ),
      ),
    );
    expect(find.text('Retry save'), findsOneWidget);
    acknowledgeRetry();
    await tester.tap(find.text('Retry save'));
    await tester.pumpAndSettle();
    expect(fixture.saver.settled, isTrue);
    expect(fixture.session.commentAt(move), 'The Sicilian [%eval 0.30]');
  });

  test(
    'repeated undo failure retains its command until session retry succeeds',
    () async {
      await failAfterPublication();
      final first = fixture.store.requestedSaves.last;
      fixture.store.saves.add(const store.IoFailure('still unavailable'));
      await fixture.session.retrySave();
      expect(fixture.store.requestedSaves.last.scope, same(first.scope));
      expect(fixture.saver.retryNeedsUndo, isTrue);
      expect(fixture.saver.referencesPending, isTrue);
      expect(fixture.saver.settled, isFalse);
      acknowledgeRetry();
      await fixture.session.retrySave();
      expect(fixture.saver.retryNeedsUndo, isFalse);
      expect(fixture.saver.referencesPending, isFalse);
      expect(fixture.session.commentAt(move), 'The Sicilian [%eval 0.30]');
    },
  );

  test('a refusal after unknown undo cannot unlock newer edits', () async {
    await failAfterPublication();
    fixture.store.saves.add(
      const store.RestoreRefused('cannot confirm the receipt'),
    );
    await fixture.session.retrySave();
    expect(fixture.saver.referencesPending, isTrue);
    expect(fixture.saver.settled, isFalse);
    fixture.session.setComment(move, 'Newer');
    expect(fixture.session.commentAt(move), 'Changed [%eval 0.30]');
    acknowledgeRetry();
    await fixture.session.retrySave();
    expect(fixture.saver.settled, isTrue);
  });

  test('a clean refused compound undo releases its edit gate', () async {
    fixture.store.saves.add(const store.RestoreRefused('not a kept version'));
    expect(await fixture.session.undo(), isA<UndoRefused>());
    expect(fixture.saver.referencesPending, isFalse);
    expect(fixture.saver.settled, isTrue);
    fixture.session.setComment(move, 'Newer');
    await fixture.saver.flush();
    expect(fixture.onDisk, contains('Newer'));
  });

  for (final undo in [false, true]) {
    test(
      'late failed ${undo ? 'undo' : 'save'} does not poison a new open',
      () async {
        fixture.store.hold = true;
        fixture.store.saves.add(
          const store.IoFailure('old acknowledgement lost'),
        );
        final Future<void> writing;
        if (undo) {
          writing = fixture.session.undo().then((_) {});
        } else {
          fixture.saver.save(
            edited,
            WholeDocument(
              references: ReferenceChanges([
                SectionRename(path: fixture.ref.path, from: 'Old', to: 'New'),
              ]),
            ),
          );
          writing = fixture.saver.flush();
        }
        await pumpEventQueue();
        expect(fixture.saver.referencesPending, isTrue);
        fixture.saver.opened(fixture.ref, scriptedRevision(edited));
        fixture.store.hold = false;
        fixture.store.releaseAll();
        await writing;
        expect(fixture.saver.referencesPending, isFalse);
        expect(fixture.saver.retryNeedsUndo, isFalse);
        expect(fixture.saver.settled, isTrue);
      },
    );
  }

  test(
    'dispose lets accepted compound undo finish without retrying it',
    () async {
      fixture.store.hold = true;
      fixture.store.saves.add(const store.IoFailure('late failure'));
      final undoing = fixture.saver.undo();
      await pumpEventQueue();
      final attempts = fixture.store.requestedSaves.length;
      fixture.saver.dispose();
      saverDisposed = true;
      fixture.store.hold = false;
      fixture.store.releaseAll();
      expect(await undoing, isA<UndoRefused>());
      await fixture.saver.flush();
      expect(fixture.store.requestedSaves, hasLength(attempts));
    },
  );

  test(
    'Retry also completes an ordinary failed undo without changing edit admission',
    () async {
      final ordinary = await openSession(blackChapter);
      addTearDown(ordinary.dispose);
      ordinary.session.setComment(move, 'Changed');
      await ordinary.saver.flush();
      ordinary.store.saves.add(const store.IoFailure('disk busy'));
      await ordinary.session.undo();
      expect(ordinary.saver.takesWords, isTrue);
      await ordinary.session.retrySave();
      expect(ordinary.saver.settled, isTrue);
      expect(ordinary.session.commentAt(move), 'The Sicilian [%eval 0.30]');
    },
  );

  test('new ordinary edit supersedes a failed ordinary undo retry', () async {
    final ordinary = await openSession(blackChapter);
    addTearDown(ordinary.dispose);
    ordinary.session.setComment(move, 'Changed');
    await ordinary.saver.flush();
    ordinary.store.saves.add(const store.IoFailure('disk busy'));
    await ordinary.session.undo();
    ordinary.session.setComment(move, 'Newer');
    await ordinary.session.retrySave();
    expect(ordinary.saver.settled, isTrue);
    expect(ordinary.saver.retryNeedsUndo, isFalse);
    expect(ordinary.onDisk, contains('Newer'));
    expect(ordinary.session.commentAt(move), 'Newer [%eval 0.30]');
  });

  test(
    'words typed during a failed ordinary undo are the retry draft',
    () async {
      final ordinary = await openSession(blackChapter);
      addTearDown(ordinary.dispose);
      ordinary.session.setComment(move, 'Changed');
      await ordinary.saver.flush();
      ordinary.store.hold = true;
      ordinary.store.saves.add(const store.IoFailure('disk busy'));
      final undoing = ordinary.session.undo();
      await pumpEventQueue();
      ordinary.session.setComment(move, 'Newer');
      ordinary.store.hold = false;
      ordinary.store.releaseAll();
      await undoing;
      await ordinary.session.retrySave();
      expect(ordinary.saver.settled, isTrue);
      expect(ordinary.saver.retryNeedsUndo, isFalse);
      expect(ordinary.onDisk, contains('Newer'));
    },
  );

  test('opening resets a failed forward compound gate', () async {
    fixture.store.saves.add(const store.IoFailure('not acknowledged'));
    fixture.saver.save(
      edited,
      WholeDocument(
        references: ReferenceChanges([
          SectionRename(path: fixture.ref.path, from: 'Old', to: 'New'),
        ]),
      ),
    );
    await fixture.saver.flush();
    expect(fixture.saver.takesWords, isFalse);
    fixture.saver.opened(fixture.ref, scriptedRevision(edited));
    expect(fixture.saver.takesWords, isTrue);
  });
}
