/// Designating a book when you do not have one yet: the Add button offers
/// three starting points, not just "pick from what is already here".
library;

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chess_auto_prep/features/games/services/my_repertoire_settings.dart';
import 'package:chess_auto_prep/features/games/widgets/my_repertoires_panel.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';

/// Repertoires live in a temp directory; only what this panel calls is
/// implemented.
class _TempStorage implements StorageService {
  _TempStorage(this.root);

  final String root;

  /// Folders reported as existing repertoires.
  List<RepertoireMetadata> repertoires = const [];

  @override
  Future<List<RepertoireMetadata>> listRepertoires() async => repertoires;

  @override
  Future<List<RepertoireMetadata>> listChapters(String dir) async => const [];

  @override
  Future<String> repertoireDirectoryPath(String name) async =>
      p.join(root, name);

  @override
  String chapterFilePath(String repertoireDirPath, String chapterName) =>
      p.join(repertoireDirPath, '$chapterName.pgn');

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    File(path).parent.createSync(recursive: true);
    File(path).writeAsStringSync(content);
  }

  @override
  Future<String?> readFile(String path) async {
    final file = File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('${invocation.memberName} is not used here');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late _TempStorage storage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    dir = Directory.systemTemp.createTempSync('my_reps_panel_test');
    storage = _TempStorage(dir.path);
    StorageFactory.instanceForTest = storage;
    // The panel edits the singleton; clear it between cases.
    await MyRepertoireSettings.instance.ensureLoaded();
    await MyRepertoireSettings.instance.setPaths(white: true, paths: const []);
    await MyRepertoireSettings.instance.setPaths(white: false, paths: const []);
  });

  tearDown(() {
    StorageFactory.instanceForTest = null;
    dir.deleteSync(recursive: true);
  });

  Future<void> pumpPanel(WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: MyRepertoiresPanel()),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Press Add on the White section.
  Future<void> tapAddWhite(WidgetTester tester) async {
    await tester.tap(find.text('Add repertoire').first);
    await tester.pumpAndSettle();
  }

  testWidgets('with nothing in the app, Add still offers two ways in', (
    tester,
  ) async {
    await pumpPanel(tester);
    await tapAddWhite(tester);

    expect(find.text('Add White repertoire'), findsOneWidget);
    expect(find.text('Import a PGN file…'), findsOneWidget);
    expect(find.text('Start an empty one…'), findsOneWidget);
    // The old dead end — a snackbar saying there was nothing to add — is now a
    // disabled row that says why.
    expect(find.text('You have no repertoires in the app yet'), findsOneWidget);
    final tile = tester.widget<ListTile>(
      find.widgetWithText(ListTile, 'Choose one I already have'),
    );
    expect(tile.enabled, isFalse);
  });

  testWidgets('starting an empty one creates it and designates it', (
    tester,
  ) async {
    await pumpPanel(tester);
    await tapAddWhite(tester);

    await tester.tap(find.text('Start an empty one…'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byKey(const Key('repertoire-name-field')),
      'London System',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    // The folder exists, its Main chapter carries the colour of the section
    // the user pressed Add in…
    final chapter = File(p.join(dir.path, 'London System', 'Main.pgn'));
    expect(chapter.existsSync(), isTrue);
    expect(chapter.readAsStringSync(), contains('// Color: White'));
    // …and it is designated, without a second trip through a picker.
    expect(MyRepertoireSettings.instance.whitePaths, [
      p.join(dir.path, 'London System'),
    ]);
    expect(MyRepertoireSettings.instance.blackPaths, isEmpty);
    expect(find.text('London System'), findsOneWidget);
  });

  testWidgets('a name already in use is refused in the field', (tester) async {
    storage.repertoires = [
      RepertoireMetadata(
        filePath: p.join(dir.path, 'Taken'),
        name: 'Taken',
        lastModified: DateTime(2026, 8, 1),
      ),
    ];
    await pumpPanel(tester);
    await tapAddWhite(tester);

    await tester.tap(find.text('Start an empty one…'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('repertoire-name-field')),
      'taken',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(
      find.text('A repertoire named "taken" already exists'),
      findsOneWidget,
      reason: 'the form stays open and says so',
    );
    expect(MyRepertoireSettings.instance.whitePaths, isEmpty);
  });

  testWidgets('an existing repertoire can still just be picked', (
    tester,
  ) async {
    storage.repertoires = [
      RepertoireMetadata(
        filePath: p.join(dir.path, 'Caro-Kann'),
        name: 'Caro-Kann',
        lastModified: DateTime(2026, 8, 1),
      ),
    ];
    await pumpPanel(tester);
    // Designate it as Black — the second section's Add button.
    await tester.tap(find.text('Add repertoire').last);
    await tester.pumpAndSettle();
    expect(find.text('1 available'), findsOneWidget);

    await tester.tap(find.text('Choose one I already have'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Caro-Kann').last);
    await tester.pumpAndSettle();

    expect(MyRepertoireSettings.instance.blackPaths, [
      p.join(dir.path, 'Caro-Kann'),
    ]);
  });
}
