import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/pgn/chapter.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/chess/training/training_line.dart';
import 'package:chess_auto_prep/v2/features/trainer/progress.dart';
import 'package:chess_auto_prep/v2/storage/atomic_write.dart';
import 'package:chess_auto_prep/v2/storage/pending_writes.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import '../../support/fixtures.dart';

void main() {
  late Directory documents;
  late TrainingStore store;
  late TrainingProgress progress;
  late PendingWrites pending;
  late List<TrainingLine> lines;
  var failing = true;
  var publications = 0;

  File file(String name) => File(p.join(documents.path, name));
  Future<ProgressLoaded> read() async =>
      await store.read({lines.first.key.source}) as ProgressLoaded;

  setUp(() async {
    documents = await Directory.systemTemp.createTemp('training-queue-');
    failing = true;
    publications = 0;
    store = TrainingStore(
      documents,
      support: Directory(p.join(documents.path, 'Support')),
      publish: (path, bytes) async {
        if (!failing || publications == 0) {
          await replaceFile(path, bytes);
          publications++;
        }
        if (failing) throw const FileSystemException('acknowledgement lost');
      },
    );
    await file('Main.pgn').writeAsString(blackChapter);
    lines = trainingLines(
      parseChapter(name: 'Main', text: blackChapter),
      source: p.join(documents.path, 'Main.pgn'),
    );
    pending = PendingWrites();
    progress = TrainingProgress(
      files: store,
      loaded: await read(),
      pendingWrites: pending,
      time: (now: () => DateTime.utc(2026, 9, 24), jitter: () => 0),
    );
  });
  tearDown(() => documents.delete(recursive: true));

  test(
    'mark then exclude materializes the second row after recovery',
    () async {
      expect(
        await progress.mark([lines.first], known: true),
        isA<ProgressFailed>(),
      );
      expect(
        await progress.setExcluded(lines.first, excluded: true),
        isA<ProgressFailed>(),
      );
      expect(
        publications,
        1,
        reason: 'the successor must not replace the prepared files',
      );
      progress.dispose();
      failing = false;
      await pending.retry(store);
      expect(await pending.settle(), isNull);
      final row = (await read()).reviews[lines.first.key]!;
      expect(row.lastRating, 'good');
      expect(row.excluded, isTrue);
      expect(await file(historyFile).readAsLines(), hasLength(2));
    },
  );

  test('a later rating cannot obstruct another line partial commit', () async {
    expect(
      await progress.finished(lines.first, Rating.good, clean: true),
      isA<ProgressFailed>(),
    );
    expect(
      await progress.finished(lines.last, Rating.easy, clean: true),
      isA<ProgressFailed>(),
    );
    expect(publications, 1);
    expect((await read()).reviews.containsKey(lines.last.key), isFalse);
    progress.dispose();
    failing = false;
    await pending.retry(store);
    expect(await pending.settle(), isNull);
    final rows = (await read()).reviews;
    expect(rows[lines.first.key]!.lastRating, 'good');
    expect(rows[lines.last.key]!.lastRating, 'easy');
    expect(await file(historyFile).readAsLines(), hasLength(3));
  });

  test(
    'a later answer waits for an uncertain append to be reconciled',
    () async {
      final answer = (
        ply: 0,
        fen: Fen.initial,
        played: 'd5',
        expected: 'e5',
        correct: false,
        phase: AttemptPhase.drilling,
      );
      expect(
        await progress.answered(lines.first, answer),
        isA<ProgressFailed>(),
      );
      expect(
        await progress.answered(lines.last, answer),
        isA<ProgressFailed>(),
      );
      expect(await file(attemptsFile).readAsLines(), hasLength(1));
      progress.dispose();
      failing = false;
      await pending.retry(store);
      expect(await pending.settle(), isNull);
      expect(await file(attemptsFile).readAsLines(), hasLength(2));
      expect((await read()).mistakes.map((a) => a.key), [
        lines.first.key,
        lines.last.key,
      ]);
    },
  );
}
