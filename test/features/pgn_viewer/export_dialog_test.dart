// Export games…: the name asked for, `.pgn` added only when it is missing,
// and what the user is told when there is nothing to export or the export
// fails.
import 'dart:io';

import 'package:chess_auto_prep/features/pgn_viewer/export_dialog.dart';
import 'package:chess_auto_prep/storage/pgn_export.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/viewer_fixture.dart';

void main() {
  late Directory folder;
  late ViewerFixture fixture;
  late List<String?> said;
  late bool finished;

  setUp(() {
    folder = Directory.systemTemp.createTempSync('viewer-export-dialog-');
    said = [];
    finished = false;
  });
  tearDown(() => folder.deleteSync(recursive: true));

  Future<void> show(WidgetTester tester, {bool open = true}) async {
    fixture = await viewerOver(
      threeGameFile,
      exporter: PgnExport(pickDirectory: () async => folder.path),
    );
    addTearDown(fixture.dispose);
    if (open) await fixture.open();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => exportViewerPgn(
                context,
                fixture.viewer,
                said.add,
              ).then((_) => finished = true),
              child: const Text('Export'),
            ),
          ),
        ),
      ),
    );
  }

  /// Types [name] into the dialog and confirms it, letting the real write
  /// reach the disk.
  Future<void> export(WidgetTester tester, String name) async {
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Export games'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'PGN file name'),
      name,
    );
    await tester.tap(find.text('Choose folder'));
    await tester.pumpAndSettle();
    // The export's disk work answers on the real clock, a pump at a time.
    for (var i = 0; i < 300 && !finished; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(finished, isTrue);
  }

  List<String> written() =>
      [for (final file in folder.listSync()) p.basename(file.path)]..sort();

  testWidgets('the name is given `.pgn` when it lacks one, and the games '
      'shown are written', (tester) async {
    await show(tester);
    final text = fixture.viewer.exportText();
    await export(tester, 'club');
    expect(written(), ['club.pgn']);
    expect(
      await tester.runAsync(
        () => File(p.join(folder.path, 'club.pgn')).readAsString(),
      ),
      text,
    );
    expect(said, isEmpty);
  });

  testWidgets('a name that already ends in .pgn, in any case, is kept', (
    tester,
  ) async {
    await show(tester);
    await export(tester, 'Club.PGN');
    expect(written(), ['Club.PGN']);
    expect(said, isEmpty);
  });

  testWidgets('a failed export says why', (tester) async {
    await show(tester);
    File(p.join(folder.path, 'club.pgn')).writeAsStringSync('kept');
    await export(tester, 'club');
    expect(said, ['That file already exists. Choose another name.']);
    expect(File(p.join(folder.path, 'club.pgn')).readAsStringSync(), 'kept');
  });

  testWidgets('backing out of the name writes nothing and says nothing', (
    tester,
  ) async {
    await show(tester);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(written(), isEmpty);
    expect(said, isEmpty);
  });

  testWidgets('with no games to export it says what to do and asks for no '
      'name', (tester) async {
    await show(tester, open: false);
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(find.text('Export games'), findsNothing);
    expect(said, [
      'Wait for filtering to finish and select at least one game.',
    ]);
  });
}
