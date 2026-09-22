import 'package:chess_auto_prep/v2/chess/explorer_answer.dart';
import 'package:chess_auto_prep/v2/chess/explorer_choice.dart';
import 'package:chess_auto_prep/v2/storage/settings.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a game count fits a gutter: 812, 1.2k, 12k, 1.2M', () {
    expect(formatGameCount(812), '812');
    expect(formatGameCount(1234), '1.2k');
    expect(formatGameCount(12345), '12k');
    expect(formatGameCount(1000), '1k');
    expect(formatGameCount(1234567), '1.2M');
  });

  test('a share is a whole percent, and <1% under half a percent', () {
    expect(formatShare(31, 100), '31%');
    expect(formatShare(1, 1000), '<1%');
    expect(formatShare(5, 1000), '1%');
    expect(formatShare(3, 0), '0%');
  });

  test('the answer sums its moves unless the database gave totals', () {
    const moves = [
      ExplorerMove(uci: 'e2e4', san: 'e4', white: 10, draws: 5, black: 3),
      ExplorerMove(uci: 'd2d4', san: 'd4', white: 1, draws: 1, black: 1),
    ];
    const summed = ExplorerAnswer(moves: moves);
    expect(summed.whiteTotal, 11);
    expect(summed.drawTotal, 6);
    expect(summed.blackTotal, 4);
    expect(summed.total, 21);
    const given = ExplorerAnswer(moves: moves, white: 100, draws: 50, black: 1);
    expect(given.whiteTotal, 100);
    expect(given.total, 21, reason: 'the shares are against the moves');
    expect(ExplorerAnswer.empty.isEmpty, isTrue);
  });

  test('the choice summarises itself as one line', () {
    expect(ExplorerChoice.defaults.summary, 'Masters');
    expect(
      const ExplorerChoice(source: ExplorerSource.lichess).summary,
      'Lichess · blitz rapid classical · 2000+',
    );
    expect(
      const ExplorerChoice(
        source: ExplorerSource.lichess,
        speeds: {LichessSpeed.bullet},
        ratings: {1600, 2200},
      ).summary,
      'Lichess · bullet · 1600 2200',
    );
    expect(
      const ExplorerChoice(
        source: ExplorerSource.twic,
        classicalOnly: true,
      ).summary,
      'TWIC · classical only',
    );
  });

  test('the choice survives the settings file, and a missing or unknown '
      'part is the default', () {
    const chosen = ExplorerChoice(
      source: ExplorerSource.lichess,
      speeds: {LichessSpeed.rapid, LichessSpeed.bullet},
      ratings: {1800},
      classicalOnly: true,
    );
    final text = const Settings(explorer: chosen).toJson();
    expect(Settings.fromJson(text).explorer, chosen);
    expect(Settings.fromJson('{}').explorer, ExplorerChoice.defaults);
    expect(
      ExplorerChoice.fromJson({
        'source': 'nowhere',
        'speeds': ['blitz', 'walking'],
        'ratings': [2000, 1234],
      }),
      const ExplorerChoice(speeds: {LichessSpeed.blitz}, ratings: {2000}),
    );
  });
}
