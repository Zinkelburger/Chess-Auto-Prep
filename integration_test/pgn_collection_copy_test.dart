import 'dart:io';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'pasted PGN copies and exports create exclusively without changing the source',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove('pgn_viewer.last_file');
      await prefs.setBool('pgn_viewer.auto_detect_openings', false);
      final root = await Directory(
        '${(await AppPaths.documentsDirectory()).path}/pasted-copy-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final occupied = File('${root.path}/occupied.pgn');
      await occupied.writeAsString('Existing destination must survive');
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(const ChessAutoPrepApp());
      await tester.pumpAndSettle();
      tester
          .element(find.byType(AppModeSwitcher).first)
          .read<AppState>()
          .setMode(AppMode.pgnViewer);
      await tester.pumpAndSettle();
      await Clipboard.setData(
        const ClipboardData(
          text:
              '; Pasted banner\r\n\r\n  [Event "Pasted"]\n[White "Alice"]\n[Black "Bob"]\n\n1. e4 {Pasted note} e5 *\n',
        ),
      );
      await tester.tap(find.text('Actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Paste PGN').last);
      await tester.pumpAndSettle();
      for (
        var i = 0;
        i < 100 &&
            find.byKey(const ValueKey('pgn-save-recovery')).evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.tap(find.byKey(const ValueKey('pgn-save-recovery')));
      await tester.pumpAndSettle();
      Future<void> copyTo(String name, {bool cancel = false}) async {
        await tester.tap(find.byKey(const ValueKey('document-save-copy')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('pgn-copy-directory')),
          root.path,
        );
        await tester.enterText(
          find.byKey(const ValueKey('pgn-copy-name')),
          name,
        );
        if (cancel) {
          await tester.tap(find.text('Cancel').last);
        } else {
          await tester.tap(find.byKey(const ValueKey('pgn-copy-confirm')));
        }
        await tester.pumpAndSettle();
      }

      await copyTo('Cancelled', cancel: true);
      expect(await File('${root.path}/Cancelled.pgn').exists(), isFalse);
      await copyTo('occupied.pgn');
      for (
        var i = 0;
        i < 100 &&
            find
                .textContaining('That destination already exists')
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        find.textContaining('That destination already exists'),
        findsOneWidget,
      );
      expect(
        await occupied.readAsString(),
        'Existing destination must survive',
      );
      await copyTo('Pasted native copy');
      final source = File('${root.path}/Pasted native copy.pgn');
      for (var i = 0; i < 100 && !await source.exists(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      final saved = await source.readAsString();
      expect(saved, contains('Pasted banner'));
      expect(saved, contains('Pasted note'));
      await tester.tap(find.widgetWithText(TextButton, 'Close').last);
      await tester.pumpAndSettle();
      expect(find.text('Pasted native copy'), findsOneWidget);
      await tester.tap(find.text('Actions').last);
      await tester.pumpAndSettle();
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer();
      await mouse.moveTo(tester.getCenter(find.text('Export').last));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Export as PGN…').last);
      await tester.pumpAndSettle();
      await mouse.removePointer();
      expect(find.text('Export PGN collection'), findsOneWidget);
      await copyTo('occupied.pgn');
      for (
        var i = 0;
        i < 100 &&
            find
                .textContaining('That destination already exists')
                .evaluate()
                .isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        await occupied.readAsString(),
        'Existing destination must survive',
      );
      await copyTo('Exported native copy');
      final exported = File('${root.path}/Exported native copy.pgn');
      for (var i = 0; i < 100 && !await exported.exists(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(await exported.readAsString(), contains('Pasted note'));
      await tester.tap(find.widgetWithText(TextButton, 'Close').last);
      await tester.pumpAndSettle();
      expect(find.text('Pasted native copy'), findsOneWidget);
      expect(await source.readAsString(), saved);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
