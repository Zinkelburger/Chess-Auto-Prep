@TestOn('linux')
library;

import 'dart:io';

import 'package:chess_auto_prep/features/repertoires/models/repertoire_recovery_required.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:chess_auto_prep/v2/chess/training/records.dart';
import 'package:chess_auto_prep/v2/chess/training/schedule.dart';
import 'package:chess_auto_prep/v2/storage/training_rows.dart';
import 'package:chess_auto_prep/v2/storage/training_store.dart';
import 'package:chess_auto_prep/v2/storage/training_writes.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory profile;
  late Directory documents;
  late Directory support;
  late File source;
  late ProgressLoaded loaded;

  TrainingStore native({Future<void> Function(TrainingWriteStep)? hook}) =>
      TrainingStore(documents, support: support, trainingHook: hook);
  IOStorageService legacy() =>
      IOStorageService(documentsRoot: documents, supportRoot: support);
  File note() => File(p.join(support.path, 'training-writes', 'rating-1.json'));

  Future<ProgressWrite> rate(TrainingStore store) => store.write(
    reviews: [
      (
        before: null,
        after: Review(
          key: (source: source.path, id: 'line'),
          lineName: 'Line, with comma',
          lastRating: 'good',
          passes: 1,
        ),
      ),
    ],
    history: [
      HistoryRow(
        key: (source: source.path, id: 'line'),
        at: DateTime.utc(2026, 9, 25),
        rating: 'good',
        mistake: false,
        kind: HistoryKind.trainer,
      ),
    ],
    operation: ProgressOperation(id: 'rating-1', sources: loaded.sources),
  );

  setUp(() async {
    profile = await Directory.systemTemp.createTemp('training-coexistence-');
    documents = await Directory(p.join(profile.path, 'Documents')).create();
    support = await Directory(p.join(profile.path, 'Support')).create();
    source = File(p.join(documents.path, 'repertoires', 'Course', 'Main.pgn'));
    await source.parent.create(recursive: true);
    await source.writeAsString('[Event "Line"]\n\n1. e4 *\n');
    loaded = await native().read({source.path}) as ProgressLoaded;
  });
  tearDown(() => profile.delete(recursive: true));

  for (final phase in [TrainingWriteStep.queued, TrainingWriteStep.intent]) {
    test(
      'v1 admits a real completed receipt with native ${phase.name} copy',
      () async {
        String? captured;
        final store = native(
          hook: (step) async {
            if (step == phase) captured = await note().readAsString();
          },
        );
        expect(await rate(store), isA<ProgressWritten>());
        expect(captured, isNotNull);
        final copy = await File(
          p.join(note().parent.path, '.rating-1.json.v2-tmp.previous-123-456'),
        ).writeAsString(captured!);
        expect(await legacy().readFile(source.path), contains('1. e4'));
        expect(
          await legacy().readFile(p.join(documents.path, reviewsFile)),
          contains('Line, with comma'),
        );
        expect(await copy.readAsString(), captured);
        expect(await native().read({source.path}), isA<ProgressLoaded>());
      },
    );
  }

  test(
    'v1 refuses real partial publication until v2 recovery completes',
    () async {
      expect(
        await rate(
          native(
            hook: (step) async {
              if (step == TrainingWriteStep.reviews)
                throw StateError('lost acknowledgement');
            },
          ),
        ),
        isA<ProgressFailed>(),
      );
      final before = await note().readAsBytes();
      await expectLater(
        legacy().readFile(source.path),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      await expectLater(
        legacy().writeFile(p.join(documents.path, reviewsFile), 'overwrite'),
        throwsA(isA<RepertoireRecoveryRequired>()),
      );
      expect(await note().readAsBytes(), before);
      expect(await native().read({source.path}), isA<ProgressLoaded>());
      expect(await legacy().readFile(source.path), contains('1. e4'));
      final rows = File(p.join(documents.path, historyFile));
      expect(await rows.readAsLines(), hasLength(2));
      expect(await rate(native()), isA<ProgressWritten>());
      expect(await rows.readAsLines(), hasLength(2));
    },
  );
}
