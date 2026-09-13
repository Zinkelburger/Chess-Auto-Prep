import 'dart:io';

import 'package:chess_auto_prep/features/repertoire/widgets/local_reference_pane.dart';
import 'package:chess_auto_prep/models/explorer_response.dart';
import 'package:dartchess/dartchess.dart' hide File;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Paths extends PathProviderPlatform with MockPlatformInterfaceMixin {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationCachePath() async => path;
}

Future<void> _until(WidgetTester tester, Finder finder) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  while (finder.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 30)),
    );
    await tester.pump(const Duration(milliseconds: 30));
  }
  expect(finder, findsWidgets);
}

void main() {
  testWidgets(
    'local PGN follows board, adds moves, searches games and reopens its index',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final directory = Directory.systemTemp.createTempSync('reference-pane-');
      final originalPaths = PathProviderPlatform.instance;
      PathProviderPlatform.instance = _Paths(directory.path);
      addTearDown(() {
        PathProviderPlatform.instance = originalPaths;
        directory.deleteSync(recursive: true);
      });
      final file = File('${directory.path}/sample.pgn');
      file.writeAsStringSync(
        List.generate(
          60,
          (i) =>
              '[Event "Club"]\n[White "Player $i"]\n[Black "Opponent"]\n[Result "1-0"]\n\n1. e4 e5 2. Nf3 1-0\n\n',
        ).join(),
      );
      tester.view.physicalSize = const Size(1000, 420);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      ExplorerMove? added;
      Position position = Chess.initial;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => LocalReferencePane(
                initialPath: file.path,
                fen: position.fen,
                onAddMove: (move) => added = move,
                onPlayMove: (san) => setState(
                  () => position = position.play(position.parseSan(san)!),
                ),
              ),
            ),
          ),
        ),
      );
      await _until(tester, find.text('1–50 of 60 games'));
      await tester.tap(find.byTooltip('Add e4 to repertoire'));
      expect(added?.san, 'e4');
      await tester.tap(find.text('e4').first);
      await _until(tester, find.text('e5'));
      expect(position.turn, Side.black);
      await tester.enterText(find.byType(TextField), 'Player 17');
      await tester.pump(const Duration(milliseconds: 300));
      await _until(tester, find.text('1–1 of 1 games'));
      expect(find.textContaining('Player 17 vs Opponent'), findsOneWidget);
      expect(find.text('e5'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      // Reopen from the remembered local file, without choosing it again.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LocalReferencePane(
              fen: Chess.initial.fen,
              onPlayMove: (_) {},
            ),
          ),
        ),
      );
      await _until(tester, find.text('1–50 of 60 games'));
      expect(find.text('e4'), findsOneWidget);
      tester.view.physicalSize = const Size(600, 280);
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.widgetWithText(Tab, 'Moves'), findsOneWidget);
      expect(find.widgetWithText(Tab, 'Games'), findsOneWidget);
      await tester.tap(find.widgetWithText(Tab, 'Games'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
    },
  );
}
