import 'package:chess_auto_prep/services/eval/eval_canonicalize.dart';
import 'package:chess_auto_prep/services/eval/external_eval_provider.dart';
import 'package:chess_auto_prep/services/eval/in_memory_eval_provider.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const startFen =
      'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1';

  group('InMemoryEvalProvider', () {
    test('returns hit when depth meets minimum', () async {
      final provider = InMemoryEvalProvider()
        ..put(startFen, const EvalHit(cp: 25, depth: 20));

      final result = await provider.lookup(startFen, minDepth: 18);
      expect(result.isHit, isTrue);
      expect(result.hit!.cp, 25);
    });

    test('returns shallow when depth below minimum', () async {
      final provider = InMemoryEvalProvider()
        ..put(startFen, const EvalHit(cp: 10, depth: 12));

      final result = await provider.lookup(startFen, minDepth: 18);
      expect(result.shallow, isTrue);
      expect(result.isHit, isFalse);
    });

    test('returns hard miss for unknown FEN', () async {
      final provider = InMemoryEvalProvider();
      final result = await provider.lookup(startFen, minDepth: 10);
      expect(result.hardMiss, isTrue);
    });

    test('canonicalizes FEN to 4 fields', () async {
      final provider = InMemoryEvalProvider()
        ..put(canonicalizeFen4(startFen), const EvalHit(cp: 5, depth: 20));

      final extended =
          '$startFen 99'; // invalid extra field — key uses 4-field form
      final result = await provider.lookup(extended, minDepth: 10);
      expect(result.isHit, isTrue);
    });
  });
}
