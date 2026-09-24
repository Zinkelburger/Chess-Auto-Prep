import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/file_lock.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

const _key = (source: '/repertoires/course.pgn', id: 'line');
const _review = Review(key: _key, lineName: 'Line', lastRating: 'good');
const _streak = MoveStreak(key: _key, ply: 0, streak: 1, learned: false);
final _history = HistoryRow(
  key: _key,
  at: DateTime.utc(2026, 9, 24),
  rating: 'good',
  mistake: false,
  kind: HistoryKind.trainer,
);
final _attempt = Attempt(
  key: _key,
  ply: 0,
  fen: Fen.initial,
  played: 'd4',
  expected: 'e4',
  correct: false,
  phase: AttemptPhase.drilling,
  at: DateTime.utc(2026, 9, 24),
);

Future<ProgressWrite> _rate(TrainingStore store, ProgressOperation operation) =>
    store.write(
      reviews: [(before: null, after: _review)],
      streaks: [(before: null, after: _streak)],
      history: [_history],
      operation: operation,
    );

void main() {
  late Directory documents;
  File file(String name) => File(p.join(documents.path, name));

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('training-retry-');
  });
  tearDown(() => documents.delete(recursive: true));

  for (final boundary in [1, 2, 3]) {
    test(
      'rating retry after replacement $boundary applies each file once',
      () async {
        var publications = 0;
        final store = TrainingStore(
          documents,
          publish: (path, bytes) async {
            await replaceFile(path, bytes);
            if (++publications == boundary) {
              throw const FileSystemException('acknowledgement lost');
            }
          },
        );
        final operation = ProgressOperation();
        expect(await _rate(store, operation), isA<ProgressFailed>());
        expect(await _rate(store, operation), isA<ProgressWritten>());
        expect(await _rate(store, operation), isA<ProgressWritten>());
        expect(await file(historyFile).readAsLines(), hasLength(2));
        expect(publications, 3);
        final loaded = await store.read({_key.source}) as ProgressLoaded;
        expect(loaded.reviews.keys, [_key]);
        expect(loaded.streaks.values.single, _streak);
      },
    );
  }

  for (final attempt in [false, true]) {
    test(
      '${attempt ? 'attempt' : 'rating'} retry after lock acknowledgement',
      () async {
        var loseAcknowledgement = true;
        final store = TrainingStore(
          documents,
          lock: (directory, action) async {
            final result = await withDirectoryLock(directory, action);
            if (loseAcknowledgement) {
              loseAcknowledgement = false;
              throw const FileSystemException(
                'lock release acknowledgement lost',
              );
            }
            return result;
          },
        );
        final operation = ProgressOperation();
        Future<ProgressWrite> write() => attempt
            ? store.logAttempt(_attempt, operation: operation)
            : _rate(store, operation);
        expect(await write(), isA<ProgressFailed>());
        expect(await write(), isA<ProgressWritten>());
        expect(await write(), isA<ProgressWritten>());
        expect(
          await file(attempt ? attemptsFile : historyFile).readAsLines(),
          hasLength(attempt ? 1 : 2),
        );
      },
    );
  }

  test(
    'attempt retry after publication does not append the answer twice',
    () async {
      var publications = 0;
      final store = TrainingStore(
        documents,
        publish: (path, bytes) async {
          await replaceFile(path, bytes);
          if (++publications == 1)
            throw const FileSystemException('disk sync failed');
        },
      );
      final operation = ProgressOperation();
      expect(
        await store.logAttempt(_attempt, operation: operation),
        isA<ProgressFailed>(),
      );
      expect(
        await store.logAttempt(_attempt, operation: operation),
        isA<ProgressWritten>(),
      );
      expect(
        await store.logAttempt(_attempt, operation: operation),
        isA<ProgressWritten>(),
      );
      expect(await file(attemptsFile).readAsLines(), hasLength(1));
      expect(publications, 1);
      expect(
        (await store.read({_key.source}) as ProgressLoaded).mistakes,
        hasLength(1),
      );
    },
  );

  test(
    'retry refuses intervening bytes before applying any remaining file',
    () async {
      var publications = 0;
      final store = TrainingStore(
        documents,
        publish: (path, bytes) async {
          await replaceFile(path, bytes);
          if (++publications == 1)
            throw const FileSystemException('acknowledgement lost');
        },
      );
      final operation = ProgressOperation();
      expect(await _rate(store, operation), isA<ProgressFailed>());
      await file(historyFile).writeAsString('another writer\n');
      expect(await _rate(store, operation), isA<ProgressConflict>());
      expect(await file(historyFile).readAsString(), 'another writer\n');
      expect(await file(streaksFile).exists(), isFalse);
      expect(publications, 1);
    },
  );

  test('operation cannot change its payload or destination', () async {
    var publications = 0;
    final store = TrainingStore(
      documents,
      publish: (path, bytes) async {
        await replaceFile(path, bytes);
        if (++publications == 1)
          throw const FileSystemException('acknowledgement lost');
      },
    );
    final operation = ProgressOperation();
    expect(await _rate(store, operation), isA<ProgressFailed>());
    expect(
      await store.write(history: [_history], operation: operation),
      isA<ProgressConflict>(),
    );
    final other = await Directory(p.join(documents.path, 'other')).create();
    expect(
      await _rate(TrainingStore(other), operation),
      isA<ProgressConflict>(),
    );
    expect(await other.list().isEmpty, isTrue);
    expect(await _rate(store, operation), isA<ProgressWritten>());
  });

  test(
    'separate identical operations remain separate accepted answers',
    () async {
      final store = TrainingStore(documents);
      for (var i = 0; i < 2; i++) {
        expect(await _rate(store, ProgressOperation()), isA<ProgressWritten>());
        expect(
          await store.logAttempt(_attempt, operation: ProgressOperation()),
          isA<ProgressWritten>(),
        );
      }
      expect(await file(historyFile).readAsLines(), hasLength(3));
      expect(await file(attemptsFile).readAsLines(), hasLength(2));
    },
  );

  test('confirmed operation remains acknowledged after later edits', () async {
    final store = TrainingStore(documents);
    final operation = ProgressOperation();
    expect(await _rate(store, operation), isA<ProgressWritten>());
    await file(historyFile).writeAsString('a later edit\n');
    expect(await _rate(store, operation), isA<ProgressWritten>());
    expect(await file(historyFile).readAsString(), 'a later edit\n');
  });
}
