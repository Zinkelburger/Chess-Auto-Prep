import 'dart:io';

import 'package:chess_auto_prep/features/repertoire/controllers/repertoire_outline_controller.dart';
import 'package:chess_auto_prep/features/repertoire/models/repertoire_outline.dart';
import 'package:chess_auto_prep/features/repertoire/services/chapter_splitter.dart';
import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String root;
  late RepertoireOutlineService service;

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
    service = RepertoireOutlineService(
      storage: IOStorageService(),
      splitter: ChapterSplitter(
        storage: IOStorageService(),
        review: RepertoireReviewService(storage: _CsvStorage()),
      ),
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  group('build', () {
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
  });

  group('controller', () {
    test('opens, reveals the active chapter, follows a rename', () async {
      String? followed;
      final c = RepertoireOutlineController(
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
      final c = RepertoireOutlineController(service: service);
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

    test('splitting a chapter with no course chapters is refused', () async {
      final c = RepertoireOutlineController(service: service);
      await c.open(rootPath: root, activeChapterPath: null, isWhite: false);
      final out = await c.splitChapter(p.join(root, 'Advance.pgn'));
      expect(out.ok, isFalse);
      expect(out.error, contains('no course chapters'));
    });

    test('deleting the active chapter clears it', () async {
      String? followed = 'unset';
      final c = RepertoireOutlineController(
        service: service,
        onActiveChapterMoved: (path) => followed = path,
      );
      final active = p.join(root, 'Advance.pgn');
      await c.open(rootPath: root, activeChapterPath: active, isWhite: false);
      await c.deleteChapter(active);
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
