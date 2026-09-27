import 'package:chess_auto_prep/features/studies/models/study_workspace_snapshot.dart';
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/documents/controllers/workspace_recovery_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import 'package:chess_auto_prep/features/documents/repositories/workspace_recovery_store.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import '../../support/scripted_document_store.dart';
import '../../support/study_fixture.dart';
import '../../support/memory_workspace_recovery_store.dart';

StudyController owner(
  Store store, {
  Future<StudyDocument> Function(String, String, String)? decode,
}) => StudyController(
  library: MemoryStudyLibrary(),
  documents: store,
  autoSaveDelay: const Duration(days: 1),
  decode:
      decode ??
      (text, name, path) async =>
          StudyDocument.fromPgn(text, name: name, filePath: path),
);
void main() {
  test(
    'a repeated restore is rejected while the first awaits its checkpoint',
    () async {
      final source = memoryStudy()..playSan('e4');
      final study = memoryStudy();
      final store = MemoryWorkspaceRecoveryStore<StudyWorkspaceSnapshot>();
      final gate = Completer<void>();
      store.beforeWrite = () => gate.future;
      final entry = WorkspaceRecoveryEntry<StudyWorkspaceSnapshot>(
        id: 'old',
        revision: 'one',
        updatedAt: DateTime(2026),
        snapshot: source.captureWorkspace(),
      );
      store.entries.add(entry);
      final recovery = WorkspaceRecoveryController<StudyWorkspaceSnapshot>(
        workspace: study,
        capture: study.captureWorkspace,
        restoreSnapshot: study.restoreWorkspace,
        store: store,
      );
      final first = recovery.restore(entry);
      expect(await recovery.restore(entry), isFalse);
      expect(store.resolved, isEmpty);
      gate.complete();
      expect(await first, isTrue);
      expect(store.resolved, ['old']);
      await recovery.shutdown();
      recovery.dispose();
      study.dispose();
      source.dispose();
    },
  );
  test(
    'restore retains baseline, chapter cursor and flip; external changes still conflict',
    () async {
      final store = Store()
        ..current = snapshot(
          '[Event "One"]\n\n1. e4 e5 *\n\n[Event "Two"]\n\n1. d4 d5 *',
        );
      final first = owner(store);
      await first.openStudy('/main.pgn');
      first.selectChapter(1);
      first.jump(TreePath.from([0]));
      first.toggleFlipped();
      first.setComment(TreePath.from([0]), 'restart note');
      final checkpoint = first.captureWorkspace();
      // Simulate an external replacement while the app was stopped.
      store.current = snapshot(
        '[Event "External"]\n\n1. c4 *',
        revision: 'external',
      );
      final restored = owner(store);
      await restored.restoreWorkspace(checkpoint);
      expect(restored.chapterIndex, 1);
      expect(restored.path, TreePath.from([0]));
      expect(restored.flipped, checkpoint.flipped);
      expect(restored.doc.toPgn(), contains('restart note'));
      expect(restored.autoSaveEnabled, isFalse);
      expect(await restored.flushSave(), isFalse);
      expect(store.saves, isEmpty);
      expect(await restored.save(), isA<PgnConflict>());
      expect(store.current.content, contains('External'));
      first.dispose();
      restored.dispose();
    },
  );
  test(
    'restoring preserves displaced draft and rejects edits during slow decode',
    () async {
      final source = memoryStudy()..playSan('e4');
      final checkpoint = source.captureWorkspace();
      final decoding = Completer<StudyDocument>();
      final target = owner(
        Store(),
        decode: (text, name, path) => decoding.future,
      )..playSan('d4');
      final restore = target.restoreWorkspace(checkpoint);
      await Future<void>.delayed(Duration.zero);
      target.setComment(TreePath.empty, 'late edit');
      decoding.complete(
        StudyDocument.fromPgn(checkpoint.content, name: checkpoint.name),
      );
      await expectLater(restore, throwsStateError);
      expect(target.doc.toPgn(), contains('late edit'));
      expect(target.doc.toPgn(), contains('d4'));
      final target2 = owner(Store())..playSan('c4');
      await target2.restoreWorkspace(checkpoint);
      expect(target2.state.retainedDrafts.single.content, contains('c4'));
      expect(target2.doc.filePath, isNull);
      source.dispose();
      target.dispose();
      target2.dispose();
    },
  );
  test(
    'in-flight save-copy checkpoint remembers its uncertain destination',
    () async {
      final source = memoryStudy()..playSan('e4');
      final store = Store();
      final pending = Completer<PgnWriteResult>();
      store.onCreate = (_, _) => pending.future;
      final study = owner(store);
      await study.restoreWorkspace(source.captureWorkspace());
      final saving = study.saveCopy('/copy.pgn');
      await Future<void>.delayed(Duration.zero);
      final checkpoint = study.captureWorkspace();
      expect(checkpoint.uncertain, isTrue);
      expect(checkpoint.uncertainPath, '/copy.pgn');
      final restored = owner(Store());
      await restored.restoreWorkspace(checkpoint);
      expect(restored.state.uncertain, isTrue);
      expect(restored.state.canSave, isFalse);
      pending.complete(PgnWriteFailed(StateError('disk')));
      await saving;
      study.dispose();
      source.dispose();
      restored.dispose();
    },
  );
  test(
    'checkpoint writes coalesce later edits behind an in-flight write',
    () async {
      final study = memoryStudy();
      final store = MemoryWorkspaceRecoveryStore<StudyWorkspaceSnapshot>();
      final recovery = WorkspaceRecoveryController<StudyWorkspaceSnapshot>(
        workspace: study,
        capture: study.captureWorkspace,
        restoreSnapshot: study.restoreWorkspace,
        store: store,
        interval: const Duration(days: 1),
      );
      final gate = Completer<void>();
      store.beforeWrite = () => gate.future;
      study.playSan('e4');
      final writing = recovery.flush();
      await Future<void>.delayed(Duration.zero);
      study.playSan('e5');
      study.playSan('Nf3');
      store.beforeWrite = null;
      gate.complete();
      await writing;
      expect(store.snapshots, hasLength(2));
      expect(store.snapshots.last.content, contains('Nf3'));
      await recovery.shutdown();
      recovery.dispose();
      study.dispose();
    },
  );
  test(
    'old checkpoint is resolved only after replacement persistence succeeds',
    () async {
      final source = memoryStudy()..playSan('e4');
      final entry = WorkspaceRecoveryEntry<StudyWorkspaceSnapshot>(
        id: 'old',
        revision: '1',
        updatedAt: DateTime(2026),
        snapshot: source.captureWorkspace(),
      );
      final store = MemoryWorkspaceRecoveryStore<StudyWorkspaceSnapshot>()
        ..entries.add(entry)
        ..writeError = StateError('disk');
      final study = memoryStudy();
      final recovery = WorkspaceRecoveryController<StudyWorkspaceSnapshot>(
        workspace: study,
        capture: study.captureWorkspace,
        restoreSnapshot: study.restoreWorkspace,
        store: store,
      );
      await recovery.restore(entry);
      expect(recovery.actionError, isNotNull);
      expect(store.resolved, isEmpty);
      expect(study.doc.toPgn(), contains('e4'));
      expect(study.dirty, isTrue);
      store.writeError = null;
      await recovery.flush();
      expect(store.snapshots.single.content, contains('e4'));
      await recovery.dismiss(entry);
      expect(store.resolved, ['old']);
      await recovery.shutdown();
      recovery.dispose();
      study.dispose();
      source.dispose();
    },
  );
  test(
    'opening another clean document preserves retained draft checkpoints',
    () async {
      final store = Store()..current = snapshot('[Event "Study"]\n\n1. e4 *');
      final study = owner(store);
      await study.openStudy('/main.pgn');
      study.setComment(TreePath.empty, 'retain across open');
      await study.reloadPreservingDraft();
      store.current = snapshot(
        '[Event "Other"]\n\n1. d4 *',
        path: '/other.pgn',
      );
      await study.openStudy('/other.pgn');
      expect(
        study.state.retainedDrafts.single.content,
        contains('retain across open'),
      );
      expect(study.captureWorkspace().needsRecovery, isTrue);
      study.dispose();
    },
  );
}
