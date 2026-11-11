import 'package:chess_auto_prep/chess/generation/expectimax_options.dart';
import 'package:flutter_test/flutter_test.dart';

ExpectimaxOptions read(Map<String, Object?> json) =>
    ExpectimaxOptions.fromJson(json);

void main() {
  test('a new search keeps four first moves, leaves a reply met less than '
      'once in a hundred games, scores at depth 14 and trusts a database '
      'from ten games', () {
    const options = ExpectimaxOptions.defaults;
    expect(options.rootMoves, 4);
    expect(options.candidateMoves, 1);
    expect(options.rareOnceIn, 100);
    expect(options.replyFloor, 0.01);
    expect(options.evalDepth, 14);
    expect(options.fallbackUnder, 10);
    expect(options.depth, isNull);
    expect(read(const {}), options);
  });

  test('rare at zero searches every reply', () {
    expect(const ExpectimaxOptions(rareOnceIn: 0).replyFloor, 0);
    expect(read({'rareOnceIn': 0}).rareOnceIn, 0);
  });

  test('a setting is read inside its range, ends included, and anything '
      'past an end keeps the default', () {
    void range(
      String key,
      int low,
      int high,
      int Function(ExpectimaxOptions) of,
    ) {
      final fallback = of(ExpectimaxOptions.defaults);
      expect(of(read({key: low})), low, reason: '$key $low');
      expect(of(read({key: high})), high, reason: '$key $high');
      expect(of(read({key: low - 1})), fallback, reason: '$key ${low - 1}');
      expect(of(read({key: high + 1})), fallback, reason: '$key ${high + 1}');
    }

    range('rootMoves', 1, 218, (o) => o.rootMoves);
    range('laterMoves', 1, 218, (o) => o.candidateMoves);
    range('evalDepth', 1, 40, (o) => o.evalDepth);
    range('fallbackUnder', 1, 100000, (o) => o.fallbackUnder);
    expect(read({'rareOnceIn': 100000}).rareOnceIn, 100000);
    expect(read({'rareOnceIn': 100001}).rareOnceIn, 100);
    expect(
      read({'rareOnceIn': 1}).rareOnceIn,
      100,
      reason: 'one is every game',
    );
  });

  test(
    'a depth is read from 1 to 64; outside, or not a number, it is none',
    () {
      expect(read({'depth': 1}).depth, 1);
      expect(read({'depth': 64}).depth, 64);
      expect(read({'depth': 0}).depth, isNull);
      expect(read({'depth': 65}).depth, isNull);
      expect(read({'depth': '8'}).depth, isNull);
    },
  );

  test('every option survives the settings file', () {
    const chosen = ExpectimaxOptions(
      method: SearchMethod.mainline,
      depth: 12,
      rootMoves: 6,
      candidateMoves: 2,
      bothSides: true,
      rareOnceIn: 500,
      evalDepth: 20,
      replies: ReplySource.twic,
      maiaFallback: false,
      fallbackUnder: 30,
    );
    expect(ExpectimaxOptions.fromJson(chosen.toJson()), chosen);
  });
}
