import 'package:chess_auto_prep/services/eval/cdbdirect_eval_provider.dart';
import 'package:chess_auto_prep/services/eval/cdbdirect_parse.dart';
import 'package:chess_auto_prep/services/eval/eval_canonicalize.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('parseCdbDirectResponse', () {
    test('verbose pipe format', () {
      final r = parseCdbDirectResponse(
        'move:e2e4,score:30,rank:0,note:,winrate:0.515|'
        'move:d2d4,score:25,rank:1,note:,winrate:0.512',
      );
      expect(r, isNotNull);
      expect(r!.cp, 30);
      expect(r.bestMove, 'e2e4');
    });

    test('simple format', () {
      final r = parseCdbDirectResponse('e2e4:30|d2d4:25');
      expect(r?.cp, 30);
    });

    test('eval only', () {
      expect(parseCdbDirectResponse('eval:42')?.cp, 42);
    });

    test('null and unknown', () {
      expect(parseCdbDirectResponse(null), isNull);
      expect(parseCdbDirectResponse(''), isNull);
      expect(parseCdbDirectResponse('unknown'), isNull);
    });
  });

  group('CdbDirectEvalProvider mock', () {
    const startFen = 'rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1';

    final mockData = {
      canonicalizeFen4(startFen):
          'move:e2e4,score:30,rank:0,note:,winrate:0.515',
    };

    test('lookup via override without FFI', () async {
      final provider = CdbDirectEvalProvider(
        path: '/mock/path',
        lookupOverride: (fen) => mockData[fen],
      );
      expect(await provider.init(), isTrue);

      final hit = await provider.lookup(startFen, minDepth: 20);
      expect(hit.isHit, isTrue);
      expect(hit.hit!.cp, 30);

      final miss = await provider.lookup(
        'rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq e3 0 1',
        minDepth: 20,
      );
      expect(miss.hardMiss, isTrue);
    });
  });
}
