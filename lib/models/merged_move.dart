/// One row of merged engine analysis (Stockfish + Maia + DB) for the unified
/// engine pane. Promoted from a private class to enable extracting the row
/// widget. See MAINTAINABILITY_PLAN WS-C/WS-E.
library;

import '../utils/chess_utils.dart';
import '../utils/eval_constants.dart';

class MergedMove {
  final String uci;
  String san = '';
  int? stockfishCp;
  int? stockfishMate;
  List<String> fullPv = []; // Full PV from Stockfish (including this move)
  double? maiaProb; // 0.0 – 1.0
  double? dbProb; // 0 – 100 (percentage)
  int? stockfishRank; // 1-based rank from Stockfish MultiPV

  MergedMove({required this.uci});

  String get evalString =>
      formatEvalDisplay(scoreCp: stockfishCp, scoreMate: stockfishMate);

  int get effectiveCp =>
      effectiveCpFromScores(scoreCp: stockfishCp, scoreMate: stockfishMate);

  bool get hasStockfish => stockfishCp != null || stockfishMate != null;
}
