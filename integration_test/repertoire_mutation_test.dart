/// Native desktop journey: the production import interaction keeps a failed
/// draft, retries against the newer chapter, and survives closing/reopening.
library;

import 'dart:io';

import 'package:chess_auto_prep/core/app_state.dart';
import 'package:chess_auto_prep/services/storage/app_paths.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/widgets/interactive_pgn_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;

import 'helpers/board_helpers.dart';
import 'helpers/tactics_helpers.dart';

const _original =
    '// Color: White\n\n[Event "Safety baseline"]\n[Result "*"]\n\n1. e4 e5 *\n';
const _import = '[Event "Imported safely"]\n[Result "*"]\n\n1. d4 d5 2. c4 *';

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  if (finder.evaluate().isEmpty) {
    final visibleText = find
        .byType(Text)
        .evaluate()
        .map((element) => (element.widget as Text).data ?? '')
        .join(' | ');
    debugPrint('Visible text at failed desktop gate: $visibleText');
  }
  expect(finder, findsWidgets);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'DATA-01: import conflict keeps draft, retry and reopen preserve both writers',
    (tester) async {
      // agent_job owns the disposable profile. Refuse an accidental native run
      // outside that runner rather than booting against the normal accounts.
      expect(Platform.environment['XDG_DATA_HOME'], contains('/profile/'));
      final root = await AppPaths.repertoiresDirectory(create: true);
      final folder = Directory(p.join(root.path, 'Renewal safety'));
      await folder.create(recursive: true);
      final file = File(p.join(folder.path, 'Main.pgn'));
      await file.writeAsString(_original);
      final storage = StorageFactory.instance;
      addTearDown(() {
        StorageFactory.instanceForTest = storage;
      });
      await pumpApp(tester);
      getAppState(tester).handOff(OpenBuilder(repertoirePath: file.path));
      await _waitFor(tester, find.byType(InteractivePgnEditor));
      await tester.tap(find.text('Actions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import PGN…'));
      await tester.pumpAndSettle();
      final draft = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      );
      await tester.enterText(draft, _import);
      await tester.pump();
      StorageFactory.instanceForTest = _InterleavingStorage(file.path);
      await tester.tap(find.widgetWithText(FilledButton, 'Add to repertoire'));
      await _waitFor(
        tester,
        find.text('Chapter changed. PGN kept; retry to add to latest.'),
      );
      expect(tester.widget<TextField>(draft).controller!.text, _import);
      expect(await file.readAsString(), contains('{External annotation}'));
      expect(await file.readAsString(), isNot(contains('Imported safely')));
      StorageFactory.instanceForTest = storage;
      await tester.tap(find.widgetWithText(FilledButton, 'Add to repertoire'));
      await _waitFor(tester, find.text('Imported safely'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final committed = await file.readAsString();
      expect(committed, contains('Safety baseline'));
      expect(committed, contains('External annotation'));
      expect(committed, contains('Imported safely'));
      expect(RegExp('Imported safely').allMatches(committed), hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
      await pumpApp(tester);
      getAppState(tester).handOff(OpenBuilder(repertoirePath: file.path));
      await _waitFor(tester, find.text('Imported safely'));
      expect(await file.readAsString(), committed);
      expect(tester.takeException(), isNull);
    },
  );
}

class _InterleavingStorage extends IOStorageService {
  _InterleavingStorage(this.destination);
  final String destination;

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (path == destination) {
      await File(
        path,
      ).writeAsString(_original.replaceFirst('e5', 'e5 {External annotation}'));
    }
    await super.writeFile(
      path,
      content,
      createOnly: createOnly,
      expectedContent: expectedContent,
    );
  }
}
