import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_import_dialog.dart';
import 'package:chess_auto_prep/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/repertoire_creation.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/widgets/pgn_import_dialog.dart';
import 'package:chess_auto_prep/widgets/repertoire_list_body.dart';

const _pgn = '[Event "Caro-Kann"]\n\n1. e4 c6 2. d4 d5 (2... d6) *';
const _picked = PickedPgnImport(
  result: PgnImportResult(
    pgnContent: _pgn,
    gameCount: 1,
    fileName: 'Caro-Kann.pgn',
  ),
  suggestedName: 'Caro-Kann',
  suggestedColor: 'Black',
);

class _Storage implements StorageService {
  final files = <String, String>{};
  bool failWrite = false;

  @override
  Future<List<RepertoireMetadata>> listRepertoires() async => [];
  @override
  Future<String> repertoireDirectoryPath(String name) async =>
      '/repertoires/$name';
  @override
  String chapterFilePath(String path, String name) => '$path/$name.pgn';
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (failWrite) throw StateError('Disk unavailable');
    files[path] = content;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Storage storage;
  RepertoireCreationResult? result;
  final name = find.byKey(const ValueKey('repertoire-import-name'));
  final paste = find.byKey(const ValueKey('repertoire-import-pgn'));
  final import = find.widgetWithText(FilledButton, 'Import');

  setUp(() {
    storage = _Storage();
    StorageFactory.instanceForTest = storage;
    result = null;
  });
  tearDown(() => StorageFactory.instanceForTest = null);

  Future<void> open(
    WidgetTester tester, {
    Future<PickedPgnImport?> Function()? picker,
    List<String> existingNames = const [],
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showRepertoireImportDialog(
                  context,
                  existingNames: existingNames,
                  pickPgn: picker ?? () async => _picked,
                );
              },
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'one form imports a file, its suggested name and selected color',
    (tester) async {
      await open(tester);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(paste, findsNothing);
      expect(tester.widget<FilledButton>(import).onPressed, isNull);
      await tester.tap(find.text('Choose file…'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.text('Caro-Kann.pgn'), findsOneWidget);
      expect(tester.widget<TextField>(name).controller!.text, 'Caro-Kann');
      expect(
        tester
            .widget<SegmentedButton<String>>(
              find.byType(SegmentedButton<String>),
            )
            .selected,
        {'Black'},
      );
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(result!.gameCount, 2); // Both branches survive the import.
      expect(storage.files.values.single, contains('// Color: Black'));
      expect(storage.files.values.single, contains('d6'));
    },
  );

  testWidgets('picker preserves an explicitly chosen name and color', (
    tester,
  ) async {
    await open(tester);
    await tester.enterText(name, 'My defense');
    await tester.tap(find.text('Black'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('White'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose file…'));
    await tester.pumpAndSettle();
    await tester.tap(import);
    await tester.pumpAndSettle();
    expect(result!.chapterPath, '/repertoires/My defense/Main.pgn');
    expect(storage.files.values.single, contains('// Color: White'));
  });

  testWidgets('trainer list offers import and pastes inside the same form', (
    tester,
  ) async {
    RepertoireMetadata? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: RepertoireListBody(onSelected: (value) => selected = value),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('New repertoire'), findsNothing);
    await tester.tap(find.text('Import repertoire'));
    await tester.pumpAndSettle();
    await tester.enterText(name, 'Pasted repertoire');
    await tester.tap(find.text('Paste PGN instead'));
    await tester.pumpAndSettle();
    await tester.enterText(paste, _pgn);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.tap(import);
    await tester.pumpAndSettle();
    expect(selected!.gameCount, 2);
    expect(selected!.filePath, '/repertoires/Pasted repertoire/Main.pgn');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'invalid names, duplicate names and PGN without moves stay in the form',
    (tester) async {
      await open(tester, existingNames: ['Caro-Kann']);
      await tester.tap(find.text('Choose file…'));
      await tester.pumpAndSettle();
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(find.textContaining('already exists'), findsOneWidget);
      await tester.enterText(name, '../bad');
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(find.textContaining('Names cannot contain'), findsOneWidget);
      await tester.enterText(name, 'Valid name');
      await tester.tap(find.text('Paste PGN instead'));
      await tester.pumpAndSettle();
      await tester.enterText(paste, '[Event "Empty"]\n\n*');
      await tester.pump();
      await tester.tap(import);
      await tester.pumpAndSettle();
      expect(find.textContaining('with moves to train'), findsOneWidget);
      expect(storage.files, isEmpty);
    },
  );

  testWidgets(
    'read errors are inline and cancel does not create a repertoire',
    (tester) async {
      await open(
        tester,
        picker: () async =>
            const PickedPgnImport(error: 'Could not read that file.'),
      );
      await tester.tap(find.text('Choose file…'));
      await tester.pumpAndSettle();
      expect(find.text('Could not read that file.'), findsOneWidget);
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(storage.files, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelling a replacement keeps the selected file', (
    tester,
  ) async {
    var calls = 0;
    await open(tester, picker: () async => calls++ == 0 ? _picked : null);
    await tester.tap(find.text('Choose file…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Caro-Kann.pgn'));
    await tester.pumpAndSettle();
    expect(find.text('Caro-Kann.pgn'), findsOneWidget);
    expect(tester.widget<FilledButton>(import).onPressed, isNotNull);
  });

  testWidgets('closing during a file read safely ignores the late result', (
    tester,
  ) async {
    final pending = Completer<PickedPgnImport?>();
    await open(tester, picker: () => pending.future);
    await tester.tap(find.text('Choose file…'));
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    pending.complete(_picked);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(storage.files, isEmpty);
  });

  testWidgets('write failure preserves form data and allows retry', (
    tester,
  ) async {
    storage.failWrite = true;
    await open(tester);
    await tester.tap(find.text('Choose file…'));
    await tester.pumpAndSettle();
    await tester.tap(import);
    await tester.pumpAndSettle();
    expect(find.textContaining('Your PGN is still here'), findsOneWidget);
    expect(find.text('Caro-Kann.pgn'), findsOneWidget);
    storage.failWrite = false;
    await tester.tap(import);
    await tester.pumpAndSettle();
    expect(result, isNotNull);
  });
}
