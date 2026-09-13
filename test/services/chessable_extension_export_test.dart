import 'dart:io';

import 'package:dartchess/dartchess.dart' show PgnGame;
import 'package:flutter_test/flutter_test.dart';

import 'package:chess_auto_prep/services/repertoire_service.dart';

/// The browser extension in `tools/chessable_extension` writes lines in the
/// Chessable-export shape. Its fixture output must load like a course export.
void main() {
  final fixture = File(
    'tools/chessable_extension/fixture/expected.pgn',
  ).readAsStringSync();

  test('extension output loads as one trainable line with its comments', () {
    final lines = RepertoireService().parseRepertoirePgn(
      fixture,
      inferColorWhenUnknown: true,
    );
    expect(lines, hasLength(1));
    final line = lines.single;
    expect(line.moves, [
      'e4', 'e5', 'Nf3', 'Nc6', 'Bb5', 'a6', 'Bxc6', 'dxc6', 'Nxe5', 'Qd4', //
    ]);
    expect(line.comments['6'], contains('Google Maps'));
    expect(line.comments['7'], contains('c8-bishop'));
    expect(line.comments['9'], contains('Case closed'));
  });

  test('position glyph survives as a NAG on the move', () {
    final game = PgnGame.parsePgn(fixture);
    final last = game.moves.mainline().last;
    expect(last.san, 'Qd4');
    expect(last.nags, [15]);
  });

  test('a course file groups by the chapter in the White header', () {
    String game(String chapter, String title, String moves) => [
      '[Event "Course"]',
      '[Site "https://www.chessable.com/variation/1/"]',
      '[Date "????.??.??"]',
      '[Round "?"]',
      '[White "$chapter"]',
      '[Black "$title"]',
      '[Result "*"]',
      '',
      '$moves *',
      '',
    ].join('\n');
    final course = [
      game(
        '1) Exchange',
        '5.Nxe5',
        '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Bxc6 dxc6',
      ),
      game(
        '1) Exchange',
        '5.d3',
        '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Bxc6 dxc6 5. d3',
      ),
      game('2) Norwegian', '6.O-O', '1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Ba4 b5'),
    ].join('\n');
    final chapters = RepertoireService().courseChaptersOf(course);
    expect(chapters.map((c) => c.name), ['1) Exchange', '2) Norwegian']);
    expect(chapters.map((c) => c.lineCount), [2, 1]);
    final lines = RepertoireService().parseRepertoirePgn(
      course,
      inferColorWhenUnknown: true,
    );
    expect(lines.map((l) => l.name), ['5.Nxe5', '5.d3', '6.O-O']);
    expect(lines.map((l) => l.chapter), [
      '1) Exchange',
      '1) Exchange',
      '2) Norwegian',
    ]);
  });

  test('a single downloaded line is named by its Opening header', () {
    const single = '''
[Event "Ruy Lopez course"]
[Site "https://www.chessable.com/variation/1/"]
[Date "????.??.??"]
[Round "?"]
[White "?"]
[Black "Exchange Variation 5.Nxe5"]
[Result "*"]
[Opening "Exchange Variation 5.Nxe5"]

1. e4 e5 2. Nf3 Nc6 3. Bb5 a6 4. Bxc6 dxc6 5. Nxe5 Qd4 *
''';
    final lines = RepertoireService().parseRepertoirePgn(
      single,
      inferColorWhenUnknown: true,
    );
    expect(lines.single.name, 'Exchange Variation 5.Nxe5');
    expect(lines.single.chapter, isNull);
  });
}
