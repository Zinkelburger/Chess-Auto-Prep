/// Represents one opponent reply at a trap position.
library;

import '../../../constants/engine_defaults.dart';

enum TrapReplyClass {
  blunder,
  mistake,
  inaccuracy,
  acceptable,
  good,
}

class TrapReply {
  final String san;
  final double probability;
  final int evalAfterCp;
  final TrapReplyClass classification;

  const TrapReply({
    required this.san,
    required this.probability,
    required this.evalAfterCp,
    required this.classification,
  });

  Map<String, dynamic> toJson() => {
        'san': san,
        'probability': probability,
        'eval_after_cp': evalAfterCp,
        'classification': classification.name,
      };

  factory TrapReply.fromJson(Map<String, dynamic> json) => TrapReply(
        san: json['san'] as String,
        probability: (json['probability'] as num).toDouble(),
        evalAfterCp: json['eval_after_cp'] as int,
        classification: TrapReplyClass.values
            .byName(json['classification'] as String? ?? 'good'),
      );

  static TrapReplyClass classify(int diffFromBest) {
    if (diffFromBest >= kTrapBlunderThreshold) return TrapReplyClass.blunder;
    if (diffFromBest >= kTrapMistakeThreshold) return TrapReplyClass.mistake;
    if (diffFromBest >= kTrapInaccuracyThreshold) {
      return TrapReplyClass.inaccuracy;
    }
    if (diffFromBest >= kTrapAcceptableThreshold) {
      return TrapReplyClass.acceptable;
    }
    return TrapReplyClass.good;
  }
}
