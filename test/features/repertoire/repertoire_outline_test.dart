import 'package:chess_auto_prep/infrastructure/repertoires/legacy_repertoire_catalog_repository.dart';
import 'package:chess_auto_prep/infrastructure/documents/native_pgn_document_store.dart';
import 'dart:async';
import 'package:chess_auto_prep/features/documents/models/pgn_document.dart';
import 'dart:io';

import 'package:chess_auto_prep/features/repertoire/controllers/repertoire_outline_controller.dart';
import 'package:chess_auto_prep/features/repertoire/models/repertoire_outline.dart';
import 'package:chess_auto_prep/features/repertoire/services/chapter_splitter.dart';
import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';
import 'package:chess_auto_prep/features/repertoire/services/review_progress_repointer.dart';
import 'package:chess_auto_prep/models/repertoire_review_entry.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

/// Keeps the review CSVs a split re-points out of the user's real
/// `~/Documents`; everything else runs against the temp directory.
class _CsvStorage implements StorageService {
  String? reviews;
  String? moveProgress;

  @override
  Future<String?> readRepertoireReviewsCsv() async => reviews;
  @override
  Future<void> saveRepertoireReviewsCsv(String csv) async => reviews = csv;
  @override
  Future<String?> readRepertoireMoveProgressCsv() async => moveProgress;
  @override
  Future<void> saveRepertoireMoveProgressCsv(String csv) async =>
      moveProgress = csv;

  final Map<String, String> backups = {};
  @override
  Future<String?> readFile(String path) async => switch (path) {
    'repertoire_reviews.csv' => reviews,
    'repertoire_move_progress.csv' => moveProgress,
    _ => backups[path],
  };
  @override
  Future<bool> fileExists(String path) async => await readFile(path) != null;
  @override
  Future<void> writeFile(
    String path,
    String content, {
    bool createOnly = false,
    String? expectedContent,
  }) async {
    backups[path] = content;
  }

  @override
  Future<String> updateFile(
    String path,
    FutureOr<String> Function(String?) update,
  ) async {
    final next = await update(await readFile(path));
    if (path == 'repertoire_reviews.csv') reviews = next;
    if (path == 'repertoire_move_progress.csv') moveProgress = next;
    return next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The outline is the file structure: folders nest, chapters are `.pgn`
/// files, lines are games. These run against a real temp directory through
/// [IOStorageService], since the whole point is that what the panel shows is
/// what is on disk.
String _game(String event, String moves, {String? chapter}) =>
    '[Event "$event"]\n'
    '${chapter != null ? '[White "$chapter"]\n' : ''}'
    '[Result "*"]\n\n$moves *\n';

class _ControlledRepointer extends ReviewProgressRepointer {
  _ControlledRepointer({required super.review});
  bool fail = false;
  Completer<void>? hold;
  final entered = Completer<void>();
  @override
  Future<void> repoint({
    required String from,
    required Map<String, Set<String>> movedIdsByPath,
  }) async {
    if (!entered.isCompleted) entered.complete();
    await hold?.future;
    if (fail) throw StateError('progress unavailable');
    await super.repoint(from: from, movedIdsByPath: movedIdsByPath);
  }
}

class _ControlledCatalog extends LegacyRepertoireCatalogRepository {
  _ControlledCatalog(super.storage, {required super.documents});
  Completer<void>? hold;
  final entered = Completer<void>();
  bool throws = false;
  bool uncertain = false;
  int deletions = 0;
  @override
  Future<PgnQuarantineResult> deleteChapter(PgnSnapshot baseline) async {
    deletions++;
    if (!entered.isCompleted) entered.complete();
    await hold?.future;
    if (throws) throw StateError('unexpected adapter failure');
    final result = await super.deleteChapter(baseline);
    if (uncertain && result is PgnQuarantined) {
      return PgnQuarantineUncertain(
        error: StateError('acknowledgement lost'),
        before: baseline,
        quarantinePath: result.retained.path,
        recoveryPath: result.recoveryPath,
        observedSource: null,
        observedQuarantine: result.retained,
      );
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String root;
  late RepertoireOutlineService service;
  late _ControlledCatalog catalog;
  late _CsvStorage csv;
  late _ControlledRepointer repointer;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('outline_test');
    root = p.join(tmp.path, 'French');
    Directory(root).createSync();
    File(p.join(root, 'Advance.pgn')).writeAsStringSync(
      '// Advance\n// Color: Black\n\n'
      '${_game('Main line', '1. e4 e6 2. d4 d5 3. e5 c5 4. c3 Nc6')}\n'
      '${_game('Qb6 line', '1. e4 e6 2. d4 d5 3. e5 c5 4. c3 Qb6')}\n',
    );
    Directory(p.join(root, 'Sidelines')).createSync();
    File(p.join(root, 'Sidelines', 'Exchange.pgn')).writeAsStringSync(
      '// Color: Black\n\n${_game('Exchange', '1. e4 e6 2. d4 d5 3. exd5 exd5')}\n',
    );
    final storage = IOStorageService(
      documentsRoot: tmp,
      supportRoot: tmp,
      repertoiresRoot: Directory(root),
    );
    csv = _CsvStorage();
    repointer = _ControlledRepointer(
      review: RepertoireReviewService(storage: csv),
    );
    catalog = _ControlledCatalog(storage, documents: NativePgnDocumentStore());
    service = RepertoireOutlineService(
      catalog: catalog,
      storage: storage,
      repointer: repointer,
      splitter: ChapterSplitter(
        documents: NativePgnDocumentStore(),
        storage: storage,
        repointer: repointer,
      ),
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('build', () {
    test('excludes native recovery storage at every chapter level', () async {
      for (final parent in [root, p.join(root, 'Sidelines')]) {
        final history = Directory(p.join(parent, '.cap-pgn-history'));
        history.createSync();
        File(
          p.join(history.path, 'recovered.pgn'),
        ).writeAsStringSync(_game('Recovery only', '1. e4 e5'));
      }
      final outline = await service.build(root, trainingColor: 'black');
      expect(outline.folders.map((f) => f.name), ['Sidelines']);
      expect(outline.folders.single.folders, isEmpty);
      expect(outline.lineCount, 3);
    });

    test('mirrors folders, chapters and lines', () async {
      final outline = await service.build(root, trainingColor: 'black');
      expect(outline.name, 'French');
      expect(outline.folders.map((f) => f.name), ['Sidelines']);
      expect(outline.chapters.map((c) => c.name), ['Advance']);
      expect(outline.chapters.single.lines!.map((l) => l.name), [
        'Main line',
        'Qb6 line',
      ]);
      expect(outline.lineCount, 3);
      expect(
        outline.findChapter(p.join(root, 'Sidelines', 'Exchange.pgn')),
        isNotNull,
      );
    });

    test('groups course-composer sections inside a chapter', () async {
      File(p.join(root, 'Course.pgn')).writeAsStringSync(
        '${_game('A', '1. e4 e6 2. d4 d5 3. Nc3', chapter: 'Classical')}\n'
        '${_game('B', '1. e4 e6 2. d4 d5 3. Nd2', chapter: 'Tarrasch')}\n'
        '${_game('C', '1. e4 e6 2. d4 d5 3. Nc3 Nf6', chapter: 'Classical')}\n',
      );
      final outline = await service.build(root, trainingColor: 'black');
      final course = outline.findChapter(p.join(root, 'Course.pgn'))!;
      expect(course.sections, ['Classical', 'Tarrasch']);
      expect(course.linesIn('Classical').map((l) => l.name), ['A', 'C']);
    });

    test('caches parsed lines by mtime', () async {
      final first = await service.build(root, trainingColor: 'black');
      final second = await service.build(root, trainingColor: 'black');
      expect(
        identical(first.chapters.single.lines, second.chapters.single.lines),
        isTrue,
      );
    });
  });

  group('names', () {
    test('rejects empty, separators and reserved names', () {
      expect(RepertoireOutlineService.validateName(''), isNotNull);
      expect(RepertoireOutlineService.validateName('a/b'), isNotNull);
      expect(RepertoireOutlineService.validateName('..'), isNotNull);
      expect(RepertoireOutlineService.validateName('King\'s Gambit'), isNull);
    });
  });

  group('edits', () {
    test('create, rename and move a chapter', () async {
      final created = await service.createChapter(
        folderPath: root,
        name: 'Tarrasch',
        isWhite: false,
      );
      expect(File(created.path).existsSync(), isTrue);

      final renamed = await service.renameChapter(
        created.path,
        'Tarrasch 3.Nd2',
      );
      expect(File(renamed).existsSync(), isTrue);
      expect(File(created.path).existsSync(), isFalse);

      final moved = await service.moveChapter(
        renamed,
        p.join(root, 'Sidelines'),
      );
      expect(p.dirname(moved), p.join(root, 'Sidelines'));

      expect(
        () => service.moveChapter(moved, p.join(root, 'Sidelines')),
        returnsNormally,
      );
    });

    test('refuses a rename onto an existing chapter', () async {
      final path = p.join(root, 'Sidelines', 'Exchange.pgn');
      await service.createChapter(
        folderPath: p.join(root, 'Sidelines'),
        name: 'Other',
        isWhite: false,
      );
      expect(
        () => service.renameChapter(path, 'Other'),
        throwsA(isA<OutlineEditException>()),
      );
    });

    test('folders: create, rename, nest, and refuse self-nesting', () async {
      final f = await service.createFolder(parentPath: root, name: 'Rare');
      final g = await service.renameFolder(f, 'Rare stuff');
      expect(Directory(g).existsSync(), isTrue);
      final nested = await service.moveFolder(g, p.join(root, 'Sidelines'));
      expect(p.dirname(nested), p.join(root, 'Sidelines'));
      expect(
        () => service.moveFolder(p.join(root, 'Sidelines'), nested),
        throwsA(isA<OutlineEditException>()),
      );
    });

    test('moves a line between chapters without losing it', () async {
      final advance = p.join(root, 'Advance.pgn');
      final exchange = p.join(root, 'Sidelines', 'Exchange.pgn');
      final before = await service.build(root, trainingColor: 'black');
      final line = before.findChapter(advance)!.lines!.last;

      final ok = await service.moveLine(
        fromChapterPath: advance,
        gameIndex: line.gameIndex,
        toChapterPath: exchange,
      );
      expect(ok, isTrue);

      final after = await service.build(root, trainingColor: 'black');
      expect(after.findChapter(advance)!.lines!.map((l) => l.name), [
        'Main line',
      ]);
      expect(after.findChapter(exchange)!.lines!.map((l) => l.name), [
        'Exchange',
        'Qb6 line',
      ]);
    });

    test('a moved line keeps its id and its review schedule', () async {
      final advance = p.join(root, 'Advance.pgn');
      final exchange = p.join(root, 'Sidelines', 'Exchange.pgn');
      final before = await service.build(root, trainingColor: 'black');
      final line = before.findChapter(advance)!.lines!.last;
      final review = RepertoireReviewService(storage: csv);
      await review.saveAll([
        RepertoireReviewEntry(
          repertoireId: advance,
          lineId: line.id,
          lineName: line.name,
          intervalDays: 6,
        ),
      ]);

      final landed = await service.moveLines(
        fromChapterPath: advance,
        gameIndexes: {line.gameIndex},
        toChapterPath: exchange,
        toIndex: 0,
      );
      expect(landed, [0]);

      final after = await service.build(root, trainingColor: 'black');
      final moved = after.findChapter(exchange)!.lines!.first;
      expect(moved.name, 'Qb6 line');
      // The position-based id would have changed with the move; pinning it
      // into the game as a header is what keeps it.
      expect(moved.id, line.id);
      expect(
        File(exchange).readAsStringSync(),
        contains('[LineID "${line.id}"]'),
      );
      final entries = await review.loadAll();
      expect(entries.single.repertoireId, exchange);
      expect(entries.single.intervalDays, 6);
    });

    test('lines are reordered in place and put back exactly', () async {
      final advance = p.join(root, 'Advance.pgn');
      final landed = await service.moveLines(
        fromChapterPath: advance,
        gameIndexes: {0},
        toChapterPath: advance,
        toIndex: 2,
      );
      expect(landed, [1]);
      var names = (await service.build(
        root,
      )).findChapter(advance)!.lines!.map((l) => l.name);
      expect(names, ['Qb6 line', 'Main line']);

      await service.moveLines(
        fromChapterPath: advance,
        gameIndexes: {1},
        toChapterPath: advance,
        toIndexes: [0],
      );
      names = (await service.build(
        root,
      )).findChapter(advance)!.lines!.map((l) => l.name);
      expect(names, ['Main line', 'Qb6 line']);
    });

    test('deleted lines come back where they were', () async {
      final advance = p.join(root, 'Advance.pgn');
      final removed = await service.deleteLines(advance, {0});
      expect(removed.single.index, 0);
      expect(removed.single.text, contains('Main line'));
      expect(
        (await service.build(
          root,
        )).findChapter(advance)!.lines!.map((l) => l.name),
        ['Qb6 line'],
      );
      await service.restoreLines(advance, removed);
      expect(
        (await service.build(
          root,
        )).findChapter(advance)!.lines!.map((l) => l.name),
        ['Main line', 'Qb6 line'],
      );
    });
  });

  group('controller', () {
    test('opens, reveals the active chapter, follows a rename', () async {
      String? followed;
      final c = RepertoireOutlineController(
        catalog: catalog,
        service: service,
        onActiveChapterMoved: (path) => followed = path,
      );
      final active = p.join(root, 'Sidelines', 'Exchange.pgn');
      await c.open(rootPath: root, activeChapterPath: active, isWhite: false);

      expect(c.outline, isNotNull);
      expect(c.isExpanded(p.join(root, 'Sidelines')), isTrue);
      expect(c.isChapterOpen(active), isTrue);

      final out = await c.renameChapter(active, 'Exchange variation');
      expect(out.ok, isTrue);
      expect(followed, p.join(root, 'Sidelines', 'Exchange variation.pgn'));
      expect(c.activeChapterPath, followed);
      expect(c.outline!.findChapter(followed!), isNotNull);
    });

    test('reports refusals as outcomes, not exceptions', () async {
      final c = RepertoireOutlineController(catalog: catalog, service: service);
      await c.open(rootPath: root, activeChapterPath: null, isWhite: false);
      final out = await c.createChapter(folderPath: root, name: 'Advance');
      expect(out.ok, isFalse);
      expect(out.error, contains('already exists'));
    });

    test(
      'splitting the active chapter follows it to the first new one',
      () async {
        // A course export: chapters in [White], variations in [Black].
        final course = p.join(root, 'Course.pgn');
        File(course).writeAsStringSync(
          '// Color: Black\n\n'
          '${_game('Course', '1. d4 d5 2. c4 e6', chapter: 'Tartakower')}\n'
          '${_game('Course', '1. d4 d5 2. c4 c6', chapter: 'Tartakower')}\n'
          '${_game('Course', '1. d4 Nf6 2. c4 e6', chapter: 'Catalan')}\n'
          '${_game('Course', '1. d4 Nf6 2. c4 g6', chapter: 'Catalan')}\n',
        );

        String? followed = 'unset';
        final c = RepertoireOutlineController(
          catalog: catalog,
          service: service,
          onActiveChapterMoved: (path) => followed = path,
        );
        await c.open(rootPath: root, activeChapterPath: course, isWhite: false);

        final out = await c.splitChapter(course);
        expect(out.ok, isTrue);
        expect(File(course).existsSync(), isFalse);
        expect(followed, p.join(root, 'Tartakower.pgn'));
        expect(c.activeChapterPath, followed);
        expect(
          c.outline!.chapters.map((ch) => ch.name),
          containsAll(['Catalan', 'Tartakower']),
        );
        expect(
          c.outline!.findChapter(p.join(root, 'Catalan.pgn'))!.lineCount,
          2,
        );
      },
    );

    test(
      'progress failure refreshes committed files and follows quarantined active source',
      () async {
        final course = p.join(root, 'Course.pgn');
        await File(course).writeAsString(
          [
            for (final title in ['One', 'Two'])
              for (final moves in ['1. e4 e5', '1. d4 d5'])
                _game('Course', moves, chapter: title),
          ].join('\n'),
        );
        repointer.fail = true;
        String? active;
        final c = RepertoireOutlineController(
          catalog: catalog,
          service: service,
          onActiveChapterMoved: (path) => active = path,
        );
        addTearDown(c.dispose);
        await c.open(rootPath: root, activeChapterPath: course, isWhite: false);
        final outcome = await c.splitChapter(course);
        expect(outcome.ok, isFalse);
        expect(
          outcome.splitFailure!.sourceState,
          ChapterSplitSourceState.committed,
        );
        expect(outcome.splitFailure!.sourceRemoved, isTrue);
        expect(outcome.error, contains('not rolled back'));
        expect(active, p.join(root, 'One.pgn'));
        expect(c.outline!.findChapter(course), isNull);
        expect(c.outline!.findChapter(active!)!.lineCount, 2);
        expect(c.outline!.findChapter(p.join(root, 'Two.pgn'))!.lineCount, 2);
      },
    );

    test('pending split rejects another split and structural edits', () async {
      final course = p.join(root, 'Course.pgn');
      await File(course).writeAsString(
        [
          for (final title in ['One', 'Two'])
            for (final moves in ['1. e4 e5', '1. d4 d5'])
              _game('Course', moves, chapter: title),
        ].join('\n'),
      );
      repointer.hold = Completer<void>();
      final c = RepertoireOutlineController(catalog: catalog, service: service);
      addTearDown(c.dispose);
      await c.open(rootPath: root, activeChapterPath: course, isWhite: false);
      final first = c.splitChapter(course);
      await repointer.entered.future;
      expect((await c.splitChapter(course)).error, contains('still running'));
      expect(
        (await c.renameChapter(p.join(root, 'One.pgn'), 'Changed')).ok,
        isFalse,
      );
      expect(File(p.join(root, 'Changed.pgn')).existsSync(), isFalse);
      repointer.hold!.complete();
      expect((await first).ok, isTrue);
      expect(
        (await c.renameChapter(p.join(root, 'One.pgn'), 'Changed')).ok,
        isTrue,
      );
    });

    test('splitting a chapter with no course chapters is refused', () async {
      final c = RepertoireOutlineController(catalog: catalog, service: service);
      await c.open(rootPath: root, activeChapterPath: null, isWhite: false);
      final out = await c.splitChapter(p.join(root, 'Advance.pgn'));
      expect(out.ok, isFalse);
      expect(out.error, contains('no course chapters'));
    });

    test('moving lines is reported and undone', () async {
      final advance = p.join(root, 'Advance.pgn');
      final exchange = p.join(root, 'Sidelines', 'Exchange.pgn');
      var reloads = 0;
      final c = RepertoireOutlineController(
        catalog: catalog,
        service: service,
        onActiveChapterMoved: (_) => reloads++,
      );
      await c.open(rootPath: root, activeChapterPath: advance, isWhite: false);

      final out = await c.moveLines(
        fromChapterPath: advance,
        gameIndexes: {0, 1},
        toChapterPath: exchange,
        toIndex: 0,
      );
      expect(out.ok, isTrue);
      expect(out.message, 'Moved 2 lines to "Exchange".');
      expect(out.undo, isNotNull);
      expect(reloads, 1, reason: 'the active chapter lost lines');
      expect(c.isChapterOpen(exchange), isTrue);
      expect(c.outline!.findChapter(advance)!.lineCount, 0);
      expect(c.outline!.findChapter(exchange)!.lines!.map((l) => l.name), [
        'Main line',
        'Qb6 line',
        'Exchange',
      ]);

      final back = await out.undo!();
      expect(back.ok, isTrue);
      expect(back.message, 'Moved 2 lines back.');
      expect(c.outline!.findChapter(advance)!.lines!.map((l) => l.name), [
        'Main line',
        'Qb6 line',
      ]);
      expect(c.outline!.findChapter(exchange)!.lineCount, 1);
    });

    test('dropping a line back where it was says nothing', () async {
      final advance = p.join(root, 'Advance.pgn');
      final c = RepertoireOutlineController(catalog: catalog, service: service);
      await c.open(rootPath: root, activeChapterPath: null, isWhite: false);
      final out = await c.moveLines(
        fromChapterPath: advance,
        gameIndexes: {1},
        toChapterPath: advance,
        toIndex: 2,
      );
      expect(out.ok, isTrue);
      expect(out.message, isNull);
      expect(out.undo, isNull);
    });

    test('deleting lines is undoable', () async {
      final advance = p.join(root, 'Advance.pgn');
      final c = RepertoireOutlineController(catalog: catalog, service: service);
      await c.open(rootPath: root, activeChapterPath: null, isWhite: false);
      final out = await c.deleteLines(advance, {0});
      expect(out.message, 'Deleted "Main line".');
      expect(c.outline!.findChapter(advance)!.lineCount, 1);
      final back = await out.undo!();
      expect(back.ok, isTrue);
      expect(c.outline!.findChapter(advance)!.lines!.map((l) => l.name), [
        'Main line',
        'Qb6 line',
      ]);
    });

    test('undo returns moved lines and retains the created chapter', () async {
      final advance = p.join(root, 'Advance.pgn');
      final c = RepertoireOutlineController(catalog: catalog, service: service);
      await c.open(rootPath: root, activeChapterPath: advance, isWhite: false);
      final out = await c.createChapterWithLines(
        folderPath: p.join(root, 'Sidelines'),
        name: 'Qb6',
        fromChapterPath: advance,
        gameIndexes: {1},
      );
      expect(out.ok, isTrue);
      expect(
        out.message,
        'Made "Qb6" from 1 line. Undo returns the lines and keeps the chapter.',
      );
      final made = p.join(root, 'Sidelines', 'Qb6.pgn');
      expect(c.outline!.findChapter(made)!.lines!.single.name, 'Qb6 line');
      expect(c.outline!.findChapter(advance)!.lineCount, 1);

      final back = await out.undo!();
      expect(back.ok, isTrue);
      expect(File(made).existsSync(), isTrue);
      expect(c.outline!.findChapter(made)!.lineCount, 0);
      expect(c.outline!.findChapter(advance)!.lineCount, 2);
    });

    for (final addLine in [false, true]) {
      test(
        'undo retains ${addLine ? 'later lines' : 'header-only edits'} without a cached-count delete',
        () async {
          final source = p.join(root, 'Advance.pgn');
          final c = RepertoireOutlineController(
            catalog: catalog,
            service: service,
          );
          await c.open(
            rootPath: root,
            activeChapterPath: source,
            isWhite: false,
          );
          final made = p.join(root, 'Retained.pgn');
          final result = await c.createChapterWithLines(
            folderPath: root,
            name: 'Retained',
            fromChapterPath: source,
            gameIndexes: {1},
          );
          expect(result.ok, isTrue);
          final added = addLine
              ? _game('Later addition', '1. d4 d5')
              : '// Later header annotation\n';
          final file = File(made);
          final previous = file.readAsStringSync();
          file.writeAsStringSync(
            addLine ? '$previous\n$added' : '$added$previous',
          );
          // Deliberately do not refresh: the old cached line count matches the
          // created chapter and used to authorize deleting these later edits.
          final undone = await result.undo!();
          expect(undone.ok, isTrue);
          expect(undone.message, contains('kept "Retained"'));
          expect(file.existsSync(), isTrue);
          expect(
            file.readAsStringSync(),
            contains(addLine ? 'Later addition' : 'Later header annotation'),
          );
          expect(c.outline!.findChapter(source)!.lineCount, 2);
          expect(c.outline!.findChapter(made)!.lineCount, addLine ? 1 : 0);
          c.dispose();
        },
      );
    }

    test('moving a chapter is undoable', () async {
      final advance = p.join(root, 'Advance.pgn');
      final c = RepertoireOutlineController(catalog: catalog, service: service);
      await c.open(rootPath: root, activeChapterPath: null, isWhite: false);
      final out = await c.moveChapter(advance, p.join(root, 'Sidelines'));
      expect(out.message, 'Moved "Advance" to "Sidelines".');
      expect(
        File(p.join(root, 'Sidelines', 'Advance.pgn')).existsSync(),
        isTrue,
      );
      final back = await out.undo!();
      expect(back.ok, isTrue);
      expect(File(advance).existsSync(), isTrue);
    });

    test(
      'delete shares admission with create and split, releases after thrown failure',
      () async {
        final active = p.join(root, 'Advance.pgn');
        final c = RepertoireOutlineController(
          catalog: catalog,
          service: service,
        );
        addTearDown(c.dispose);
        await c.open(rootPath: root, activeChapterPath: active, isWhite: false);
        final before =
            (await catalog.prepareChapterDeletion(active) as PgnOpened)
                .snapshot;
        catalog.hold = Completer<void>();
        catalog.throws = true;
        final removal = c.deleteChapter(before);
        final failed = expectLater(removal, throwsStateError);
        await catalog.entered.future;
        expect(
          (await c.createChapter(folderPath: root, name: 'Blocked')).ok,
          isFalse,
        );
        expect((await c.splitChapter(active)).ok, isFalse);
        expect(await c.deleteChapter(before), isA<PgnQuarantineFailed>());
        expect(catalog.deletions, 1);
        catalog.hold!.complete();
        await failed;
        expect(File(active).existsSync(), isTrue);
        expect(
          (await c.createChapter(folderPath: root, name: 'After')).ok,
          isTrue,
        );
      },
    );

    test(
      'uncertain deletion refreshes observed rows without closing or following',
      () async {
        final active = p.join(root, 'Advance.pgn');
        final followed = <String?>[];
        final c = RepertoireOutlineController(
          catalog: catalog,
          service: service,
          onActiveChapterMoved: followed.add,
        );
        addTearDown(c.dispose);
        await c.open(rootPath: root, activeChapterPath: active, isWhite: false);
        final before =
            (await catalog.prepareChapterDeletion(active) as PgnOpened)
                .snapshot;
        catalog.uncertain = true;
        final outcome = await c.deleteChapter(before);
        expect(outcome, isA<PgnQuarantineUncertain>());
        expect(File(active).existsSync(), isFalse);
        expect(c.outline!.findChapter(active), isNull);
        expect(c.activeChapterPath, active);
        expect(c.isChapterOpen(active), isTrue);
        expect(followed, isEmpty);
        // Recreating the source shows fresh content, not the cached old chapter.
        File(active).writeAsStringSync(_game('Replacement', '1. d4 d5'));
        await c.refresh();
        expect(
          c.outline!.findChapter(active)!.lines!.single.name,
          'Replacement',
        );
        expect(
          (await c.createChapter(folderPath: root, name: 'After')).ok,
          isTrue,
        );
      },
    );

    test(
      'acknowledged old deletion cannot clear active selection after A B A',
      () async {
        final active = p.join(root, 'Advance.pgn');
        final followed = <String?>[];
        final c = RepertoireOutlineController(
          catalog: catalog,
          service: service,
          onActiveChapterMoved: followed.add,
        );
        addTearDown(c.dispose);
        await c.open(rootPath: root, activeChapterPath: active, isWhite: false);
        final before =
            (await catalog.prepareChapterDeletion(active) as PgnOpened)
                .snapshot;
        catalog.hold = Completer<void>();
        final removal = c.deleteChapter(before);
        await catalog.entered.future;
        c.setActiveChapter(p.join(root, 'Sidelines', 'Exchange.pgn'));
        c.setActiveChapter(active);
        catalog.hold!.complete();
        expect(await removal, isA<PgnQuarantined>());
        expect(c.activeChapterPath, active);
        expect(c.isChapterOpen(active), isTrue);
        expect(followed, isEmpty);
      },
    );

    test('deleting the active chapter clears it', () async {
      String? followed = 'unset';
      final c = RepertoireOutlineController(
        catalog: catalog,
        service: service,
        onActiveChapterMoved: (path) => followed = path,
      );
      final active = p.join(root, 'Advance.pgn');
      await c.open(rootPath: root, activeChapterPath: active, isWhite: false);
      await c.deleteChapter(
        ((await catalog.prepareChapterDeletion(active)) as PgnOpened).snapshot,
      );
      expect(followed, isNull);
      expect(c.activeChapterPath, isNull);
      expect(c.outline!.chapters, isEmpty);
    });
  });

  test('OutlineLine helpers', () {
    final line = OutlineLine(
      path: 'x',
      id: 'i',
      gameIndex: 0,
      name: 'n',
      moves: ['e4', 'e6', 'd4', 'd5', 'e5'],
    );
    expect(line.passesThrough(['e4', 'e6']), isTrue);
    expect(line.passesThrough(['d4']), isFalse);
    expect(line.preview(maxPlies: 4), '1.e4 e6 2.d4 d5 …');
  });
}
