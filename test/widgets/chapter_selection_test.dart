import 'dart:async';
import 'package:chess_auto_prep/l10n/generated/app_localizations.dart';

import 'package:chess_auto_prep/design_system/theme/app_theme.dart';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'package:chess_auto_prep/features/repertoire/widgets/repertoire_toolbar.dart';
import 'package:chess_auto_prep/features/repertoires/models/repertoire_metadata.dart';
import 'package:chess_auto_prep/features/repertoires/repositories/repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/features/training/models/chapter_layout.dart';
import 'package:chess_auto_prep/widgets/chapter_list_body.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:path/path.dart' as p;

RepertoireMetadata _entry(String path) => RepertoireMetadata(
  filePath: path,
  name: p.basename(path),
  lastModified: DateTime(2026),
);

class _Catalog implements RepertoireCatalogRepository {
  Future<List<RepertoireMetadata>> Function(String) read = (_) async => [];
  Future<List<ChapterSummary>> Function(String) sections = (_) async => [];
  Future<PgnWriteResult> Function()? createResult;
  Future<PgnOpenResult> Function(String)? capture;
  Future<PgnQuarantineResult> Function(PgnSnapshot)? remove;
  int deletions = 0;
  @override
  Future<PgnOpenResult> prepareChapterDeletion(String path) => capture!(path);
  @override
  Future<PgnQuarantineResult> deleteChapter(PgnSnapshot before) {
    deletions++;
    return remove!(before);
  }

  int reads = 0;
  int writes = 0;
  @override
  Future<List<RepertoireMetadata>> listChapters(String folderPath) {
    reads++;
    return read(folderPath);
  }

  @override
  Future<List<ChapterSummary>> chapterSections(String path) => sections(path);
  @override
  Future<PgnWriteResult> createChapter({
    required String folderPath,
    required String name,
    bool? isWhite,
  }) {
    writes++;
    return createResult!();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _Catalog catalog;
  RepertoireMetadata? selected;
  var currentGeneration = 1;
  setUp(() {
    catalog = _Catalog();
    selected = null;
    currentGeneration = 1;
  });

  Future<void> breadcrumb(
    WidgetTester tester, {
    int generation = 1,
    bool enabled = true,
  }) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.dark(),
      home: Scaffold(
        body: RepertoireBreadcrumbTitle(
          key: ValueKey(generation),
          chapter: _entry('/A/Main'),
          catalog: catalog,
          enabled: enabled,
          isCurrent: () => currentGeneration == generation,
          onSelectChapter: (value) => selected = value,
        ),
      ),
    ),
  );

  Future<void> picker(WidgetTester tester, String folder) => tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      theme: AppTheme.dark(),
      home: Provider<RepertoireCatalogRepository>.value(
        value: catalog,
        child: Scaffold(
          body: ChapterListBody(
            repertoire: _entry(folder),
            onSelected: (value) => selected = value.chapter,
          ),
        ),
      ),
    ),
  );

  const before = PgnSnapshot(
    path: '/A/Main.pgn',
    content: '1. e4 *',
    revision: PgnRevision(
      documentId: '/A/Main.pgn',
      nativeIdentity: 'original',
      sha256: 'old',
    ),
  );
  testWidgets('picker rejects delayed deletion capture after folder A B A', (
    tester,
  ) async {
    final capture = Completer<PgnOpenResult>();
    catalog.read = (folder) async => [_entry('$folder/Main.pgn')];
    catalog.capture = (_) => capture.future;
    await picker(tester, '/A');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete chapter'));
    await picker(tester, '/B');
    await picker(tester, '/A');
    capture.complete(const PgnOpened(before));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(catalog.deletions, 0);
    expect(selected, isNull);
  });

  testWidgets('picker confirmation rejects folder A B A before mutation', (
    tester,
  ) async {
    catalog.read = (folder) async => [_entry('$folder/Main.pgn')];
    catalog.capture = (_) async => const PgnOpened(before);
    await picker(tester, '/A');
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Delete chapter'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await picker(tester, '/B');
    await picker(tester, '/A');
    await tester.tap(find.text('Delete'));
    await tester.pumpAndSettle();
    expect(catalog.deletions, 0);
    expect(selected, isNull);
  });

  for (final returnToA in [false, true]) {
    testWidgets(
      'picker keeps admitted uncertainty evidence after folder ${returnToA ? "A B A" : "A B"}',
      (tester) async {
        final result = Completer<PgnQuarantineResult>();
        catalog.read = (folder) async => [_entry('$folder/Main.pgn')];
        catalog.capture = (_) async => const PgnOpened(before);
        catalog.remove = (_) => result.future;
        await picker(tester, '/A');
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('Delete chapter'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Delete'));
        await tester.pumpAndSettle();
        expect(catalog.deletions, 1);
        await picker(tester, '/B');
        if (returnToA) await picker(tester, '/A');
        await tester.pumpAndSettle();
        final reads = catalog.reads;
        result.complete(
          PgnQuarantineUncertain(
            error: StateError('lost acknowledgement'),
            before: before,
            quarantinePath: '/A/.cap-pgn-history/retained.pgn',
            recoveryPath: '/A/.cap-pgn-history/raw.pgn',
            observedSource: null,
            observedQuarantine: null,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Review chapter deletion'), findsOneWidget);
        final text = tester
            .widget<SelectableText>(find.byType(SelectableText))
            .data!;
        expect(text, contains('/A/Main.pgn'));
        expect(text, contains('/A/.cap-pgn-history/retained.pgn'));
        expect(text, contains('/A/.cap-pgn-history/raw.pgn'));
        expect(text, isNot(contains('/B')));
        expect(
          catalog.reads,
          reads,
          reason: 'Old completion cannot reload the new view',
        );
        expect(catalog.deletions, 1);
        expect(selected, isNull);
      },
    );
  }

  testWidgets(
    'breadcrumb loads on demand and rejects duplicate opening clicks',
    (tester) async {
      final read = Completer<List<RepertoireMetadata>>();
      catalog.read = (_) => read.future;
      await breadcrumb(tester);
      expect(catalog.reads, 0);
      await tester.tap(find.byTooltip('Switch chapter'));
      await tester.tap(find.byTooltip('Switch chapter'));
      expect(catalog.reads, 1);
      read.complete([_entry('/A/Other')]);
      await tester.pumpAndSettle();
      expect(find.byType(Dialog), findsOneWidget);
      await tester.tap(find.text('Other'));
      await tester.pumpAndSettle();
      expect(selected?.filePath, '/A/Other');
    },
  );

  testWidgets('late breadcrumb read cannot open a dialog after A B A', (
    tester,
  ) async {
    final old = Completer<List<RepertoireMetadata>>();
    catalog.read = (_) => old.future;
    await breadcrumb(tester);
    await tester.tap(find.byTooltip('Switch chapter'));
    await breadcrumb(tester, generation: 2);
    await breadcrumb(tester, generation: 3);
    old.complete([_entry('/A/Old')]);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(selected, isNull);
  });

  testWidgets('changed session rejects lookup before a widget rebuild', (
    tester,
  ) async {
    final read = Completer<List<RepertoireMetadata>>();
    catalog.read = (_) => read.future;
    await breadcrumb(tester);
    await tester.tap(find.byTooltip('Switch chapter'));
    currentGeneration = 2;
    read.complete([_entry('/A/Old')]);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
    expect(selected, isNull);
  });

  testWidgets('generation locking during lookup prevents opening', (
    tester,
  ) async {
    final read = Completer<List<RepertoireMetadata>>();
    catalog.read = (_) => read.future;
    await breadcrumb(tester);
    await tester.tap(find.byTooltip('Switch chapter'));
    await breadcrumb(tester, enabled: false);
    read.complete([_entry('/A/Other')]);
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets(
    'old breadcrumb dialog selection cannot target a replacement session',
    (tester) async {
      catalog.read = (_) async => [_entry('/A/Other')];
      await breadcrumb(tester);
      await tester.tap(find.byTooltip('Switch chapter'));
      await tester.pumpAndSettle();
      await breadcrumb(tester, generation: 2);
      await tester.tap(find.text('Other'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
    },
  );

  testWidgets('breadcrumb read failure is visible and retryable', (
    tester,
  ) async {
    catalog.read = (_) async => throw StateError('unavailable');
    await breadcrumb(tester);
    await tester.tap(find.byTooltip('Switch chapter'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Could not load chapters.'), findsOneWidget);
    catalog.read = (_) async => [_entry('/A/Other')];
    await tester.tap(find.byTooltip('Switch chapter'));
    await tester.pumpAndSettle();
    expect(find.text('Other'), findsOneWidget);
    expect(catalog.reads, 2);
  });

  testWidgets('picker rejects a stale folder listing after A B A', (
    tester,
  ) async {
    final reads = <Completer<List<RepertoireMetadata>>>[];
    catalog.read = (_) {
      final read = Completer<List<RepertoireMetadata>>();
      reads.add(read);
      return read.future;
    };
    await picker(tester, '/A');
    await picker(tester, '/B');
    await picker(tester, '/A');
    reads.last.complete([_entry('/A/Current')]);
    await tester.pumpAndSettle();
    reads.first.complete([_entry('/A/Obsolete')]);
    reads[1].complete([_entry('/B/Other')]);
    await tester.pumpAndSettle();
    expect(find.text('Current'), findsOneWidget);
    expect(find.text('Obsolete'), findsNothing);
    expect(find.text('Other'), findsNothing);
  });

  testWidgets(
    'course sections enrich visible files progressively and reject old reads',
    (tester) async {
      final old = Completer<List<ChapterSummary>>();
      catalog.read = (folder) async => [_entry('$folder/Course')];
      catalog.sections = (path) => path.startsWith('/A')
          ? old.future
          : Future.value([
              const ChapterSummary(name: 'New section', lineCount: 2),
            ]);
      await picker(tester, '/A');
      await tester.pumpAndSettle();
      expect(find.text('Course'), findsOneWidget);
      expect(find.text('Old section'), findsNothing);
      await picker(tester, '/B');
      await tester.pumpAndSettle();
      old.complete([const ChapterSummary(name: 'Old section', lineCount: 2)]);
      await tester.pumpAndSettle();
      expect(find.text('New section'), findsOneWidget);
      expect(find.text('Old section'), findsNothing);
    },
  );

  for (final uncertain in [false, true]) {
    testWidgets(
      '${uncertain ? 'uncertain' : 'failed'} creation retains picker without selecting or retrying',
      (tester) async {
        catalog.createResult = () async => uncertain
            ? PgnWriteUncertain(
                error: StateError('lost acknowledgement'),
                before: null,
                observed: null,
                recoveryPath: '/A/recovery',
              )
            : PgnWriteFailed(StateError('denied'));
        await picker(tester, '/A');
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add chapter'));
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'New');
        await tester.tap(find.text('Create'));
        await tester.pumpAndSettle();
        expect(selected, isNull);
        expect(catalog.writes, 1);
        expect(
          find.textContaining(
            uncertain
                ? 'Chapter creation needs verification: /A/New.pgn'
                : 'Could not create chapter.',
          ),
          findsOneWidget,
        );
        if (uncertain) {
          expect(find.textContaining('/A/recovery'), findsOneWidget);
        }
        await tester.pump(const Duration(seconds: 1));
        expect(catalog.writes, 1);
      },
    );
  }

  testWidgets(
    'acknowledged create finishing after folder A B A does not select',
    (tester) async {
      final write = Completer<PgnWriteResult>();
      catalog.createResult = () => write.future;
      await picker(tester, '/A');
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add chapter'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'New');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(catalog.writes, 1);
      await picker(tester, '/B');
      await picker(tester, '/A');
      write.complete(
        const PgnSaved(
          before: null,
          after: PgnSnapshot(
            path: '/A/New.pgn',
            revision: PgnRevision(
              documentId: 'new',
              nativeIdentity: 'new',
              sha256: 'new',
            ),
            content: '// Color: Black',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(selected, isNull);
      expect(catalog.writes, 1);
    },
  );
}
