import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/main.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/app_mode_switcher.dart';
import 'package:chess_auto_prep/widgets/pgn/pgn_annotation_panel.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_parser.dart';
import 'package:chess_auto_prep/chess_core/pgn/pgn_text.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'viewer native save preserves other games and retains conflicted work',
    (tester) async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('pgn_viewer.auto_detect_openings', false);
      await prefs.setBool('game_view.auto_save', true);
      final root = await Directory(
        '${(await AppPaths.documentsDirectory()).path}/collection-save-${DateTime.now().microsecondsSinceEpoch}',
      ).create();
      final file = File('${root.path}/games.pgn');
      const first =
          '[Event "Native viewer"]\n[White "Alice"]\n[Black "Bob"]\n[WhiteElo "2000"]\n[Result "*"]\n\n1. e4 e5 ({Native variation introduction} 1... c5) *';
      const other = '[Event "Unrelated"]\n\n1. d4 {keep this} *';
      const original = '; My banner\n\n$first\n\n$other\n';
      await file.writeAsString(original);
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
          .switchToPgnViewer(path: file.path, ply: 1);
      for (var i = 0; i < 100 && find.text('Alice').evaluate().isEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpAndSettle();
      await tester.tap(find.text('Actions').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Edit').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(RegExp(r'^Forward')).first);
      await tester.pumpAndSettle();
      final input = find.descendant(
        of: find.byType(PgnAnnotationPanel),
        matching: find.byType(TextField),
      );
      expect(input, findsOneWidget);
      expect(tester.widget<TextField>(input).enabled, isTrue);
      await tester.enterText(input, 'Native editor saved note');
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if ((await file.readAsString()).contains('Native editor saved note')) {
          break;
        }
      }
      final saved = await file.readAsString();
      expect(saved, startsWith('; My banner'));
      expect(saved, contains(other));
      expect(saved, contains('Native editor saved note'));
      expect(saved, contains('Native variation introduction'));
      expect(saved, contains('c5'));
      final history = Directory('${root.path}/.cap-pgn-history');
      final archived = await history
          .list()
          .where((entry) => entry.path.endsWith('.bytes'))
          .toList();
      expect(archived, isNotEmpty);
      expect(await File(archived.first.path).readAsString(), original);

      await tester.tap(find.text('c5', findRichText: true).last);
      await tester.pumpAndSettle();
      await tester.tap(input);
      await tester.pumpAndSettle();
      await tester.enterText(input, 'Native sideline saved note');
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Native sideline saved note',
      );
      await tester.tap(find.byTooltip('Good move').last);
      await tester.pump();
      expect(
        tester
            .widget<PgnAnnotationPanel>(find.byType(PgnAnnotationPanel))
            .comment,
        'Native sideline saved note',
      );
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if ((await file.readAsString()).contains(
          'Native sideline saved note',
        )) {
          break;
        }
      }
      final edited = await file.readAsString();
      final game = parsePgnGame(splitPgnIntoGames(edited).first);
      final sideline = game.moves.children.first.children[1].data;
      expect(sideline.san, 'c5');
      expect(sideline.startingComments, ['Native variation introduction']);
      expect(sideline.comments, ['Native sideline saved note']);
      expect(sideline.nags, [1]);
      expect(edited, contains('Native editor saved note'));
      expect(edited, contains(other));

      await file.writeAsString('; Changed externally\n\n$other\n');
      await tester.tap(input);
      await tester.pumpAndSettle();
      await tester.enterText(input, 'Retain this conflicted edit');
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.textContaining('recovery copy').evaluate().isNotEmpty) break;
      }
      expect(await file.readAsString(), '; Changed externally\n\n$other\n');
      expect(find.textContaining('recovery copy'), findsWidgets);
      expect(
        tester.widget<TextField>(input).controller!.text,
        'Retain this conflicted edit',
      );
      final recovery = Directory(
        '${(await AppPaths.documentsDirectory()).path}/recovery',
      );
      var retained = false;
      await for (final entry in recovery.list()) {
        if (entry is File &&
            entry.path.endsWith('.pgn') &&
            (await entry.readAsString()).contains(
              'Retain this conflicted edit',
            )) {
          retained = true;
        }
      }
      expect(retained, isTrue);
      await tester.tap(find.byKey(const ValueKey('pgn-save-recovery')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inspect current file'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Changed externally'), findsWidgets);
      await tester.tap(find.widgetWithText(TextButton, 'Close').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reload and keep draft'));
      for (
        var i = 0;
        i < 100 && find.text('Restore retained draft').evaluate().isEmpty;
        i++
      ) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(find.text('Restore retained draft'), findsOneWidget);
      await tester.tap(find.text('Restore retained draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('pgn-save-recovery')));
      await tester.pumpAndSettle();
      Future<void> copyTo(String name) async {
        await tester.tap(find.byKey(const ValueKey('document-save-copy')));
        await tester.pumpAndSettle();
        await tester.enterText(
          find.byKey(const ValueKey('pgn-copy-name')),
          name,
        );
        await tester.tap(find.byKey(const ValueKey('pgn-copy-confirm')));
        await tester.pumpAndSettle();
      }

      await copyTo('games.pgn');
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
      expect(await file.readAsString(), '; Changed externally\n\n$other\n');
      await copyTo('Recovered viewer copy.pgn');
      final copy = File('${root.path}/Recovered viewer copy.pgn');
      for (var i = 0; i < 100 && !await copy.exists(); i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(
        await copy.readAsString(),
        contains('Retain this conflicted edit'),
      );
      expect(await file.readAsString(), '; Changed externally\n\n$other\n');
      await tester.tap(find.widgetWithText(TextButton, 'Close').last);
      await tester.pumpAndSettle();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
