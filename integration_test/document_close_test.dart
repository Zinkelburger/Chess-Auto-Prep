import 'dart:io';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/features/studies/controllers/study_controller.dart';
import 'package:chess_auto_prep/infrastructure/desktop/window_close_adapter.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'helpers/tactics_helpers.dart';

/// Observe the final approved native handoff without destroying the test host.
/// attach/onWindowClose are the production adapter and receive real close events.
class RecordingWindow extends WindowCloseAdapter {
  int approvals = 0;
  int requests = 0;
  @override
  void onWindowClose() {
    requests++;
    super.onWindowClose();
  }

  @override
  Future<void> close() async {
    approvals++;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native close in another mode retains Study draft, then saves a copy before approval',
    (tester) async {
      await windowManager.ensureInitialized();
      final window = RecordingWindow();
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(ChessAutoPrepApp(closePort: window));
      await tester.pumpAndSettle();
      final study = tester
          .element(find.byKey(AppModeSwitcher.switcherKey).first)
          .read<StudyController>();
      // Other modes can add Study content without ever constructing StudyScreen.
      study.playSan('e4');
      expect(study.dirty, isTrue);
      // GTK ignores gtk_window_close for an unrealized test window.
      await windowManager.show();
      await tester.pumpAndSettle();
      expect(await windowManager.isPreventClose(), isTrue);
      await windowManager.close();
      for (
        var i = 0;
        i < 100 && find.text('Close application?').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(
        window.requests,
        1,
        reason: 'The native GTK close event reached Dart',
      );
      expect(find.text('Close application?'), findsOneWidget);
      expect(window.approvals, 0);
      expect(study.dirty, isTrue);
      await tester.tap(find.text('Keep app open'));
      await tester.pumpAndSettle();
      expect(study.doc.toPgn(), contains('e4'));
      // Visiting the viewer must not transfer ownership of native close policy.
      await switchToMode(tester, 'PGN Viewer');
      await switchToMode(tester, 'Tactics');
      expect(await windowManager.isPreventClose(), isTrue);
      await windowManager.close();
      for (
        var i = 0;
        i < 100 && find.text('Close application?').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      await tester.tap(find.byKey(const ValueKey('document-save-copy')));
      await tester.pumpAndSettle();
      final name = 'Close recovery ${DateTime.now().microsecondsSinceEpoch}';
      await tester.enterText(find.byType(TextField).last, name);
      await tester.tap(find.widgetWithText(FilledButton, 'Save a copy…'));
      for (var i = 0; i < 100 && study.dirty; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(study.doc.filePath, isNotNull);
      expect(await File(study.doc.filePath!).readAsString(), contains('e4'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('study-close-confirm')));
      for (var i = 0; i < 100 && window.approvals == 0; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(window.approvals, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
