import 'package:chess_auto_prep/services/scid/scid_home_pawns.dart';
import 'package:dartchess/dartchess.dart';
import 'package:flutter_test/flutter_test.dart';

Position _play(Position from, String san) =>
    from.play(from.parseSan(san) as NormalMove);

void main() {
  test('the standard start has every home pawn in place', () {
    expect(ScidHomePawnTracker.signatureOf(Chess.initial), 0xFFFF);
  });

  test('records departures as 15 - index, White a-h then Black a-h', () {
    final tracker = ScidHomePawnTracker();
    Position pos = Chess.initial;
    pos = _play(pos, 'e4');
    tracker.noteMove(pos);
    pos = _play(pos, 'c5');
    tracker.noteMove(pos);
    pos = _play(pos, 'Nf3'); // no pawn moved
    tracker.noteMove(pos);
    pos = _play(pos, 'a6');
    tracker.noteMove(pos);

    // e-file is index 4 → 11; Black c-file is index 10 → 5; Black a is 8 → 7.
    expect(tracker.departures, [11, 5, 7]);
    expect(tracker.count, 3);
  });

  test('packs the count and nibbles high-first into nine bytes', () {
    final tracker = ScidHomePawnTracker();
    Position pos = Chess.initial;
    pos = _play(pos, 'e4');
    tracker.noteMove(pos);
    pos = _play(pos, 'c5');
    tracker.noteMove(pos);
    pos = _play(pos, 'd4');
    tracker.noteMove(pos);

    final bytes = tracker.toBytes();
    expect(bytes, hasLength(ScidHomePawnTracker.recordBytes));
    expect(bytes[0], 3);
    expect(bytes[1], (11 << 4) | 5);
    expect(bytes[2], 12 << 4); // d-file is index 3 → 12
    expect(bytes.sublist(3), everyElement(0));
  });

  test('a captured home pawn counts as a departure', () {
    final tracker = ScidHomePawnTracker();
    Position pos = Chess.initial;
    for (final san in ['e4', 'e5', 'Qh5', 'Nc6', 'Qxf7+']) {
      pos = _play(pos, san);
      tracker.noteMove(pos);
    }
    // e4 leaves e2 (11), e5 leaves e7 (3), Qxf7 takes the pawn on f7 (2).
    expect(tracker.departures, [11, 3, 2]);
  });

  test('a disabled tracker records nothing', () {
    final tracker = ScidHomePawnTracker(enabled: false);
    tracker.noteMove(_play(Chess.initial, 'e4'));
    expect(tracker.count, 0);
    expect(tracker.toBytes(), everyElement(0));
  });
}
