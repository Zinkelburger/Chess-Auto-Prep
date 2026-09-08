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
  final written = Completer<void>();

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
    if (!written.isCompleted) written.complete();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Storage storage;
  RepertoireCreationResult? result;
  final paste = find.byKey(const ValueKey('repertoire-import-pgn'));

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
    'file picker imports immediately with filename and inferred side',
    (tester) async {
      await open(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(result!.chapterPath, '/repertoires/Caro-Kann/Main.pgn');
      expect(result!.gameCount, 2);
      expect(storage.files.values.single, contains('// Color: Black'));
      expect(storage.files.values.single, contains('d6'));
    },
  );

  testWidgets('duplicate names get a unique suffix, ignoring case', (
    tester,
  ) async {
    await open(tester, existingNames: ['CARO-KANN', 'Caro-Kann (2)']);
    expect(result!.chapterPath, '/repertoires/Caro-Kann (3)/Main.pgn');
  });

  testWidgets('unsafe filenames become safe repertoire names', (tester) async {
    await open(
      tester,
      picker: () async => const PickedPgnImport(
        result: PgnImportResult(pgnContent: _pgn, gameCount: 1),
        suggestedName: 'Caro:Kann?',
      ),
    );
    expect(result!.chapterPath, '/repertoires/Caro_Kann_/Main.pgn');
  });

  testWidgets('cancel returns to the library without a form or writes', (
    tester,
  ) async {
    await open(tester, picker: () async => null);
    expect(result, isNull);
    expect(storage.files, isEmpty);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
  });

  testWidgets('read errors are visible and create nothing', (tester) async {
    await open(
      tester,
      picker: () async =>
          const PickedPgnImport(error: 'Could not read that file.'),
    );
    expect(find.text('Could not read that file.'), findsOneWidget);
    expect(storage.files, isEmpty);
  });

  testWidgets('headers without moves cannot create an empty repertoire', (
    tester,
  ) async {
    await open(
      tester,
      picker: () async => const PickedPgnImport(
        result: PgnImportResult(
          pgnContent: '[Event "Empty"]\n\n*',
          gameCount: 1,
        ),
      ),
    );
    expect(find.text('That PGN has no moves to train.'), findsOneWidget);
    expect(storage.files, isEmpty);
  });

  testWidgets('leaving during file selection ignores its late result', (
    tester,
  ) async {
    final pending = Completer<PickedPgnImport?>();
    await open(tester, picker: () => pending.future);
    await tester.pumpWidget(const SizedBox());
    pending.complete(_picked);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(storage.files, isEmpty);
  });

  testWidgets('write failure is visible and another import can succeed', (
    tester,
  ) async {
    storage.failWrite = true;
    await open(tester);
    expect(
      find.textContaining('Could not import the repertoire'),
      findsOneWidget,
    );
    expect(result, isNull);
    storage.failWrite = false;
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    expect(result, isNotNull);
  });

  testWidgets(
    'library primary action goes straight to picker and prevents double imports',
    (tester) async {
      final pending = Completer<PickedPgnImport?>();
      var calls = 0;
      RepertoireMetadata? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepertoireListBody(
              pickPgn: () {
                calls++;
                return pending.future;
              },
              onSelected: (value) => selected = value,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Import repertoire'));
      await tester.pump();
      expect(calls, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      pending.complete(_picked);
      await tester.pumpAndSettle();
      expect(selected!.filePath, '/repertoires/Caro-Kann/Main.pgn');
      expect(find.text('Import repertoire'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'secondary paste action validates moves and imports without naming',
    (tester) async {
      RepertoireMetadata? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepertoireListBody(onSelected: (value) => selected = value),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(TextButton, 'Paste PGN'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(paste, '[Event "Empty"]\n\n*');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await tester.pumpAndSettle();
      expect(find.text('Paste PGN with moves to train.'), findsOneWidget);
      await tester.enterText(paste, _pgn);
      await tester.pump();
      await tester.runAsync(() async {
        await tester.tap(find.widgetWithText(FilledButton, 'Import'));
        await storage.written.future.timeout(const Duration(seconds: 10));
      });
      await tester.pumpAndSettle();
      expect(selected!.filePath, '/repertoires/Pasted repertoire/Main.pgn');
      expect(selected!.gameCount, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
