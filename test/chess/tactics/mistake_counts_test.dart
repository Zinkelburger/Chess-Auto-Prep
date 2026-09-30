import 'package:chess_auto_prep/chess/tactics/analyzed_games.dart';
import 'package:chess_auto_prep/chess/tactics/game_ids.dart';
import 'package:chess_auto_prep/chess/tactics/mistake_counts.dart';
import 'package:chess_auto_prep/chess/tactics/puzzle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const one = MistakeCounts(blunders: 1, mistakes: 2);

  test('counts go in the line after the analysed games and read back', () {
    final preamble = withAnalyzed('', {'lichess_a'});
    final written = withMistakes(preamble, {'lichess_a': one});
    final lines = written.split('\n');
    expect(lines[0], startsWith(analyzedGamesPrefix));
    expect(lines[1], startsWith(mistakeCountsPrefix));
    expect(analyzedIn(written), {'lichess_a'});
    expect(mistakesIn(written), {'lichess_a': one});
  });

  test('a later game is added to the counts already there', () {
    final first = withMistakes(withAnalyzed('', {'a'}), {'a': one});
    final both = withMistakes(first, {'b': const MistakeCounts()});
    expect(mistakesIn(both), {'a': one, 'b': const MistakeCounts()});
    expect(
      both.split('\n').where((l) => l.startsWith(mistakeCountsPrefix)),
      hasLength(1),
    );
  });

  test('a line that cannot be read is no counts, not a failure', () {
    expect(mistakesIn('${mistakeCountsPrefix}not base64!\n'), isEmpty);
    expect(mistakesIn(''), isEmpty);
  });

  test('counts add up by kind and print as the rows show them', () {
    final counts = const MistakeCounts()
        .plus(MistakeKind.blunder)
        .plus(MistakeKind.inaccuracy)
        .plus(MistakeKind.inaccuracy);
    expect(counts.glyphs, '1?? 2?!');
    expect(const MistakeCounts().glyphs, 'clean');
    expect(counts.words, '1 blunder, 2 inaccuracies');
    expect(const MistakeCounts().words, 'No mistakes');
  });

  test('a game\'s speed comes from its time control', () {
    String game(String control) => '[TimeControl "$control"]\n\n1. e4 *';
    expect(speedIn(game('60+0')), GameSpeed.bullet);
    expect(speedIn(game('180+2')), GameSpeed.blitz);
    expect(speedIn(game('600+0')), GameSpeed.rapid);
    expect(speedIn(game('1800+30')), GameSpeed.classical);
    expect(speedIn(game('1/259200')), GameSpeed.classical);
    expect(speedIn('1. e4 *'), isNull);
    expect(keepsSpeed({GameSpeed.blitz}, '1. e4 *'), isTrue);
    expect(keepsSpeed({GameSpeed.blitz}, game('60+0')), isFalse);
  });
}
