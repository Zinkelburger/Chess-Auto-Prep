/// In-memory [ExternalEvalProvider] for unit tests.
library;

import 'eval_canonicalize.dart';
import 'external_eval_provider.dart';

class InMemoryEvalProvider implements ExternalEvalProvider {
  final Map<String, EvalHit> _data;

  InMemoryEvalProvider([Map<String, EvalHit>? seed]) : _data = {...?seed};

  void put(String fen, EvalHit hit) {
    _data[canonicalizeFen4(fen)] = hit;
  }

  @override
  Future<EvalLookupResult> lookup(String fen, {required int minDepth}) async {
    final key = canonicalizeFen4(fen);
    final hit = _data[key];
    if (hit == null) return const EvalLookupResult.hardMiss();
    if (hit.depth < minDepth) return const EvalLookupResult.shallow();
    return EvalLookupResult.found(hit);
  }
}
