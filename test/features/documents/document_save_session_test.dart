import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/controllers/document_save_session.dart';
import 'package:chess_auto_prep/features/documents/models/document_save_state.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import '../../support/scripted_document_store.dart';

void main() {
  late Store store;
  late DocumentSaveSession session;
  setUp(() {
    store = Store();
    session = DocumentSaveSession.opened(store, store.current);
  });
  tearDown(() => session.dispose());

  test(
    'save uses captured revision; in-flight edits remain dirty and duplicate save is ignored',
    () async {
      final before = session.state.baseline;
      final pending = Completer<PgnWriteResult>();
      store.onSave = (_, _) => pending.future;
      session.edit('submitted');
      final save = session.save();
      session.edit('later edit');
      expect(await session.save(), isNull);
      expect(store.saves, [before]);
      pending.complete(
        PgnSaved(
          before: before,
          after: snapshot('submitted', revision: '2'),
        ),
      );
      await save;
      expect(session.state.content, 'later edit');
      expect(session.state.baseline!.content, 'submitted');
      expect(session.state.phase, DocumentSavePhase.dirty);
      store.onSave = null;
      store.current = session.state.baseline!;
      await session.save();
      expect(store.saves.last.content, 'submitted');
      expect(session.state.phase, DocumentSavePhase.saved);
    },
  );

  test(
    'conflict and dismissal retain baseline and never authorize replacement',
    () async {
      final original = session.state.baseline;
      session.edit('my draft');
      store.current = snapshot('external', revision: 'external');
      await session.save();
      expect(session.state.phase, DocumentSavePhase.conflict);
      session.keepEditing();
      expect(session.state.baseline, same(original));
      expect(session.state.content, 'my draft');
      await session.save();
      expect(session.state.phase, DocumentSavePhase.conflict);
      expect(store.current.content, 'external');
    },
  );

  test(
    'inspection does not adopt; reload reads again and retains edits made during read',
    () async {
      session.edit('my draft');
      store.current = snapshot('first external', revision: '2');
      await session.save();
      await session.inspectCurrent();
      expect(session.state.content, 'my draft');
      final pending = Completer<PgnOpenResult>();
      store.onOpen = (_) => pending.future;
      final reload = session.reloadPreservingDraft();
      session.edit('latest draft');
      pending.complete(PgnOpened(snapshot('second external', revision: '3')));
      await reload;
      expect(session.state.content, 'second external');
      expect(session.state.retainedDrafts.single.content, 'latest draft');
      await session.restoreDraft(0);
      expect(session.state.content, 'latest draft');
      expect(session.state.baseline!.revision.nativeIdentity, '3');
      expect(store.saves, hasLength(1));
    },
  );

  test(
    'missing and unreadable reload never discard a draft or its baseline',
    () async {
      session.edit('draft');
      final baseline = session.state.baseline;
      for (final result in [
        const PgnMissing(),
        PgnReadFailed(StateError('read')),
      ]) {
        store.onOpen = (_) async => result;
        await session.reloadPreservingDraft();
        expect(session.state.readFailure, same(result));
        expect(session.state.content, 'draft');
        expect(session.state.baseline, same(baseline));
      }
    },
  );

  test(
    'copy collision preserves original; successful exclusive copy adopts new path',
    () async {
      session.edit('draft');
      final baseline = session.state.baseline;
      store.onCreate = (_, _) async => const PgnNameCollision();
      await session.saveCopy('/copy.pgn');
      expect(session.state.phase, DocumentSavePhase.collision);
      expect(session.state.baseline, same(baseline));
      expect(session.state.path, '/main.pgn');
      store.onCreate = null;
      await session.saveCopy('/other.pgn');
      expect(session.state.path, '/other.pgn');
      expect(session.state.phase, DocumentSavePhase.saved);
      expect(store.saves, isEmpty);
      expect(store.creates, ['/copy.pgn', '/other.pgn']);
    },
  );

  test(
    'uncertain result blocks retry even after edits, dismissal and failed copy',
    () async {
      session.edit('draft');
      store.onSave = (before, _) async => PgnWriteUncertain(
        error: StateError('flush'),
        before: before,
        observed: null,
      );
      await session.save();
      session.keepEditing();
      session.edit('new draft');
      store.onCreate = (_, _) async => const PgnNameCollision();
      await session.saveCopy('/copy.pgn');
      expect(session.state.phase, DocumentSavePhase.uncertain);
      expect(await session.save(), isNull);
      expect(store.saves, hasLength(1));
      expect(session.state.content, 'new draft');
    },
  );

  test(
    'uncertain copy inspects its destination rather than unrelated original',
    () async {
      session.edit('draft');
      store.onCreate = (_, _) async => PgnWriteUncertain(
        error: StateError('flush'),
        before: null,
        observed: null,
      );
      await session.saveCopy('/copy.pgn');
      expect(session.state.path, '/main.pgn');
      store.onOpen = (path) async {
        expect(path, '/copy.pgn');
        return PgnOpened(snapshot('installed copy', path: path));
      };
      await session.reloadPreservingDraft();
      expect(session.state.path, '/copy.pgn');
      expect(session.state.retainedDrafts.single.content, 'draft');
      expect(session.state.phase, DocumentSavePhase.clean);
    },
  );

  test(
    'unexpected adapter throw is uncertain, not permission to retry',
    () async {
      session.edit('draft');
      store.onSave = (_, _) => throw StateError('unknown commit state');
      await session.save();
      expect(session.state.phase, DocumentSavePhase.uncertain);
      expect(session.state.canSave, isFalse);
    },
  );

  test(
    'ordinary failure preserves draft and supports explicit retry',
    () async {
      session.edit('draft');
      store.onSave = (_, _) async => PgnWriteFailed(StateError('disk full'));
      await session.save();
      expect(session.state.phase, DocumentSavePhase.failed);
      expect(session.state.content, 'draft');
      store.onSave = null;
      await session.save();
      expect(session.state.phase, DocumentSavePhase.saved);
    },
  );

  test('edits during a failed reload cannot leave a saved status', () async {
    final pending = Completer<PgnOpenResult>();
    store.onOpen = (_) => pending.future;
    final reload = session.reloadPreservingDraft();
    session.edit('typed during read');
    pending.complete(const PgnMissing());
    await reload;
    expect(session.state.content, 'typed during read');
    expect(session.state.phase, DocumentSavePhase.dirty);
    expect(session.state.canSave, isTrue);
  });

  test('multiple reloads retain each displaced draft', () async {
    session.edit('first');
    await session.reloadPreservingDraft();
    session.edit('second');
    await session.reloadPreservingDraft();
    expect(session.state.retainedDrafts.map((d) => d.content), [
      'first',
      'second',
    ]);
    session.edit('third');
    await session.restoreDraft(0);
    expect(session.state.content, 'first');
    expect(session.state.retainedDrafts.map((d) => d.content), [
      'second',
      'third',
    ]);
  });

  test(
    'new draft only uses exclusive create and disposal during save does not lose receipt',
    () async {
      await session.dispose();
      session = DocumentSaveSession.draft(
        store,
        path: '/new.pgn',
        content: 'draft',
      );
      final pending = Completer<PgnWriteResult>();
      store.onCreate = (_, _) => pending.future;
      final saving = session.save();
      await session.dispose();
      final result = PgnSaved(
        before: null,
        after: snapshot('draft', path: '/new.pgn'),
      );
      pending.complete(result);
      expect(await saving, same(result));
      expect(store.saves, isEmpty);
      expect(store.creates, ['/new.pgn']);
    },
  );
}
