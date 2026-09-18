import 'package:provider/provider.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_factory.dart';
import 'package:chess_auto_prep/widgets/chapter_list_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _competingPgn = '[Event "Another writer"]\n\n1. d4 d5 *\n';

class _ControlledStorage extends IOStorageService {
  _ControlledStorage(Directory root)
    : super(documentsRoot: root, supportRoot: root, repertoiresRoot: root);

  bool competingCreate = false;
  final writeFinished = Completer<void>();
  final mutationStarted = Completer<void>();
  final allowMutation = Completer<void>();
  final mutationFinished = Completer<void>();

  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    if (competingCreate) File(path).writeAsStringSync(_competingPgn);
    try {
      await super.writeFile(
        path,
        content,
        createOnly: createOnly,
        expectedContent: expectedContent,
      );
    } finally {
      writeFinished.complete();
    }
  }

  Future<void> _mutate(Future<void> Function() mutation) async {
    mutationStarted.complete();
    await allowMutation.future;
    try {
      await mutation();
    } finally {
      mutationFinished.complete();
    }
  }

  @override
  Future<void> renameFile(String oldPath, String newPath) =>
      _mutate(() => super.renameFile(oldPath, newPath));

  @override
  Future<void> deleteFile(String path) => _mutate(() => super.deleteFile(path));
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 200 && !ready(); i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 16));
  }
  expect(ready(), isTrue);
}

void main() {
  late Directory root;
  late Directory folder;
  late _ControlledStorage storage;
  ChapterPick? selected;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chapter-mutation-');
    folder = Directory(p.join(root.path, 'Course'))..createSync();
    storage = _ControlledStorage(root);
    StorageFactory.instanceForTest = storage;
    selected = null;
  });

  tearDown(() {
    StorageFactory.instanceForTest = null;
    root.deleteSync(recursive: true);
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => Provider<RepertoireCatalogRepository>(
          create: (_) => LegacyRepertoireCatalogRepository(
            StorageFactory.instance,
            documents: LegacyPgnDocumentStore(StorageFactory.instance),
          ),
          child: child!,
        ),
        theme: AppTheme.dark(),
        home: Scaffold(
          body: ChapterListBody(
            repertoire: RepertoireMetadata(
              filePath: folder.path,
              name: 'Course',
              lastModified: DateTime(2026),
            ),
            onSelected: (value) => selected = value,
          ),
        ),
      ),
    );
    await _until(tester, () => find.text('Add chapter').evaluate().isNotEmpty);
  }

  testWidgets('competing chapter creation preserves the other writer', (
    tester,
  ) async {
    storage.competingCreate = true;
    await open(tester);
    await tester.tap(find.text('Add chapter'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Main');
    await tester.tap(find.text('Create'));
    await _until(tester, () => find.byType(SnackBar).evaluate().isNotEmpty);
    expect(
      File(p.join(folder.path, 'Main.pgn')).readAsStringSync(),
      _competingPgn,
    );
    expect(selected, isNull);
    expect(
      find.textContaining('Chapter creation needs verification:'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final equalText in [false, true]) {
    testWidgets(
      'delete confirmation preserves a ${equalText ? 'same-text' : 'changed'} replacement',
      (tester) async {
        final original = File(p.join(folder.path, 'Main.pgn'))
          ..writeAsStringSync(_competingPgn);
        await open(tester);
        await tester.tap(find.byTooltip('Delete chapter'));
        await tester.pumpAndSettle();
        expect(find.text('Delete chapter "Main"?'), findsOneWidget);

        // Keep the old inode alive, making even equal-text replacement a
        // distinct document while the user's confirmation is pending.
        final retained = original.renameSync(p.join(root.path, 'original.pgn'));
        final replacementText = equalText ? _competingPgn : '1. c4 e5 *\n';
        original.writeAsStringSync(replacementText);
        await tester.tap(find.text('Delete'));
        await _until(tester, () => storage.mutationStarted.isCompleted);
        storage.allowMutation.complete();
        await _until(tester, () => storage.mutationFinished.isCompleted);
        expect(tester.takeException(), isNull);
        expect(retained.readAsStringSync(), _competingPgn);
        expect(
          original.existsSync(),
          isTrue,
          reason:
              'confirmation for the old document cannot remove its replacement',
        );
        expect(original.readAsStringSync(), replacementText);
      },
    );
  }

  for (final rename in [true, false]) {
    testWidgets('${rename ? 'rename' : 'delete'} can finish after leaving', (
      tester,
    ) async {
      final original = File(p.join(folder.path, 'Main.pgn'))
        ..writeAsStringSync(_competingPgn);
      await open(tester);
      await tester.tap(
        find.byTooltip(rename ? 'Rename chapter' : 'Delete chapter'),
      );
      await tester.pumpAndSettle();
      if (rename) {
        await tester.enterText(find.byType(TextField).last, 'Renamed');
      }
      await tester.tap(find.text(rename ? 'Rename' : 'Delete'));
      await _until(tester, () => storage.mutationStarted.isCompleted);
      await tester.pumpWidget(const SizedBox());
      final messages = <String?>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => messages.add(message);
      try {
        storage.allowMutation.complete();
        await _until(tester, () => storage.mutationFinished.isCompleted);
        await tester.pump();
        expect(original.existsSync(), isFalse);
        if (rename) {
          expect(
            File(p.join(folder.path, 'Renamed.pgn')).readAsStringSync(),
            _competingPgn,
          );
        }
        expect(
          messages.where((message) => message?.contains('failed:') ?? false),
          isEmpty,
        );
        expect(tester.takeException(), isNull);
      } finally {
        debugPrint = previousPrint;
      }
    });
  }
}
