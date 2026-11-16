import 'dart:convert';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/storage/csv_records.dart';
import 'package:chess_auto_prep/storage/training_payload.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';

const _from = '/home/u/Documents/repertoires/KID/Main.pgn';
const _to = '/home/u/Documents/repertoires/KID/Sidelines.pgn';

String _attempt({int ply = 0, String id = 'a'}) => encodeAttempt(
  Attempt(
    key: (source: _from, id: id),
    ply: ply,
    fen: Fen.initial,
    played: 'e4',
    expected: 'e4',
    correct: true,
    phase: AttemptPhase.learning,
    at: DateTime.utc(2026, 11, 12),
  ),
);

String _streak({String id = 'a'}) => encodeCsvRecord(
  encodeStreak(
    MoveStreak(key: (source: _from, id: id), ply: 0, streak: 1, learned: false),
  ),
);

String _review() => encodeCsvRecord(
  encodeReview(const Review(key: (source: _from, id: 'a'), lineName: 'Main')),
);

String _write({
  List<Object?> reviews = const [],
  List<Object?> streaks = const [],
  List<Object?> history = const [],
}) => jsonEncode(['write', reviews, streaks, history]);

void main() {
  test('an answer reads back as itself', () {
    final line = _attempt();
    expect(TrainingPayload.decode(jsonEncode(['attempt', line])).attempt, line);
  });

  test('an answer at a negative move or with no line id is refused', () {
    for (final line in [_attempt(ply: -1), _attempt(id: '')]) {
      expect(
        () => TrainingPayload.decode(jsonEncode(['attempt', line])),
        throwsFormatException,
        reason: line,
      );
    }
  });

  test('a two-item payload that is not an answer is refused plainly', () {
    for (final payload in [
      ['answer', _attempt()],
      ['attempt', 5],
      ['write', 5],
    ]) {
      expect(
        () => TrainingPayload.decode(jsonEncode(payload)),
        throwsFormatException,
        reason: '$payload',
      );
    }
  });

  test('a new row needs no earlier one', () {
    final payload = TrainingPayload.decode(
      _write(
        streaks: [
          [null, _streak()],
        ],
      ),
    );
    expect(payload.streaks.single.before, isNull);
  });

  test('a review row with the right cells but a value it cannot read is '
      'refused', () {
    final cells = readCsvRecords(_review());
    final fields = [...(cells as CsvParsed).records.single.fields];
    fields[3] = 'not a number';
    expect(
      () => TrainingPayload.decode(
        _write(
          reviews: [
            [null, encodeCsvRecord(fields)],
          ],
        ),
      ),
      throwsFormatException,
    );
  });

  test('a chapter move repoints the history rows that named it', () {
    final payload = TrainingPayload.decode(
      _write(
        history: [
          [_from, 'a', '2026-11-12T00:00:00.000Z', 'good', '0', 'trainer'],
        ],
      ),
    );
    final moved = TrainingPayload.decode(payload.relocated({_from: _to}));
    expect(moved.history.single.first, _to);
  });

  test('a move of another chapter leaves the history rows as they were', () {
    const row = [
      _from,
      'a',
      '2026-11-12T00:00:00.000Z',
      'good',
      '0',
      'trainer',
    ];
    final payload = TrainingPayload.decode(_write(history: [row]));
    final kept = TrainingPayload.decode(payload.relocated({_to: _from}));
    expect(kept.history.single, row);
  });

  test('an earlier row that is not text is refused plainly', () {
    expect(
      () => TrainingPayload.decode(
        _write(
          streaks: [
            [5, _streak()],
          ],
        ),
      ),
      throwsFormatException,
    );
  });
}
