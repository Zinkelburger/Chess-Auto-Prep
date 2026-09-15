import 'package:chess_auto_prep/services/engine/uci_info_line.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('parses a full Stockfish info line', () {
    final info = UciInfoLine.parse(
      'info depth 22 seldepth 30 multipv 2 score cp -37 nodes 1234567 '
      'nps 987654 hashfull 120 tbhits 0 time 1250 pv e7e5 g1f3 b8c6',
    );
    expect(info.depth, 22);
    expect(info.multiPv, 2);
    expect(info.scoreCp, -37);
    expect(info.scoreMate, isNull);
    expect(info.nodes, 1234567);
    expect(info.nps, 987654);
    expect(info.pv, ['e7e5', 'g1f3', 'b8c6']);
  });

  test('a mate score clears cp and the pv runs to the end of the line', () {
    final info = UciInfoLine.parse('info depth 5 score mate -3 pv e1g1 h7h6');
    expect(info.scoreMate, -3);
    expect(info.scoreCp, isNull);
    expect(info.pv, ['e1g1', 'h7h6']);
  });

  test('absent fields are null and a missing pv stays null', () {
    final info = UciInfoLine.parse('info depth 3 score cp 10');
    expect(info.multiPv, isNull);
    expect(info.nodes, isNull);
    expect(info.nps, isNull);
    expect(info.pv, isNull);
  });

  test('unparseable values follow the worker conventions', () {
    final info = UciInfoLine.parse(
      'info depth x multipv y score cp z nodes n nps m',
    );
    expect(info.depth, isNull);
    expect(info.multiPv, isNull);
    expect(info.scoreCp, isNull);
    expect(info.nodes, 0);
    expect(info.nps, 0);
  });

  test('a bound annotation does not hide the score', () {
    final info = UciInfoLine.parse(
      'info depth 12 score cp 55 lowerbound nodes 10 pv d2d4',
    );
    expect(info.scoreCp, 55);
    expect(info.pv, ['d2d4']);
  });

  test('truncated trailing keys are ignored', () {
    final info = UciInfoLine.parse('info depth 4 score cp 7 pv');
    expect(info.depth, 4);
    expect(info.scoreCp, 7);
    expect(info.pv, isNull);
  });
}
