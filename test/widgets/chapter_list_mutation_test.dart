import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/documents/repositories/pgn_document_store.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';
import 'package:provider/provider.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/legacy_pgn_document_store.dart';
import 'dart:async';
import 'package:document_file_io/document_file_io.dart';
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

class _ControlledDocuments extends NativePgnDocumentStore {
  bool hold = false;
  final entered = Completer<void>();
  final allow = Completer<void>();
  final finished = Completer<void>();
  int calls = 0;
  @override
  Future<PgnQuarantineResult> quarantine(
    PgnSnapshot baseline, {
    String? allowedRoot,
  }) async {
    calls++;
    if (!entered.isCompleted) entered.complete();
    if (hold) await allow.future;
    try {
      return await super.quarantine(baseline, allowedRoot: allowedRoot);
    } finally {
      if (!finished.isCompleted) finished.complete();
    }
  }
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
  late _ControlledDocuments documents;
  ChapterPick? selected;

  setUp(() {
    root = Directory.systemTemp.createTempSync('chapter-mutation-');
    folder = Directory(p.join(root.path, 'Course'))..createSync();
    storage = _ControlledStorage(root);
    documents = _ControlledDocuments();
    StorageFactory.instanceForTest = storage;
    selected = null;
  });

  tearDown(() {
    StorageFactory.instanceForTest = null;
    root.deleteSync(recursive: true);
  });

  Future<void> open(
    WidgetTester tester, {
    PgnDocumentStore? documentStore,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        builder: (context, child) => Provider<RepertoireCatalogRepository>(
          create: (_) => LegacyRepertoireCatalogRepository(
            StorageFactory.instance,
            documents: documentStore ?? documents,
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
    await open(tester, documentStore: LegacyPgnDocumentStore(storage));
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

  testWidgets(
    'uncertain native deletion shows selectable recovery and refreshes list without selecting',
    (tester) async {
      final original = File(p.join(folder.path, 'Main.pgn'))
        ..writeAsStringSync(_competingPgn);
      var postMoveFlushes = 0;
      final native = NativePgnDocumentStore(
        guardOperation: storage.guardDocumentOperation,
        flushDirectory: (path) async {
          if (path == folder.path) {
            postMoveFlushes++;
            throw const FileSystemException('directory acknowledgement lost');
          }
          await syncDirectory(path);
        },
      );
      await open(tester, documentStore: native);
      await tester.tap(find.byTooltip('Delete chapter'));
      await _until(
        tester,
        () => find.text('Delete chapter "Main"?').evaluate().isNotEmpty,
      );
      await tester.tap(find.text('Delete'));
      await _until(
        tester,
        () => find.text('Review chapter deletion').evaluate().isNotEmpty,
      );
      expect(original.existsSync(), isFalse);
      expect(postMoveFlushes, 1);
      expect(selected, isNull);
      final evidence = tester
          .widget<SelectableText>(find.byType(SelectableText))
          .data!;
      expect(evidence, contains(original.path));
      expect(evidence, contains('.cap-pgn-history'));
      expect(find.text('Retry'), findsNothing);
      await tester.tap(find.text('Close'));
      await _until(tester, () => find.text('Main').evaluate().isEmpty);
      expect(find.byTooltip('Delete chapter'), findsNothing);
      expect(postMoveFlushes, 1);
    },
  );

  testWidgets('cancel leaves chapter and sends no deletion', (tester) async {
    final original = File(p.join(folder.path, 'Main.pgn'))
      ..writeAsStringSync(_competingPgn);
    await open(tester);
    await tester.tap(find.byTooltip('Delete chapter'));
    await _until(
      tester,
      () => find.text('Delete chapter "Main"?').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(documents.calls, 0);
    expect(original.readAsStringSync(), _competingPgn);
  });

  for (final equalText in [false, true]) {
    testWidgets(
      'delete confirmation preserves a ${equalText ? 'same-text' : 'changed'} replacement',
      (tester) async {
        final original = File(p.join(folder.path, 'Main.pgn'))
          ..writeAsStringSync(_competingPgn);
        await open(tester);
        await tester.tap(find.byTooltip('Delete chapter'));
        await _until(
          tester,
          () => find.text('Delete chapter "Main"?').evaluate().isNotEmpty,
        );
        expect(find.text('Delete chapter "Main"?'), findsOneWidget);

        // Keep the old inode alive, making even equal-text replacement a
        // distinct document while the user's confirmation is pending.
        final retained = original.renameSync(p.join(root.path, 'original.pgn'));
        final replacementText = equalText ? _competingPgn : '1. c4 e5 *\n';
        original.writeAsStringSync(replacementText);
        await tester.tap(find.text('Delete'));
        await _until(tester, () => documents.finished.isCompleted);
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
      documents.hold = !rename;
      await open(tester);
      await tester.tap(
        find.byTooltip(rename ? 'Rename chapter' : 'Delete chapter'),
      );
      await _until(
        tester,
        () => find.byType(AlertDialog).evaluate().isNotEmpty,
      );
      if (rename) {
        await tester.enterText(find.byType(TextField).last, 'Renamed');
      }
      await tester.tap(find.text(rename ? 'Rename' : 'Delete'));
      await _until(
        tester,
        () => rename
            ? storage.mutationStarted.isCompleted
            : documents.entered.isCompleted,
      );
      await tester.pumpWidget(const SizedBox());
      final messages = <String?>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => messages.add(message);
      try {
        if (rename) {
          storage.allowMutation.complete();
        } else {
          documents.allow.complete();
        }
        await _until(
          tester,
          () => rename
              ? storage.mutationFinished.isCompleted
              : documents.finished.isCompleted,
        );
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
