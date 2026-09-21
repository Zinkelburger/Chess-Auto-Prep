import 'dart:math' as math;
import 'dart:typed_data';

import 'maia_mirror.dart';
import 'maia_vocabulary.dart';

/// What a legal move the network produced no number for is scored. Low
/// enough that the softmax makes it zero without making the others NaN.
const double _missingLogit = -9999.0;

/// The network's move output as a share per legal move, most likely first.
///
/// Softmax over the masked entries only, so the moves that can actually be
/// played share the whole 1.0 between them: a position with two legal moves
/// gives two numbers, not 4352. Shares are what the builder needs, because
/// the question is always "how much of the opponent's play goes down this
/// move", never "what is this move worth".
///
/// Worked example: two legal moves with logits 3.0 and 1.0 come back as
/// 0.881 and 0.119, because e^2 : e^0 is about 7.4 : 1.
///
/// When the position was [mirrored] to put White on the move, the names are
/// mirrored back to the board the caller asked about.
Map<String, double> sharesFromLogits(
  List<double> logits,
  Float32List legalMask, {
  required bool mirrored,
  required MaiaVocabulary vocabulary,
}) {
  final indices = <int>[];
  final scores = <double>[];
  for (var i = 0; i < legalMask.length; i++) {
    if (legalMask[i] <= 0) continue;
    indices.add(i);
    scores.add(i < logits.length ? logits[i] : _missingLogit);
  }
  if (indices.isEmpty) return const {};

  // The highest score is taken out before the exponential so a large logit
  // cannot overflow; it cancels in the division.
  final highest = scores.reduce(math.max);
  final weights = [for (final score in scores) math.exp(score - highest)];
  final total = weights.reduce((a, b) => a + b);
  final shares = <MapEntry<String, double>>[
    for (var i = 0; i < indices.length; i++)
      MapEntry(
        _nameOf(vocabulary, indices[i], mirrored: mirrored),
        weights[i] / total,
      ),
  ]..sort((a, b) => b.value.compareTo(a.value));
  return Map.fromEntries(shares);
}

String _nameOf(MaiaVocabulary vocabulary, int index, {required bool mirrored}) {
  final name = vocabulary.nameAt(index);
  return mirrored ? mirrorUci(name) : name;
}
