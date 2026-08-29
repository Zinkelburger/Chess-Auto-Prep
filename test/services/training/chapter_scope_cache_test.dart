/// The scope derives its trainable lines and chapter names once per source
/// list and grouping setting; the trainer reads them on every rebuild.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/services/asked_questions_store.dart';
import 'package:chess_auto_prep/services/training/chapter_scope.dart';
import 'package:dartchess/dartchess.dart';

RepertoireLine _line(String id, String name, {bool model = false}) =>
    RepertoireLine(
      id: id,
      name: name,
      moves: const ['e4'],
      color: 'white',
      fullPgn: '',
      startPosition: Chess.initial,
      isModelGame: model,
    );

void main() {
  test('lines and names keep their identity until the source changes', () {
    var lines = [
      _line('a', 'Advance: main'),
      _line('b', 'Advance: Qb6'),
      _line('c', 'Exchange: main'),
      _line('m', 'Model game', model: true),
    ];
    final settings = TrainingSettings()
      ..chapterGrouping = ChapterGroupingMode.namePrefix
      ..chapterDelimiter = ':';
    final scope = ChapterScope(
      askedQuestions: AskedQuestionsStore(),
      settings: () => settings,
      lines: () => lines,
      sourceIsStudy: () => false,
    );

    final trainable = scope.lines;
    expect(trainable.map((l) => l.id), ['a', 'b', 'c']);
    expect(identical(scope.lines, trainable), isTrue);
    expect(() => trainable.clear(), throwsUnsupportedError);

    final names = scope.names;
    expect(names, ['Advance', 'Exchange']);
    expect(identical(scope.names, names), isTrue);
    expect(scope.hasUngroupedLines, isFalse);

    lines = [...lines, _line('d', 'Untitled')];
    expect(identical(scope.lines, trainable), isFalse);
    expect(scope.lines.length, 4);
    expect(scope.names, ['Advance', 'Exchange']);
    expect(scope.hasUngroupedLines, isTrue);

    settings.chapterGrouping = ChapterGroupingMode.off;
    expect(scope.names, isEmpty);
  });
}
