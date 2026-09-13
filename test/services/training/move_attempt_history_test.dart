import 'dart:async';
import 'package:chess_auto_prep/services/repertoire_review_service.dart';
import 'package:chess_auto_prep/services/storage/storage_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _MemoryStorage implements StorageService {
  final files = <String, String>{};
  @override
  Future<String?> readFile(String path) async => files[path];
  @override
  Future<String> updateFile(
    String path,
    FutureOr<String> Function(String?) update,
  ) async => files[path] = await update(files[path]);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'answers survive a fresh service and correct replay retains the wrong move',
    () async {
      final storage = _MemoryStorage();
      final service = RepertoireReviewService(storage: storage);
      for (final correct in [false, true]) {
        await service.recordAttempt(
          repertoireId: '/book/chapter.pgn',
          lineId: 'line',
          moveIndex: 2,
          fen: 'position',
          playedSan: correct ? 'Nf3' : 'Bc4',
          expectedSan: 'Nf3',
          correct: correct,
          phase: correct ? 'replaying' : 'drilling',
        );
      }
      final reopened = RepertoireReviewService(storage: storage);
      final records = await reopened.loadAttempts(
        repertoireId: '/book/chapter.pgn',
      );
      expect(records, hasLength(2));
      expect(records.first['playedSan'], 'Bc4');
      expect(records.first['correct'], isFalse);
      expect(records.last['correct'], isTrue);
      expect(records.first['moveIndex'], 2);
      expect(
        await reopened.loadAttempts(repertoireId: '/different.pgn'),
        isEmpty,
      );
    },
  );
}
