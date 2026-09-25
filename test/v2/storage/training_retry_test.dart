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

void main() {
  late Directory documents;
  late LineKey key;
  late Review review;
  late MoveStreak streak;
  late HistoryRow history;
  late Attempt answer;
  late ProgressLoaded admission;

  ProgressOperation accepted() => ProgressOperation(sources: admission.sources);

  Future<ProgressWrite> rate(
    TrainingStore store,
    ProgressOperation operation,
  ) => store.write(
    reviews: [(before: null, after: review)],
    streaks: [(before: null, after: streak)],
    history: [history],
    operation: operation,
  );
  File file(String name) => File(p.join(documents.path, name));

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('training-retry-');
    final source = p.join(documents.path, 'repertoires', 'course.pgn');
    await File(source).parent.create(recursive: true);
    await File(source).writeAsString('[Event "Line"]\n\n1. e4 *\n');
    key = (source: source, id: 'line');
    review = Review(key: key, lineName: 'Line', lastRating: 'good');
    streak = MoveStreak(key: key, ply: 0, streak: 1, learned: false);
    history = HistoryRow(
      key: key,
      at: DateTime.utc(2026, 9, 24),
      rating: 'good',
      mistake: false,
      kind: HistoryKind.trainer,
    );
    answer = Attempt(
      key: key,
      ply: 0,
      fen: Fen.initial,
      played: 'd4',
      expected: 'e4',
      correct: false,
      phase: AttemptPhase.drilling,
      at: DateTime.utc(2026, 9, 24),
    );
    // Read the real source before installing publication/acknowledgement
    // faults. Every retry below keeps this admission and its operation token.
    admission =
        await TrainingStore(
              documents,
              support: Directory(p.join(documents.path, 'Support')),
            ).read({source})
            as ProgressLoaded;
  });
  tearDown(() => documents.delete(recursive: true));

  for (final boundary in [1, 2, 3]) {
    test(
      'rating retry after replacement $boundary applies each file once',
      () async {
        var publications = 0;
        final store = TrainingStore(
          documents,
          support: Directory(p.join(documents.path, 'Support')),
          publish: (path, bytes) async {
            await replaceFile(path, bytes);
            if (++publications == boundary) {
              throw const FileSystemException('acknowledgement lost');
            }
          },
        );
        final operation = accepted();
        expect(await rate(store, operation), isA<ProgressFailed>());
        expect(await rate(store, operation), isA<ProgressWritten>());
        expect(await rate(store, operation), isA<ProgressWritten>());
        expect(await file(historyFile).readAsLines(), hasLength(2));
        expect(publications, 3);
        final loaded = await store.read({key.source}) as ProgressLoaded;
        expect(loaded.reviews.keys, [key]);
        expect(loaded.streaks.values.single, streak);
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
          support: Directory(p.join(documents.path, 'Support')),
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
        final operation = accepted();
        Future<ProgressWrite> write() => attempt
            ? store.logAttempt(answer, operation: operation)
            : rate(store, operation);
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
        support: Directory(p.join(documents.path, 'Support')),
        publish: (path, bytes) async {
          await replaceFile(path, bytes);
          if (++publications == 1)
            throw const FileSystemException('disk sync failed');
        },
      );
      final operation = accepted();
      expect(
        await store.logAttempt(answer, operation: operation),
        isA<ProgressFailed>(),
      );
      expect(
        await store.logAttempt(answer, operation: operation),
        isA<ProgressWritten>(),
      );
      expect(
        await store.logAttempt(answer, operation: operation),
        isA<ProgressWritten>(),
      );
      expect(await file(attemptsFile).readAsLines(), hasLength(1));
      expect(publications, 1);
      expect(
        (await store.read({key.source}) as ProgressLoaded).mistakes,
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
        support: Directory(p.join(documents.path, 'Support')),
        publish: (path, bytes) async {
          await replaceFile(path, bytes);
          if (++publications == 1)
            throw const FileSystemException('acknowledgement lost');
        },
      );
      final operation = accepted();
      expect(await rate(store, operation), isA<ProgressFailed>());
      await file(historyFile).writeAsString('another writer\n');
      expect(await rate(store, operation), isA<ProgressConflict>());
      expect(await file(historyFile).readAsString(), 'another writer\n');
      expect(await file(streaksFile).exists(), isFalse);
      expect(publications, 1);
    },
  );

  test('operation cannot change its payload or destination', () async {
    var publications = 0;
    final store = TrainingStore(
      documents,
      support: Directory(p.join(documents.path, 'Support')),
      publish: (path, bytes) async {
        await replaceFile(path, bytes);
        if (++publications == 1)
          throw const FileSystemException('acknowledgement lost');
      },
    );
    final operation = accepted();
    expect(await rate(store, operation), isA<ProgressFailed>());
    expect(
      await store.write(history: [history], operation: operation),
      isA<ProgressConflict>(),
    );
    final other = await Directory(p.join(documents.path, 'other')).create();
    expect(
      await rate(
        TrainingStore(other, support: Directory(p.join(other.path, 'Support'))),
        operation,
      ),
      isA<ProgressConflict>(),
    );
    expect(await other.list().isEmpty, isTrue);
    expect(await rate(store, operation), isA<ProgressWritten>());
  });

  test(
    'separate identical operations remain separate accepted answers',
    () async {
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
      );
      for (var i = 0; i < 2; i++) {
        expect(await rate(store, accepted()), isA<ProgressWritten>());
        expect(
          await store.logAttempt(answer, operation: accepted()),
          isA<ProgressWritten>(),
        );
      }
      expect(await file(historyFile).readAsLines(), hasLength(3));
      expect(await file(attemptsFile).readAsLines(), hasLength(2));
    },
  );

  test('confirmed operation remains acknowledged after later edits', () async {
    final store = TrainingStore(
      documents,
      support: Directory(p.join(documents.path, 'Support')),
    );
    final operation = accepted();
    expect(await rate(store, operation), isA<ProgressWritten>());
    await file(historyFile).writeAsString('a later edit\n');
    expect(await rate(store, operation), isA<ProgressWritten>());
    expect(await file(historyFile).readAsString(), 'a later edit\n');
  });
}
