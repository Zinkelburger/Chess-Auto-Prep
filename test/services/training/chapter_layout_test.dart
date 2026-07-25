import 'package:chess_auto_prep/models/repertoire_line.dart';
import 'package:chess_auto_prep/models/training_settings.dart';
import 'package:chess_auto_prep/services/training/chapter_layout.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

RepertoireLine _line(String name, {String? chapter}) => RepertoireLine(
  id: name,
  name: name,
  moves: const ['e4'],
  color: 'white',
  startPosition: Chess.initial,
  fullPgn: '',
  chapter: chapter,
);

void main() {
  group('detectChapterLayout', () {
    test('header chapters win and are listed in file order with counts', () {
      final proposal = detectChapterLayout([
        _line('Colle - 3...c6 #1', chapter: '1) 3...c6'),
        _line('Colle - 3...c6 #2', chapter: '1) 3...c6'),
        _line('Colle - 3...Bg4', chapter: '2) 3...Bg4'),
        _line('Colle - 3...Bf5', chapter: '3) 3...Bf5'),
        _line('Colle - 3...Bf5 #2', chapter: '3) 3...Bf5'),
      ]);

      expect(proposal, isNotNull);
      expect(proposal!.mode, ChapterGroupingMode.auto);
      expect(proposal.formatLabel, 'a course export');
      expect(proposal.chapters.map((c) => c.name), [
        '1) 3...c6',
        '2) 3...Bg4',
        '3) 3...Bf5',
      ]);
      expect(proposal.chapters.first.lineCount, 2);
      expect(proposal.groupedLineCount, 5);
      expect(proposal.ungroupedLineCount, 0);
    });

    test('untitled games are reported as ungrouped, not dropped', () {
      final proposal = detectChapterLayout([
        _line('Intro'),
        _line('a', chapter: 'One'),
        _line('b', chapter: 'One'),
        _line('c', chapter: 'Two'),
        _line('d', chapter: 'Two'),
      ]);

      expect(proposal!.chapterCount, 2);
      expect(proposal.ungroupedLineCount, 1);
      expect(proposal.groupedLineCount, 4);
    });

    test('falls back to the name prefix when there are no header chapters', () {
      final proposal = detectChapterLayout([
        _line('Benoni # 1'),
        _line('Benoni # 2'),
        _line('Kings Indian # 1'),
        _line('Kings Indian # 2'),
      ]);

      expect(proposal!.mode, ChapterGroupingMode.namePrefix);
      expect(proposal.chapters.map((c) => c.name), ['Benoni', 'Kings Indian']);
    });

    test('a flat list of unrelated lines proposes nothing', () {
      final proposal = detectChapterLayout([
        _line('Line one'),
        _line('Line two'),
        _line('Line three'),
        _line('Line four'),
      ]);

      expect(proposal, isNull);
    });

    test('one chapter per line is not a grouping', () {
      final proposal = detectChapterLayout([
        _line('a', chapter: 'One'),
        _line('b', chapter: 'Two'),
        _line('c', chapter: 'Three'),
        _line('d', chapter: 'Four'),
      ]);

      expect(
        proposal,
        isNull,
        reason: 'every chapter holding a single line is just the line list',
      );
    });

    test('a mostly untitled file is not chapter-organised', () {
      final proposal = detectChapterLayout([
        _line('a', chapter: 'One'),
        _line('b', chapter: 'One'),
        _line('c'),
        _line('d'),
        _line('e'),
        _line('f'),
      ]);

      expect(proposal, isNull);
    });
  });
}
