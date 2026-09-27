import 'dart:io';

import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/widgets/training/trainer_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

Future<void> ready(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 120 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsWidgets);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'partial bulk save offers durable reload without replaying history',
    (tester) async {
      final root = await AppPaths.studiesDirectory(create: true);
      final source = File(
        p.join(
          root.path,
          'Bulk recovery ${DateTime.now().microsecondsSinceEpoch}.pgn',
        ),
      );
      const content = '[Event "Bulk recovery"]\n[Result "*"]\n\n1. e4 *\n';
      await source.writeAsString(content);
      final history = await AppPaths.documentsFile(
        'repertoire_review_history.csv',
      );
      final originalHistory = await history.exists()
          ? await history.readAsBytes()
          : null;
      final obstruction = Directory(history.path);
      addTearDown(() async {
        if (await obstruction.exists()) await obstruction.delete();
        if (originalHistory != null) {
          await history.writeAsBytes(originalHistory);
        }
        if (await source.exists()) await source.delete();
      });
      await pumpApp(tester);
      getAppState(tester).switchToStudyTraining(path: source.path);
      await ready(tester, find.byType(TrainerBrowser));
      final session = tester
          .widget<TrainerBrowser>(find.byType(TrainerBrowser))
          .session;
      final line = session.lines.single;
      if (await history.exists()) await history.delete();
      await obstruction.create();
      await tester.tap(find.text('Mark lines I know'));
      await tester.pump();
      await tester.tap(
        find
            .descendant(
              of: find.byType(TrainerBrowser),
              matching: find.text(line.name),
            )
            .last,
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      await ready(tester, find.text('Reload saved progress'));
      expect(find.textContaining('may be partly saved'), findsOneWidget);
      expect(find.text('Retry'), findsNothing);
      expect(session.progressNeedsReload, isTrue);
      expect(session.reviewMap[line.id]!.isNew, isTrue);
      // The schedule committed before history failed. The PGN is still original.
      final reviews = RepertoireReviewService();
      final saved = (await reviews.loadAll())
          .where((entry) => entry.repertoireId == source.path)
          .single;
      expect(saved.isNew, isFalse);
      expect(await source.readAsString(), content);
      await obstruction.delete();
      if (originalHistory != null) await history.writeAsBytes(originalHistory);
      await tester.tap(find.text('Reload saved progress'));
      await ready(tester, find.byType(TrainerBrowser));
      expect(session.progressNeedsReload, isFalse);
      expect(session.reviewMap[line.id]!.isNew, isFalse);
      expect(
        (await reviews.loadHistory()).where(
          (entry) => entry.repertoireId == source.path,
        ),
        isEmpty,
      );
      expect(await source.readAsString(), content);
      // A new explicit selection can now reset progress. This is one new write,
      // not a replay of the failed mark-known history.
      await tester.tap(find.text('Mark lines I know'));
      await tester.pump();
      await tester.tap(
        find
            .descendant(
              of: find.byType(TrainerBrowser),
              matching: find.text(line.name),
            )
            .last,
      );
      await tester.pump();
      await tester.tap(find.text('Save'));
      for (var i = 0; i < 120 && find.text('Save').evaluate().isNotEmpty; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(session.reviewMap[line.id]!.isNew, isTrue);
      final rows = (await reviews.loadHistory())
          .where((entry) => entry.repertoireId == source.path)
          .toList();
      expect(rows, hasLength(1));
      expect(rows.single.rating, isEmpty);
      expect(rows.single.sessionType, 'marked');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
