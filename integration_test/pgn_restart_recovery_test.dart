import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_workspace_snapshot.dart';
import 'package:chess_auto_prep/infrastructure/desktop/window_close_adapter.dart';
import 'package:chess_auto_prep/infrastructure/documents/file_workspace_recovery_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/pgn_workspace_codec.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/screens/pgn_viewer_screen.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';

class ObservingWindow extends WindowCloseAdapter {
  int approvals = 0;
  @override
  Future<void> close() async {
    approvals++;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'app-owned PGN close and restart recovery preserve drafts, cursor and source',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pgn_viewer.auto_detect_openings', false);
      await prefs.setBool('game_view.auto_save', false);
      final root = await Directory(
        '${(await AppPaths.documentsDirectory()).path}/pgn-restart-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final file = File('${root.path}/Original.pgn');
      const firstGame = '[Event "First"]\n\n1. e4 e5 *';
      const secondGame = '[Event "Second"]\n\n1. d4 d5 *';
      const original = '; Original banner\n\n$firstGame\n\n$secondGame\n';
      await file.writeAsString(original);
      FileWorkspaceRecoveryStore<PgnWorkspaceSnapshot> store() =>
          FileWorkspaceRecoveryStore<PgnWorkspaceSnapshot>(
            directory: () async => Directory('${root.path}/checkpoints'),
            codec: const PgnWorkspaceCodec(),
          );
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await windowManager.ensureInitialized();
      final window = ObservingWindow();
      await tester.pumpWidget(
        ChessAutoPrepApp(pgnRecoveryStore: store(), closePort: window),
      );
      await tester.pumpAndSettle();
      final appContext = tester.element(find.byType(AppModeSwitcher).first);
      final first = appContext.read<PgnViewerLifetime>();
      first.controller.setAutoSave(false);
      await first.controller.loadFile(file.path);
      first.controller.persistMoveCommentsFor(
        first.controller.allGames[1],
        '1. d4 {Restart draft} d5 *',
      );
      expect(find.byType(PgnViewerScreen), findsNothing);
      // The app owns close protection before a reader route has ever existed.
      await windowManager.show();
      await windowManager.close();
      for (
        var i = 0;
        i < 100 && find.text('Save PGN collection').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.text('Save PGN collection'), findsOneWidget);
      expect(window.approvals, 0);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      appContext.read<AppState>().setMode(AppMode.pgnViewer);
      await tester.pumpAndSettle();
      first.controller.goToGame(1);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RegExp(r'^Forward')).first);
      await tester.pumpAndSettle();
      first.controller.toggleBoardFlipped();
      await tester.pumpAndSettle();
      await first.recovery.flush();
      expect(first.controller.captureWorkspace().ply, 1);
      expect(await file.readAsString(), original);
      await tester.pumpWidget(const SizedBox.shrink());
      await first.shutdown();
      await tester.pumpAndSettle();

      const changed =
          '; External banner\n\n$firstGame\n\n[Event "Second changed"]\n\n1. c4 *\n';
      await file.writeAsString(changed);
      await prefs.setBool('game_view.auto_save', true);
      final restartStore = store();
      final entry = (await restartStore.list()).entries.single;
      await tester.pumpWidget(ChessAutoPrepApp(pgnRecoveryStore: restartStore));
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 100 &&
            find
                .byKey(const ValueKey('review-pgn-recovery'))
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(find.byType(PgnViewerScreen), findsNothing);
      await tester.tap(find.byKey(const ValueKey('review-pgn-recovery')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(ValueKey(('restore-pgn-recovery', entry.id))),
      );
      for (
        var i = 0;
        i < 100 && find.byType(PgnViewerScreen).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.pumpAndSettle();
      final restored = tester
          .element(find.byType(PgnViewerScreen))
          .read<PgnViewerLifetime>();
      expect(restored.controller.currentGameIndex, 1);
      expect(restored.reader.mainLineIndex, 1);
      expect(restored.controller.boardFlipped, isTrue);
      expect(
        restored.controller.allGames[1].pgnText,
        contains('Restart draft'),
      );
      await restored.controller.flushPendingMetadata();
      expect(await file.readAsString(), changed);
      await tester.tap(find.byKey(const ValueKey('pgn-save-recovery')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('document-save')));
      for (
        var i = 0;
        i < 100 &&
            (restored.controller.saveActions.state.outcome is! PgnConflict ||
                restored.controller.saveActions.state.busy);
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(restored.controller.saveActions.state.outcome, isA<PgnConflict>());
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('pgn-copy-name')),
        'Recovered restart',
      );
      await tester.tap(find.byKey(const ValueKey('pgn-copy-confirm')));
      for (var i = 0; i < 100 && restored.controller.hasUnsavedChanges; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        await File('${root.path}/Recovered restart.pgn').readAsString(),
        contains('Restart draft'),
      );
      expect(await file.readAsString(), changed);
      await tester.tap(find.widgetWithText(TextButton, 'Close').last);
      await tester.pumpAndSettle();
      await restored.recovery.flush();
      await tester.pumpWidget(const SizedBox.shrink());
      await restored.shutdown();
      await tester.pumpAndSettle();
      final inspection = store();
      expect((await inspection.list()).entries, isEmpty);
      await inspection.close();
    },
  );
}
