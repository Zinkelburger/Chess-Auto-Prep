import 'dart:convert';
import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/file_lock.dart';
import 'package:chess_auto_prep/v2/storage/training_writes.dart';
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

  for (final boundary in [1]) {
    test(
      'fresh storage recovers a partially published rating before read',
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
        final reopened = TrainingStore(
          documents,
          support: Directory(p.join(documents.path, 'Support')),
        );
        final loaded = await reopened.read({key.source}) as ProgressLoaded;
        expect(loaded.streaks.values, [streak]);
        expect(await file(historyFile).readAsLines(), hasLength(2));
        expect(loaded.reviews.keys, [key]);
        expect(loaded.streaks.values.single, streak);
      },
    );
  }

  TrainingStore normal() => TrainingStore(
    documents,
    support: Directory(p.join(documents.path, 'Support')),
  );
  Future<List<Map<String, Object?>>> notes() async => [
    await for (final entry in Directory(
      p.join(documents.path, 'Support', 'training-writes'),
    ).list())
      if (entry is File)
        jsonDecode(await entry.readAsString()) as Map<String, Object?>,
  ];

  test(
    'queued successor survives failed predecessor without its original owners',
    () async {
      var writes = 0;
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
        publish: (path, bytes) async {
          await replaceFile(path, bytes);
          if (++writes == 1) throw const FileSystemException('lost ack');
        },
      );
      final a = accepted();
      expect(await rate(store, a), isA<ProgressFailed>());
      final b = ProgressOperation(
        sources: admission.sources,
        predecessorId: a.id,
      );
      expect(
        await store.enqueueWrite(
          reviews: [(before: review, after: review.copyWith(excluded: true))],
          history: [history],
          operation: b,
        ),
        isA<ProgressEnqueued>(),
      );
      expect(writes, 1, reason: 'enqueue does not replay failed predecessor');
      expect((await notes()).map((n) => n['state']), contains('queued'));
      final loaded = await normal().read({key.source}) as ProgressLoaded;
      expect(loaded.reviews[key]!.excluded, isTrue);
      expect(loaded.streaks.values.single, streak);
      expect(await file(historyFile).readAsLines(), hasLength(3));
      await normal().read({key.source});
      expect(await file(historyFile).readAsLines(), hasLength(3));
      for (final receipt in await notes()) {
        expect(receipt['state'], 'complete');
        expect(receipt['payload'], isNull);
        expect(receipt['files'], isNull);
      }
    },
  );

  test(
    'missing acceptance predecessor cannot be sequenced after its successor',
    () async {
      var fail = true;
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
        lock: (directory, action) {
          if (fail) {
            fail = false;
            throw const FileSystemException('enqueue unavailable');
          }
          return withDirectoryLock(directory, action);
        },
      );
      final a = accepted();
      final b = ProgressOperation(
        sources: admission.sources,
        predecessorId: a.id,
      );
      expect(
        await store.enqueueWrite(
          reviews: [(before: null, after: review)],
          operation: a,
        ),
        isA<ProgressRejected>(),
      );
      expect(
        await store.enqueueWrite(
          reviews: [(before: review, after: review.copyWith(excluded: true))],
          operation: b,
        ),
        isA<ProgressRejected>(),
      );
      expect(
        await store.enqueueWrite(
          reviews: [(before: null, after: review)],
          operation: a,
        ),
        isA<ProgressEnqueued>(),
      );
      expect(
        await store.enqueueWrite(
          reviews: [(before: review, after: review.copyWith(excluded: true))],
          operation: b,
        ),
        isA<ProgressEnqueued>(),
      );
      final loaded = await normal().read({key.source}) as ProgressLoaded;
      expect(loaded.reviews[key]!.excluded, isTrue);
      final ordered = await notes()
        ..sort(
          (a, b) => (a['sequence']! as int).compareTo(b['sequence']! as int),
        );
      expect(ordered.map((n) => n['id']), [a.id, b.id]);
    },
  );

  test('distinct identical attempts recover exactly once each', () async {
    final store = normal();
    final a = accepted();
    final b = ProgressOperation(
      sources: admission.sources,
      predecessorId: a.id,
    );
    expect(
      await store.enqueueAttempt(answer, operation: a),
      isA<ProgressEnqueued>(),
    );
    expect(
      await store.enqueueAttempt(answer, operation: b),
      isA<ProgressEnqueued>(),
    );
    expect(
      (await normal().read({key.source}) as ProgressLoaded).mistakes,
      hasLength(2),
    );
    expect(
      await normal().enqueueAttempt(
        answer,
        operation: ProgressOperation(id: a.id, sources: admission.sources),
      ),
      isA<ProgressEnqueued>(),
    );
    expect(await file(attemptsFile).readAsLines(), hasLength(2));
    await normal().read({key.source});
    expect(await file(attemptsFile).readAsLines(), hasLength(2));
  });

  test('same id cannot change its command or dependency', () async {
    final store = normal();
    final a = accepted();
    expect(
      await store.enqueueAttempt(answer, operation: a),
      isA<ProgressEnqueued>(),
    );
    expect(
      await store.enqueueWrite(
        history: [history],
        operation: ProgressOperation(id: a.id, sources: admission.sources),
      ),
      isA<ProgressRejected>(),
    );
    expect(
      await store.enqueueAttempt(
        answer,
        operation: ProgressOperation(
          id: a.id,
          sources: admission.sources,
          predecessorId: 'unrelated',
        ),
      ),
      isA<ProgressRejected>(),
    );
    expect(
      (await normal().read({key.source}) as ProgressLoaded).mistakes,
      hasLength(1),
    );
  });

  test(
    'unchanged fourth participant is checked before recovery publishes anything',
    () async {
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
        trainingHook: (step) async {
          if (step == TrainingWriteStep.intent) throw StateError('interrupted');
        },
      );
      expect(await rate(store, accepted()), isA<ProgressFailed>());
      await file(attemptsFile).writeAsString('external answer\n');
      expect(await normal().read({key.source}), isA<ProgressFailed>());
      expect(await file(reviewsFile).exists(), isFalse);
      expect(await file(streaksFile).exists(), isFalse);
      expect(await file(historyFile).exists(), isFalse);
      expect(await file(attemptsFile).readAsString(), 'external answer\n');
    },
  );

  test(
    'staged participant symlink is preserved without touching its target',
    () async {
      final outside = await file('outside').writeAsString('untouched');
      final stage = Link(temporaryPathFor(file(reviewsFile).path));
      await stage.create(outside.path);
      expect(await rate(normal(), accepted()), isA<ProgressFailed>());
      expect(await outside.readAsString(), 'untouched');
      expect(await stage.exists(), isTrue);
    },
    skip: !Platform.isLinux,
  );

  test(
    'pending historical source alias must still resolve to the pinned profile',
    () async {
      final alias = Link('${documents.path}-alias');
      final other = await Directory('${documents.path}-other').create();
      addTearDown(() async {
        await alias.delete();
        await other.delete(recursive: true);
      });
      await alias.create(documents.path);
      final aliased = p.join(alias.path, 'repertoires', 'course.pgn');
      final store = TrainingStore(
        Directory(alias.path),
        support: Directory(p.join(documents.path, 'Support')),
      );
      final sources = (await store.read({aliased}) as ProgressLoaded).sources;
      final row = Review(key: (source: aliased, id: 'line'), lineName: 'Line');
      expect(
        await store.enqueueWrite(
          reviews: [(before: null, after: row)],
          operation: ProgressOperation(sources: sources),
        ),
        isA<ProgressEnqueued>(),
      );
      await alias.delete();
      await alias.create(other.path);
      expect(await normal().read({key.source}), isA<ProgressFailed>());
      expect(await file(reviewsFile).exists(), isFalse);
    },
    skip: !Platform.isLinux,
  );
  test(
    'known stale row is refused before accepting an unreplayable command',
    () async {
      final store = normal();
      expect(await rate(store, accepted()), isA<ProgressWritten>());
      final before = await file(reviewsFile).readAsString();
      final result = await store.enqueueWrite(
        reviews: [
          (
            before: review.copyWith(passes: 1),
            after: review.copyWith(passes: 3),
          ),
        ],
        operation: accepted(),
      );
      expect(result, isA<ProgressRejected>());
      expect(await notes(), hasLength(1));
      expect(await normal().read({key.source}), isA<ProgressLoaded>());
      expect(await file(reviewsFile).readAsString(), before);
    },
  );

  test(
    'completed receipt behind queued predecessor is impossible and blocks reads',
    () async {
      final store = normal();
      final a = accepted();
      final b = ProgressOperation(
        sources: admission.sources,
        predecessorId: a.id,
      );
      await store.enqueueAttempt(answer, operation: a);
      await store.enqueueAttempt(answer, operation: b);
      final path = File(
        p.join(documents.path, 'Support', 'training-writes', '${b.id}.json'),
      );
      final impossible =
          jsonDecode(await path.readAsString()) as Map<String, Object?>;
      impossible
        ..['state'] = 'complete'
        ..['payload'] = null
        ..['files'] = null
        ..['planDigest'] = '0' * 64;
      await path.writeAsString(jsonEncode(impossible));
      expect(await normal().read({key.source}), isA<ProgressFailed>());
      expect(await file(attemptsFile).exists(), isFalse);
    },
  );

  test('Documents and Support may share one canonical lock', () async {
    final store = TrainingStore(documents, support: documents);
    expect(await rate(store, accepted()), isA<ProgressWritten>());
    expect((await store.read({key.source}) as ProgressLoaded).reviews.keys, [
      key,
    ]);
  }, timeout: const Timeout(Duration(seconds: 10)));
}
