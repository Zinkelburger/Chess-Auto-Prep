import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:chess_auto_prep/app/app_dependencies.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_creation.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_import_dialog.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_creation_screen.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:chess_auto_prep/widgets/pgn_import_dialog.dart';
import 'package:chess_auto_prep/features/repertoires/widgets/repertoire_list_body.dart';

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
    await pumpCatalogWidget(
      tester,
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                result = await showRepertoireImportDialog(
                  context,
                  existingNames: existingNames,
                  create: LegacyRepertoireCatalogRepository(
                    storage,
                    documents: LegacyPgnDocumentStore(storage),
                  ).create,
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
    await _settleImport(tester);
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
    await pumpCatalogWidget(tester, const SizedBox());
    pending.complete(_picked);
    await _settleImport(tester);
    expect(tester.takeException(), isNull);
    expect(storage.files, isEmpty);
  });

  testWidgets('write failure is visible and another import can succeed', (
    tester,
  ) async {
    storage.failWrite = true;
    await open(tester);
    expect(
      find.textContaining('The file may already be saved.'),
      findsOneWidget,
    );
    expect(result, isNull);
    storage.failWrite = false;
    await tester.tap(find.text('Open'));
    await _settleImport(tester);
    expect(result, isNotNull);
  });

  testWidgets(
    'library primary action goes straight to picker and prevents double imports',
    (tester) async {
      final pending = Completer<PickedPgnImport?>();
      var calls = 0;
      RepertoireMetadata? selected;
      await pumpCatalogWidget(
        tester,
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
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
      await _settleImport(tester);
      await tester.tap(find.text('Open PGN file…'));
      await tester.pump();
      expect(calls, 1);
      expect(find.byType(AlertDialog), findsNothing);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      pending.complete(_picked);
      await _settleImport(tester);
      expect(selected!.filePath, '/repertoires/Caro-Kann/Main.pgn');
      expect(find.text('Open PGN file…'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'secondary paste action validates moves and imports without naming',
    (tester) async {
      RepertoireMetadata? selected;
      await pumpCatalogWidget(
        tester,
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: RepertoireListBody(onSelected: (value) => selected = value),
          ),
        ),
      );
      await _settleImport(tester);
      await tester.tap(find.widgetWithText(TextButton, 'Paste PGN'));
      await _settleImport(tester);
      expect(find.byType(TextField), findsOneWidget);
      await tester.enterText(paste, '[Event "Empty"]\n\n*');
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      await _settleImport(tester);
      expect(find.text('Paste PGN with moves to train.'), findsOneWidget);
      await tester.enterText(paste, _pgn);
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Import'));
      // Disk completion precedes controller refresh and Navigator completion.
      // Wait for the user-visible handoff, rather than assuming the write's
      // completer also means that the route has returned its result.
      for (var i = 0; i < 50 && selected == null; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
        // Advance the route animation without waiting indefinitely on the
        // progress indicator while real async controller work is still pending.
        await tester.pump(const Duration(milliseconds: 100));
      }
      await _settleImport(tester);
      expect(selected, isNotNull);
      expect(selected!.filePath, '/repertoires/Pasted repertoire/Main.pgn');
      expect(selected!.gameCount, 2);
      expect(tester.takeException(), isNull);
    },
  );
  Future<void> openCreation(WidgetTester tester) async {
    await pumpCatalogWidget(
      tester,
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: RepertoireListBody(onSelected: (_) {})),
      ),
    );
    await _settleImport(tester);
    await tester.tap(find.text('Create new repertoire'));
    await _settleImport(tester);
    expect(find.byType(RepertoireCreationScreen), findsOneWidget);
  }

  testWidgets('create opens a fresh form and cancel returns to its caller', (
    tester,
  ) async {
    await openCreation(tester);
    await tester.enterText(
      find.byKey(const ValueKey('repertoire-create-name')),
      'Draft',
    );
    await tester.tap(find.text('Cancel'));
    await _settleImport(tester);
    expect(storage.files, isEmpty);
    expect(find.byType(RepertoireListBody), findsOneWidget);
    await tester.tap(find.text('Create new repertoire'));
    await _settleImport(tester);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).controller!.text,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('create imports named black lines and returns to the caller', (
    tester,
  ) async {
    RepertoireMetadata? selected;
    await pumpCatalogWidget(
      tester,
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RepertoireListBody(onSelected: (value) => selected = value),
        ),
      ),
    );
    await _settleImport(tester);
    await tester.tap(find.text('Create new repertoire'));
    await _settleImport(tester);
    await tester.enterText(
      find.byKey(const ValueKey('repertoire-create-name')),
      'My Caro',
    );
    await tester.tap(find.text('Black'));
    await tester.enterText(
      find.byKey(const ValueKey('repertoire-create-pgn')),
      _pgn,
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
    await _settleImport(tester);
    expect(find.byType(RepertoireCreationScreen), findsNothing);
    expect(selected!.filePath, '/repertoires/My Caro/Main.pgn');
    expect(selected!.gameCount, 2);
    expect(storage.files.values.single, contains('// Color: Black'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'creation validates moves and retains input after write failure',
    (tester) async {
      await openCreation(tester);
      await tester.enterText(
        find.byKey(const ValueKey('repertoire-create-name')),
        'My Caro',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      await _settleImport(tester);
      expect(
        find.text('Open or paste a PGN with moves to train.'),
        findsOneWidget,
      );
      expect(storage.files, isEmpty);
      await tester.enterText(
        find.byKey(const ValueKey('repertoire-create-pgn')),
        _pgn,
      );
      storage.failWrite = true;
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      await _settleImport(tester);
      expect(find.textContaining('The file may already be saved.'), findsOneWidget);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const ValueKey('repertoire-create-pgn')),
            )
            .controller!
            .text,
        _pgn,
      );
      storage.failWrite = false;
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      await _settleImport(tester);
      expect(storage.files, hasLength(1));
      expect(find.byType(RepertoireCreationScreen), findsNothing);
    },
  );

  testWidgets(
    'explicit empty creation stays in the library without loading a lesson',
    (tester) async {
      await openCreation(tester);
      await tester.enterText(
        find.byKey(const ValueKey('repertoire-create-name')),
        'Later',
      );
      await tester.tap(find.text('Empty repertoire'));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Create repertoire'));
      await _settleImport(tester);
      expect(storage.files.keys.single, '/repertoires/Later/Main.pgn');
      expect(find.byType(RepertoireListBody), findsOneWidget);
      expect(find.byType(RepertoireCreationScreen), findsNothing);
    },
  );
}

Future<void> pumpCatalogWidget(WidgetTester tester, Widget child) =>
    tester.pumpWidget(
      AppDependencies(
        documentStore: LegacyPgnDocumentStore(StorageFactory.instance),
        child: child,
      ),
    );

Future<void> _settleImport(WidgetTester tester) async {
  // Import preparation runs in a real isolate, outside the fake frame clock.
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 40));
  }
}
