import 'dart:async';

import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/chapter_files.dart';
import 'package:chess_auto_prep/v2/workspace/document_session.dart';
import 'package:chess_auto_prep/v2/storage/edit_scope.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart' as disk;
import 'package:chess_auto_prep/v2/workspace/document_saver.dart';
import 'package:flutter_test/flutter_test.dart';

import '../support/scripted_store.dart';

void main() {
  late ScriptedDocumentStore store;
  late DocumentSaver saver;
  late _Guard guard;
  var disposed = false;
  const ref = DocumentRef('/repertoires/Main.pgn');

  setUp(() {
    disposed = false;
    store = ScriptedDocumentStore()
      ..documents[ref] = disk.Opened('before', scriptedRevision('before'));
    guard = _Guard();
    saver = DocumentSaver(store, delay: Duration.zero, writeGuard: () => guard)
      ..opened(ref, scriptedRevision('before'));
  });
  tearDown(() {
    if (!disposed) saver.dispose();
  });

  test(
    'undo cannot cross an open while waiting for accepted training',
    () async {
      const before = '// Color: White\n\n[Event "Before"]\n\n1. e4 *\n';
      const after = '// Color: White\n\n[Event "After"]\n\n1. d4 *\n';
      final other = ChapterRef.at('/repertoires/Other.pgn');
      store.documents[ref] = disk.Opened(before, scriptedRevision(before));
      store.documents[other] = disk.Opened(before, scriptedRevision(before));
      final session = DocumentSession(store, saver);
      addTearDown(session.dispose);
      await session.open(ChapterRef.at(ref.path));
      saver.save(after, const WholeDocument());
      await saver.flush();
      final release = Completer<void>();
      guard.pauseOnce = release;
      final undoing = session.undo();
      await pumpEventQueue();
      await session.open(other);
      saver.save(after, const WholeDocument());
      await saver.flush();
      release.complete();
      expect(await undoing, isA<UndoRefused>());
      expect(session.source, other);
      expect((store.documents[other] as disk.Opened).text, after);
      expect(guard.active, 0);
    },
  );

  for (final failing in ['guard', 'save', 'undo']) {
    test(
      '$failing exception releases its write hold and remains retryable',
      () async {
        if (failing == 'undo') {
          saver.save('after', const WholeDocument());
          await saver.flush();
        }
        if (failing == 'guard') {
          guard.throwOnce = true;
        } else {
          store.throwOnSave = StateError('write failed');
        }
        if (failing == 'undo') {
          expect(await saver.undo(), isA<UndoRefused>());
        } else {
          saver.save('after', const WholeDocument());
          await saver.flush();
        }
        expect(guard.active, 0);
        expect(saver.state, isA<SaveFailed>());
        if (failing == 'undo') {
          expect(await saver.undo(), isA<Restored>());
        } else {
          await saver.flush();
        }
        expect(guard.active, 0);
        expect(saver.settled, isTrue);
      },
    );
  }

  for (final ending in ['reopened', 'disposed']) {
    test(
      'a $ending saver releases its in-flight hold after the store answers',
      () async {
        store.hold = true;
        saver.save('after', const WholeDocument());
        final saving = saver.flush();
        await pumpEventQueue();
        expect(guard.active, 1);
        expect(store.waiting, 1);
        var adoptedWhileHeld = false;
        if (ending == 'reopened') {
          saver.opened(ref, scriptedRevision('before'));
          saver.addListener(() {
            if (saver.lastReceipt != null) adoptedWhileHeld = guard.active > 0;
          });
        } else {
          saver.dispose();
          disposed = true;
        }
        store.releaseAll();
        await saving;
        expect(guard.active, 0);
        expect((store.documents[ref] as disk.Opened).text, 'after');
        if (ending == 'reopened') expect(adoptedWhileHeld, isTrue);
      },
    );
  }
}

class _Guard implements DocumentWriteGuard {
  int active = 0;
  bool throwOnce = false;
  Completer<void>? pauseOnce;

  @override
  Future<String?> pauseForWrite() async {
    active++;
    final pause = pauseOnce;
    pauseOnce = null;
    await pause?.future;
    if (throwOnce) {
      throwOnce = false;
      throw StateError('training drain failed');
    }
    return null;
  }

  @override
  void resumeAfterWrite() => active--;
}
