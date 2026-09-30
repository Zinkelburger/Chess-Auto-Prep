import 'dart:async';
import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/chess/training/training_line.dart';
import 'package:chess_auto_prep/features/trainer/progress.dart';
import 'package:chess_auto_prep/storage/atomic_write.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/file_lock.dart';
import 'package:chess_auto_prep/storage/pending_writes.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../support/fixtures.dart';
import 'store_fixture.dart';

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

  test('a retry keeps rows another writer added in between', () async {
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
    await file(historyFile).writeAsString('$historyHeader\nanother,writer\n');
    expect(await rate(store, operation), isA<ProgressWritten>());
    final lines = await file(historyFile).readAsLines();
    expect(lines.take(2), [historyHeader, 'another,writer']);
    expect(lines, hasLength(3));
    expect(await file(streaksFile).exists(), isTrue);
  });

  test(
    'a commit that waited behind the one that refused its change says so',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      var first = true;
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
        lock: (directory, action) async {
          if (first) {
            first = false;
            entered.complete();
            await release.future;
          }
          return withDirectoryLock(directory, action);
        },
      );
      // No row equals this change's `before`, so it can never be written.
      final refused = accepted();
      expect(
        await store.enqueueWrite(
          reviews: [
            (before: review, after: review.copyWith(lastRating: 'easy')),
          ],
          operation: refused,
        ),
        isA<ProgressEnqueued>(),
      );
      final logged = accepted();
      expect(
        await store.enqueueAttempt(answer, operation: logged),
        isA<ProgressEnqueued>(),
      );
      final loggedDone = store.commit(logged);
      await entered.future;
      final refusedDone = store.commit(refused);
      release.complete();
      expect(await loggedDone, isA<ProgressWritten>());
      expect(await refusedDone, isA<ProgressConflict>());
      expect(await file(reviewsFile).exists(), isFalse);
      expect(await file(attemptsFile).readAsLines(), hasLength(1));
    },
  );

  group('a rating whose write failed', () {
    late Review rerated;
    late MoveStreak restreaked;
    late HistoryRow again;

    setUp(() {
      rerated = review.copyWith(lastRating: 'easy');
      restreaked = MoveStreak(key: key, ply: 0, streak: 2, learned: true);
      again = HistoryRow(
        key: key,
        at: DateTime.utc(2026, 9, 25),
        rating: 'easy',
        mistake: false,
        kind: HistoryKind.trainer,
      );
    });

    Future<ProgressWrite> rateAgain(TrainingStore store, ProgressLoaded read) =>
        store.write(
          reviews: [(before: read.reviews[key], after: rerated)],
          streaks: [
            (before: read.streaks[(line: key, ply: 0)], after: restreaked),
          ],
          history: [again],
          operation: ProgressOperation(sources: read.sources),
        );

    test('is read back and written before the next rating', () async {
      var failures = 1;
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
        publish: (path, bytes) async {
          if (failures-- > 0) {
            throw const FileSystemException('sharing violation');
          }
          await replaceFile(path, bytes);
        },
      );
      expect(await rate(store, accepted()), isA<ProgressFailed>());
      final reloaded = await store.read({key.source}) as ProgressLoaded;
      expect(reloaded.reviews[key], review);
      expect(reloaded.streaks[(line: key, ply: 0)], streak);
      expect(await rateAgain(store, reloaded), isA<ProgressWritten>());
      expect(await file(historyFile).readAsLines(), hasLength(3));
      final fresh = await store.read({key.source}) as ProgressLoaded;
      expect(fresh.reviews[key], rerated);
      expect(fresh.streaks[(line: key, ply: 0)], restreaked);
    });

    test('is read back while its files still cannot be written', () async {
      var failing = true;
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
        publish: (path, bytes) async {
          if (failing) throw const FileSystemException('sharing violation');
          await replaceFile(path, bytes);
        },
      );
      expect(await rate(store, accepted()), isA<ProgressFailed>());
      expect(
        await store.logAttempt(answer, operation: accepted()),
        isA<ProgressFailed>(),
      );
      final reloaded = await store.read({key.source}) as ProgressLoaded;
      expect(reloaded.reviews[key], review);
      expect(reloaded.streaks[(line: key, ply: 0)], streak);
      expect(reloaded.mistakes.single.played, answer.played);
      expect(await file(reviewsFile).exists(), isFalse);
      failing = false;
      expect(await rateAgain(store, reloaded), isA<ProgressWritten>());
      expect(await file(historyFile).readAsLines(), hasLength(3));
      expect(await file(attemptsFile).readAsLines(), hasLength(1));
      final fresh = await store.read({key.source}) as ProgressLoaded;
      expect(fresh.reviews[key], rerated);
      expect(fresh.mistakes.single.played, answer.played);
    });

    test('shows a mistake already published once', () async {
      var failing = true;
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
        trainingHook: (_) async {
          if (failing) throw const FileSystemException('sync failed');
        },
      );
      expect(
        await store.logAttempt(answer, operation: accepted()),
        isA<ProgressFailed>(),
      );
      expect(await file(attemptsFile).readAsLines(), hasLength(1));
      final reloaded = await store.read({key.source}) as ProgressLoaded;
      expect(reloaded.mistakes, hasLength(1));
      failing = false;
      final fresh = await store.read({key.source}) as ProgressLoaded;
      expect(fresh.mistakes, hasLength(1));
      expect(await file(attemptsFile).readAsLines(), hasLength(1));
    });
  });

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

  group('a change accepted before its chapter moved', () {
    late StoreFixture fixture;
    late DocumentRef source;
    late Opened opened;

    setUp(() async {
      fixture = await StoreFixture.create();
      source = fixture.ref('repertoires/Course/Main.pgn');
      await fixture.put(source, oneGame('1. e4'));
      opened = await fixture.store.open(source) as Opened;
    });
    tearDown(() => fixture.dispose());

    /// Moves [source] as [mutation] says and returns where it went.
    Future<String> relocate(String mutation) async {
      switch (mutation) {
        case 'delete':
          final deleted =
              await fixture.store.delete(source, expected: opened.revision)
                  as Deleted;
          return deleted.recoveredTo;
        case 'folder move':
          final folder = p.dirname(source.path);
          final to = p.join(p.dirname(folder), 'Moved');
          expect(
            await fixture.store.moveFolder(folder, to),
            isA<FolderMoved>(),
          );
          return p.join(to, 'Main.pgn');
        default:
          expect(
            await fixture.store.rename(
              source,
              'Moved.pgn',
              expected: opened.revision,
            ),
            isA<Moved>(),
          );
          return p.join(p.dirname(source.path), 'Moved.pgn');
      }
    }

    for (final mutation in ['rename', 'folder move', 'delete']) {
      // A sharing violation before anything lands, and an acknowledgement
      // lost after the history row did.
      for (final failing in [reviewsFile, historyFile]) {
        test('follows a $mutation after $failing failed', () async {
          var failures = 1;
          final store = TrainingStore(
            fixture.documents,
            support: fixture.support,
            publish: (path, bytes) async {
              if (p.basename(path) == failing && failures-- > 0) {
                if (failing == historyFile) await replaceFile(path, bytes);
                throw const FileSystemException('sharing violation');
              }
              await replaceFile(path, bytes);
            },
          );
          final line = (source: source.path, id: 'l1');
          final loaded =
              await store.read(
                    {source.path},
                    observed: {source.path: opened.revision},
                  )
                  as ProgressLoaded;
          expect(
            await store.write(
              reviews: [
                (before: null, after: Review(key: line, lineName: 'L1')),
              ],
              history: [
                HistoryRow(
                  key: line,
                  at: DateTime.utc(2026, 9, 29),
                  rating: 'good',
                  mistake: false,
                  kind: HistoryKind.trainer,
                ),
              ],
              operation: ProgressOperation(sources: loaded.sources),
            ),
            isA<ProgressFailed>(),
          );
          final moved = await relocate(mutation);
          final fresh = await store.read({moved}) as ProgressLoaded;
          expect(
            await store.logAttempt(
              Attempt(
                key: (source: moved, id: 'l1'),
                ply: 0,
                fen: Fen.initial,
                played: 'e4',
                expected: 'e4',
                correct: true,
                phase: AttemptPhase.drilling,
                at: DateTime.utc(2026, 9, 29),
              ),
              operation: ProgressOperation(sources: fresh.sources),
            ),
            isA<ProgressWritten>(),
          );
          final reviews = await File(
            p.join(fixture.documents.path, reviewsFile),
          ).readAsLines();
          expect(reviews.where((row) => row.contains(',l1,')), hasLength(1));
          expect(reviews.any((row) => row.contains(moved)), isTrue);
          expect(reviews.any((row) => row.contains(source.path)), isFalse);
          final history = await File(
            p.join(fixture.documents.path, historyFile),
          ).readAsLines();
          expect(history.skip(1).single, contains(moved));
          final after = await store.read({moved}) as ProgressLoaded;
          expect(after.reviews.keys, [(source: moved, id: 'l1')]);
        });
      }
    }

    test('shows a still-failing change under the renamed path', () async {
      final store = TrainingStore(
        fixture.documents,
        support: fixture.support,
        publish: (path, bytes) async {
          if (p.basename(path) == reviewsFile) {
            throw const FileSystemException('sharing violation');
          }
          await replaceFile(path, bytes);
        },
      );
      final line = (source: source.path, id: 'l1');
      final loaded =
          await store.read(
                {source.path},
                observed: {source.path: opened.revision},
              )
              as ProgressLoaded;
      expect(
        await store.write(
          reviews: [(before: null, after: Review(key: line, lineName: 'L1'))],
          operation: ProgressOperation(sources: loaded.sources),
        ),
        isA<ProgressFailed>(),
      );
      final moved = await relocate('rename');
      final fresh = await store.read({moved}) as ProgressLoaded;
      expect(fresh.reviews.keys, [(source: moved, id: 'l1')]);
    });
  });

  test(
    'a training file that cannot be written still fails every change',
    () async {
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
      );
      await Process.run('chmod', ['a-w', documents.path]);
      addTearDown(() => Process.run('chmod', ['u+w', documents.path]));
      expect(await rate(store, accepted()), isA<ProgressFailed>());
      final logged = accepted();
      expect(
        await store.logAttempt(answer, operation: logged),
        isA<ProgressFailed>(),
      );
      await Process.run('chmod', ['u+w', documents.path]);
      expect(
        await store.logAttempt(answer, operation: logged),
        isA<ProgressWritten>(),
      );
      expect(await file(historyFile).readAsLines(), hasLength(2));
      expect(await file(attemptsFile).readAsLines(), hasLength(1));
    },
    skip: !Platform.isLinux || Platform.environment['USER'] == 'root'
        ? 'needs a Linux user without root'
        : false,
  );

  group('an exclusion or a mark the store lands later', () {
    late PendingWrites pending;
    late TrainingProgress progress;
    late TrainingLine line;

    setUp(() async {
      final source = p.join(documents.path, 'repertoires', 'main.pgn');
      await File(source).writeAsString(blackChapter);
      var failures = 1;
      final store = TrainingStore(
        documents,
        support: Directory(p.join(documents.path, 'Support')),
        publish: (path, bytes) async {
          if (p.basename(path) == reviewsFile && failures-- > 0) {
            throw const FileSystemException('sharing violation');
          }
          await replaceFile(path, bytes);
        },
      );
      pending = PendingWrites();
      progress = TrainingProgress(
        files: store,
        loaded: await store.read({source}) as ProgressLoaded,
        time: (now: () => DateTime.utc(2026, 9, 30), jitter: () => 0),
        pendingWrites: pending,
      );
      addTearDown(progress.dispose);
      line = trainingLines(
        parseChapter(name: 'Main', text: blackChapter),
        source: source,
      ).first;
    });

    Future<ProgressWrite> answered() => progress.answered(line, (
      ply: 0,
      fen: line.start,
      played: 'e2e4',
      expected: 'e2e4',
      correct: true,
      phase: AttemptPhase.drilling,
    ));

    for (final command in ['mark', 'exclusion']) {
      Future<ProgressWrite> failed() => command == 'mark'
          ? progress.mark([line], known: true)
          : progress.setExcluded(line, excluded: true);

      test('is no longer asked about: a $command', () async {
        expect(await failed(), isA<ProgressFailed>());
        expect(await answered(), isA<ProgressWritten>());
        expect(await pending.settle(), isNull);
      });

      test('is built on by the next rating: a $command', () async {
        expect(await failed(), isA<ProgressFailed>());
        expect(await answered(), isA<ProgressWritten>());
        expect(
          await progress.finished(line, Rating.easy, clean: true),
          isA<ProgressWritten>(),
        );
        expect(progress.stale, isFalse);
        expect(await pending.settle(), isNull);
        final read =
            await TrainingStore(
                  documents,
                  support: Directory(p.join(documents.path, 'Support')),
                ).read({line.key.source})
                as ProgressLoaded;
        expect(read.reviews[line.key]?.lastRating, Rating.easy.name);
        expect(read.reviews[line.key]?.excluded, command == 'exclusion');
        expect(
          await file(historyFile).readAsLines(),
          hasLength(command == 'mark' ? 3 : 2),
        );
      });
    }
  });

  test('a mark refused by one unreadable row does not hold back the other '
      'lines it named', () async {
    final source = p.join(documents.path, 'repertoires', 'main.pgn');
    await File(source).writeAsString(blackChapter);
    final lines = trainingLines(
      parseChapter(name: 'Main', text: blackChapter),
      source: source,
    );
    final [broken, healthy, ...] = lines;
    // A row that is not one: reads pass over it, so the line looks
    // untrained, and a write naming it is refused for good.
    final bad = '${broken.key.source},${broken.key.id},x,y';
    await file(reviewsFile).writeAsString('$reviewsHeader\n$bad\n');
    final store = TrainingStore(
      documents,
      support: Directory(p.join(documents.path, 'Support')),
    );
    final pending = PendingWrites();
    final progress = TrainingProgress(
      files: store,
      loaded: await store.read({source}) as ProgressLoaded,
      time: (now: () => DateTime.utc(2026, 9, 30), jitter: () => 0),
      pendingWrites: pending,
    );
    addTearDown(progress.dispose);

    expect(
      await progress.mark([broken, healthy], known: true),
      isA<ProgressUnreadable>(),
    );
    expect(
      await progress.finished(healthy, Rating.good, clean: true),
      isA<ProgressWritten>(),
    );
    expect(
      await progress.setExcluded(healthy, excluded: true),
      isA<ProgressWritten>(),
    );
    expect(progress.stale, isFalse);
    // The mark never landed, so its prompt stays.
    expect(await pending.settle(), contains('Lines could not be marked.'));
    final read = await store.read({source}) as ProgressLoaded;
    expect(read.reviews.keys, [healthy.key]);
    expect(read.reviews[healthy.key]?.lastRating, Rating.good.name);
    expect(read.reviews[healthy.key]?.excluded, isTrue);
    expect((await file(reviewsFile).readAsLines())[1], bad);
  });
}
