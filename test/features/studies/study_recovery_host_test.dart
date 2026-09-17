import 'package:chess_auto_prep/features/studies/models/study_workspace_snapshot.dart';
import 'package:flutter/material.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chess_auto_prep/features/documents/controllers/workspace_recovery_controller.dart';
import 'package:chess_auto_prep/features/documents/widgets/workspace_recovery_host.dart';
import 'package:chess_auto_prep/features/documents/repositories/workspace_recovery_store.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import '../../support/study_fixture.dart';
import '../../support/scripted_document_store.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import '../../support/memory_workspace_recovery_store.dart';

StudyController inMemoryStudy() => StudyController(
  library: MemoryStudyLibrary(),
  documents: Store(),
  decode: (text, name, path) async =>
      StudyDocument.fromPgn(text, name: name, filePath: path),
);
void main() {
  testWidgets(
    'recovery from another mode restores a draft; dismissal requires confirmation',
    (tester) async {
      final source = inMemoryStudy()..playSan('e4');
      final study = inMemoryStudy();
      final store = MemoryWorkspaceRecoveryStore<StudyWorkspaceSnapshot>();
      final entry = WorkspaceRecoveryEntry<StudyWorkspaceSnapshot>(
        id: 'one',
        revision: '1',
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
      var navigations = 0;
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WorkspaceRecoveryHost<StudyWorkspaceSnapshot>(
            id: 'study',
            workspaceName: 'Study',
            title: (snapshot) => snapshot.name,
            path: (snapshot) => snapshot.path,
            recovery: recovery,
            onRestored: () => navigations++,
            child: const Scaffold(body: Text('Tactics')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review recovery'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Dismiss recovery'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(store.resolved, isEmpty);
      await tester.tap(find.text('Restore draft'));
      await tester.pumpAndSettle();
      expect(navigations, 1);
      expect(study.doc.toPgn(), contains('e4'));
      expect(study.doc.filePath, isNull);
      expect(study.autoSaveEnabled, isFalse);
      expect(store.resolved, ['one']);
      expect(find.text('Review recovery'), findsNothing);
      await recovery.shutdown();
      recovery.dispose();
      study.dispose();
      source.dispose();
    },
  );
  testWidgets(
    'unavailable recovery stays visible and an explicit retry recovers',
    (tester) async {
      final study = inMemoryStudy();
      final store = MemoryWorkspaceRecoveryStore<StudyWorkspaceSnapshot>()
        ..readError = StateError('disk');
      final recovery = WorkspaceRecoveryController<StudyWorkspaceSnapshot>(
        workspace: study,
        capture: study.captureWorkspace,
        restoreSnapshot: study.restoreWorkspace,
        store: store,
      );
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: WorkspaceRecoveryHost<StudyWorkspaceSnapshot>(
            id: 'study',
            workspaceName: 'Study',
            title: (snapshot) => snapshot.name,
            path: (snapshot) => snapshot.path,
            recovery: recovery,
            onRestored: () {},
            child: const Scaffold(body: Text('Workspace')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Study recovery is unavailable'),
        findsOneWidget,
      );
      store.readError = null;
      await tester.tap(find.text('Retry recovery'));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialBanner), findsNothing);
      await recovery.shutdown();
      recovery.dispose();
      study.dispose();
    },
  );
  testWidgets(
    'continuous edits checkpoint periodically instead of starving a debounce',
    (tester) async {
      final study = inMemoryStudy();
      final store = MemoryWorkspaceRecoveryStore<StudyWorkspaceSnapshot>();
      final recovery = WorkspaceRecoveryController<StudyWorkspaceSnapshot>(
        workspace: study,
        capture: study.captureWorkspace,
        restoreSnapshot: study.restoreWorkspace,
        store: store,
      );
      for (var i = 0; i < 10; i++) {
        study.setComment(TreePath.empty, 'note $i');
        await tester.pump(const Duration(milliseconds: 300));
      }
      expect(store.snapshots.length, inInclusiveRange(2, 3));
      await tester.pump(const Duration(seconds: 1));
      expect(store.snapshots.last.content, contains('note 9'));
      await recovery.shutdown();
      recovery.dispose();
      study.dispose();
    },
  );
}
