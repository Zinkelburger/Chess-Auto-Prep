import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:chess_auto_prep/features/documents/controllers/document_save_session.dart';
import 'package:chess_auto_prep/features/documents/models/document_save_state.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import '../test/support/document_save_host.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native shared save interaction preserves external edit and draft through reload and exclusive copy',
    (tester) async {
      final root = await Directory.systemTemp.createTemp(
        'document-save-journey-',
      );
      addTearDown(() => root.delete(recursive: true));
      final path = p.join(root.path, 'Main.pgn');
      final copy = p.join(root.path, 'Copy.pgn');
      final store = NativePgnDocumentStore();
      const original = '[Event "Original"]\n\n1. e4 e5 *';
      const draft = '[Event "Draft"]\n\n1. d4 d5 *';
      const external = '[Event "External"]\n\n1. c4 e5 *';
      final created = await store.create(path, original) as PgnSaved;
      final session = DocumentSaveSession.opened(store, created.after);
      addTearDown(session.dispose);
      var destination = path;
      await tester.pumpWidget(
        DocumentSaveHost(
          session: session,
          chooseCopyDestination: (_) async => destination,
          light: true,
          scale: 1.5,
        ),
      );
      await tester.enterText(
        find.byKey(const ValueKey('document-draft')),
        draft,
      );
      await File(path).writeAsString(external);
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('document-save')));
      await tester.pumpAndSettle();
      // Native work runs off-isolate; pump until it finishes rather than assuming
      // one settled frame implies the filesystem future completed.
      for (var i = 0; i < 100 && session.state.busy; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(session.state.phase, DocumentSavePhase.conflict);
      await tester.pumpAndSettle();
      expect(await File(path).readAsString(), external);
      await tester.tap(find.text('Reload and keep draft'));
      for (var i = 0; i < 100 && session.state.busy; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(session.state.content, external);
      await tester.tap(find.text('Restore retained draft'));
      await tester.pumpAndSettle();
      expect(session.state.content, draft);
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 100 && session.state.busy; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(session.state.phase, DocumentSavePhase.collision);
      expect(await File(path).readAsString(), external);
      destination = copy;
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      for (var i = 0; i < 100 && session.state.busy; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      expect(session.state.phase, DocumentSavePhase.saved);
      expect(await File(copy).readAsString(), draft);
      expect(await File(path).readAsString(), external);
      // Reopening through a fresh store proves persisted bytes, not fake state.
      final reopened = await NativePgnDocumentStore().open(copy) as PgnOpened;
      expect(reopened.snapshot.content, draft);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
