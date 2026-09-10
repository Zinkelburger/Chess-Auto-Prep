import 'dart:io';

import 'package:chess_auto_prep/features/repertoire/services/review_progress_repointer.dart';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/storage/io_storage_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late Directory repertoires;
  late IOStorageService storage;
  late RepertoireReviewService review;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('attempt-relocation-');
    repertoires = await Directory(p.join(root.path, 'repertoires')).create();
    storage = IOStorageService(
      documentsRoot: root,
      supportRoot: root,
      repertoiresRoot: repertoires,
    );
    review = RepertoireReviewService(storage: storage);
  });
  tearDown(() => root.delete(recursive: true));

  Future<void> record(String source, String line) => review.recordAttempt(
    repertoireId: source,
    lineId: line,
    moveIndex: 2,
    fen: 'position',
    playedSan: 'Bc4',
    expectedSan: 'Nf3',
    correct: false,
    phase: 'drilling',
  );

  test(
    'moving selected lines keeps their mistakes and leaves other source identities alone',
    () async {
      final from = p.join(repertoires.path, 'Old.pgn');
      final to = p.join(repertoires.path, 'New.pgn');
      final elsewhere = p.join(repertoires.path, 'Other.pgn');
      await record(from, 'moving');
      await record(from, 'staying');
      await record(elsewhere, 'moving');
      final original = (await review.loadAttempts()).first;
      await ReviewProgressRepointer(review: review).repoint(
        from: from,
        movedIdsByPath: {
          to: {'moving'},
        },
      );
      final moved = await review.loadAttempts(repertoireId: to);
      expect(moved, hasLength(1));
      expect(moved.single, {...original, 'repertoireId': to});
      expect(
        (await review.loadAttempts(repertoireId: from)).single['lineId'],
        'staying',
      );
      expect(await review.loadAttempts(repertoireId: elsewhere), hasLength(1));
    },
  );

  test(
    'owned chapter and folder renames preserve discoverable mistake history',
    () async {
      final folder = await Directory(
        p.join(repertoires.path, 'Course'),
      ).create();
      final nested = await Directory(p.join(folder.path, 'Nested')).create();
      final oldChapter = p.join(nested.path, 'Old.pgn');
      final newChapter = p.join(nested.path, 'New.pgn');
      await File(oldChapter).writeAsString('1. e4 e5 *');
      await record(oldChapter, 'line');
      final unrelated = p.join(repertoires.path, 'Course-other', 'Other.pgn');
      await record(unrelated, 'line');

      await storage.renameFile(oldChapter, newChapter);
      expect(await review.loadAttempts(repertoireId: oldChapter), isEmpty);
      expect(await review.loadAttempts(repertoireId: newChapter), hasLength(1));
      final renamed = await storage.renameRepertoireDirectory(
        folder.path,
        'Renamed',
      );
      final renamedChapter = p.join(renamed, 'Nested', 'New.pgn');
      expect(
        await review.loadAttempts(repertoireId: renamedChapter),
        hasLength(1),
      );
      final movedNested = p.join(renamed, 'Moved');
      await storage.moveDirectory(p.join(renamed, 'Nested'), movedNested);
      final finalChapter = p.join(movedNested, 'New.pgn');
      final rows = await review.loadAttempts(repertoireId: finalChapter);
      expect(rows.single['playedSan'], 'Bc4');
      expect(rows.single['expectedSan'], 'Nf3');
      expect(await File(finalChapter).exists(), isTrue);
      expect(await review.loadAttempts(repertoireId: unrelated), hasLength(1));
      expect(await review.loadAttempts(), hasLength(2));
    },
  );
}
