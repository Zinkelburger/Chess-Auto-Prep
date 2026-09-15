/// Turning Maia-3's raw network outputs into a policy and a win probability.
///
/// Pure functions, so the ONNX session can stay out of the tests.
library;

import 'dart:math' as math;
import 'dart:typed_data';

/// Logit given to a legal move the network produced no output for; effectively
/// zero probability after the softmax.
const double _kMissingLogit = -9999.0;

/// White's win probability from the value head's `[loss, draw, win]` logits,
/// which are from the side to move's point of view.
///
/// A draw counts as half a win. Rounded to four decimals so cached values
/// compare exactly. Returns 0.5 when the head is malformed.
double winProbabilityFromWdl(List<double> wdl, {required bool isBlack}) {
  if (wdl.length < 3) return 0.5;

  final maxLogit = math.max(wdl[0], math.max(wdl[1], wdl[2]));
  final expLoss = math.exp(wdl[0] - maxLogit);
  final expDraw = math.exp(wdl[1] - maxLogit);
  final expWin = math.exp(wdl[2] - maxLogit);
  final sum = expLoss + expDraw + expWin;

  var winProb = (expWin + 0.5 * expDraw) / sum;
  if (isBlack) winProb = 1.0 - winProb;

  return (winProb * 10000).round() / 10000;
}

/// Softmax of [logits] over the moves [legalMask] marks, keyed by UCI and
/// ordered most likely first.
///
/// The network always sees a White-to-move board, so for Black the moves are
/// mirrored back with [mirrorMove]. [moveOf] names the vocabulary index.
Map<String, double> policyFromLogits(
  List<double> logits,
  Float32List legalMask, {
  required bool isBlack,
  required String Function(int index) moveOf,
  required String Function(String uci) mirrorMove,
}) {
  final legalIndices = <int>[];
  final legalLogits = <double>[];
  for (var i = 0; i < legalMask.length; i++) {
    if (legalMask[i] <= 0) continue;
    legalIndices.add(i);
    legalLogits.add(i < logits.length ? logits[i] : _kMissingLogit);
  }
  if (legalLogits.isEmpty) return {};

  final maxLogit = legalLogits.reduce(math.max);
  final expLogits = [for (final l in legalLogits) math.exp(l - maxLogit)];
  final sumExp = expLogits.fold(0.0, (a, b) => a + b);

  final entries = <MapEntry<String, double>>[
    for (var i = 0; i < legalIndices.length; i++)
      MapEntry(
        isBlack ? mirrorMove(moveOf(legalIndices[i])) : moveOf(legalIndices[i]),
        expLogits[i] / sumExp,
      ),
  ]..sort((a, b) => b.value.compareTo(a.value));
  return Map.fromEntries(entries);
}
