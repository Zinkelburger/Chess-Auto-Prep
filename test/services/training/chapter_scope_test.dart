import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/services/asked_questions_store.dart';
import 'package:chess_auto_prep/services/training/chapter_scope.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

/// [ChapterScope] carries the chapter grouping/scoping logic that used to sit
/// inline in TrainingSessionController. It reads its inputs through suppliers
/// so the owner can swap `settings`/`lines` wholesale without desyncing it.

RepertoireLine line(String name, {String? chapter, bool isModelGame = false}) =>
    RepertoireLine(
      id: name,
      name: name,
      moves: const ['e4'],
      color: 'white',
      startPosition: Chess.initial,
      fullPgn: '',
      chapter: chapter,
      isModelGame: isModelGame,
    );

/// Scope over a mutable settings/lines pair the test can reassign, mirroring
/// how the controller replaces both when a new file loads.
({ChapterScope scope, void Function(List<RepertoireLine>) setLines}) scopeOver(
  TrainingSettings settings,
  List<RepertoireLine> initial,
) {
  var lines = initial;
  final scope = ChapterScope(
    askedQuestions: AskedQuestionsStore(),
    settings: () => settings,
    lines: () => lines,
    sourceIsStudy: () => false,
  );
  return (scope: scope, setLines: (next) => lines = next);
}

void main() {
  late TrainingSettings settings;

  setUp(() => settings = TrainingSettings());

  group('chapterOf', () {
    test('off mode groups nothing', () {
      settings.chapterGrouping = ChapterGroupingMode.off;
      final s = scopeOver(settings, [line('a', chapter: 'Intro')]).scope;
      expect(s.chapterOf(line('a', chapter: 'Intro')), isNull);
    });

    test('auto mode reads the line header chapter', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, const []).scope;
      expect(s.chapterOf(line('a', chapter: 'Intro')), 'Intro');
      expect(s.chapterOf(line('b')), isNull);
    });

    test('namePrefix mode splits on the delimiter', () {
      settings.chapterGrouping = ChapterGroupingMode.namePrefix;
      settings.chapterDelimiter = '#';
      final s = scopeOver(settings, const []).scope;
      expect(s.chapterOf(line('Reversed Meran # 4')), 'Reversed Meran');
      expect(s.chapterOf(line('no delimiter here')), isNull);
      expect(s.chapterOf(line('# leading delimiter')), isNull);
    });

    test('an empty delimiter disables namePrefix grouping', () {
      settings.chapterGrouping = ChapterGroupingMode.namePrefix;
      settings.chapterDelimiter = '';
      final s = scopeOver(settings, const []).scope;
      expect(s.chapterOf(line('Reversed Meran # 4')), isNull);
    });

    test('a declined file groups nothing regardless of mode', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, const []).scope;
      s.declined = true;
      expect(s.chapterOf(line('a', chapter: 'Intro')), isNull);
    });
  });

  group('names and membership', () {
    test('names are distinct and in file order', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, [
        line('a', chapter: 'B'),
        line('b', chapter: 'A'),
        line('c', chapter: 'B'),
        line('d'),
      ]).scope;
      expect(s.names, ['B', 'A']);
    });

    test('a null chapter matches every line', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, const []).scope;
      expect(s.contains(line('a', chapter: 'Intro'), null), isTrue);
      expect(s.contains(line('b'), null), isTrue);
    });

    test('the ungrouped sentinel matches only chapterless lines', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, const []).scope;
      expect(s.contains(line('a'), ChapterScope.ungrouped), isTrue);
      expect(
        s.contains(line('b', chapter: 'Intro'), ChapterScope.ungrouped),
        isFalse,
      );
    });

    test('hasUngroupedLines is false when every line has a chapter', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final all = scopeOver(settings, [
        line('a', chapter: 'A'),
        line('b', chapter: 'B'),
      ]).scope;
      expect(all.hasUngroupedLines, isFalse);

      final some = scopeOver(settings, [
        line('a', chapter: 'A'),
        line('b'),
      ]).scope;
      expect(some.hasUngroupedLines, isTrue);
    });

    test('hasUngroupedLines is false when there are no chapters at all', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, [line('a'), line('b')]).scope;
      expect(s.hasUngroupedLines, isFalse);
    });
  });

  group('model games', () {
    test('are not trainable lines and get no chapter of their own', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, [
        line('a', chapter: 'Open Sicilian'),
        line('Kasparov – Karpov', chapter: 'Model games', isModelGame: true),
      ]).scope;

      expect(s.lines.map((l) => l.name), ['a']);
      expect(s.scopedLines.map((l) => l.name), ['a']);
      expect(s.names, ['Open Sicilian']);
    });

    test('their absence does not make the rest look ungrouped', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, [
        line('a', chapter: 'Open Sicilian'),
        line('Kasparov – Karpov', chapter: 'Model games', isModelGame: true),
      ]).scope;
      expect(s.hasUngroupedLines, isFalse);
    });
  });

  group('scopedLines', () {
    test('returns every line when unscoped', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, [
        line('a', chapter: 'A'),
        line('b', chapter: 'B'),
      ]).scope;
      expect(s.scopedLines.length, 2);
    });

    test('filters to the active chapter', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, [
        line('a', chapter: 'A'),
        line('b', chapter: 'B'),
        line('c', chapter: 'A'),
      ]).scope;
      s.setActive('A');
      expect(s.scopedLines.map((l) => l.id), ['a', 'c']);
    });

    test('the ungrouped sentinel selects the chapterless lines', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, [line('a', chapter: 'A'), line('b')]).scope;
      s.setActive(ChapterScope.ungrouped);
      expect(s.scopedLines.map((l) => l.id), ['b']);
    });
  });

  group('setActive reports whether anything changed', () {
    test('true on a real change, false on a repeat', () {
      final s = scopeOver(settings, const []).scope;
      expect(s.setActive('A'), isTrue);
      expect(s.setActive('A'), isFalse);
      expect(s.setActive(null), isTrue);
      expect(s.setActive(null), isFalse);
    });
  });

  group('prompt lifecycle', () {
    test('dismissPrompt clears without recording, and reports it', () {
      final s = scopeOver(settings, const []).scope;
      expect(s.dismissPrompt(), isFalse, reason: 'nothing showing');
    });

    test('reopenPrompt is a no-op when no layout was detected', () {
      final s = scopeOver(settings, const []).scope;
      expect(s.canOffer, isFalse);
      expect(s.reopenPrompt(), isFalse);
      expect(s.pendingPrompt, isNull);
    });
  });

  group('supplier reads stay live', () {
    test('replacing the owner line list is picked up immediately', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final over = scopeOver(settings, [line('a', chapter: 'A')]);
      expect(over.scope.names, ['A']);

      over.setLines([line('b', chapter: 'B'), line('c', chapter: 'C')]);
      expect(over.scope.names, [
        'B',
        'C',
      ], reason: 'a cached copy would still report the old file');
    });

    test('mutating the settings object is picked up immediately', () {
      settings.chapterGrouping = ChapterGroupingMode.auto;
      final s = scopeOver(settings, [line('X # 1')]).scope;
      expect(s.names, isEmpty, reason: 'no header chapters');

      settings.chapterGrouping = ChapterGroupingMode.namePrefix;
      settings.chapterDelimiter = '#';
      expect(s.names, ['X']);
    });
  });
}
