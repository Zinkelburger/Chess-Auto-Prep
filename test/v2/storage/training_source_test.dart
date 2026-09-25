import 'dart:io';

import 'package:chess_auto_prep/v2/chess/fen.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/storage/document_ref.dart';
import 'package:chess_auto_prep/v2/storage/pgn_document_store.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
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
    expect(
      await fixture.edit(source, oneGame('1. e4 e5'), opened.revision),
      isA<Saved>(),
    );
    expect(await write('history', operation), isA<ProgressWritten>());
  });

  test('a valid first review still writes', () async {
    expect(await write('review', await accepted()), isA<ProgressWritten>());
  });
}
