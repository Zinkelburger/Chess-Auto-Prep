/// The outline is flattened into rows once per change of its inputs; the
/// panel renders the rows lazily.  These pin what the flattening produces
/// and when the controller reuses it.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:chess_auto_prep/features/repertoire/controllers/repertoire_outline_controller.dart';
import 'package:chess_auto_prep/features/repertoire/models/outline_rows.dart';
import 'package:chess_auto_prep/features/repertoire/models/repertoire_outline.dart';
import 'package:chess_auto_prep/features/repertoire/services/repertoire_outline_service.dart';

OutlineLine _line(
  String chapter,
  int i,
  String name,
  List<String> moves, {
  String? section,
}) => OutlineLine(
  path: chapter,
  id: 'l$i',
  gameIndex: i,
  name: name,
  moves: moves,
  section: section,
);

OutlineFolder _fixture() {
  const advance = '/rep/Advance.pgn';
  const exchange = '/rep/Sidelines/Exchange.pgn';
  return OutlineFolder(
    path: '/rep',
    name: 'rep',
    children: [
      OutlineFolder(
        path: '/rep/Sidelines',
        name: 'Sidelines',
        children: [
          OutlineChapter(
            path: exchange,
            name: 'Exchange',
            lines: [
              _line(exchange, 0, 'Exchange', ['e4', 'e6', 'd4', 'd5', 'exd5']),
            ],
          ),
        ],
      ),
      OutlineChapter(
        path: advance,
        name: 'Advance',
        lines: [
          _line(advance, 0, 'Main line', [
            'e4',
            'e6',
            'd4',
            'd5',
            'e5',
            'c5',
          ], section: 'Main'),
          _line(advance, 1, 'Qb6 line', [
            'e4',
            'e6',
            'd4',
            'd5',
            'e5',
            'Qb6',
          ], section: 'Main'),
          _line(advance, 2, 'Nc6 line', [
            'e4',
            'e6',
            'd4',
            'd5',
            'e5',
            'Nc6',
          ], section: 'Rare'),
        ],
      ),
    ],
  );
}

OutlineRowBuilder _builder({
  OutlineFilter filter = OutlineFilter.none,
  Set<String> expanded = const {},
  Set<String> open = const {},
  String? active,
}) => OutlineRowBuilder(
  filter: filter,
  isExpanded: expanded.contains,
  isChapterOpen: open.contains,
  activeChapterPath: active,
);

void main() {
  group('OutlineRowBuilder', () {
    test('a collapsed folder is one row; a closed chapter is one row', () {
      final rows = _builder().build(_fixture());
      expect(rows.map((r) => r.runtimeType), [FolderRow, ChapterRow]);
      expect((rows.last as ChapterRow).visibleLines, 3);
    });

    test('an open sectioned chapter lists section headers and lines', () {
      final rows = _builder(open: {'/rep/Advance.pgn'}).build(_fixture());
      expect(rows.map((r) => r.runtimeType), [
        FolderRow,
        ChapterRow,
        SectionRow,
        LineRow,
        LineRow,
        SectionRow,
        LineRow,
      ]);
      final sections = rows.whereType<SectionRow>().map((s) => s.title);
      expect(sections, ['Main', 'Rare']);
      expect(rows.whereType<LineRow>().map((l) => l.depth), [2, 2, 2]);
    });

    test('an expanded folder reveals its chapter at one level deeper', () {
      final rows = _builder(expanded: {'/rep/Sidelines'}).build(_fixture());
      final chapter = rows.whereType<ChapterRow>().first;
      expect(chapter.chapter.name, 'Exchange');
      expect(chapter.depth, 1);
    });

    test('a search unfolds every chapter with a hit and hides the rest', () {
      final rows = _builder(
        filter: const OutlineFilter(search: 'qb6'),
      ).build(_fixture());
      final chapters = rows.whereType<ChapterRow>().toList();
      expect(chapters.map((c) => c.chapter.name), ['Advance']);
      expect(chapters.single.open, isTrue);
      expect(chapters.single.visibleLines, 1);
      expect(rows.whereType<LineRow>().single.line.name, 'Qb6 line');
      // The folder holding no hit is gone with its chapter.
      expect(rows.whereType<FolderRow>(), isEmpty);
    });

    test('a folder name hit keeps the folder even with no line hits', () {
      final rows = _builder(
        filter: const OutlineFilter(search: 'sidel'),
      ).build(_fixture());
      expect(rows.whereType<FolderRow>().single.folder.name, 'Sidelines');
    });

    test('"at this position" keeps only lines through the board', () {
      final rows = _builder(
        filter: const OutlineFilter(
          atPosition: true,
          currentMoves: ['e4', 'e6', 'd4', 'd5', 'exd5'],
        ),
        expanded: {'/rep/Sidelines'},
      ).build(_fixture());
      expect(rows.whereType<LineRow>().single.line.name, 'Exchange');
      expect(rows.whereType<ChapterRow>().map((c) => c.chapter.name), [
        'Exchange',
      ]);
    });

    test('the active chapter is marked', () {
      final rows = _builder(active: '/rep/Advance.pgn').build(_fixture());
      expect(rows.whereType<ChapterRow>().single.active, isTrue);
    });

    test('rows carry stable keys', () {
      final rows = _builder(open: {'/rep/Advance.pgn'}).build(_fixture());
      final keys = rows.map((r) => r.key).toSet();
      expect(keys.length, rows.length);
    });
  });

  group('OutlineFilter', () {
    test('compares by content', () {
      expect(
        const OutlineFilter(search: 'a', currentMoves: ['e4']),
        const OutlineFilter(search: 'a', currentMoves: ['e4']),
      );
      expect(
        const OutlineFilter(search: 'a', currentMoves: ['e4']),
        isNot(const OutlineFilter(search: 'a', currentMoves: ['d4'])),
      );
      expect(const OutlineFilter().isActive, isFalse);
      expect(const OutlineFilter(atPosition: true).isActive, isFalse);
      expect(
        const OutlineFilter(atPosition: true, currentMoves: ['e4']).isActive,
        isTrue,
      );
    });
  });

  group('OutlineNode derived data', () {
    test('is computed once per node', () {
      final line = _line('/c', 0, 'French Advance', ['e4', 'e6']);
      expect(identical(line.searchText, line.searchText), isTrue);
      expect(line.matches('advance'), isTrue);
      expect(line.matches('e4 e6'), isTrue);
      expect(line.previewLabel, '1.e4 e6');
      final folder = _fixture();
      expect(folder.lineCount, 4);
      expect(folder.chapterList.map((c) => c.name), ['Exchange', 'Advance']);
      final advance = folder.chapterList.last;
      expect(advance.sections, ['Main', 'Rare']);
      expect(advance.linesIn('Rare').single.name, 'Nc6 line');
      expect(identical(advance.linesBySection, advance.linesBySection), isTrue);
    });
  });

  group('RepertoireOutlineController.rows', () {
    test('reuses the row list until fold state or filter changes', () async {
      final controller = RepertoireOutlineController(
        service: _FixtureService(),
      );
      await controller.open(
        rootPath: '/rep',
        activeChapterPath: '/rep/Advance.pgn',
        isWhite: false,
      );

      final rows = controller.rows(OutlineFilter.none);
      expect(identical(controller.rows(OutlineFilter.none), rows), isTrue);
      expect(
        identical(controller.rows(const OutlineFilter(currentMoves: [])), rows),
        isTrue,
        reason: 'an equal filter is the same key',
      );

      controller.toggleChapter('/rep/Advance.pgn');
      final folded = controller.rows(OutlineFilter.none);
      expect(identical(folded, rows), isFalse);
      expect(folded.length, lessThan(rows.length));

      final searched = controller.rows(const OutlineFilter(search: 'qb6'));
      expect(searched.whereType<LineRow>().single.line.name, 'Qb6 line');
      expect(
        identical(
          controller.rows(const OutlineFilter(search: 'qb6')),
          searched,
        ),
        isTrue,
      );
      controller.dispose();
    });

    test('the active chapter starts open and marked', () async {
      final controller = RepertoireOutlineController(
        service: _FixtureService(),
      );
      await controller.open(
        rootPath: '/rep',
        activeChapterPath: '/rep/Advance.pgn',
        isWhite: false,
      );
      final chapter = controller
          .rows(OutlineFilter.none)
          .whereType<ChapterRow>()
          .firstWhere((c) => p.equals(c.chapter.path, '/rep/Advance.pgn'));
      expect(chapter.active, isTrue);
      expect(chapter.open, isTrue);
      controller.dispose();
    });
  });
}

/// Serves the in-memory fixture instead of reading a folder.
class _FixtureService implements RepertoireOutlineService {
  @override
  Future<OutlineFolder> build(
    String folderPath, {
    bool loadLines = true,
    String? trainingColor,
  }) async => _fixture();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
