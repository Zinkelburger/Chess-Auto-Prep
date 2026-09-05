/// Designating a book is one click per way in: Import PGN… goes straight to
/// the file picker and designates what it imports; Add existing is a menu of
/// what is already in the app, with "New empty repertoire…" at its foot.
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
import 'package:chess_auto_prep/widgets/pgn_import_dialog.dart';

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

const _caroKannPgn =
    '[Event "Caro-Kann"]\n[Result "*"]\n\n1. e4 c6 2. d4 d5 *\n\n'
    '[Event "Advance"]\n[Result "*"]\n\n1. e4 c6 2. d4 d5 3. e5 Bf5 *\n';

PickedPgnImport _pickedCaroKann({String? suggestedColor = 'Black'}) =>
    PickedPgnImport(
      result: const PgnImportResult(
        pgnContent: _caroKannPgn,
        gameCount: 2,
        fileName: 'Caro-Kann.pgn',
      ),
      fileName: 'Caro-Kann.pgn',
      suggestedName: 'Caro-Kann',
      suggestedColor: suggestedColor,
    );

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

  Future<void> pumpPanel(
    WidgetTester tester, {
    Future<PickedPgnImport?> Function()? pickPgn,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MyRepertoiresPanel(pickPgn: pickPgn ?? pickPgnImport),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// Open the Add existing menu of one section (first = White, last = Black).
  Future<void> openAddExisting(WidgetTester tester, {bool white = true}) async {
    final button = find.widgetWithText(OutlinedButton, 'Add existing');
    await tester.tap(white ? button.first : button.last);
    await tester.pumpAndSettle();
  }

  testWidgets('both ways in are on the panel itself, per colour', (
    tester,
  ) async {
    await pumpPanel(tester);

    expect(find.text('Import PGN…'), findsNWidgets(2));
    expect(find.text('Add existing'), findsNWidgets(2));
    // No chooser dialog in between: the menu opens right here, and with
    // nothing in the app it says so instead of dead-ending.
    await openAddExisting(tester);
    expect(find.text('No other repertoires in the app'), findsOneWidget);
    expect(find.text('New empty repertoire…'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('a new empty repertoire is created and designated', (
    tester,
  ) async {
    await pumpPanel(tester);
    await openAddExisting(tester);
    await tester.tap(find.text('New empty repertoire…'));
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
    await openAddExisting(tester);
    await tester.tap(find.text('New empty repertoire…'));
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

  testWidgets('an existing repertoire is one menu click', (tester) async {
    storage.repertoires = [
      RepertoireMetadata(
        filePath: p.join(dir.path, 'Caro-Kann'),
        name: 'Caro-Kann',
        lastModified: DateTime(2026, 8, 1),
      ),
    ];
    await pumpPanel(tester);
    // Designate it as Black — the second section's menu.
    await openAddExisting(tester, white: false);
    await tester.tap(find.text('Caro-Kann').last);
    await tester.pumpAndSettle();

    expect(MyRepertoireSettings.instance.blackPaths, [
      p.join(dir.path, 'Caro-Kann'),
    ]);
    expect(MyRepertoireSettings.instance.whitePaths, isEmpty);
    // Now designated for Black, it is no longer offered there.
    await openAddExisting(tester, white: false);
    expect(find.text('No other repertoires in the app'), findsOneWidget);
  });

  testWidgets(
    'importing a PGN designates it under the file name, no questions',
    (tester) async {
      var picks = 0;
      await pumpPanel(
        tester,
        pickPgn: () async {
          picks++;
          return _pickedCaroKann();
        },
      );

      // Black's Import button; the file reads as a Black book, so nothing to
      // confirm and nothing to name.
      await tester.tap(find.widgetWithText(FilledButton, 'Import PGN…').last);
      await tester.pumpAndSettle();

      expect(picks, 1);
      expect(find.byKey(const Key('repertoire-name-field')), findsNothing);
      expect(find.byType(AlertDialog), findsNothing);
      final chapter = File(p.join(dir.path, 'Caro-Kann', 'Caro-Kann.pgn'));
      expect(
        chapter.existsSync(),
        isTrue,
        reason: 'chapter named after the file',
      );
      final content = chapter.readAsStringSync();
      expect(content, contains('// Color: Black'));
      expect(content, contains('3. e5 Bf5'));
      expect(MyRepertoireSettings.instance.blackPaths, [
        p.join(dir.path, 'Caro-Kann'),
      ]);
      expect(MyRepertoireSettings.instance.whitePaths, isEmpty);
      expect(
        find.text('Caro-Kann is now your Black book — 2 lines imported.'),
        findsOneWidget,
      );
    },
  );

  testWidgets('a file whose name is already taken gets a numbered name', (
    tester,
  ) async {
    storage.repertoires = [
      RepertoireMetadata(
        filePath: p.join(dir.path, 'Caro-Kann'),
        name: 'Caro-Kann',
        lastModified: DateTime(2026, 8, 1),
      ),
    ];
    await pumpPanel(tester, pickPgn: () async => _pickedCaroKann());
    await tester.tap(find.widgetWithText(FilledButton, 'Import PGN…').last);
    await tester.pumpAndSettle();

    expect(
      File(p.join(dir.path, 'Caro-Kann 2', 'Caro-Kann 2.pgn')).existsSync(),
      isTrue,
    );
    expect(MyRepertoireSettings.instance.blackPaths, [
      p.join(dir.path, 'Caro-Kann 2'),
    ]);
  });

  testWidgets('a file that reads as the other colour asks once', (
    tester,
  ) async {
    await pumpPanel(
      tester,
      pickPgn: () async => _pickedCaroKann(suggestedColor: 'White'),
    );
    // Pressed under Black, but the file's move tree says White.
    await tester.tap(find.widgetWithText(FilledButton, 'Import PGN…').last);
    await tester.pumpAndSettle();
    expect(find.text('This looks like a White repertoire'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(MyRepertoireSettings.instance.blackPaths, isEmpty);
    expect(Directory(p.join(dir.path, 'Caro-Kann')).existsSync(), isFalse);

    await tester.tap(find.widgetWithText(FilledButton, 'Import PGN…').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add as Black'));
    await tester.pumpAndSettle();
    expect(MyRepertoireSettings.instance.blackPaths, [
      p.join(dir.path, 'Caro-Kann'),
    ]);
    expect(
      File(p.join(dir.path, 'Caro-Kann', 'Caro-Kann.pgn')).readAsStringSync(),
      contains('// Color: Black'),
      reason: 'the section pressed wins once confirmed',
    );
  });

  testWidgets('cancelling the picker or a bad file changes nothing', (
    tester,
  ) async {
    PickedPgnImport? next;
    await pumpPanel(tester, pickPgn: () async => next);

    await tester.tap(find.widgetWithText(FilledButton, 'Import PGN…').first);
    await tester.pumpAndSettle();
    expect(MyRepertoireSettings.instance.whitePaths, isEmpty);

    next = const PickedPgnImport(error: 'No lines found in empty.pgn.');
    await tester.tap(find.widgetWithText(FilledButton, 'Import PGN…').first);
    await tester.pumpAndSettle();
    expect(find.text('No lines found in empty.pgn.'), findsOneWidget);
    expect(MyRepertoireSettings.instance.whitePaths, isEmpty);
    expect(dir.listSync(), isEmpty);
  });
}
