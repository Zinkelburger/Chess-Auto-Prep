import 'dart:io';

import 'package:chess_auto_prep/chess/fen.dart';
import 'package:chess_auto_prep/chess/training/records.dart';
import 'package:chess_auto_prep/chess/training/schedule.dart';
import 'package:chess_auto_prep/storage/document_ref.dart';
import 'package:chess_auto_prep/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/storage/training_store.dart';
import 'package:chess_auto_prep/storage/training_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'store_fixture.dart';

void main() {
  late StoreFixture fixture;
  late TrainingStore progress;
  late DocumentRef source;
  late Opened opened;

  setUp(() async {
    fixture = await StoreFixture.create();
    source = fixture.ref('repertoires/Course/Main.pgn');
    await fixture.put(source, oneGame('1. e4'));
    opened = await fixture.store.open(source) as Opened;
    progress = TrainingStore(fixture.documents, support: fixture.support);
  });
  tearDown(() => fixture.dispose());

  Future<ProgressOperation> accepted() async {
    final loaded =
        await progress.read(
              {source.path},
              observed: {source.path: opened.revision},
            )
            as ProgressLoaded;
    return ProgressOperation(sources: loaded.sources);
  }

  Future<ProgressWrite> write(String kind, ProgressOperation operation) {
    final key = (source: source.path, id: 'first-line');
    if (kind == 'attempt') {
      return progress.logAttempt(
        Attempt(
          key: key,
          ply: 0,
          fen: Fen.initial,
          played: 'e4',
          expected: 'e4',
          correct: true,
          phase: AttemptPhase.learning,
          at: DateTime.utc(2026),
        ),
        operation: operation,
      );
    }
    return progress.write(
      reviews: kind == 'review'
          ? [(before: null, after: Review(key: key, lineName: 'First'))]
          : [],
      streaks: kind == 'streak'
          ? [
              (
                before: null,
                after: MoveStreak(key: key, ply: 0, streak: 1, learned: false),
              ),
            ]
          : [],
      history: kind == 'history'
          ? [
              HistoryRow(
                key: key,
                at: DateTime.utc(2026),
                rating: 'good',
                mistake: false,
                kind: HistoryKind.trainer,
              ),
            ]
          : [],
      operation: operation,
    );
  }

  for (final mutation in ['move', 'folder move', 'delete', 'replace']) {
    for (final kind in ['review', 'streak', 'history', 'attempt']) {
      test(
        'first $kind refuses after $mutation and identical path reuse',
        () async {
          final operation = await accepted();
          if (mutation == 'delete') {
            expect(
              await fixture.store.delete(source, expected: opened.revision),
              isA<Deleted>(),
            );
          } else if (mutation == 'folder move') {
            expect(
              await fixture.store.moveFolder(
                p.dirname(source.path),
                p.join(p.dirname(p.dirname(source.path)), 'Moved'),
              ),
              isA<FolderMoved>(),
            );
          } else {
            expect(
              await fixture.store.rename(
                source,
                'Moved.pgn',
                expected: opened.revision,
              ),
              isA<Moved>(),
            );
          }
          if (mutation == 'replace') {
            expect(
              await fixture.store.create(source, opened.text),
              isA<Created>(),
            );
          }
          expect(await write(kind, operation), isA<ProgressConflict>());
          for (final name in [
            reviewsFile,
            streaksFile,
            historyFile,
            attemptsFile,
          ]) {
            expect(
              await File(p.join(fixture.documents.path, name)).exists(),
              isFalse,
            );
          }
        },
      );
    }
  }

  for (final replacement in [false, true]) {
    for (final kind in ['review', 'streak', 'history', 'attempt']) {
      test(
        'new $kind refuses an external ${replacement ? 'replacement' : 'edit'}',
        () async {
          final operation = await accepted();
          if (replacement) {
            final next = File('${source.path}.new');
            await next.writeAsString(opened.text);
            await next.rename(source.path);
          } else {
            await File(source.path).writeAsString(oneGame('1. d4'));
          }
          expect(await write(kind, operation), isA<ProgressConflict>());
          for (final name in [
            reviewsFile,
            streaksFile,
            historyFile,
            attemptsFile,
          ]) {
            expect(
              File(p.join(fixture.documents.path, name)).existsSync(),
              isFalse,
            );
          }
        },
      );
    }
  }

  test('missing source authority cannot write a first review', () async {
    expect(await write('review', ProgressOperation()), isA<ProgressConflict>());
  });

  test(
    'PGN observation cannot be renewed after identical replacement',
    () async {
      await fixture.store.rename(
        source,
        'Other.pgn',
        expected: opened.revision,
      );
      await fixture.store.create(source, opened.text);
      expect(
        await progress.read(
          {source.path},
          observed: {source.path: opened.revision},
        ),
        isA<ProgressFailed>(),
      );
    },
  );

  test('an accepted write survives a save of its chapter', () async {
    final operation = await accepted();
    final key = (source: source.path, id: 'first-line');
    expect(
      await progress.enqueueWrite(
        history: [
          HistoryRow(
            key: key,
            at: DateTime.utc(2026),
            rating: 'good',
            mistake: false,
            kind: HistoryKind.trainer,
          ),
        ],
        operation: operation,
      ),
      isA<ProgressEnqueued>(),
    );
    expect(
      await fixture.edit(source, oneGame('1. e4 e5'), opened.revision),
      isA<Saved>(),
    );
    expect(await write('history', operation), isA<ProgressWritten>());
  });

  test(
    'an unreadable source fails retryably and the same operation lands later',
    () async {
      final operation = await accepted();
      await Process.run('chmod', ['000', source.path]);
      addTearDown(() => Process.run('chmod', ['644', source.path]));
      expect(await write('review', operation), isA<ProgressFailed>());
      for (final name in [
        reviewsFile,
        streaksFile,
        historyFile,
        attemptsFile,
      ]) {
        expect(
          await File(p.join(fixture.documents.path, name)).exists(),
          isFalse,
        );
      }
      await Process.run('chmod', ['644', source.path]);
      expect(await write('review', operation), isA<ProgressWritten>());
      final lines = await File(
        p.join(fixture.documents.path, reviewsFile),
      ).readAsLines();
      expect(lines.where((line) => line.contains('first-line')), hasLength(1));
      final loaded = await progress.read({source.path}) as ProgressLoaded;
      expect(loaded.reviews.keys.single.id, 'first-line');
    },
    skip: _needsAPlainUser,
  );

  group('a chapter that cannot be read right now', () {
    late DocumentRef other;
    late ProgressLoaded loaded;

    setUp(() async {
      other = fixture.ref('repertoires/Course/Other.pgn');
      await fixture.put(other, oneGame('1. d4'));
      final otherOpened = await fixture.store.open(other) as Opened;
      loaded =
          await progress.read(
                {source.path, other.path},
                observed: {
                  source.path: opened.revision,
                  other.path: otherOpened.revision,
                },
              )
              as ProgressLoaded;
      await Process.run('chmod', ['000', source.path]);
      addTearDown(() => Process.run('chmod', ['644', source.path]));
    });

    ProgressOperation accepted() => ProgressOperation(sources: loaded.sources);
    LineKey inMain(String id) => (source: source.path, id: id);
    LineKey inOther(String id) => (source: other.path, id: id);
    HistoryRow historyOf(LineKey key) => HistoryRow(
      key: key,
      at: DateTime.utc(2026, 9, 30),
      rating: 'good',
      mistake: false,
      kind: HistoryKind.trainer,
    );
    Future<ProgressWrite> first(LineKey key, ProgressOperation operation) =>
        progress.write(
          reviews: [(before: null, after: Review(key: key, lineName: key.id))],
          history: [historyOf(key)],
          operation: operation,
        );
    Future<List<String>> rows(String name) async {
      final file = File(p.join(fixture.documents.path, name));
      return await file.exists() ? file.readAsLines() : <String>[];
    }

    test('holds back only the changes that name it', () async {
      expect(await first(inMain('a1'), accepted()), isA<ProgressFailed>());
      expect(await first(inOther('b1'), accepted()), isA<ProgressWritten>());
      final a2 = accepted();
      expect(await first(inMain('a2'), a2), isA<ProgressFailed>());
      expect(
        await progress.logAttempt(
          Attempt(
            key: inOther('b1'),
            ply: 0,
            fen: Fen.initial,
            played: 'e4',
            expected: 'd4',
            correct: false,
            phase: AttemptPhase.drilling,
            at: DateTime.utc(2026, 9, 30),
          ),
          operation: accepted(),
        ),
        isA<ProgressWritten>(),
      );
      final landed = await rows(reviewsFile);
      expect(landed.where((row) => row.contains(',b1,')), hasLength(1));
      expect(landed.where((row) => row.contains(',a1,')), isEmpty);
      expect(landed.where((row) => row.contains(',a2,')), isEmpty);
      final read = await progress.read({other.path}) as ProgressLoaded;
      expect(read.reviews.keys, [inOther('b1')]);
      expect(read.mistakes.single.played, 'e4');

      await Process.run('chmod', ['644', source.path]);
      expect(await first(inMain('a2'), a2), isA<ProgressWritten>());
      final reviews = await rows(reviewsFile);
      final history = await rows(historyFile);
      for (final id in ['a1', 'a2', 'b1']) {
        expect(reviews.where((row) => row.contains(',$id,')), hasLength(1));
        expect(history.where((row) => row.contains(',$id,')), hasLength(1));
      }
      expect(history, hasLength(4));
      expect(
        history.indexWhere((row) => row.contains(',a1,')),
        lessThan(history.indexWhere((row) => row.contains(',a2,'))),
      );
    });

    test('holds back a change to another chapter that builds on it', () async {
      final main = Review(key: inMain('a1'), lineName: 'a1');
      final marked = Review(key: inOther('b1'), lineName: 'b1');
      expect(
        await progress.write(
          reviews: [(before: null, after: main), (before: null, after: marked)],
          history: [historyOf(main.key), historyOf(marked.key)],
          operation: accepted(),
        ),
        isA<ProgressFailed>(),
      );
      final rated = marked.copyWith(lastRating: 'easy');
      final rating = accepted();
      Future<ProgressWrite> rate() => progress.write(
        reviews: [(before: marked, after: rated)],
        operation: rating,
      );
      expect(await rate(), isA<ProgressFailed>());
      expect(await rows(reviewsFile), isEmpty);

      await Process.run('chmod', ['644', source.path]);
      expect(await rate(), isA<ProgressWritten>());
      final read =
          await progress.read({source.path, other.path}) as ProgressLoaded;
      expect(read.reviews[main.key], main);
      expect(read.reviews[marked.key], rated);
      expect(await rows(historyFile), hasLength(3));
    });
  }, skip: _needsAPlainUser);

  test('a source replaced by a link refuses only its own change', () async {
    final operation = await accepted();
    final target = p.join(fixture.documents.path, 'elsewhere.pgn');
    await File(source.path).rename(target);
    await Link(source.path).create(target);
    expect(await write('review', operation), isA<ProgressConflict>());
    final other = fixture.ref('repertoires/Course/Other.pgn');
    await fixture.put(other, oneGame('1. d4'));
    final loaded = await progress.read({other.path}) as ProgressLoaded;
    final key = (source: other.path, id: 'other-line');
    expect(
      await progress.write(
        reviews: [(before: null, after: Review(key: key, lineName: 'Other'))],
        operation: ProgressOperation(sources: loaded.sources),
      ),
      isA<ProgressWritten>(),
    );
    final lines = await File(
      p.join(fixture.documents.path, reviewsFile),
    ).readAsLines();
    expect(lines.where((line) => line.contains('first-line')), isEmpty);
    expect(lines.where((line) => line.contains('other-line')), hasLength(1));
  }, skip: Platform.isWindows ? 'links need privileges on Windows' : false);

  test('a valid first review still writes', () async {
    expect(await write('review', await accepted()), isA<ProgressWritten>());
  });
}

/// chmod 000 keeps a file from its owner only on Linux and not from root.
final Object _needsAPlainUser =
    !Platform.isLinux || Platform.environment['USER'] == 'root'
    ? 'needs a Linux user without root'
    : false;
