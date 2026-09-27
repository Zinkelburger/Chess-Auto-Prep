import 'dart:io';

import 'package:chess_auto_prep/app/pgn_viewer_lifetime.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:chess_auto_prep/widgets/chess_board_widget.dart';
import 'package:chess_auto_prep/widgets/fullscreen_game_view.dart';
import 'package:chess_auto_prep/widgets/settings/settings_widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
  expect(ready(), isTrue);
  await tester.pumpAndSettle();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native Viewer changes and saves perspective, enters and exits fullscreen, and reopens',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pgn_viewer.auto_detect_openings', false);
      await prefs.remove('pgn_viewer.last_file');
      final root = await Directory(
        '${(await AppPaths.documentsDirectory()).path}/viewer-presentation-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final file = File('${root.path}/Presentation journey.pgn');
      const original =
          '; Keep this banner\n\n'
          '[Event "First"]\n[White "Alice"]\n[Black "Bob"]\n\n1. e4 e5 *\n\n'
          '[Event "Second"]\n[White "Bob"]\n[Black "Alice"]\n\n1. d4 d5 *\n';
      await file.writeAsString(original);
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });
      await tester.pumpWidget(const ChessAutoPrepApp());
      await tester.pumpAndSettle();
      final context = tester.element(find.byType(AppModeSwitcher).first);
      context.read<AppState>().setMode(AppMode.pgnViewer);
      await tester.pumpAndSettle();
      final first = context.read<PgnViewerLifetime>();
      await first.document.loadFile(file.path);
      first.document.editor.setAutoSave(false);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('view-settings-pgnViewer')));
      await tester.pumpAndSettle();
      final orientation = find.byWidgetPredicate(
        (widget) =>
            widget is SettingsChoiceTile<String> &&
            widget.label == 'Board orientation',
      );
      await tester.ensureVisible(orientation);
      await tester.pumpAndSettle();
      final field = find.descendant(
        of: orientation,
        matching: find.byType(TextField),
      );
      await tester.enterText(field, 'Always Black');
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(CompositedTransformFollower),
          matching: find.text('Always Black'),
        ),
      );
      await tester.pumpAndSettle();
      expect(first.document.presentation.boardFlipped, isTrue);
      expect(first.document.editor.hasUnsavedChanges, isTrue);
      expect(await file.readAsString(), original);
      await tester.tap(find.byTooltip(RegExp(r'^Close settings')));
      await tester.pumpAndSettle();
      expect(await first.document.editor.saveChanges(), isTrue);
      final saved = await file.readAsString();
      expect(saved.replaceFirst('[StudyPerspective "black"]\n', ''), original);
      expect(
        tester
            .widget<ChessBoardWidget>(find.byType(ChessBoardWidget).first)
            .flipped,
        isTrue,
      );

      await tester.sendKeyEvent(LogicalKeyboardKey.f11);
      await waitFor(tester, () => first.document.presentation.isFullScreen);
      expect(find.byType(FullscreenGameView), findsOneWidget);
      expect(
        tester
            .widget<FullscreenGameView>(find.byType(FullscreenGameView))
            .boardFlipped,
        isTrue,
      );
      final fullscreen = find.byType(FullscreenGameView);
      final startPly = first.reader.mainLineIndex;
      expect(first.reader.mainLineLength, 2);
      await tester.tap(
        find.descendant(
          of: fullscreen,
          matching: find.byIcon(Icons.chevron_right),
        ),
      );
      await tester.pumpAndSettle();
      expect(first.reader.mainLineIndex, startPly + 1);
      await tester.tap(
        find.descendant(
          of: fullscreen,
          matching: find.byIcon(Icons.chevron_left),
        ),
      );
      await tester.pumpAndSettle();
      expect(first.reader.mainLineIndex, startPly);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();
      expect(first.reader.mainLineIndex, startPly + 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(first.reader.mainLineIndex, startPly);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await waitFor(tester, () => !first.document.presentation.isFullScreen);
      expect(find.byType(FullscreenGameView), findsNothing);
      expect(first.reader.mainLineIndex, startPly);
      expect(first.reader.mainLineLength, 2);
      expect(await file.readAsString(), saved);
      await tester.pumpWidget(const SizedBox.shrink());
      await first.shutdown();
      await tester.pumpAndSettle();

      await tester.pumpWidget(const ChessAutoPrepApp());
      await tester.pumpAndSettle();
      final nextContext = tester.element(find.byType(AppModeSwitcher).first);
      nextContext.read<AppState>().setMode(AppMode.pgnViewer);
      final next = nextContext.read<PgnViewerLifetime>();
      await waitFor(
        tester,
        () => next.document.filePath == file.path && !next.document.isLoading,
      );
      expect(next.document.presentation.boardFlipped, isTrue);
      expect(next.document.presentation.perspective.toHeaderValue(), 'black');
      expect(next.document.presentation.isFullScreen, isFalse);
      expect(await file.readAsString(), saved);
      await tester.pumpWidget(const SizedBox.shrink());
      await next.shutdown();
      await tester.pumpAndSettle();
    },
  );
}
