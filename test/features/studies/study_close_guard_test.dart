import 'dart:async';
import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/app/desktop_application.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/features/studies/models/study_document.dart';
import 'package:chess_auto_prep/features/studies/widgets/study_close_guard.dart';
import 'package:chess_auto_prep/infrastructure/settings/shared_preferences_app_settings_repository.dart';
import 'package:chess_auto_prep/chess_core/moves/tree_path.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import '../../support/memory_appearance_preferences.dart';
import '../../support/memory_desktop_close_port.dart';
import '../../support/scripted_document_store.dart';
import '../../support/study_fixture.dart';

void main() {
  late Store store;
  late StudyController study;
  late MemoryDesktopClosePort window;
  void initialize() {
    store = Store()..current = snapshot('[Event "Study"]\n\n1. e4 *');
    study = StudyController(
      library: MemoryStudyLibrary(),
      documents: store,
      autoSaveDelay: const Duration(days: 1),
      decode: (text, name, path) async =>
          StudyDocument.fromPgn(text, name: name, filePath: path),
    );
    window = MemoryDesktopClosePort();
  }

  tearDown(() => study.dispose());
  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(
      AppDependencies(
        settings: SharedPreferencesAppSettingsRepository(
          appearance: MemoryAppearancePreferences(),
        ),
        child: DesktopApplication(
          closePort: window,
          home: StudyCloseGuard(
            study: study,
            child: const Scaffold(body: Text('Other mode')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('clean study closes through the app once', (tester) async {
    initialize();
    await mount(tester);
    window.request!();
    window.request!();
    await tester.pumpAndSettle();
    expect(window.closes, 1);
    expect(find.byType(AlertDialog), findsNothing);
  });
  testWidgets(
    'untitled draft in another mode blocks close; cancellation keeps it intact',
    (tester) async {
      initialize();
      study.playSan('e4');
      await mount(tester);
      window.request!();
      window.request!();
      await tester.pumpAndSettle();
      expect(find.text('Close application?'), findsOneWidget);
      expect(window.closes, 0);
      await tester.tap(find.text('Keep app open'));
      await tester.pumpAndSettle();
      expect(study.doc.toPgn(), contains('e4'));
      expect(study.dirty, isTrue);
      expect(window.closes, 0);
    },
  );
  testWidgets('explicit discard approves only the current revision', (
    tester,
  ) async {
    initialize();
    study.playSan('e4');
    await mount(tester);
    window.request!();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('study-close-discard')));
    await tester.pumpAndSettle();
    expect(window.closes, 1);
    // Approval is not a silent document mutation; cancellation by another
    // owner later would still leave this draft available.
    expect(study.doc.toPgn(), contains('e4'));
  });
  testWidgets('save a copy then explicitly close preserves an untitled draft', (
    tester,
  ) async {
    initialize();
    study.playSan('e4');
    await mount(tester);
    window.request!();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('document-save-copy')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Recovered on close');
    await tester.tap(find.widgetWithText(FilledButton, 'Save a copy…'));
    await tester.pumpAndSettle();
    expect(study.doc.filePath, '/studies/Recovered on close.pgn');
    expect(
      find.text('Your study is saved. You can close the app.'),
      findsOneWidget,
    );
    expect(study.dirty, isFalse);
    expect(window.closes, 0);
    await tester.tap(find.byKey(const ValueKey('study-close-confirm')));
    await tester.pumpAndSettle();
    expect(window.closes, 1);
  });
  testWidgets(
    'closing waits for save and preserves edits made during its write',
    (tester) async {
      initialize();
      await study.openStudy('/main.pgn');
      study.setComment(TreePath.empty, 'first');
      final pending = Completer<PgnWriteResult>();
      late String submitted;
      store.onSave = (before, content) {
        submitted = content;
        return pending.future;
      };
      await mount(tester);
      window.request!();
      await tester.pump();
      study.setComment(TreePath.empty, 'second');
      expect(window.closes, 0);
      store.onSave = null;
      store.current = snapshot(submitted, revision: '2');
      pending.complete(
        PgnSaved(before: study.state.baseline, after: store.current),
      );
      await tester.pumpAndSettle();
      expect(store.current.content, contains('second'));
      expect(window.closes, 1);
    },
  );
  testWidgets(
    'retained drafts prevent closure even when current file is clean',
    (tester) async {
      initialize();
      await study.openStudy('/main.pgn');
      study.setComment(TreePath.empty, 'retained note');
      await study.reloadPreservingDraft();
      expect(study.dirty, isFalse);
      await mount(tester);
      window.request!();
      await tester.pumpAndSettle();
      expect(window.closes, 0);
      expect(find.text('Restore retained draft'), findsOneWidget);
      await tester.tap(find.text('Keep app open'));
      await tester.pumpAndSettle();
      expect(
        study.state.retainedDrafts.single.content,
        contains('retained note'),
      );
    },
  );
  testWidgets('known uncertain save is not retried by closing', (tester) async {
    initialize();
    await study.openStudy('/main.pgn');
    study.playSan('d4');
    store.onSave = (before, _) async => PgnWriteUncertain(
      error: StateError('ack'),
      before: before,
      observed: null,
    );
    await study.save();
    await mount(tester);
    window.request!();
    await tester.pumpAndSettle();
    expect(window.closes, 0);
    expect(store.saves, hasLength(1));
    await tester.tap(find.text('Keep app open'));
    await tester.pumpAndSettle();
  });
}
