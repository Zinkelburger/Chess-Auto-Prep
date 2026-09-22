import 'dart:async';
import 'package:chess_auto_prep/features/documents/models/document_save_state.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/scripted_document_store.dart';
import '../../support/study_fixture.dart';

const original = '[Event "Study"]\n\n1. e4 *';
const external = '[Event "External"]\n\n1. d4 d5 *';
Future<void> tick() => Future<void>.delayed(Duration.zero);

void main() {
  late Store store;
  late MemoryStudyLibrary library;
  late StudyController study;
  var disposed = false;
  Future<StudyDocument> Function(String, String, String)? onDecode;
  setUp(() async {
    onDecode = null;
    disposed = false;
    store = Store()..current = snapshot(original);
    library = MemoryStudyLibrary();
    study = StudyController(
      library: library,
      documents: store,
      autoSaveDelay: const Duration(milliseconds: 20),
      decode: (content, name, path) async => onDecode != null
          ? await onDecode!(content, name, path)
          : StudyDocument.fromPgn(content, name: name, filePath: path),
    );
    await study.openStudy('/main.pgn');
  });
  tearDown(() async {
    if (!disposed) study.dispose();
    await tick();
  });

  test(
    'write receipt advances only submitted content; later tree edits stay dirty',
    () async {
      final pending = Completer<PgnWriteResult>();
      late String submitted;
      store.onSave = (before, content) {
        submitted = content;
        return pending.future;
      };
      study.setComment(TreePath.empty, 'submitted note');
      final saving = study.save();
      await tick();
      study.setComment(TreePath.empty, 'newer note');
      pending.complete(
        PgnSaved(
          before: store.current,
          after: snapshot(submitted, revision: '2'),
        ),
      );
      await saving;
      expect(study.state.baseline!.content, contains('submitted note'));
      expect(study.doc.toPgn(), contains('newer note'));
      expect(study.dirty, isTrue);
      expect(study.state.phase, DocumentSavePhase.dirty);
      store.current = study.state.baseline!;
      store.onSave = null;
      expect(await study.flushSave(), isTrue);
      expect(store.current.content, contains('newer note'));
    },
  );

  for (final uncertain in [false, true]) {
    test(
      '${uncertain ? 'uncertain' : 'failed'} save is never replayed by edit, dismissal, navigation or disposal',
      () async {
        store.onSave = (before, _) async => uncertain
            ? PgnWriteUncertain(
                error: StateError('ack'),
                before: before,
                observed: null,
              )
            : PgnWriteFailed(StateError('disk'));
        study.setComment(TreePath.empty, 'keep me');
        await study.save();
        study.keepEditing();
        study.setComment(TreePath.empty, 'keep latest');
        await Future<void>.delayed(const Duration(milliseconds: 40));
        expect(await study.flushSave(), isFalse);
        await study.openStudy('/other.pgn');
        expect(study.doc.filePath, '/main.pgn');
        expect(study.doc.toPgn(), contains('keep latest'));
        expect(store.saves, hasLength(1));
        expect(library.recoveries.single, contains('keep me'));
        if (!uncertain) {
          store.onSave = null;
          expect(await study.save(), isA<PgnSaved>());
          expect(study.dirty, isFalse);
        }
        final writes = store.saves.length;
        study.dispose();
        disposed = true;
        await tick();
        expect(store.saves, hasLength(writes));
      },
    );
  }

  test('queued autosave cannot replay an in-flight failure', () async {
    final pending = Completer<PgnWriteResult>();
    store.onSave = (_, _) => pending.future;
    study.setComment(TreePath.empty, 'first');
    final saving = study.save();
    await tick();
    study.setComment(TreePath.empty, 'second');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    pending.complete(PgnWriteFailed(StateError('disk')));
    await saving;
    await tick();
    expect(store.saves, hasLength(1));
    expect(study.doc.toPgn(), contains('second'));
  });

  test(
    'reload decodes before adoption and retains edits made during decoding',
    () async {
      study.setComment(TreePath.empty, 'before reload');
      store.current = snapshot(external, revision: 'external');
      await study.save();
      final decoded = Completer<StudyDocument>();
      onDecode = (content, name, path) => decoded.future;
      final reload = study.reloadPreservingDraft();
      await tick();
      study.setComment(TreePath.empty, 'while decoding');
      decoded.complete(
        StudyDocument.fromPgn(
          external,
          name: 'External',
          filePath: '/main.pgn',
        ),
      );
      await reload;
      expect(study.doc.toPgn(), contains('d4'));
      expect(
        study.state.retainedDrafts.single.content,
        contains('while decoding'),
      );
      expect(study.dirty, isFalse);
      onDecode = null;
      study.setComment(TreePath.empty, 'new disk draft');
      await study.restoreDraft(0);
      expect(study.doc.toPgn(), contains('while decoding'));
      expect(
        study.state.retainedDrafts.single.content,
        contains('new disk draft'),
      );
      expect(study.state.baseline!.revision.nativeIdentity, 'external');
      expect(study.dirty, isTrue);
      expect(store.saves, hasLength(1));
      await Future<void>.delayed(const Duration(milliseconds: 40));
      expect(
        store.saves,
        hasLength(1),
        reason: 'restoration needs an explicit save',
      );
    },
  );

  test(
    'failed decode and failed read preserve the entire old document',
    () async {
      study.setComment(TreePath.empty, 'draft');
      final document = study.doc;
      final baseline = study.state.baseline;
      onDecode = (_, _, _) => throw StateError('decode');
      await study.reloadPreservingDraft();
      expect(study.doc, same(document));
      expect(study.state.baseline, same(baseline));
      expect(study.state.readFailure, isA<PgnReadFailed>());
      store.onOpen = (_) async => const PgnMissing();
      await study.reloadPreservingDraft();
      expect(study.doc, same(document));
      expect(study.state.readFailure, isA<PgnMissing>());
      expect(study.doc.toPgn(), contains('draft'));
    },
  );

  test(
    'copy collision keeps original; successful copy keeps edits made during its write',
    () async {
      store.onCreate = (_, _) async => const PgnNameCollision();
      study.setComment(TreePath.empty, 'copy');
      expect(await study.saveCopy('/copy.pgn'), isA<PgnNameCollision>());
      expect(study.doc.filePath, '/main.pgn');
      final pending = Completer<PgnWriteResult>();
      late String submitted;
      store.onCreate = (_, content) {
        submitted = content;
        return pending.future;
      };
      final copy = study.saveCopy('/copy.pgn');
      await tick();
      study.setComment(TreePath.empty, 'after capture');
      pending.complete(
        PgnSaved(before: null, after: snapshot(submitted, path: '/copy.pgn')),
      );
      await copy;
      expect(study.doc.filePath, '/copy.pgn');
      expect(study.state.baseline!.content, contains('copy'));
      expect(study.doc.toPgn(), contains('after capture'));
      expect(study.dirty, isTrue);
      expect(store.saves, isEmpty);
      // A successful copy resumes autosave even if the edit arrived while a
      // previous collision had suspended the timer.
      final autosaved = Completer<void>();
      store.onSave = (before, content) async {
        expect(before.path, '/copy.pgn');
        expect(before.content, contains('copy'));
        expect(content, contains('after capture'));
        autosaved.complete();
        return PgnSaved(
          before: before,
          after: snapshot(content, path: before.path, revision: '2'),
        );
      };
      await autosaved.future.timeout(const Duration(seconds: 5));
      await tick();
      expect(study.doc.filePath, '/copy.pgn');
      expect(study.dirty, isFalse);
    },
  );

  test(
    'opening another file saves edits made during its slow decode',
    () async {
      final pending = Completer<StudyDocument>();
      onDecode = (_, name, path) => pending.future;
      store.onOpen = (path) async => PgnOpened(snapshot(external, path: path));
      final opening = study.openStudy('/other.pgn');
      await tick();
      study.setComment(TreePath.empty, 'late original edit');
      pending.complete(
        StudyDocument.fromPgn(external, name: 'Other', filePath: '/other.pgn'),
      );
      await opening;
      expect(store.current.content, contains('late original edit'));
      expect(study.doc.filePath, '/other.pgn');
      expect(study.doc.toPgn(), contains('d4'));
    },
  );

  test(
    'conflict during slow open preserves original draft instead of replacing it',
    () async {
      final pending = Completer<StudyDocument>();
      onDecode = (_, name, path) => pending.future;
      final opening = study.openStudy('/other.pgn');
      await tick();
      study.setComment(TreePath.empty, 'late draft');
      store.current = snapshot(external, revision: 'external');
      pending.complete(
        StudyDocument.fromPgn(external, name: 'Other', filePath: '/other.pgn'),
      );
      await opening;
      expect(study.doc.filePath, '/main.pgn');
      expect(study.doc.toPgn(), contains('late draft'));
      expect(study.state.outcome, isA<PgnConflict>());
    },
  );

  test('newer open wins over a stale decode', () async {
    final pending = Completer<StudyDocument>();
    onDecode = (_, name, path) async => path == '/slow.pgn'
        ? await pending.future
        : StudyDocument.fromPgn(external, name: name, filePath: path);
    store.onOpen = (path) async => PgnOpened(snapshot(external, path: path));
    final slow = study.openStudy('/slow.pgn');
    await tick();
    await study.openStudy('/newer.pgn');
    pending.complete(
      StudyDocument.fromPgn(original, name: 'Slow', filePath: '/slow.pgn'),
    );
    await slow;
    expect(study.doc.filePath, '/newer.pgn');
  });

  test(
    'edits during deletion survive as an untitled draft and do not recreate the file',
    () async {
      final pending = Completer<void>();
      library.beforeDelete = () => pending.future;
      final deleting = study.deleteStudy('/main.pgn');
      await tick();
      study.setComment(TreePath.empty, 'after confirmation');
      pending.complete();
      await deleting;
      expect(study.doc.filePath, isNull);
      expect(study.doc.toPgn(), contains('after confirmation'));
      expect(study.dirty, isTrue);
      expect(study.state.canSave, isFalse);
      expect(store.saves, isEmpty);
    },
  );

  test(
    'export snapshot is exclusive and leaves the source draft untouched',
    () async {
      study.setComment(TreePath.empty, 'exported note');
      final document = study.doc;
      final baseline = study.state.baseline;
      final export = study.exportSession('/export.pgn');
      study.setComment(TreePath.empty, 'later source note');
      expect(await export.save(), isA<PgnSaved>());
      expect(export.state.content, contains('exported note'));
      expect(study.doc.session, document.session);
      expect(document.toPgn(), contains('exported note'));
      expect(document.toPgn(), isNot(contains('later source note')));
      expect(study.state.baseline, same(baseline));
      expect(study.doc.toPgn(), contains('later source note'));
      expect(study.dirty, isTrue);
      await export.dispose();
      await study.flushSave();
    },
  );
}
